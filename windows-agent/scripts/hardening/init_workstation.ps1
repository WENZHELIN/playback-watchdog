#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Playback Workstation Hardening — Init Script
    適用：Windows 10/11 現場播控主機

.USAGE
    powershell -ExecutionPolicy Bypass -File init_workstation.ps1 -Username "User" -Password "yourpassword"

.PARAMS
    -Username   Windows 登入帳號（用於 AutoAdminLogon）
    -Password   Windows 登入密碼（必須是本機密碼，不是 PIN 也不是 Microsoft 帳號密碼）
    -ServiceName  播控服務名稱（預設 PlaybackAgent，用於故障自恢復設定）
#>

param(
    [string]$Username = $env:USERNAME,
    [string]$Password = "",
    [string]$ServiceName = "PlaybackAgent"
)

$ErrorActionPreference = "Continue"
$pass = 0; $fail = 0; $warn = 0

function Write-OK   { param($msg) Write-Host "  [OK]   $msg" -ForegroundColor Green;  $script:pass++ }
function Write-FAIL { param($msg) Write-Host "  [FAIL] $msg" -ForegroundColor Red;    $script:fail++ }
function Write-WARN { param($msg) Write-Host "  [WARN] $msg" -ForegroundColor Yellow; $script:warn++ }
function Write-INFO { param($msg) Write-Host "  [INFO] $msg" -ForegroundColor Cyan }
function Write-SKIP { param($msg) Write-Host "  [SKIP] $msg" -ForegroundColor DarkGray }

function Ensure-RegPath {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -Path $Path -Force | Out-Null
        Write-INFO "建立 Registry 路徑：$Path"
    }
}

function Disable-ServiceSafe {
    param([string]$Name)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $svc) { Write-SKIP "$Name 服務不存在"; return }
    try {
        Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue
        Set-Service  -Name $Name -StartupType Disabled -ErrorAction Stop
        Write-OK "$Name 已停止並設為 Disabled"
    } catch {
        # 受保護的服務（如 WaaSMedicSvc）改用 Registry
        Write-WARN "$Name 用 sc.exe 停用受阻，改寫 Registry Start=4"
        try {
            $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$Name"
            if (Test-Path $regPath) {
                Set-ItemProperty -Path $regPath -Name "Start" -Value 4 -Type DWord
                Write-OK "$Name Registry Start=4 (Disabled)"
            } else {
                Write-FAIL "$Name Registry 路徑不存在"
            }
        } catch {
            Write-FAIL "$Name 完全無法停用：$($_.Exception.Message)"
        }
    }
}

