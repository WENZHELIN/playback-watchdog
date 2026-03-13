# 正式環境部署指南

> 更新：2026-03-13  
> 適用：現有測試環境升級為正式播控監控環境

---

## 前置資訊（必填）

在開始之前，請確認以下資訊：

| 項目 | samoi-roy | samoi-4card |
|------|-----------|-------------|
| 播控程式名稱 | `播控程式.exe` | `播控程式.exe` |
| 播控程式完整路徑 | `C:\...\播控程式.exe` | `C:\...\播控程式.exe` |
| 播控程式工作目錄 | `C:\...` | `C:\...` |
| machineId | `samoi-roy` | `samoi-4card` |
| IP | `192.168.1.158` | `192.168.1.235` |

---

## 一、Linux 監控伺服器（Mac mini）

### 狀態確認
```bash
# 確認 monitor 正在跑
curl -s http://localhost:3100/api/v1/nodes | python3 -c "
import sys, json
for n in json.load(sys.stdin):
    print(n['machineId'], '|', n['health'], '| app:', n['appRunning'])
"
```

### 若 monitor 沒在跑，重新啟動
```bash
cd ~/projects/playback-watchdog/linux-monitor
PORT=3100 npm run dev &
```

### 若要正式安裝為開機自啟（systemd）
```bash
cd ~/projects/playback-watchdog/linux-monitor

# 編輯 service 讓 PORT=3100
sudo sed -i 's|ExecStart=|Environment="PORT=3100"\nExecStart=|' /etc/systemd/system/playback-monitor.service

sudo bash scripts/install-systemd.sh
sudo systemctl start playback-monitor
sudo systemctl status playback-monitor
```

---

## 二、samoi-roy（播控主機 A）

> 已裝好最新 agent，只需要換成真實播控程式路徑。

以**系統管理員**身份開啟 PowerShell，執行：

### Step 1：更新程式（取得最新 bug fix）
```powershell
cd C:\PlaybackAgent
git pull
cd windows-agent
npm run build
```

### Step 2：設定真實播控程式路徑
```powershell
# ⬇️ 把下面三行換成真實資訊
$processName = "播控程式.exe"
$processPath = "C:\真實路徑\播控程式.exe"
$workingDir  = "C:\真實路徑"

# 寫入 config
$config = Get-Content "C:\PlaybackAgent\windows-agent\config\agent.config.json" | ConvertFrom-Json
$config.processName = $processName
$config.processPath = $processPath
$config.workingDir  = $workingDir
$config | ConvertTo-Json -Depth 5 | Set-Content "C:\PlaybackAgent\windows-agent\config\agent.config.json" -Encoding UTF8

Write-Host "設定完成：" -ForegroundColor Green
Get-Content "C:\PlaybackAgent\windows-agent\config\agent.config.json" | ConvertFrom-Json | Select-Object machineId, processName, processPath
```

### Step 3：重啟 agent（精準重啟，不影響 OpenClaw）
```powershell
# 找到 port 4010 的 PID 並停止
$pid4010 = (netstat -ano | Select-String ':4010 ') |
    ForEach-Object { ($_ -split '\s+')[-1] } |
    Select-Object -First 1
if ($pid4010 -match '^\d+$') {
    Stop-Process -Id $pid4010 -Force -ErrorAction SilentlyContinue
    Write-Host "舊 agent 已停止（PID $pid4010）" -ForegroundColor Yellow
}

Start-Sleep 2

# 啟動新 agent
Start-Process -FilePath (Get-Command node).Source `
    -ArgumentList "C:\PlaybackAgent\windows-agent\dist\agent.js" `
    -WorkingDirectory "C:\PlaybackAgent\windows-agent" `
    -WindowStyle Hidden

Start-Sleep 3
Write-Host "Agent 已啟動" -ForegroundColor Green
```

### Step 4：驗證
```powershell
$token = (Get-Content "C:\PlaybackAgent\windows-agent\config\agent.config.json" | ConvertFrom-Json).sharedToken
$h = @{Authorization = "Bearer $token"}
Invoke-RestMethod -Uri "http://localhost:4010/api/v1/status" -Headers $h
```

預期輸出：`appRunning: True`（播控程式正在執行中）

---

## 三、samoi-4card（播控主機 B）

> 同樣步驟，但 config 的 machineId 確認是 `samoi-4card`。

以**系統管理員**身份開啟 PowerShell：

```powershell
# Step 1：更新
cd C:\PlaybackAgent
git pull
cd windows-agent
npm run build

