#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Playback Workstation Hardening — Init Script
    依據 Windows Hardened Checklist 2026 初始化現場播控主機

.USAGE
    以系統管理員身份執行：
    powershell -ExecutionPolicy Bypass -File init_workstation.ps1 -Username "User" -Password "yourpassword"
#>

param(
    [string]$Username = $env:USERNAME,
    [string]$Password = "",
    [string]$ServiceName = "PlaybackAgent"
)

$ErrorActionPreference = "Continue"
$pass = 0
$fail = 0

function Write-OK   { param($msg) Write-Host "  [OK]   $msg" -ForegroundColor Green;  $script:pass++ }
function Write-FAIL { param($msg) Write-Host "  [FAIL] $msg" -ForegroundColor Red;    $script:fail++ }
function Write-SKIP { param($msg) Write-Host "  [SKIP] $msg" -ForegroundColor Yellow }
function Write-INFO { param($msg) Write-Host "  [INFO] $msg" -ForegroundColor Cyan }

function Ensure-RegPath {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -Path $Path -Force | Out-Null
        Write-INFO "建立 Registry 路徑：$Path"
    }
}

Write-Host "`n========================================" -ForegroundColor White
Write-Host " Playback Workstation Init — 2026"       -ForegroundColor White
Write-Host "========================================`n" -ForegroundColor White

# ── 1. AutoAdminLogon ─────────────────────────────────────────
Write-Host "[1] AutoAdminLogon 設定"
if ($Password -eq "") {
    Write-SKIP "未提供 -Password 參數，跳過 AutoAdminLogon 設定"
} else {
    try {
        $winlogon = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
        Ensure-RegPath $winlogon
        Set-ItemProperty -Path $winlogon -Name "AutoAdminLogon"  -Value "1" -Type String
        Set-ItemProperty -Path $winlogon -Name "DefaultUserName" -Value $Username -Type String
        Set-ItemProperty -Path $winlogon -Name "DefaultPassword" -Value $Password -Type String
        Write-OK "AutoAdminLogon 已設定（User: $Username）"
    } catch {
        Write-FAIL "AutoAdminLogon 設定失敗：$($_.Exception.Message)"
    }
}

# ── 2. 防止 Windows Update 自動重開 ──────────────────────────
Write-Host "`n[2] Windows Update 自動重開保護"
try {
    $wuPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
    Ensure-RegPath $wuPath
    Set-ItemProperty -Path $wuPath -Name "NoAutoRebootWithLoggedOnUsers" -Value 1 -Type DWord
    Set-ItemProperty -Path $wuPath -Name "NoAutoUpdate"                  -Value 1 -Type DWord
    Write-OK "NoAutoRebootWithLoggedOnUsers = 1"
    Write-OK "NoAutoUpdate = 1"
} catch {
    Write-FAIL "Windows Update Policy 設定失敗：$($_.Exception.Message)"
}

# ── 3. 停用 Windows Update Service ───────────────────────────
Write-Host "`n[3] 停用 Windows Update 服務"
foreach ($svc in @("wuauserv", "WaaSMedicSvc")) {
    try {
        $service = Get-Service -Name $svc -ErrorAction SilentlyContinue
        if ($null -eq $service) {
            Write-SKIP "$svc 服務不存在，跳過"
            continue
        }
        Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
        Set-Service  -Name $svc -StartupType Disabled -ErrorAction SilentlyContinue
        Write-OK "$svc 已停止並設為 Disabled"
    } catch {
        # WaaSMedicSvc 受保護可能失敗，記錄但繼續
        Write-SKIP "$svc 停用受限（受系統保護），嘗試 Registry 方式"
        try {
            $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$svc"
            if (Test-Path $regPath) {
                Set-ItemProperty -Path $regPath -Name "Start" -Value 4 -Type DWord
                Write-OK "$svc Registry Start=4 (Disabled)"
            }
        } catch {
            Write-FAIL "$svc 完全無法停用：$($_.Exception.Message)"
        }
    }
}

# ── 4. 防睡眠 / 螢幕保護 ──────────────────────────────────────
Write-Host "`n[4] 防睡眠設定"
try {
    powercfg /change standby-timeout-ac  0 2>$null
    powercfg /change monitor-timeout-ac  0 2>$null
    powercfg /change hibernate-timeout-ac 0 2>$null
    powercfg -h off 2>$null
    Write-OK "待機 / 螢幕逾時 / 休眠 全部設為 0（關閉）"
} catch {
    Write-FAIL "powercfg 設定失敗：$($_.Exception.Message)"
}

# ── 5. 停用鎖定畫面 ───────────────────────────────────────────
Write-Host "`n[5] 停用鎖定畫面"
try {
    $lockPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization"
    Ensure-RegPath $lockPath
    Set-ItemProperty -Path $lockPath -Name "NoLockScreen" -Value 1 -Type DWord
    Write-OK "NoLockScreen = 1"
} catch {
    Write-FAIL "鎖定畫面停用失敗：$($_.Exception.Message)"
}

# ── 6. Active Hours（防止系統自行重啟）────────────────────────
Write-Host "`n[6] Active Hours 設定（08:00 ~ 23:00）"
try {
    $auPath = "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings"
    Ensure-RegPath $auPath
    Set-ItemProperty -Path $auPath -Name "ActiveHoursStart" -Value 8  -Type DWord
    Set-ItemProperty -Path $auPath -Name "ActiveHoursEnd"   -Value 23 -Type DWord
    Write-OK "Active Hours: 08:00 ~ 23:00"
} catch {
    Write-FAIL "Active Hours 設定失敗：$($_.Exception.Message)"
}

# ── 7. 服務故障自恢復（PlaybackAgent）────────────────────────
Write-Host "`n[7] 服務故障自恢復設定"
try {
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($null -eq $svc) {
        Write-SKIP "服務 $ServiceName 不存在，跳過故障恢復設定"
    } else {
        sc.exe failure $ServiceName reset= 86400 actions= restart/5000/restart/10000/restart/30000 | Out-Null
        Write-OK "$ServiceName 故障恢復：restart 5s / 10s / 30s"
    }
} catch {
    Write-FAIL "故障恢復設定失敗：$($_.Exception.Message)"
}

# ── 完成 ─────────────────────────────────────────────────────
Write-Host "`n========================================" -ForegroundColor White
Write-Host " 完成：$pass OK / $fail FAIL"             -ForegroundColor $(if ($fail -eq 0) { "Green" } else { "Yellow" })
Write-Host "========================================`n" -ForegroundColor White
Write-Host "建議執行 check_status.ps1 確認所有設定生效" -ForegroundColor Cyan

if ($fail -gt 0) { exit 1 } else { exit 0 }
