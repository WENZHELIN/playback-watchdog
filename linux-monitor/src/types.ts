export type NodeHealth = 'healthy' | 'warning' | 'degraded' | 'offline' | 'recovering' | 'agent_down';

export interface PlaybackNodeState {
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
}

export interface NodeConfig {
  machineId: string;
  displayName: string;
  hostIp: string;
  agentBaseUrl: string;
  heartbeatTimeoutMs: number;
  pingIntervalMs: number;
  statusPollIntervalMs: number;
  recoveringTimeoutMs: number;
  maxRestartPer10Min: number;
  restartCooldownMs: number;
  token: string;
}

export interface HeartbeatPayload {
  machineId: string;
  appRunning: boolean;
  appPid: number | null;
  timestamp: number;
}

export interface AgentStatusResponse {
  machineId: string;
  appRunning: boolean;
  appPid: number | null;
  uptime: number;
}
