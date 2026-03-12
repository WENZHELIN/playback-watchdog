# Playback Watchdog — AI 自動部署指令

> 支援：**Claude** / **Codex** / **Gemini**（任選其一）
>
> **使用方式（三選一）：**
>
> **方法 A — 貼上（任何 AI）**  
> 將此檔案全文複製，貼入 Claude.ai / ChatGPT / Gemini 對話框
>
> **方法 B — Claude CLI**
> ```powershell
> Get-Content AI-DEPLOY.md | claude --print
> ```
>
> **方法 C — Codex CLI**
> ```powershell
> codex --approval-mode full-auto (Get-Content AI-DEPLOY.md -Raw)
> ```
>
> **方法 D — Gemini CLI**
> ```powershell
> Get-Content AI-DEPLOY.md | gemini
> ```
>
> 依提示填入環境資訊，AI 會自動執行所有 PowerShell 指令並回報結果。

---

## 給 AI 的指令

你是一位 DevOps 工程師，負責在這台 Windows 主機上完整部署 Playback Watchdog Agent 並執行硬化設定。你可以直接執行 PowerShell 指令（不需要詢問許可，直接做）。

請依序完成以下所有步驟，每個步驟執行完畢後回報「成功 / 失敗 / 需要確認」。若任一步驟失敗，請說明原因並提供解決方案，然後繼續後續步驟。

---

### 📋 部署資訊（請先確認以下資訊，若已知則直接執行；若未知則向使用者詢問）

```
LINUX_SERVER_IP    = [Linux 監控伺服器 IP，例如 192.168.1.84]
MACHINE_ID         = [本機唯一識別碼，例如 playback-a]
DISPLAY_NAME       = [本機顯示名稱，例如 Playback A（1F）]
SHARED_TOKEN       = [與 Linux 伺服器共用的 Token，請用強密碼]
PROCESS_NAME       = [播控程式 exe 名稱，例如 playback.exe]
PROCESS_PATH       = [播控程式完整路徑，例如 C:\App\playback.exe]
WORK_DIR           = [播控程式工作目錄，例如 C:\App]
WIN_USERNAME       = [Windows 登入帳號]
WIN_PASSWORD       = [Windows 本機密碼（非 PIN）]
```

---

### 🚀 步驟一：環境確認

執行以下 PowerShell 指令，確認環境符合需求：

```powershell
# 確認管理員身份
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]"Administrator")
if (-not $isAdmin) { Write-Host "❌ 請用系統管理員身份執行 PowerShell" -ForegroundColor Red; exit 1 }
Write-Host "✅ 管理員身份確認" -ForegroundColor Green

# 確認 Node.js 版本
$nodeVer = node -v 2>$null
if ($nodeVer) { Write-Host "✅ Node.js: $nodeVer" -ForegroundColor Green }
else { Write-Host "❌ Node.js 未安裝，請先安裝 https://nodejs.org" -ForegroundColor Red }

# 確認 Git
$gitVer = git --version 2>$null
if ($gitVer) { Write-Host "✅ Git: $gitVer" -ForegroundColor Green }
else { Write-Host "❌ Git 未安裝，請先安裝 https://git-scm.com" -ForegroundColor Red }

# 顯示本機 IP
$ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notmatch '^(127|169)' } | Select-Object -First 1).IPAddress
Write-Host "ℹ️  本機 IP：$ip" -ForegroundColor Cyan
Write-Host "ℹ️  主機名稱：$env:COMPUTERNAME" -ForegroundColor Cyan
```

若 Node.js 或 Git 未安裝，請先安裝後再繼續。

---

### 🚀 步驟二：Clone Repo 並 Build

```powershell
# 若 C:\PlaybackAgent 已存在，先更新；否則 clone
if (Test-Path "C:\PlaybackAgent") {
    Write-Host "ℹ️  目錄已存在，執行 git pull..." -ForegroundColor Cyan
    cd C:\PlaybackAgent
    git pull
} else {
    Write-Host "ℹ️  Clone repo..." -ForegroundColor Cyan
    git clone https://github.com/WENZHELIN/playback-watchdog.git C:\PlaybackAgent
}

cd C:\PlaybackAgent\windows-agent
Write-Host "ℹ️  安裝相依套件..." -ForegroundColor Cyan
npm install

Write-Host "ℹ️  Build TypeScript..." -ForegroundColor Cyan
npm run build
if ($LASTEXITCODE -eq 0) {
    Write-Host "✅ Build 成功" -ForegroundColor Green
} else {
    Write-Host "❌ Build 失敗" -ForegroundColor Red
}
```

