#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Playback Workstation Hardening — Status Check
    驗證所有 hardening 設定是否如預期生效
#>

$pass = 0; $fail = 0; $warn = 0

function Write-OK   { param($msg) Write-Host "  [OK]   $msg" -ForegroundColor Green;  $script:pass++ }
function Write-FAIL { param($msg) Write-Host "  [FAIL] $msg" -ForegroundColor Red;    $script:fail++ }
function Write-WARN { param($msg) Write-Host "  [WARN] $msg" -ForegroundColor Yellow; $script:warn++ }
function Write-INFO { param($msg) Write-Host "  [INFO] $msg" -ForegroundColor Cyan }

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host " Workstation Status Check — 2026"         -ForegroundColor Cyan
Write-Host " $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# ── 1. AutoAdminLogon ─────────────────────────────────────────
Write-Host "[1] AutoAdminLogon"
try {
    $winlogon = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -ErrorAction Stop
    if ($winlogon.AutoAdminLogon -eq "1") {
        Write-OK "AutoAdminLogon = 1（User: $($winlogon.DefaultUserName)）"
        if ($winlogon.DefaultPassword -ne $null -and $winlogon.DefaultPassword -ne "") {
            Write-OK "DefaultPassword 已設定"
        } else {
            Write-FAIL "DefaultPassword 未設定（將無法自動登入）"
        }
    } else {
        Write-FAIL "AutoAdminLogon = $($winlogon.AutoAdminLogon)（未啟用）"
    }
} catch {
    Write-FAIL "無法讀取 Winlogon：$($_.Exception.Message)"
}

# ── 2. Windows Update Policy ─────────────────────────────────
Write-Host "`n[2] Windows Update Policy"
try {
    $wuPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
    if (Test-Path $wuPath) {
        $wu = Get-ItemProperty $wuPath -ErrorAction SilentlyContinue
        if ($wu.NoAutoRebootWithLoggedOnUsers -eq 1) {
            Write-OK "NoAutoRebootWithLoggedOnUsers = 1"
        } else {
            Write-FAIL "NoAutoRebootWithLoggedOnUsers 未設定（可能自動重開）"
        }
        if ($wu.NoAutoUpdate -eq 1) {
            Write-OK "NoAutoUpdate = 1"
        } else {
            Write-WARN "NoAutoUpdate 未設定（仍會自動更新）"
        }
    } else {
        Write-FAIL "WindowsUpdate\AU Policy 路徑不存在（未設定）"
    }
} catch {
    Write-FAIL "無法讀取 WU Policy：$($_.Exception.Message)"
}

# ── 3. Windows Update 服務狀態 ───────────────────────────────
Write-Host "`n[3] Windows Update 服務"
foreach ($svcName in @("wuauserv", "WaaSMedicSvc")) {
    try {
        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if ($null -eq $svc) {
            Write-INFO "$svcName 服務不存在"
            continue
        }
        $startType = $svc.StartType
        $status    = $svc.Status
        if ($startType -eq "Disabled" -and $status -ne "Running") {
            Write-OK "$svcName：$startType / $status"
        } elseif ($status -eq "Running") {
            Write-WARN "$svcName 仍在執行中（StartType: $startType）"
        } else {
            Write-WARN "$svcName：StartType=$startType / Status=$status（非完全停用）"
        }
    } catch {
        Write-FAIL "$svcName 檢查失敗：$($_.Exception.Message)"
    }
}

# ── 4. 電源設定 ───────────────────────────────────────────────
Write-Host "`n[4] 電源設定"
try {
    $output = powercfg /query SCHEME_CURRENT SUB_SLEEP STANDBYIDLE 2>$null | Out-String
    if ($output -match "Power Setting Index: 0x00000000") {
        Write-OK "待機逾時 = 0（關閉）"
    } else {
        Write-WARN "待機逾時可能不為 0，請手動確認"
    }
    $hibernate = powercfg /a 2>$null | Out-String
    if ($hibernate -match "Hibernate\s+Not Available|Hibernate\s+is not") {
        Write-OK "休眠已關閉"
    } else {
        Write-WARN "休眠可能仍開啟（請確認 powercfg -h off）"
    }
} catch {
    Write-WARN "powercfg 檢查受限：$($_.Exception.Message)"
}

