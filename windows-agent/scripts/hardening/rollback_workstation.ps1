#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Playback Workstation Hardening — Rollback Script
    還原 init_workstation.ps1 所有設定，恢復 Windows 預設值
#>

$ErrorActionPreference = "Continue"
$pass = 0; $fail = 0

function Write-OK   { param($msg) Write-Host "  [OK]   $msg" -ForegroundColor Green;  $script:pass++ }
function Write-FAIL { param($msg) Write-Host "  [FAIL] $msg" -ForegroundColor Red;    $script:fail++ }
function Write-SKIP { param($msg) Write-Host "  [SKIP] $msg" -ForegroundColor Yellow }

Write-Host "`n========================================" -ForegroundColor Yellow
Write-Host " Playback Workstation ROLLBACK — 2026"    -ForegroundColor Yellow
Write-Host "========================================`n" -ForegroundColor Yellow

# ── 1. 移除 AutoAdminLogon ────────────────────────────────────
Write-Host "[1] 移除 AutoAdminLogon"
try {
    $winlogon = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
    Remove-ItemProperty -Path $winlogon -Name "AutoAdminLogon"  -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $winlogon -Name "DefaultPassword" -ErrorAction SilentlyContinue
    Set-ItemProperty    -Path $winlogon -Name "AutoAdminLogon"  -Value "0" -Type String
    Write-OK "AutoAdminLogon 已停用，DefaultPassword 已移除"
} catch {
    Write-FAIL "AutoAdminLogon 還原失敗：$($_.Exception.Message)"
}

# ── 2. 還原 Windows Update Policy ────────────────────────────
Write-Host "`n[2] 還原 Windows Update Policy"
try {
    $wuPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
    if (Test-Path $wuPath) {
        Remove-ItemProperty -Path $wuPath -Name "NoAutoRebootWithLoggedOnUsers" -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $wuPath -Name "NoAutoUpdate"                  -ErrorAction SilentlyContinue
        Write-OK "Windows Update Policy 已還原（移除限制）"
    } else {
        Write-SKIP "Policy 路徑不存在，無需還原"
    }
} catch {
    Write-FAIL "Windows Update Policy 還原失敗：$($_.Exception.Message)"
}

# ── 3. 重新啟用 Windows Update 服務 ──────────────────────────
Write-Host "`n[3] 重新啟用 Windows Update 服務"
foreach ($svc in @("wuauserv", "WaaSMedicSvc")) {
    try {
        $service = Get-Service -Name $svc -ErrorAction SilentlyContinue
        if ($null -eq $service) {
            Write-SKIP "$svc 服務不存在，跳過"
            continue
        }
        Set-Service -Name $svc -StartupType Manual -ErrorAction SilentlyContinue
        Write-OK "$svc 設回 Manual 啟動"
    } catch {
        Write-FAIL "$svc 還原失敗：$($_.Exception.Message)"
    }
}

# ── 4. 還原電源設定（Windows 預設值）─────────────────────────
Write-Host "`n[4] 還原電源設定"
try {
    powercfg /change standby-timeout-ac   30 2>$null  # 預設 30 分鐘
    powercfg /change monitor-timeout-ac   15 2>$null  # 預設 15 分鐘
    powercfg /change hibernate-timeout-ac 180 2>$null # 預設 3 小時
    powercfg -h on 2>$null
    Write-OK "電源設定已還原（待機 30min，螢幕 15min，休眠 180min）"
} catch {
    Write-FAIL "電源設定還原失敗：$($_.Exception.Message)"
}

# ── 5. 還原鎖定畫面 ───────────────────────────────────────────
Write-Host "`n[5] 還原鎖定畫面"
try {
    $lockPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization"
    if (Test-Path $lockPath) {
        Remove-ItemProperty -Path $lockPath -Name "NoLockScreen" -ErrorAction SilentlyContinue
        Write-OK "NoLockScreen 已移除（鎖定畫面恢復）"
    } else {
        Write-SKIP "Personalization Policy 路徑不存在，無需還原"
    }
} catch {
    Write-FAIL "鎖定畫面還原失敗：$($_.Exception.Message)"
}

# ── 6. 還原 Active Hours ──────────────────────────────────────
Write-Host "`n[6] 還原 Active Hours"
try {
    $auPath = "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings"
    if (Test-Path $auPath) {
        Remove-ItemProperty -Path $auPath -Name "ActiveHoursStart" -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $auPath -Name "ActiveHoursEnd"   -ErrorAction SilentlyContinue
        Write-OK "Active Hours 已移除（回 Windows 自動管理）"
    } else {
        Write-SKIP "Active Hours 路徑不存在，無需還原"
    }
} catch {
    Write-FAIL "Active Hours 還原失敗：$($_.Exception.Message)"
}

# ── 完成 ─────────────────────────────────────────────────────
Write-Host "`n========================================" -ForegroundColor Yellow
Write-Host " 還原完成：$pass OK / $fail FAIL"         -ForegroundColor $(if ($fail -eq 0) { "Green" } else { "Yellow" })
Write-Host "========================================`n" -ForegroundColor Yellow
Write-Host "重開機後生效" -ForegroundColor Cyan

if ($fail -gt 0) { exit 1 } else { exit 0 }
