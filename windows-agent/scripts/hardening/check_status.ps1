#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Playback Workstation Hardening — Status Check
    驗證所有 hardening 設定是否如預期生效
    exit code：0=全部 OK，1=有 WARN，2=有 FAIL
#>

$pass = 0; $fail = 0; $warn = 0

function Write-OK   { param($msg) Write-Host "  [OK]   $msg" -ForegroundColor Green;  $script:pass++ }
function Write-FAIL { param($msg) Write-Host "  [FAIL] $msg" -ForegroundColor Red;    $script:fail++ }
function Write-WARN { param($msg) Write-Host "  [WARN] $msg" -ForegroundColor Yellow; $script:warn++ }
function Write-INFO { param($msg) Write-Host "  [INFO] $msg" -ForegroundColor Cyan }

Write-Host "`n=============================================" -ForegroundColor Cyan
Write-Host "  Workstation Status Check — 2026"             -ForegroundColor Cyan
Write-Host "  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"   -ForegroundColor Cyan
Write-Host "=============================================`n" -ForegroundColor Cyan

# ── 1. Windows Hello PIN ──────────────────────────────────────
Write-Host "[1] Windows Hello PIN / 生物辨識"
try {
    $passport = Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\PassportForWork" -EA SilentlyContinue
    if ($passport -and $passport.Enabled -eq 0) {
        Write-OK "PassportForWork Enabled = 0（Windows Hello 已停用）"
    } else {
        Write-WARN "Windows Hello 未停用（可能干擾 AutoAdminLogon）"
    }

    $sysPolicy = Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -EA SilentlyContinue
    if ($sysPolicy -and $sysPolicy.AllowDomainPINLogon -eq 0) {
        Write-OK "AllowDomainPINLogon = 0"
    } else {
        Write-WARN "AllowDomainPINLogon 未設定為 0"
    }

    $wbio = Get-Service "WbioSrvc" -EA SilentlyContinue
    if ($wbio -and $wbio.StartType -eq "Disabled") {
        Write-OK "WbioSrvc（生物辨識）已停用"
    } else {
        $st = if ($wbio) { $wbio.StartType } else { "不存在" }
        Write-WARN "WbioSrvc StartType = $st"
    }
} catch {
    Write-FAIL "Windows Hello 狀態檢查失敗：$($_.Exception.Message)"
}

# ── 2. AutoAdminLogon ─────────────────────────────────────────
Write-Host "`n[2] AutoAdminLogon"
try {
    $wl = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -EA Stop
    if ($wl.AutoAdminLogon -eq "1") {
        Write-OK "AutoAdminLogon = 1（User: $($wl.DefaultUserName)）"
        if ($wl.DefaultPassword -and $wl.DefaultPassword -ne "") {
            Write-OK "DefaultPassword 已設定"
        } else {
            Write-FAIL "DefaultPassword 未設定（重開機後需手動輸入密碼）"
        }
    } else {
        Write-FAIL "AutoAdminLogon = $($wl.AutoAdminLogon)（開機自動登入未啟用）"
    }
} catch {
    Write-FAIL "Winlogon 讀取失敗：$($_.Exception.Message)"
}

# ── 3. Windows Update 停用狀態 ───────────────────────────────
Write-Host "`n[3] Windows Update 停用"

# Policy Check
try {
    $au = Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -EA SilentlyContinue
    if ($au) {
        if ($au.NoAutoUpdate -eq 1)   { Write-OK "NoAutoUpdate = 1" }
        else                          { Write-FAIL "NoAutoUpdate 未設定" }
        if ($au.AUOptions -eq 1)      { Write-OK "AUOptions = 1（Never check）" }
        else                          { Write-WARN "AUOptions = $($au.AUOptions)（建議設為 1）" }
    } else {
        Write-FAIL "Windows Update AU Policy 路徑不存在"
    }
} catch {
    Write-FAIL "WU Policy 讀取失敗：$($_.Exception.Message)"
}

# WU Server Block
try {
    $wuPol = Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -EA SilentlyContinue
    if ($wuPol -and $wuPol.WUServer -match "127\.0\.0\.1") {
        Write-OK "WUServer 已指向 127.0.0.1（封鎖）"
    } else {
        Write-WARN "WUServer 未封鎖（WUServer = $($wuPol.WUServer)）"
    }
} catch {
    Write-WARN "WU Server 設定讀取失敗"
}

# Service Status
foreach ($svcName in @("wuauserv", "WaaSMedicSvc", "UsoSvc", "DoSvc")) {
    $svc = Get-Service -Name $svcName -EA SilentlyContinue
    if ($null -eq $svc) { Write-INFO "$svcName 不存在"; continue }
    if ($svc.StartType -eq "Disabled" -and $svc.Status -ne "Running") {
        Write-OK "$svcName：Disabled / $($svc.Status)"
    } elseif ($svc.Status -eq "Running") {
        Write-WARN "$svcName 仍在執行中（StartType: $($svc.StartType)）"
    } else {
        Write-WARN "$svcName：StartType=$($svc.StartType) / Status=$($svc.Status)"
    }
}