# ── 5. 鎖定畫面 ──────────────────────────────────────────────
Write-Host "`n[5] 鎖定畫面"
try {
    $lockPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization"
    if (Test-Path $lockPath) {
        $lock = Get-ItemProperty $lockPath -ErrorAction SilentlyContinue
        if ($lock.NoLockScreen -eq 1) {
            Write-OK "NoLockScreen = 1（已停用）"
        } else {
            Write-FAIL "NoLockScreen 未設定"
        }
    } else {
        Write-FAIL "Personalization Policy 路徑不存在"
    }
} catch {
    Write-FAIL "鎖定畫面檢查失敗：$($_.Exception.Message)"
}

# ── 6. Active Hours ───────────────────────────────────────────
Write-Host "`n[6] Active Hours"
try {
    $auPath = "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings"
    if (Test-Path $auPath) {
        $au = Get-ItemProperty $auPath -ErrorAction SilentlyContinue
        $start = $au.ActiveHoursStart
        $end   = $au.ActiveHoursEnd
        if ($start -ne $null -and $end -ne $null) {
            Write-OK "Active Hours: $($start):00 ~ $($end):00"
            if ($start -le 8 -and $end -ge 22) {
                Write-OK "範圍足夠寬（覆蓋主要工作時段）"
            } else {
                Write-WARN "Active Hours 範圍較窄，可能在非 active 時段被重啟"
            }
        } else {
            Write-WARN "Active Hours 未明確設定（Windows 自動管理）"
        }
    } else {
        Write-WARN "Active Hours 路徑不存在"
    }
} catch {
    Write-FAIL "Active Hours 檢查失敗：$($_.Exception.Message)"
}

# ── 7. PlaybackAgent 服務或 Task Scheduler ────────────────────
Write-Host "`n[7] PlaybackAgent 啟動設定"
# 檢查 Task Scheduler
try {
    $task = Get-ScheduledTask -TaskName "PlaybackAgent" -ErrorAction SilentlyContinue
    if ($task) {
        $state = $task.State
        Write-OK "Task Scheduler 'PlaybackAgent' 存在（State: $state）"
    } else {
        # 檢查 Windows Service
        $svc = Get-Service -Name "PlaybackAgent" -ErrorAction SilentlyContinue
        if ($svc) {
            Write-OK "Windows Service 'PlaybackAgent'（StartType: $($svc.StartType), Status: $($svc.Status)）"
        } else {
            Write-WARN "PlaybackAgent 未以 Task Scheduler 或 Service 方式設定"
        }
    }
} catch {
    Write-FAIL "PlaybackAgent 檢查失敗：$($_.Exception.Message)"
}

# ── 8. 磁碟空間 ──────────────────────────────────────────────
Write-Host "`n[8] 磁碟空間（C:）"
try {
    $disk = Get-PSDrive C | Select-Object Used, Free
    $freeGB = [math]::Round($disk.Free / 1GB, 1)
    if ($freeGB -gt 10) {
        Write-OK "C: 剩餘空間：$($freeGB) GB"
    } elseif ($freeGB -gt 5) {
        Write-WARN "C: 剩餘空間偏低：$($freeGB) GB"
    } else {
        Write-FAIL "C: 剩餘空間不足：$($freeGB) GB（請清理）"
    }
} catch {
    Write-FAIL "磁碟空間檢查失敗：$($_.Exception.Message)"
}

# ── 9. 系統上次開機時間 ───────────────────────────────────────
Write-Host "`n[9] 系統資訊"
try {
    $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    $uptime = [math]::Round(((Get-Date) - $boot).TotalHours, 1)
    Write-INFO "上次開機：$($boot.ToString('yyyy-MM-dd HH:mm:ss'))（運行 $uptime 小時）"
    $osName = (Get-CimInstance Win32_OperatingSystem).Caption
    Write-INFO "OS：$osName"
} catch {
    Write-WARN "系統資訊讀取失敗"
}

# ── 總結 ──────────────────────────────────────────────────────
Write-Host "`n========================================" -ForegroundColor Cyan
$color = if ($fail -gt 0) { "Red" } elseif ($warn -gt 0) { "Yellow" } else { "Green" }
Write-Host " 結果：$pass OK  $warn WARN  $fail FAIL" -ForegroundColor $color
Write-Host "========================================`n" -ForegroundColor Cyan

if ($fail -gt 0) { exit 2 }
elseif ($warn -gt 0) { exit 1 }
else { exit 0 }