# Step 2：設定（⬇️ 換成真實資訊）
$processName = "播控程式.exe"
$processPath = "C:\真實路徑\播控程式.exe"
$workingDir  = "C:\真實路徑"

$config = Get-Content "C:\PlaybackAgent\windows-agent\config\agent.config.json" | ConvertFrom-Json
$config.processName = $processName
$config.processPath = $processPath
$config.workingDir  = $workingDir
$config | ConvertTo-Json -Depth 5 | Set-Content "C:\PlaybackAgent\windows-agent\config\agent.config.json" -Encoding UTF8

# Step 3：重啟 agent
$pid4010 = (netstat -ano | Select-String ':4010 ') |
    ForEach-Object { ($_ -split '\s+')[-1] } | Select-Object -First 1
if ($pid4010 -match '^\d+$') { Stop-Process -Id $pid4010 -Force -EA SilentlyContinue }
Start-Sleep 2
Start-Process -FilePath (Get-Command node).Source `
    -ArgumentList "C:\PlaybackAgent\windows-agent\dist\agent.js" `
    -WorkingDirectory "C:\PlaybackAgent\windows-agent" `
    -WindowStyle Hidden
Start-Sleep 3

# Step 4：驗證
$token = (Get-Content "C:\PlaybackAgent\windows-agent\config\agent.config.json" | ConvertFrom-Json).sharedToken
Invoke-RestMethod -Uri "http://localhost:4010/api/v1/status" -Headers @{Authorization = "Bearer $token"}
```

---

## 四、最終驗證（從 Linux 觀察）

兩台 Windows 都設定完成後，在 Linux（Mac mini）執行：

```bash
# 查看所有節點狀態
watch -n 3 "curl -s http://localhost:3100/api/v1/nodes | python3 -c \"
import sys, json, datetime
for n in json.load(sys.stdin):
    hb = n.get('lastHeartbeatAt')
    ago = str(int((\__import__('time').time()*1000 - hb)/1000)) + 's ago' if hb else 'none'
    print(f\\\"{n['machineId']:15} | {n['health']:12} | app={n['appRunning']} | hb={ago}\\\")
\""
```

**預期看到：**
```
samoi-roy       | healthy      | app=True | hb=3s ago
samoi-4card     | healthy      | app=True | hb=4s ago
```

---

## 五、主機硬化（選做，正式上線建議執行）

確認播控正常後，在每台 Windows 以管理員執行：

```powershell
# 先確認目前狀態
powershell -ExecutionPolicy Bypass -File C:\PlaybackAgent\windows-agent\scripts\hardening\check_status.ps1

# 套用硬化（替換帳號密碼）
powershell -ExecutionPolicy Bypass `
    -File C:\PlaybackAgent\windows-agent\scripts\hardening\init_workstation.ps1 `
    -Username "你的帳號" `
    -Password "你的密碼"
```

硬化內容：停用 Windows Update、停用 PIN、AutoAdminLogon、防睡眠、停鎖定畫面。

---

## 六、開機自動啟動（正式環境必做）

若還未設定，在每台 Windows 以管理員執行：

```powershell
cd C:\PlaybackAgent\windows-agent
powershell -ExecutionPolicy Bypass -File scripts\install-task-scheduler.ps1
```

重開機後 agent 會自動啟動，不需手動介入。

---

## 常見問題

**Q: monitor 顯示 `degraded`，但播控程式確實在跑？**  
→ 確認 `processName` 與 Task Manager 顯示的 exe 名稱完全一致（大小寫不影響，但名稱要對）

**Q: monitor 顯示 `offline`？**  
→ 確認防火牆已開放 port 4010，且 agent 正在跑（`netstat -ano | findstr 4010`）

**Q: 不想讓系統自動重啟播控程式（只監控不動作）？**  
→ 暫時可以把 `maxRestartPer10Min` 設為 0，monitor 只會記錄不會 restart

---

## 部署完成清單

```
[ ] Linux monitor 在線（port 3100）
[ ] samoi-roy config 換成真實播控程式路徑
[ ] samoi-roy agent 重啟成功（/status 回 appRunning=true）
[ ] samoi-4card git pull + config 換成真實路徑
[ ] samoi-4card agent 啟動成功
[ ] Linux monitor 顯示兩台皆 healthy
[ ] Task Scheduler 已設定（開機自動啟動）
[ ] 主機硬化完成（選做）
```
