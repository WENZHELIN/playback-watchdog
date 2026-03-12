# Playback Watchdog System

1 台 Linux 監控伺服器 + N 台 Windows 播控主機的全自動健康監控與重啟系統。

---

## 快速導覽

| 文件 | 內容 |
|------|------|
| **[DEPLOY.md](./DEPLOY.md)** | ✅ **完整部署手冊**（從零到上線，含 Windows 硬化） |
| [DEV-SPEC.md](./DEV-SPEC.md) | 技術規格與架構設計 |

---

## 架構概覽

```
┌─────────────────────────────┐         ┌──────────────────────────────┐
│  Linux 監控伺服器 :3100      │  ping   │  Windows 播控主機 A :4010    │
│  linux-monitor              ├────────>│  windows-agent               │
│                             ├─GET────>│  GET  /api/v1/status         │
│                             ├─POST───>│  POST /api/v1/restart        │
│  ◄──────────────────────────┤         │  heartbeat 每 5 秒           │
│  POST /api/v1/heartbeat     │         └──────────────────────────────┘
│  GET  /api/v1/nodes         │
│  GET  /api/v1/nodes/:id     │         ┌──────────────────────────────┐
└─────────────────────────────┘         │  Windows 播控主機 B :4010    │
                                        └──────────────────────────────┘
```

## 健康狀態

| 狀態 | 條件 | 動作 |
|------|------|------|
| `healthy` | ping + heartbeat + appRunning 全 OK | 無 |
| `degraded` | heartbeat 超時 或 appRunning=false | **自動重啟** |
| `recovering` | 已發出 restart，等待確認（30s timeout） | 輪詢確認 |
| `agent_down` | ping 通但 /status 無回應 | 僅警示 |
| `offline` | ping 失敗 | 僅記錄 |

## 快速啟動

```bash
# Linux 伺服器
git clone https://github.com/WENZHELIN/playback-watchdog.git
cd playback-watchdog/linux-monitor && npm install && npm run build
PORT=3100 npm start
```

```powershell
# Windows 主機（以管理員執行）
git clone https://github.com/WENZHELIN/playback-watchdog.git C:\PlaybackAgent
cd C:\PlaybackAgent\windows-agent
npm install && npm run build
# 修改 config\agent.config.json 後：
powershell -ExecutionPolicy Bypass -File scripts\install-task-scheduler.ps1
```

→ 完整說明請見 **[DEPLOY.md](./DEPLOY.md)**

## 測試

```bash
cd linux-monitor
npm test                              # 5 個單元整合測試
python3 tests/live-system.test.py    # 12 項 live 驗收測試（需系統在線）
```

## 目錄結構

```
playback-watchdog/
├── DEPLOY.md                          ← 部署手冊
├── DEV-SPEC.md                        ← 技術規格
├── linux-monitor/
│   ├── src/
│   │   ├── server.ts                  ← Fastify API 伺服器
│   │   ├── state-manager.ts           ← 節點狀態機
│   │   ├── logger.ts
│   │   └── types.ts
│   ├── config/nodes.json              ← 節點清單設定
│   ├── tests/
│   │   ├── integration.test.ts        ← Vitest 單元測試
│   │   └── live-system.test.py        ← Live 驗收測試
│   └── scripts/install-systemd.sh    ← systemd 安裝腳本
└── windows-agent/
    ├── src/
    │   ├── agent.ts                   ← Fastify API + singleton guard
    │   ├── heartbeat.ts               ← 心跳推送
    │   ├── process-manager.ts         ← tasklist + spawn
    │   └── types.ts
    ├── config/agent.config.json       ← Agent 設定
    └── scripts/
        ├── install-task-scheduler.ps1 ← Task Scheduler 安裝
        └── hardening/
            ├── init_workstation.ps1   ← 主機硬化
            ├── rollback_workstation.ps1
            └── check_status.ps1      ← 硬化狀態檢查
```
