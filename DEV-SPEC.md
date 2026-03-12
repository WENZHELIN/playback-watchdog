# 1 Server + 4 Playback Nodes Watchdog System — 開發規格

版本：v1.1（含 Phase 0 審閱修正）
更新：2026-03-13

---

## 開發測試環境（實際 IP）

| 角色 | 機器 | IP |
|---|---|---|
| Linux Server | Mac mini | 192.168.1.84 |
| Playback A | samoi-roy (Windows) | 192.168.1.158 |
| Playback B | samoi-4card (Windows) | 192.168.1.xxx（上線後確認）|

> 生產環境：Server 在 192.168.0.x，播控在 192.168.1.x（跨子網，需確認路由）

---

## Phase 0 審閱結論

### 架構確認
1. **Heartbeat vs /status 分工明確，不重複**
   - Heartbeat（push）：App → Linux，每 5 秒，證明 App 活著且主動上報
   - /status（pull）：Linux → Agent，每 3 秒，證明 Agent 可回應查詢
   - 若 heartbeat 停但 /status 正常 → App heartbeat thread 死掉，狀態應為 `warning`

2. **需補充 recovering timeout**
   - nodes.json 補 `recoveringTimeoutMs: 30000`
   - recovering 期間每 3 秒 poll /status，超時未恢復 → 轉 degraded

3. **Agent 掛掉但主機存活的狀態**
   - Ping 成功 + /status 失敗 + heartbeat 停 → 新增 `agent_down` 狀態
   - 此狀態只記錄告警，不自動做任何動作（無法遠端自動重啟 agent）

4. **Token 驗證**
   - 統一用 HTTP Header：`Authorization: Bearer <token>`
   - Linux heartbeat receiver 收到請求先驗 token

5. **PID 追蹤**
   - App 重啟後 PID 會變，Agent 每次重啟後讀取新 PID，下次 heartbeat 帶給 Linux 更新

### 技術選型
- Linux + Windows 都用 **Node.js 20 + TypeScript + Fastify**
- 測試框架：**Vitest**
- Linux 部署：**systemd**
- Windows 部署：**Task Scheduler**（`Run whether user is logged on or not`，開機觸發）
- Node.js source 直接跑（4 台固定機器，不需打包 exe）

---

## 系統架構

```
Linux Server (192.168.1.84)
├─ linux-monitor/
│  ├─ POST /api/v1/heartbeat     ← Windows agents 推送
│  ├─ GET  /api/v1/nodes         ← 查詢所有節點狀態
│  ├─ GET  /api/v1/nodes/:id     ← 查詢單一節點
│  └─ 內部：ping + status poller + timeout detector + restart dispatcher

Playback A - samoi-roy (192.168.1.158)
└─ windows-agent/
   ├─ GET  /api/v1/status        ← Linux 輪詢
   ├─ POST /api/v1/restart       ← Linux 發出重啟指令
   └─ 內部：heartbeat sender + process checker + restart handler

Playback B - samoi-4card (192.168.1.xxx)
└─ windows-agent/（同上）
```

---

## 狀態模型（補充 agent_down）

```typescript
type NodeHealth = 'healthy' | 'warning' | 'degraded' | 'offline' | 'recovering' | 'agent_down';

type PlaybackNodeState = {
  machineId: string;
  displayName: string;
  hostIp: string;
  agentBaseUrl: string;
  hostReachable: boolean;
  agentReachable: boolean | null;
  appRunning: boolean | null;
  appPid: number | null;
  lastPingOkAt: number | null;
  lastHeartbeatAt: number | null;
  lastStatusAt: number | null;
  lastRestartAt: number | null;
  restartCount10m: number;
  health: NodeHealth;
  lastError: string | null;
};
```

### 狀態判定規則（修正版）