Write-Host "`n=============================================" -ForegroundColor White
Write-Host "  Playback Workstation Hardening — Init"       -ForegroundColor White
Write-Host "  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"   -ForegroundColor White
Write-Host "=============================================`n" -ForegroundColor White

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 1. 停用 Windows Hello PIN（AutoAdminLogon 需要純密碼登入）
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Write-Host "[1] 停用 Windows Hello PIN / 生物辨識"
try {
    # 停用 Passport for Work（Windows Hello）
    $passportPath = "HKLM:\SOFTWARE\Policies\Microsoft\PassportForWork"
    Ensure-RegPath $passportPath
    Set-ItemProperty -Path $passportPath -Name "Enabled" -Value 0 -Type DWord
    Write-OK "PassportForWork Enabled = 0（Windows Hello 停用）"

    # 停用 PIN 便捷登入
    $systemPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"
    Ensure-RegPath $systemPath
    Set-ItemProperty -Path $systemPath -Name "AllowDomainPINLogon" -Value 0 -Type DWord
    Write-OK "AllowDomainPINLogon = 0"

    # 停用 Windows Hello 生物辨識服務
    Disable-ServiceSafe "WbioSrvc"

    Write-WARN "PIN 設定需要重開機後生效；請先確認帳號已設定本機密碼（非 PIN）"
} catch {
    Write-FAIL "Windows Hello 停用失敗：$($_.Exception.Message)"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 2. AutoAdminLogon（開機自動登入）
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Write-Host "`n[2] AutoAdminLogon 設定"
if ($Password -eq "") {
    Write-SKIP "未提供 -Password，跳過 AutoAdminLogon（手動設定：netplwiz 或直接寫 Registry）"
} else {
    try {
        $winlogon = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
        Ensure-RegPath $winlogon
        Set-ItemProperty -Path $winlogon -Name "AutoAdminLogon"  -Value "1"       -Type String
        Set-ItemProperty -Path $winlogon -Name "DefaultUserName" -Value $Username  -Type String
        Set-ItemProperty -Path $winlogon -Name "DefaultPassword" -Value $Password  -Type String
        # 清除 AutoLogonCount（若存在會限制自動登入次數）
        Remove-ItemProperty -Path $winlogon -Name "AutoLogonCount" -ErrorAction SilentlyContinue
        Write-OK "AutoAdminLogon = 1（User: $Username）"
        Write-WARN "DefaultPassword 以明文存於 Registry，僅適合固定現場設備"
    } catch {
        Write-FAIL "AutoAdminLogon 設定失敗：$($_.Exception.Message)"
    }
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 3. 停用 Windows Update（多層封鎖）
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Write-Host "`n[3] 停用 Windows Update（多層封鎖）"

# Layer A：Group Policy Registry
try {
    $wuPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
    Ensure-RegPath $wuPath
    Set-ItemProperty -Path $wuPath -Name "NoAutoRebootWithLoggedOnUsers" -Value 1 -Type DWord
    Set-ItemProperty -Path $wuPath -Name "NoAutoUpdate"                  -Value 1 -Type DWord
    Set-ItemProperty -Path $wuPath -Name "AUOptions"                     -Value 1 -Type DWord  # 1 = Never check
    Write-OK "Group Policy：NoAutoUpdate=1, AUOptions=1(Never check)"
} catch {
    Write-FAIL "WU Group Policy 設定失敗：$($_.Exception.Message)"
}

# Layer B：停用 Update Orchestrator Policy
try {
    $uoPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
    Ensure-RegPath $uoPath
    Set-ItemProperty -Path $uoPath -Name "DisableWindowsUpdateAccess" -Value 1 -Type DWord
    Set-ItemProperty -Path $uoPath -Name "WUServer"       -Value "https://127.0.0.1" -Type String
    Set-ItemProperty -Path $uoPath -Name "WUStatusServer" -Value "https://127.0.0.1" -Type String
    Set-ItemProperty -Path $uoPath -Name "UpdateServiceUrlAlternate" -Value "" -Type String
    Write-OK "WU Server 指向 127.0.0.1（封鎖對外更新）"
} catch {
    Write-FAIL "WU Server 設定失敗：$($_.Exception.Message)"
}

# Layer C：停用相關服務（4 個）
foreach ($svc in @("wuauserv", "WaaSMedicSvc", "UsoSvc", "DoSvc")) {
    Disable-ServiceSafe $svc
}

# Layer D：停用 Delivery Optimization
try {
    $doPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization"
    Ensure-RegPath $doPath
    Set-ItemProperty -Path $doPath -Name "DODownloadMode" -Value 100 -Type DWord  # 100 = Bypass
    Write-OK "Delivery Optimization DODownloadMode = 100（Bypass）"
} catch {
    Write-FAIL "Delivery Optimization 設定失敗：$($_.Exception.Message)"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 4. 防止自動重開（Active Hours + Registry）
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Write-Host "`n[4] 防止系統自動重開"
try {
    # Active Hours 08:00 ~ 23:00
    $auPath = "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings"
    Ensure-RegPath $auPath
    Set-ItemProperty -Path $auPath -Name "ActiveHoursStart"            -Value 8  -Type DWord
    Set-ItemProperty -Path $auPath -Name "ActiveHoursEnd"              -Value 23 -Type DWord
    Set-ItemProperty -Path $auPath -Name "IsExpedited"                 -Value 0  -Type DWord
    Set-ItemProperty -Path $auPath -Name "SmartActiveHoursState"       -Value 0  -Type DWord
    Write-OK "Active Hours: 08:00 ~ 23:00，Smart Active Hours 關閉"
} catch {
    Write-FAIL "Active Hours 設定失敗：$($_.Exception.Message)"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 5. 防睡眠 / 螢幕保護
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Write-Host "`n[5] 防睡眠設定"
try {
    powercfg /change standby-timeout-ac   0 2>$null
    powercfg /change monitor-timeout-ac   0 2>$null
    powercfg /change hibernate-timeout-ac 0 2>$null
    powercfg /change disk-timeout-ac      0 2>$null
    powercfg -h off 2>$null
    Write-OK "所有電源逾時 = 0，休眠關閉"
} catch {
    Write-FAIL "powercfg 設定失敗：$($_.Exception.Message)"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 6. 停用鎖定畫面
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Write-Host "`n[6] 停用鎖定畫面"
try {
    $lockPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization"
    Ensure-RegPath $lockPath
    Set-ItemProperty -Path $lockPath -Name "NoLockScreen" -Value 1 -Type DWord
    Write-OK "NoLockScreen = 1"
} catch {
    Write-FAIL "鎖定畫面設定失敗：$($_.Exception.Message)"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 7. 服務故障自恢復
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Write-Host "`n[7] PlaybackAgent 故障自恢復"
try {
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($null -eq $svc) {
        # 嘗試 Task Scheduler
        $task = Get-ScheduledTask -TaskName $ServiceName -ErrorAction SilentlyContinue
        if ($task) {
            Write-OK "$ServiceName 以 Task Scheduler 部署，系統自帶重啟機制"
        } else {
            Write-SKIP "服務 / Task $ServiceName 不存在，跳過"
        }
    } else {
        sc.exe failure $ServiceName reset= 86400 actions= restart/5000/restart/10000/restart/30000 | Out-Null
        Write-OK "$ServiceName 故障恢復：5s / 10s / 30s 依序重啟"
    }
} catch {
    Write-FAIL "故障恢復設定失敗：$($_.Exception.Message)"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 完成
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Write-Host "`n=============================================" -ForegroundColor White
$color = if ($fail -gt 0) { "Yellow" } elseif ($warn -gt 0) { "Cyan" } else { "Green" }
Write-Host "  完成：$pass OK  $warn WARN  $fail FAIL"  -ForegroundColor $color
Write-Host "=============================================`n" -ForegroundColor White

if ($warn -gt 0) {
    Write-Host "注意事項：" -ForegroundColor Yellow
    Write-Host "  - PIN 停用需重開機後生效"
    Write-Host "  - Windows Update 服務若被系統還原，重開機後再跑一次本腳本"
    Write-Host "  - 建議執行 check_status.ps1 確認所有設定"
}

if ($fail -gt 0) { exit 2 }
elseif ($warn -gt 0) { exit 1 }
else { exit 0 }
