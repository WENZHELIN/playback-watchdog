export interface AgentConfig {
  machineId: string;
  displayName: string;
  listenHost: string;
  listenPort: number;
  allowedServerIp: string;
  sharedToken: string;
  processName: string;
  processPath: string;
  workingDir: string;
  heartbeatTarget: string;
  heartbeatIntervalMs: number;
  localCheckIntervalMs: number;
  restartCooldownMs: number;
}

export interface StatusResponse {
  machineId: string;
  appRunning: boolean;
  appPid: number | null;
  uptime: number;
}

export interface RestartRequest {
  machineId: string;
}