| 狀態 | 條件 | 動作 |
|---|---|---|
| `healthy` | ping ok + heartbeat <10s + appRunning=true | 無 |
| `warning` | ping ok + /status ok + heartbeat 不完整或剛重啟 | 記錄，不重啟 |
| `agent_down` | ping ok + /status 失敗 | 只告警，不動作 |
| `degraded` | ping ok + (heartbeat timeout 或 appRunning=false) | 視 throttle 決定重啟 |
| `offline` | ping 失敗 | 只記錄，不對 app 發任何指令 |
| `recovering` | 剛發出 restart，等待確認 | 輪詢 /status，30 秒後未恢復→degraded |

---

## nodes.json（Linux，含修正欄位）

```json
[
  {
    "machineId": "samoi-roy",
    "displayName": "Playback A",
    "hostIp": "192.168.1.158",
    "agentBaseUrl": "http://192.168.1.158:4010",
    "heartbeatTimeoutMs": 10000,
    "pingIntervalMs": 3000,
    "statusPollIntervalMs": 3000,
    "recoveringTimeoutMs": 30000,
    "maxRestartPer10Min": 3,
    "restartCooldownMs": 60000,
    "token": "dev-secret-samoi-roy"
  },
  {
    "machineId": "samoi-4card",
    "displayName": "Playback B",
    "hostIp": "192.168.1.200",
    "agentBaseUrl": "http://192.168.1.200:4010",
    "heartbeatTimeoutMs": 10000,
    "pingIntervalMs": 3000,
    "statusPollIntervalMs": 3000,
    "recoveringTimeoutMs": 30000,
    "maxRestartPer10Min": 3,
    "restartCooldownMs": 60000,
    "token": "dev-secret-samoi-4card"
  }
]
```

## agent.config.json（Windows）

```json
{
  "machineId": "samoi-roy",
  "displayName": "Playback A",
  "listenHost": "0.0.0.0",
  "listenPort": 4010,
  "allowedServerIp": "192.168.1.84",
  "sharedToken": "dev-secret-samoi-roy",
  "processName": "playback.exe",
  "processPath": "C:\\Playback\\playback.exe",
  "workingDir": "C:\\Playback",
  "heartbeatTarget": "http://192.168.1.84:3000/api/v1/heartbeat",
  "heartbeatIntervalMs": 5000,
  "localCheckIntervalMs": 3000,
  "restartCooldownMs": 30000
}
```

---

## 驗收標準（AC）

- AC-01 多節點識別：系統正確識別所有不同 machineId 的節點
- AC-02 狀態獨立：heartbeat / ping / status / restart 彼此獨立
- AC-03 單節點 timeout 不影響其他節點
- AC-04 單節點 restart 只對該節點
- AC-05 offline 不亂 restart
- AC-06 throttle 生效：10 分鐘內超過上限停止 restart
- AC-07 Linux systemd 開機自啟
- AC-08 Windows Task Scheduler 開機自啟（不需登入）
- AC-09 log 完整：heartbeat timeout / ping fail / restart request / restart success / reject 都有結構化 log
- AC-10 文件完整：安裝 / 設定 / 測試 / 故障排查

---

## GitHub Repository

https://github.com/WENZHELIN/playback-watchdog

> 注意：如需轉移到 samoi-service org，Roy 需在 GitHub 設定 WENZHELIN 為 org member 後重新 push。

---

## 開發分期

### Phase 1：Linux Monitor MVP
- POST /api/v1/heartbeat（含 token 驗證）
- 狀態 Map 記憶體保存
- GET /api/v1/nodes
- 結構化 log（JSON）
- systemd service 腳本

### Phase 2：Windows Agent MVP
- GET /api/v1/status
- process 存在判斷（tasklist + PID）
- POST /api/v1/restart（含 cooldown）
- heartbeat sender（定時 POST 到 Linux）
- Task Scheduler 安裝腳本

### Phase 3：串接整合
- Linux ping loop
- Linux status poller
- timeout detector + 狀態機
- restart dispatcher + throttle（sliding window）
- recovering 狀態 + 30 秒逾時

### Phase 4：測試 & 驗收
- Vitest 單元測試（5 個整合案例）
- 手動測試步驟文件
- 部署清單 / 回滾策略
