# Playback Watchdog — 部署手冊

> 版本：v1.0.0 | 更新：2026-03-13  
> 適用：1 台 Linux 監控伺服器 + N 台 Windows 播控主機

---

## 目錄

1. [系統概覽](#系統概覽)
2. [前置條件](#前置條件)
3. [🤖 Claude 自動部署（推薦）](#-claude-自動部署推薦)
4. [Linux 監控伺服器部署](#linux-監控伺服器部署)
5. [Windows 播控主機部署](#windows-播控主機部署)
6. [設定說明](#設定說明)
7. [Windows 主機硬化](#windows-主機硬化)
8. [驗證系統運作](#驗證系統運作)
9. [API 參考](#api-參考)
10. [常見問題](#常見問題)

---

## 系統概覽

```
┌─────────────────────────────┐         ┌──────────────────────────────┐
│  Linux 監控伺服器 :3100      │         │  Windows 播控主機 A :4010    │
│  linux-monitor              │         │  windows-agent               │
│                             │  ping   │                              │
│  Ping Loop ─────────────────┼────────>│                              │
│  Status Poller ─────────────┼─GET────>│ GET  /api/v1/status          │
│  Restart Dispatcher ────────┼─POST───>│ POST /api/v1/restart         │
│                             │         │                              │
│  POST /api/v1/heartbeat <───┼─POST────│ Heartbeat (每 5 秒)          │
│  GET  /api/v1/nodes         │         └──────────────────────────────┘
│  GET  /api/v1/nodes/:id     │
│                             │         ┌──────────────────────────────┐
│  (每個節點各自獨立迴圈)       │         │  Windows 播控主機 B :4010    │
└─────────────────────────────┘         └──────────────────────────────┘
```

**運作邏輯（簡化）：**
1. Windows Agent 每 5 秒推送 heartbeat 給 Linux 伺服器
2. Linux 伺服器同時每 3 秒 ping 主機 + 查詢 /status
3. 偵測到播控程式不在（appRunning=false）或 heartbeat 超時 → 自動發送 restart 指令
4. Windows Agent 接收 restart → taskkill + spawn 新進程

### 健康狀態說明

| 狀態 | 條件 | 動作 |
|------|------|------|
| `healthy` | ping 通 + heartbeat 正常 + app 在跑 | 無 |
| `degraded` | ping 通 + (heartbeat 超時 或 app 未跑) | 自動重啟（有節流保護） |
| `recovering` | 已發送 restart，等待確認 | 輪詢 /status，30 秒 timeout |
| `agent_down` | ping 通 + /status 失敗 | 僅警示，不重啟 |
| `offline` | ping 失敗 | 僅記錄，不重啟 |

---

## 🤖 Claude 自動部署（推薦）

**場域端 Windows 主機可以直接用 Claude 完成所有部署步驟，無需逐行手動執行。**

### 使用方式

1. 在 Windows 主機上開啟瀏覽器，前往 [claude.ai](https://claude.ai)
2. 開啟 **[CLAUDE-DEPLOY.md](./CLAUDE-DEPLOY.md)**，複製全文貼入 Claude 對話
3. Claude 會自動詢問必要資訊（伺服器 IP、Token 等）並依序執行 10 個部署步驟
4. 完成後 Claude 會輸出清單，確認每項是否成功

**CLAUDE-DEPLOY.md 涵蓋：**
- 環境確認 → Clone/Build → 設定寫入 → 防火牆 → Task Scheduler → 啟動驗證 → 主機硬化 → Live 測試

> 若場域已安裝 Claude Code CLI，也可以：  
> `cat CLAUDE-DEPLOY.md | claude --print`

---

## 前置條件

### Linux 伺服器

- OS：Ubuntu 20.04+ / Debian 11+ / 任何現代 Linux
- Node.js：v18+（建議 v20+）
- 網路：與所有 Windows 主機在同一 LAN，或路由可達
- 防火牆：開放 port 3100（inbound，若有其他服務使用可透過 `PORT` 環境變數修改）

```bash
# 確認 Node.js 版本
node -v   # 需要 v18 以上

# 開放防火牆（ufw 範例）
sudo ufw allow 3100/tcp
```

### Windows 播控主機（每台）

- OS：Windows 10 / Windows 11
- Node.js：v18+（建議 v20+，從 https://nodejs.org 安裝）
- Git：v2.x+
- 防火牆：開放 port 4010（inbound）
- 執行身份：安裝腳本需要**系統管理員**權限

```powershell
# 確認 Node.js 版本
node -v

# 開放防火牆
New-NetFirewallRule -DisplayName "PlaybackAgent" -Direction Inbound -Protocol TCP -LocalPort 4010 -Action Allow
```

---

## Linux 監控伺服器部署

### 步驟 1：Clone 並安裝

```bash
git clone https://github.com/WENZHELIN/playback-watchdog.git
cd playback-watchdog/linux-monitor
npm install
```

### 步驟 2：設定節點清單

編輯 `config/nodes.json`，為每台 Windows 主機加一筆記錄：

```json
[
  {
    "machineId": "playback-a",
    "displayName": "Playback A（1F）",
    "hostIp": "192.168.1.100",
    "agentBaseUrl": "http://192.168.1.100:4010",
    "heartbeatTimeoutMs": 10000,
    "pingIntervalMs": 3000,
    "statusPollIntervalMs": 3000,
    "recoveringTimeoutMs": 30000,
    "maxRestartPer10Min": 3,
    "restartCooldownMs": 60000,
    "token": "your-strong-secret-token-a"
  },
  {
    "machineId": "playback-b",
    "displayName": "Playback B（2F）",
    "hostIp": "192.168.1.101",
    "agentBaseUrl": "http://192.168.1.101:4010",
    "heartbeatTimeoutMs": 10000,
    "pingIntervalMs": 3000,
    "statusPollIntervalMs": 3000,
    "recoveringTimeoutMs": 30000,
    "maxRestartPer10Min": 3,
    "restartCooldownMs": 60000,
    "token": "your-strong-secret-token-b"
  }
]
```

> ⚠️ **token 請自行產生強密碼**，每台主機使用不同的 token。  
> 產生方式：`openssl rand -hex 32`

### 步驟 3：Build

```bash
npm run build
```

### 步驟 4a：開發環境直接啟動

```bash
PORT=3100 npm run dev
```

### 步驟 4b：正式環境安裝為 systemd 服務（開機自動啟動）

```bash
# 必須在 linux-monitor 目錄下執行
chmod +x scripts/install-systemd.sh
sudo bash scripts/install-systemd.sh
```

腳本會：
- 複製程式到 `/opt/playback-monitor`
- 建立 systemd service `playback-monitor`
- 設定開機自動啟動

```bash
# 啟動服務
sudo systemctl start playback-monitor

# 查看狀態
sudo systemctl status playback-monitor

# 查看即時 log
sudo journalctl -u playback-monitor -f
```

> ⚠️ **注意**：`install-systemd.sh` 預設 port 為 3000。若需要 3100（因為 3000 被其他服務佔用），安裝後編輯 `/etc/systemd/system/playback-monitor.service`，在 `ExecStart` 前加一行：
> ```
> Environment="PORT=3100"
> ```
> 再執行 `sudo systemctl daemon-reload && sudo systemctl restart playback-monitor`

---

## Windows 播控主機部署

**每台 Windows 主機各自執行一次以下步驟。**

### 步驟 1：Clone repo

以**系統管理員**身份開啟 PowerShell，執行：

```powershell
git clone https://github.com/WENZHELIN/playback-watchdog.git C:\PlaybackAgent
cd C:\PlaybackAgent\windows-agent
npm install
npm run build
```

### 步驟 2：設定 Agent

編輯 `C:\PlaybackAgent\windows-agent\config\agent.config.json`：

```json
{
  "machineId": "playback-a",
  "displayName": "Playback A（1F）",
  "listenHost": "0.0.0.0",
  "listenPort": 4010,
  "allowedServerIp": "192.168.1.84",
  "sharedToken": "your-strong-secret-token-a",
  "processName": "your-app.exe",
  "processPath": "C:\\YourApp\\your-app.exe",
  "workingDir": "C:\\YourApp",
  "heartbeatTarget": "http://192.168.1.84:3100/api/v1/heartbeat",
  "heartbeatIntervalMs": 5000,
  "localCheckIntervalMs": 3000,
  "restartCooldownMs": 30000
}
```

**必填欄位說明：**

| 欄位 | 說明 | 範例 |
|------|------|------|
| `machineId` | 必須與 Linux `nodes.json` 中的 `machineId` **完全相同** | `"playback-a"` |
| `allowedServerIp` | Linux 伺服器 IP（安全驗證用） | `"192.168.1.84"` |
| `sharedToken` | 必須與 Linux `nodes.json` 中的 `token` **完全相同** | `"your-secret"` |
| `processName` | 播控程式的 exe 名稱（大小寫不敏感） | `"playback.exe"` |
| `processPath` | 播控程式完整路徑 | `"C:\\App\\playback.exe"` |
| `workingDir` | 播控程式工作目錄 | `"C:\\App"` |
| `heartbeatTarget` | Linux 伺服器 heartbeat 接收端點 | `"http://192.168.1.84:3100/api/v1/heartbeat"` |

### 步驟 3：安裝為 Task Scheduler（開機自動啟動，不需登入）

```powershell
# 以系統管理員執行
cd C:\PlaybackAgent\windows-agent
powershell -ExecutionPolicy Bypass -File scripts\install-task-scheduler.ps1
```

腳本會建立一個 **SYSTEM 帳號、AtStartup 觸發** 的排程工作 `PlaybackAgent`。

> ⚠️ **Node.js 路徑**：腳本預設 Node.js 在 `C:\Program Files\nodejs\node.exe`。  
> 若安裝在其他位置，請編輯腳本頂端的 `$NodePath` 變數。

```powershell
# 手動確認 node 路徑
where.exe node
```

### 步驟 4：立即啟動（不重開機）

```powershell
Start-Process -FilePath "node" `
  -ArgumentList "C:\PlaybackAgent\windows-agent\dist\agent.js" `
  -WorkingDirectory "C:\PlaybackAgent\windows-agent" `
  -WindowStyle Hidden
```

### 步驟 5：驗證 Agent 回應

```powershell
$h = @{Authorization="Bearer your-strong-secret-token-a"}
Invoke-WebRequest -Uri "http://localhost:4010/api/v1/status" -Headers $h | Select-Object -ExpandProperty Content
```

期待回傳：
```json
{"machineId":"playback-a","appRunning":true,"appPid":12345,"uptime":30}
```

---

## 設定說明

### Linux nodes.json 欄位

| 欄位 | 預設值 | 說明 |
|------|--------|------|
| `heartbeatTimeoutMs` | 10000 | 超過此時間未收到 heartbeat → degraded |
| `pingIntervalMs` | 3000 | TCP ping 間隔（ms） |
| `statusPollIntervalMs` | 3000 | 主動查詢 /status 間隔（ms） |
| `recoveringTimeoutMs` | 30000 | 發出 restart 後等待上限（ms），超過 → 回到 degraded |
| `maxRestartPer10Min` | 3 | 10 分鐘滑動視窗內最多重啟次數（防止重啟風暴） |
| `restartCooldownMs` | 60000 | 兩次重啟之間最小間隔（ms） |

### Windows agent.config.json 欄位

| 欄位 | 預設值 | 說明 |
|------|--------|------|
| `listenPort` | 4010 | Agent 監聽 port |
| `heartbeatIntervalMs` | 5000 | 推送 heartbeat 間隔（ms） |
| `localCheckIntervalMs` | 3000 | 本地 tasklist 檢查間隔（ms） |
| `restartCooldownMs` | 30000 | Agent 端重啟 cooldown（ms） |

---

## Windows 主機硬化

現場播控主機建議執行硬化腳本，防止系統更新重開、睡眠中斷播放。

腳本位於 `windows-agent/scripts/hardening/`。

### 前置說明：PIN vs 密碼

Windows AutoAdminLogon 需要**本機密碼**登入，不支援 PIN。部署前請確認：

1. 帳號已設定本機密碼（非僅有 PIN）
2. 若只有 PIN → 先到「設定 → 帳戶 → 登入選項」新增密碼
3. 硬化腳本會停用 Windows Hello PIN，防止後續系統切回 PIN 認證

### 1. 先確認目前狀態

```powershell
cd C:\PlaybackAgent\windows-agent\scripts\hardening
powershell -ExecutionPolicy Bypass -File check_status.ps1
```

exit code：`0` = 全部 OK，`1` = 有警告，`2` = 有問題需修正

### 2. 套用硬化設定

```powershell
powershell -ExecutionPolicy Bypass -File init_workstation.ps1 -Username "YourUser" -Password "YourPassword"
```

硬化內容（7 個區塊）：

| 項目 | 說明 |
|------|------|
| **停用 Windows Hello PIN** | PassportForWork Enabled=0，AllowDomainPINLogon=0，停用 WbioSrvc |
| **AutoAdminLogon** | 開機自動以密碼登入，無需手動輸入 |
| **停用 Windows Update（多層）** | Group Policy + 封鎖 WU Server + 停用 4 個服務（wuauserv / WaaSMedicSvc / UsoSvc / DoSvc）|
| **防止自動重開** | NoAutoRebootWithLoggedOnUsers + Active Hours 08:00~23:00 |
| **防睡眠** | 所有電源逾時設為 0，關閉休眠 |
| **停用鎖定畫面** | NoLockScreen Group Policy |
| **服務故障自恢復** | PlaybackAgent 故障後 5s / 10s / 30s 依序自動重啟 |

### 3. 需要還原時

```powershell
powershell -ExecutionPolicy Bypass -File rollback_workstation.ps1
```

---

## 驗證系統運作

部署完成後，依序執行以下驗證步驟。

### Step 1：確認 Linux 監控伺服器在線

```bash
curl http://localhost:3100/api/v1/nodes | python3 -m json.tool
```

期待看到每台節點的狀態物件。

### Step 2：確認每台 Windows Agent 在線

```bash
# 從 Linux 伺服器查詢
curl -H "Authorization: Bearer your-token-a" http://192.168.1.100:4010/api/v1/status
```

### Step 3：確認 heartbeat 正在更新

```bash
# 連查兩次，lastHeartbeatAt 時間戳應該遞增
curl http://localhost:3100/api/v1/nodes/playback-a | python3 -c "import sys,json,datetime; n=json.load(sys.stdin); ts=n.get('lastHeartbeatAt'); print('lastHB:', datetime.datetime.fromtimestamp(ts/1000).strftime('%H:%M:%S') if ts else 'none', '| health:', n['health'])"
```

### Step 4：模擬 App Crash，驗證自動重啟

```powershell
# 在 Windows 主機上殺掉播控程式
taskkill /F /IM your-app.exe
```

在 Linux 觀察（應在 10~15 秒內偵測到並重啟）：

```bash
watch -n 2 "curl -s http://localhost:3100/api/v1/nodes/playback-a | python3 -c \"import sys,json; n=json.load(sys.stdin); print(n['health'], '| app:', n['appRunning'], '| restarts:', n['restartCount10m'])\""
```

預期流程：`healthy` → `degraded` → `recovering` → `healthy`

### Step 5：執行 Live 系統測試（12 項驗收測試）

```bash
cd /opt/playback-monitor   # 或 playback-watchdog/linux-monitor
python3 tests/live-system.test.py
```

期待結果：`12 通過 / 0 失敗`

---

## API 參考

### Linux 監控伺服器

#### `GET /api/v1/nodes`
取得所有節點狀態清單。

**回應範例：**
```json
[
  {
    "machineId": "playback-a",
    "displayName": "Playback A（1F）",
    "hostIp": "192.168.1.100",
    "agentBaseUrl": "http://192.168.1.100:4010",
    "hostReachable": true,
    "agentReachable": true,
    "appRunning": true,
    "appPid": 12345,
    "lastPingOkAt": 1773349450646,
    "lastHeartbeatAt": 1773349448082,
    "lastStatusAt": 1773349448353,
    "lastRestartAt": null,
    "restartCount10m": 0,
    "health": "healthy",
    "lastError": null
  }
]
```

#### `GET /api/v1/nodes/:machineId`
取得指定節點狀態。404 若不存在。

#### `POST /api/v1/heartbeat`
由 Windows Agent 呼叫，更新節點心跳。

**Headers：** `Authorization: Bearer <token>`

**Body：**
```json
{
  "machineId": "playback-a",
  "displayName": "Playback A",
  "hostIp": "192.168.1.100",
  "appName": "your-app.exe",
  "appPid": 12345,
  "scene": "main",
  "fps": 60.0,
  "uptimeSec": 3600,
  "status": "alive",
  "timestamp": "2026-03-13T05:00:00+08:00"
}
```

**回應：** 200 `{"status":"ok"}` | 401 Unauthorized | 404 Unknown machineId

---

### Windows Agent

#### `GET /api/v1/status`
取得 agent 本地狀態（process 是否在跑）。

**Headers：** `Authorization: Bearer <token>`

**回應：**
```json
{"machineId":"playback-a","appRunning":true,"appPid":12345,"uptime":3600}
```

#### `POST /api/v1/restart`
觸發播控程式重啟（由 Linux 伺服器呼叫）。

**Headers：** `Authorization: Bearer <token>`

**Body：**
```json
{
  "machineId": "playback-a",
  "reason": "heartbeat_timeout",
  "requestedBy": "linux-monitor",
  "requestId": "uuid-here"
}
```

**回應：** 200 `{"success":true,"pid":12346}` | 429 Cooldown active | 401 Unauthorized

---

## 常見問題

### Q: Linux 顯示 `offline`，但 Windows 主機網路正常？
- 確認 Windows 防火牆已開放 port 4010 inbound
- 確認 Agent `listenHost` 設為 `0.0.0.0`（不是 `localhost`）
- 確認 `nodes.json` 中 `hostIp` 與 `agentBaseUrl` 的 IP 正確

### Q: health 一直停在 `recovering`，不回到 `healthy`？
- 確認 `processName` 大小寫與實際 exe 名稱一致（系統已做 case-insensitive 處理）
- 確認 `processPath` 路徑正確且可執行
- 確認 `workingDir` 目錄存在
- 查看 Windows Task Manager 確認進程是否真的有啟動

### Q: 一直出現 `Restart throttled`？
- 播控程式本身有問題（啟動後馬上 crash）→ 先手動啟動排查 app 問題
- 等待 10 分鐘 sliding window 過期後系統會重置計數
- 臨時增加 `maxRestartPer10Min` 只是掩蓋問題，請先解決 app crash 根因

### Q: Task Scheduler 裝好但重開後 Agent 沒啟動？
- 確認 SYSTEM 帳號有執行 node.exe 的權限
- 確認 `$NodePath` 路徑正確（`where.exe node` 確認）
- 查看 Task Scheduler 的「歷程記錄」tab 看有無錯誤

### Q: 需要同時管理 3 台以上的 Windows 主機？
在 Linux `config/nodes.json` 新增更多節點項目即可，系統無上限限制。每台 Windows 主機部署相同的 Agent，只需修改 `machineId`、`sharedToken`、`processPath` 三個欄位。

### Q: 如何在不停服務的情況下更新設定？
Linux 伺服器：修改 `config/nodes.json` 後重啟服務（`sudo systemctl restart playback-monitor`）。  
Windows Agent：修改 `config/agent.config.json` 後，用 Task Scheduler 重啟 `PlaybackAgent` task，或重開主機。

---

## 版本紀錄

| 版本 | 日期 | 說明 |
|------|------|------|
| v1.0.0 | 2026-03-13 | 首版：linux-monitor + windows-agent + hardening scripts + 12 項 live 測試 |