# ── 4. 防止自動重開 ───────────────────────────────────────────
Write-Host "`n[4] 防止自動重開"
try {
    $wuAu = Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -EA SilentlyContinue
    if ($wuAu -and $wuAu.NoAutoRebootWithLoggedOnUsers -eq 1) {
        Write-OK "NoAutoRebootWithLoggedOnUsers = 1"
    } else {
        Write-FAIL "NoAutoRebootWithLoggedOnUsers 未設定"
    }

    $au2 = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -EA SilentlyContinue
    if ($au2) {
        $s = $au2.ActiveHoursStart; $e = $au2.ActiveHoursEnd
        if ($s -ne $null -and $e -ne $null) {
            Write-OK "Active Hours: $($s):00 ~ $($e):00"
        } else {
            Write-WARN "Active Hours 未設定"
        }
    } else {
        Write-WARN "Active Hours 路徑不存在"
    }
} catch {
    Write-FAIL "自動重開檢查失敗：$($_.Exception.Message)"
}

# ── 5. 電源設定 ───────────────────────────────────────────────
Write-Host "`n[5] 電源設定"
try {
    $standby = powercfg /query SCHEME_CURRENT SUB_SLEEP STANDBYIDLE 2>$null | Out-String
    if ($standby -match "Power Setting Index: 0x00000000") {
        Write-OK "待機逾時 = 0（關閉）"
    } else {
        Write-WARN "待機逾時可能不為 0"
    }
    $hib = powercfg /a 2>$null | Out-String
    if ($hib -match "Hibernate\s+(is not supported|has been disabled|Not Available|ist nicht verfügbar)") {
        Write-OK "休眠已關閉"
    } else {
        Write-WARN "休眠可能仍開啟"
    }
} catch {
    Write-WARN "powercfg 查詢受限"
}

# ── 6. 鎖定畫面 ──────────────────────────────────────────────
Write-Host "`n[6] 鎖定畫面"
try {
    $lk = Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization" -EA SilentlyContinue
    if ($lk -and $lk.NoLockScreen -eq 1) {
        Write-OK "NoLockScreen = 1（已停用）"
    } else {
        Write-FAIL "NoLockScreen 未設定"
    }
} catch {
    Write-FAIL "鎖定畫面狀態讀取失敗：$($_.Exception.Message)"
}

# ── 7. PlaybackAgent 啟動設定 ────────────────────────────────
Write-Host "`n[7] PlaybackAgent"
$task  = Get-ScheduledTask -TaskName "PlaybackAgent" -EA SilentlyContinue
$svc   = Get-Service       -Name      "PlaybackAgent" -EA SilentlyContinue
$procs = Get-Process       -Name      "node"          -EA SilentlyContinue

if ($task) {
    Write-OK "Task Scheduler 'PlaybackAgent'（State: $($task.State)）"
} elseif ($svc) {
    Write-OK "Windows Service 'PlaybackAgent'（$($svc.StartType) / $($svc.Status)）"
} else {
    Write-WARN "PlaybackAgent Task / Service 未找到"
}

$nodeCount = ($procs | Measure-Object).Count
if ($nodeCount -gt 0) {
    Write-OK "node.exe 正在執行中（$nodeCount 個進程）"
} else {
    Write-WARN "未偵測到 node.exe（Agent 可能未啟動）"
}

# ── 8. 磁碟空間 ──────────────────────────────────────────────
Write-Host "`n[8] 磁碟空間（C:）"
try {
    $disk   = Get-PSDrive C
    $freeGB = [math]::Round($disk.Free / 1GB, 1)
    $totalGB = [math]::Round(($disk.Used + $disk.Free) / 1GB, 1)
    if ($freeGB -gt 10)     { Write-OK   "C: $freeGB GB 可用 / $totalGB GB" }
    elseif ($freeGB -gt 5)  { Write-WARN "C: 剩餘空間偏低 $freeGB GB / $totalGB GB" }
    else                    { Write-FAIL "C: 空間不足 $freeGB GB / $totalGB GB" }
} catch {
    Write-FAIL "磁碟空間讀取失敗"
}

# ── 9. 系統資訊 ───────────────────────────────────────────────
Write-Host "`n[9] 系統資訊"
try {
    $os     = Get-CimInstance Win32_OperatingSystem
    $boot   = $os.LastBootUpTime
    $uptime = [math]::Round(((Get-Date) - $boot).TotalHours, 1)
    Write-INFO "OS：$($os.Caption)"
    Write-INFO "上次開機：$($boot.ToString('yyyy-MM-dd HH:mm:ss'))（運行 $uptime 小時）"
    Write-INFO "主機名稱：$env:COMPUTERNAME"
    $ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notmatch '^(127|169)' } | Select-Object -First 1).IPAddress
    Write-INFO "IP：$ip"
} catch {
    Write-WARN "系統資訊讀取失敗"
}

# ── 總結 ──────────────────────────────────────────────────────
Write-Host "`n=============================================" -ForegroundColor Cyan
$color = if ($fail -gt 0) { "Red" } elseif ($warn -gt 0) { "Yellow" } else { "Green" }
Write-Host "  結果：$pass OK  $warn WARN  $fail FAIL" -ForegroundColor $color
Write-Host "=============================================`n" -ForegroundColor Cyan

if ($fail -gt 0) { exit 2 }
elseif ($warn -gt 0) { exit 1 }
else { exit 0 }
