# Playback Watchdog System

1 Linux Server + N Windows Playback Nodes watchdog with automatic health monitoring and restart.

## Architecture

```
+---------------------------+         +----------------------------+
|    Linux Server (:3000)   |         |  Windows Playback A (:4010)|
|    linux-monitor/         |         |  windows-agent/            |
|                           |  ping   |                            |
|  Ping Loop ---------------+-------->|                            |
|  Status Poller -----------+--GET--->| GET /api/v1/status         |
|  Restart Dispatcher ------+--POST-->| POST /api/v1/restart       |
|                           |         |                            |
|  POST /api/v1/heartbeat <-+--POST---| Heartbeat Sender (5s)      |
|  GET  /api/v1/nodes       |         +----------------------------+
|  GET  /api/v1/nodes/:id   |
|                           |         +----------------------------+
|                           |         |  Windows Playback B (:4010)|
|  (same loops per node) ---+-------->|  windows-agent/            |
+---------------------------+         +----------------------------+
```

## Health States

| State | Condition | Action |
|---|---|---|
| `healthy` | ping ok + heartbeat <10s + appRunning=true | None |
| `warning` | ping ok + /status ok + heartbeat incomplete | Log only |
| `agent_down` | ping ok + /status fail + heartbeat fail | Alert only |
| `degraded` | ping ok + (heartbeat timeout or appRunning=false) | Restart (with throttle) |
| `offline` | ping fail | Log only, no restart |
| `recovering` | restart dispatched, awaiting confirmation | Poll /status, 30s timeout |

## Quick Start - Linux Server

```bash
# 1. Clone repository
git clone https://github.com/WENZHELIN/playback-watchdog.git
cd playback-watchdog/linux-monitor

# 2. Install dependencies
npm install

# 3. Edit config/nodes.json with your node IPs and tokens

# 4. Build and start
npm run build
npm start

# 5. (Optional) Install as systemd service
chmod +x scripts/install-systemd.sh
./scripts/install-systemd.sh
```

## Quick Start - Windows Agent

```powershell
# 1. Copy windows-agent/ folder to C:\PlaybackAgent
xcopy /E /I windows-agent C:\PlaybackAgent

# 2. Install dependencies
cd C:\PlaybackAgent
npm install

# 3. Edit config\agent.config.json with machineId, token, processPath

# 4. Build and start
npm run build
npm start

# 5. (Optional) Register as Task Scheduler task (run as Admin)
powershell -ExecutionPolicy Bypass -File scripts\install-task-scheduler.ps1
```

## Configuration

### Linux - config/nodes.json

| Field | Type | Description |
|---|---|---|
| `machineId` | string | Unique node identifier |
| `displayName` | string | Human-readable name |
| `hostIp` | string | Windows machine IP |
| `agentBaseUrl` | string | Agent URL (http://IP:4010) |
| `heartbeatTimeoutMs` | number | Max time between heartbeats (default: 10000) |
| `pingIntervalMs` | number | TCP ping interval (default: 3000) |
| `statusPollIntervalMs` | number | GET /status interval (default: 3000) |
| `recoveringTimeoutMs` | number | Max recovery wait time (default: 30000) |
| `maxRestartPer10Min` | number | Restart throttle limit (default: 3) |
| `restartCooldownMs` | number | Min time between restarts (default: 60000) |
| `token` | string | Shared Bearer token for auth |

### Windows - config/agent.config.json

| Field | Type | Description |
|---|---|---|
| `machineId` | string | Must match nodes.json entry |
| `displayName` | string | Human-readable name |
| `listenHost` | string | Bind address (default: 0.0.0.0) |
| `listenPort` | number | Agent port (default: 4010) |
| `allowedServerIp` | string | Linux server IP for security |
| `sharedToken` | string | Must match nodes.json token |
| `processName` | string | Process name for tasklist (e.g. playback.exe) |
| `processPath` | string | Full path to executable |
| `workingDir` | string | Working directory for the process |
| `heartbeatTarget` | string | Linux heartbeat endpoint URL |
| `heartbeatIntervalMs` | number | Heartbeat send interval (default: 5000) |
| `localCheckIntervalMs` | number | Local process check interval (default: 3000) |
| `restartCooldownMs` | number | Min time between restarts (default: 30000) |

## Testing

```bash
cd linux-monitor
npm install
npm test
```

5 integration tests covering:
1. All 4 nodes healthy heartbeat -> all healthy
2. Single node heartbeat timeout -> only that node degraded + restart
3. Single node ping failure -> offline, no restart
4. Single node appRunning=false -> degraded, restart only that node
5. Restart throttle after exceeding limit

## Troubleshooting

### 1. Agent not responding (agent_down)
- Check if Node.js process is running on the Windows machine
- Verify firewall allows port 4010 inbound
- Check `config/agent.config.json` listenHost is `0.0.0.0`

### 2. Heartbeat timeout but agent reachable (warning)
- App heartbeat thread may have crashed
- Check Windows agent logs for heartbeat send errors
- Verify `heartbeatTarget` URL is correct in agent config

### 3. Node shows offline
- Check network connectivity between Linux server and Windows machine
- Verify IP address in `config/nodes.json` is correct
- Check Windows firewall rules for port 4010

### 4. Restart not triggered (throttle)
- System limits restarts to `maxRestartPer10Min` (default: 3) per 10-minute window
- Check logs for "Restart throttled" messages
- Wait for the window to expire or investigate root cause

### 5. Process won't start after restart
- Verify `processPath` in agent config points to valid executable
- Check `workingDir` exists and is accessible
- Review Windows agent logs for spawn errors
- Ensure SYSTEM account has permissions to run the process

## Acceptance Criteria

- **AC-01** Multi-node identification: System correctly identifies all nodes by unique machineId
- **AC-02** Independent state: heartbeat / ping / status / restart tracked independently per node
- **AC-03** Single node timeout does not affect other nodes
- **AC-04** Single node restart targets only that node
- **AC-05** Offline nodes are not restarted
- **AC-06** Throttle enforced: max 3 restarts per 10-minute sliding window
- **AC-07** Linux systemd auto-start on boot
- **AC-08** Windows Task Scheduler auto-start on boot (no login required)
- **AC-09** Structured JSON logs for all events: heartbeat timeout, ping fail, restart request/success/reject
- **AC-10** Complete documentation: install, config, test, troubleshooting