---

### 🚀 步驟三：寫入 Agent 設定

**請將下方的 `{}` 替換為實際值後執行：**

```powershell
$config = @{
    machineId             = "{MACHINE_ID}"
    displayName           = "{DISPLAY_NAME}"
    listenHost            = "0.0.0.0"
    listenPort            = 4010
    allowedServerIp       = "{LINUX_SERVER_IP}"
    sharedToken           = "{SHARED_TOKEN}"
    processName           = "{PROCESS_NAME}"
    processPath           = "{PROCESS_PATH}"
    workingDir            = "{WORK_DIR}"
    heartbeatTarget       = "http://{LINUX_SERVER_IP}:3100/api/v1/heartbeat"
    heartbeatIntervalMs   = 5000
    localCheckIntervalMs  = 3000
    restartCooldownMs     = 30000
}
$config | ConvertTo-Json -Depth 5 | Set-Content "C:\PlaybackAgent\windows-agent\config\agent.config.json" -Encoding UTF8
Write-Host "✅ 設定寫入完成" -ForegroundColor Green
Write-Host "--- 設定內容 ---"
Get-Content "C:\PlaybackAgent\windows-agent\config\agent.config.json"
```

---

### 🚀 步驟四：開放防火牆 Port 4010

```powershell
# 移除舊規則（若有）
Remove-NetFirewallRule -DisplayName "PlaybackAgent" -ErrorAction SilentlyContinue

# 新增規則
New-NetFirewallRule `
    -DisplayName "PlaybackAgent" `
    -Direction Inbound `
    -Protocol TCP `
    -LocalPort 4010 `
    -Action Allow `
    -Profile Any

Write-Host "✅ 防火牆 Port 4010 已開放" -ForegroundColor Green
```

---

### 🚀 步驟五：安裝 Task Scheduler（開機自動啟動）

```powershell
# 確認 node.exe 路徑
$nodePath = (Get-Command node).Source
Write-Host "ℹ️  Node.js 路徑：$nodePath" -ForegroundColor Cyan

# 移除舊 Task（若有）
Unregister-ScheduledTask -TaskName "PlaybackAgent" -Confirm:$false -ErrorAction SilentlyContinue

# 建立新 Task（SYSTEM 帳號，AtStartup，自動重試 3 次）
$action   = New-ScheduledTaskAction -Execute $nodePath `
              -Argument "C:\PlaybackAgent\windows-agent\dist\agent.js" `
              -WorkingDirectory "C:\PlaybackAgent\windows-agent"
$trigger  = New-ScheduledTaskTrigger -AtStartup
$settings = New-ScheduledTaskSettingsSet `
              -StartWhenAvailable `
              -RestartCount 3 `
              -RestartInterval (New-TimeSpan -Minutes 1) `
              -ExecutionTimeLimit (New-TimeSpan -Hours 0)  # 無時間限制
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest

Register-ScheduledTask -TaskName "PlaybackAgent" `
    -Action $action -Trigger $trigger `
    -Settings $settings -Principal $principal -Force

$task = Get-ScheduledTask -TaskName "PlaybackAgent"
Write-Host "✅ Task Scheduler 已建立（State: $($task.State)）" -ForegroundColor Green
```

---

### 🚀 步驟六：立即啟動 Agent

```powershell
# 啟動（不重開機）
Start-Process -FilePath (Get-Command node).Source `
    -ArgumentList "C:\PlaybackAgent\windows-agent\dist\agent.js" `
    -WorkingDirectory "C:\PlaybackAgent\windows-agent" `
    -WindowStyle Hidden

Start-Sleep 3

# 驗證是否有回應
try {
    $token  = (Get-Content "C:\PlaybackAgent\windows-agent\config\agent.config.json" | ConvertFrom-Json).sharedToken
    $headers = @{Authorization = "Bearer $token"}
    $resp    = Invoke-WebRequest -Uri "http://localhost:4010/api/v1/status" -Headers $headers -UseBasicParsing -TimeoutSec 5
    Write-Host "✅ Agent 啟動成功：$($resp.Content)" -ForegroundColor Green
} catch {
    Write-Host "❌ Agent 未回應：$($_.Exception.Message)" -ForegroundColor Red
    Write-Host "ℹ️  嘗試查看 node 進程：$(Get-Process node -EA SilentlyContinue | Measure-Object | Select-Object -ExpandProperty Count) 個" -ForegroundColor Cyan
}
```

---

### 🚀 步驟七：Windows 主機硬化

```powershell
# 執行硬化腳本（傳入登入帳號密碼）
powershell -ExecutionPolicy Bypass `
    -File "C:\PlaybackAgent\windows-agent\scripts\hardening\init_workstation.ps1" `
    -Username "{WIN_USERNAME}" `
    -Password "{WIN_PASSWORD}"
```

