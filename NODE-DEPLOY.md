# 播控主機（Node）部署指南

> 適用：每一台 Windows 播控主機  
> 執行身份：**系統管理員**  
> 完成時間：約 10 分鐘

---

## 前置資訊（每台主機填寫一份）

```
machineId        = playback-a          ← 每台唯一，不可重複
displayName      = Playback A（1F）
Linux 伺服器 IP  = 192.168.1.84
本機 Token       = （從 Linux nodes.json 取得，每台不同）
播控程式名稱     = yourapp.exe
播控程式路徑     = C:\YourApp\yourapp.exe
播控程式目錄     = C:\YourApp
Windows 帳號     = （本機帳號，非 PIN）
Windows 密碼     = （本機密碼）
```

---

## Step 1：確認環境

以**系統管理員**開啟 PowerShell，執行：

```powershell
# 確認管理員身份
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole("Administrator")
Write-Host ("管理員：" + $isAdmin)

# 確認 Node.js
node -v        # 需要 v18 以上

# 確認 Git
git --version

# 確認本機 IP
(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notmatch '^(127|169)' } | Select-Object -First 1).IPAddress
```

Node.js 或 Git 未安裝：
- Node.js → https://nodejs.org （安裝時勾選 **Add to PATH**）
- Git → https://git-scm.com

---

## Step 2：下載程式

```powershell
# 若 C:\PlaybackAgent 已存在（更新）
if (Test-Path C:\PlaybackAgent) {
    cd C:\PlaybackAgent; git pull
} else {
    git clone https://github.com/WENZHELIN/playback-watchdog.git C:\PlaybackAgent
}

cd C:\PlaybackAgent\windows-agent
npm install
npm run build

Write-Host "Build 完成" -ForegroundColor Green
```

---

## Step 3：寫入設定

```powershell
# ⬇️ 填入這台主機的資訊
$cfg = @{
    machineId            = "playback-a"
    displayName          = "Playback A（1F）"
    listenHost           = "0.0.0.0"
    listenPort           = 4010
    allowedServerIp      = "192.168.1.84"       # Linux 伺服器 IP
    sharedToken          = "填入此台的 token"    # 從 Linux nodes.json 取得
    processName          = "yourapp.exe"
    processPath          = "C:\\YourApp\\yourapp.exe"
    workingDir           = "C:\\YourApp"
    heartbeatTarget      = "http://192.168.1.84:3100/api/v1/heartbeat"
    heartbeatIntervalMs  = 5000
    localCheckIntervalMs = 3000
    restartCooldownMs    = 30000
}

$cfg | ConvertTo-Json -Depth 5 |
    Set-Content "C:\PlaybackAgent\windows-agent\config\agent.config.json" -Encoding UTF8

Write-Host "設定完成" -ForegroundColor Green
```

---

## Step 4：開放防火牆

```powershell
Remove-NetFirewallRule -DisplayName "PlaybackAgent" -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName "PlaybackAgent" -Direction Inbound `
    -Protocol TCP -LocalPort 4010 -Action Allow -Profile Any
Write-Host "防火牆 Port 4010 已開放" -ForegroundColor Green
```

---

## Step 5：設定開機自動啟動

```powershell
# 確認 node 路徑
$nodePath = (Get-Command node).Source
Write-Host "Node 路徑：$nodePath"

# 移除舊工作（若有）
Unregister-ScheduledTask -TaskName "PlaybackAgent" -Confirm:$false -ErrorAction SilentlyContinue

# 建立 Task（SYSTEM 帳號、開機即啟動）
$action    = New-ScheduledTaskAction -Execute $nodePath `
                 -Argument "C:\PlaybackAgent\windows-agent\dist\agent.js" `
                 -WorkingDirectory "C:\PlaybackAgent\windows-agent"
$trigger   = New-ScheduledTaskTrigger -AtStartup
$settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable `
                 -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
                 -ExecutionTimeLimit (New-TimeSpan -Hours 0)
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest

Register-ScheduledTask -TaskName "PlaybackAgent" `
    -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force

Write-Host "Task Scheduler 設定完成" -ForegroundColor Green
```

---

## Step 6：立即啟動

```powershell
Start-Process -FilePath (Get-Command node).Source `
    -ArgumentList "C:\PlaybackAgent\windows-agent\dist\agent.js" `
    -WorkingDirectory "C:\PlaybackAgent\windows-agent" `
    -WindowStyle Hidden

Start-Sleep 3

# 驗證
$token = (Get-Content "C:\PlaybackAgent\windows-agent\config\agent.config.json" |
          ConvertFrom-Json).sharedToken
try {
    $r = Invoke-RestMethod -Uri "http://localhost:4010/api/v1/status" `
             -Headers @{Authorization = "Bearer $token"}
    Write-Host "Agent 啟動成功：" -ForegroundColor Green
    $r | ConvertTo-Json
} catch {
    Write-Host "Agent 未回應，請檢查 node 進程" -ForegroundColor Red
}
```

---

## Step 7：主機硬化（正式環境必做）

```powershell
# 先確認目前狀態
powershell -ExecutionPolicy Bypass `
    -File C:\PlaybackAgent\windows-agent\scripts\hardening\check_status.ps1

# 套用硬化（填入帳號密碼）
powershell -ExecutionPolicy Bypass `
    -File C:\PlaybackAgent\windows-agent\scripts\hardening\init_workstation.ps1 `
    -Username "你的帳號" -Password "你的密碼"
```

硬化內容：停用 Windows Update、停用 PIN / Windows Hello、AutoAdminLogon（開機自動登入）、防睡眠、停鎖定畫面。

> ⚠️ 執行後需**重開機**讓設定生效

---

## Step 8：重開機後驗證

重開機後，在 **Linux 伺服器**確認此台回線：

```bash
curl -s http://localhost:3100/api/v1/nodes/playback-a | python3 -c "
import sys, json
n = json.load(sys.stdin)
print('health     :', n['health'])
print('appRunning :', n['appRunning'])
print('agent      :', n['agentReachable'])
"
```

預期：
```
health     : healthy
appRunning : True
agent      : True
```

---

## 完成清單

```
[ ] Node.js v18+ 已安裝
[ ] git clone / pull 完成，npm run build 成功
[ ] agent.config.json 填入正確 processPath 和 token
[ ] 防火牆 port 4010 已開放
[ ] Task Scheduler PlaybackAgent 已建立（SYSTEM / AtStartup）
[ ] agent 啟動並通過 /status 驗證（appRunning: true）
[ ] 主機硬化完成（check_status 無 FAIL）
[ ] 重開機後 Linux monitor 顯示 healthy
```

---

## 若需要更新（非首次部署）

```powershell
# 停掉舊 agent（精準停 port 4010）
$pid4010 = (netstat -ano | Select-String ':4010 ') |
    ForEach-Object { ($_ -split '\s+')[-1] } | Select-Object -First 1
if ($pid4010 -match '^\d+$') { Stop-Process -Id $pid4010 -Force -EA SilentlyContinue }

# 更新並重啟
cd C:\PlaybackAgent; git pull
cd windows-agent; npm run build
Start-Process -FilePath (Get-Command node).Source `
    -ArgumentList "C:\PlaybackAgent\windows-agent\dist\agent.js" `
    -WorkingDirectory "C:\PlaybackAgent\windows-agent" `
    -WindowStyle Hidden
```