---

### 🚀 步驟八：驗證所有設定

```powershell
# 硬化狀態檢查
powershell -ExecutionPolicy Bypass `
    -File "C:\PlaybackAgent\windows-agent\scripts\hardening\check_status.ps1"
```

---

### 🚀 步驟九：從 Linux 確認 heartbeat（交叉驗證）

請在 **Linux 監控伺服器**上執行以下指令，確認 Windows 主機已出現在監控清單中：

```bash
# 查詢所有節點狀態
curl -s http://localhost:3100/api/v1/nodes | python3 -m json.tool

# 查詢特定節點（{MACHINE_ID} 替換為實際值）
curl -s http://localhost:3100/api/v1/nodes/{MACHINE_ID} | python3 -c "
import sys,json,datetime
n=json.load(sys.stdin)
ts=n.get('lastHeartbeatAt')
print('health      :', n['health'])
print('appRunning  :', n['appRunning'])
print('appPid      :', n['appPid'])
print('lastHeartbeat:', datetime.datetime.fromtimestamp(ts/1000).strftime('%H:%M:%S') if ts else 'none')
"
```

預期看到 `health: healthy`。

---

### 🚀 步驟十：由 Linux 主導執行完整部署驗證（含重開機）

**在 Linux 監控伺服器上執行**（需先完成 Windows Agent 部署）：

```bash
cd /opt/playback-monitor   # 或 linux-monitor clone 位置

# 完整測試（含自動重開機 + 等待回線 + 回線後驗證）
python3 tests/deploy-orchestration-test.py \
  --monitor http://localhost:3100 \
  --machine {MACHINE_ID} \
  --agent   http://{WINDOWS_IP}:4010 \
  --token   {SHARED_TOKEN}

# 快速驗證模式（跳過重開機，只驗功能）
python3 tests/deploy-orchestration-test.py \
  --monitor http://localhost:3100 \
  --machine {MACHINE_ID} \
  --agent   http://{WINDOWS_IP}:4010 \
  --token   {SHARED_TOKEN} \
  --no-reboot
```

**Orchestration Test 7 個 Phase：**
- P1：Pre-reboot 基礎驗證（Monitor + Agent + Heartbeat）
- P2：App Crash → Auto Restart（重開機前）
- P3：觸發遠端重開機（`/api/v1/admin/reboot`）
- P4：等待主機斷線 → 回線（Ping 監控）
- P5：Task Scheduler 自動啟動驗證（Agent 自動上線）
- P6：重開機後完整功能驗證
- P7：重開機後 App Crash → Auto Restart

預期：所有 Phase 顯示 ✅，exit code 0

---

## ✅ 部署完成清單

執行完所有步驟後，Claude 請輸出以下清單，勾選每項結果：

```
[ ] 環境確認（Node.js + Git 已安裝）
[ ] Clone + Build 成功
[ ] agent.config.json 已寫入正確設定
[ ] 防火牆 Port 4010 已開放
[ ] Task Scheduler PlaybackAgent 已建立（SYSTEM / AtStartup）
[ ] Agent 啟動並通過 /status 驗證
[ ] Windows 主機硬化完成（check_status 無 FAIL）
[ ] Linux 監控伺服器確認 health: healthy
[ ] Live 測試通過
```

---

## 🔧 若需要更新（非首次部署）

```powershell
# 停止舊 Agent
$pid4010 = (netstat -ano | Select-String ':4010 ') | ForEach-Object { ($_ -split '\s+')[-1] } | Select-Object -First 1
if ($pid4010 -match '^\d+$') { Stop-Process -Id $pid4010 -Force -EA SilentlyContinue }

# 更新程式
cd C:\PlaybackAgent
git pull
cd windows-agent
npm install
npm run build

# 重新啟動
Start-Process -FilePath (Get-Command node).Source `
    -ArgumentList "C:\PlaybackAgent\windows-agent\dist\agent.js" `
    -WorkingDirectory "C:\PlaybackAgent\windows-agent" `
    -WindowStyle Hidden

Start-Sleep 2
Write-Host "更新完成"
```
