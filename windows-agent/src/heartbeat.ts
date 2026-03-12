import { log } from './logger.js';
import { getCurrentPid, checkProcess } from './process-manager.js';
import type { AgentConfig } from './types.js';

let heartbeatInterval: NodeJS.Timeout | null = null;

export function startHeartbeat(config: AgentConfig): void {
  heartbeatInterval = setInterval(async () => {
    try {
      const appRunning = await checkProcess(config);
      const appPid = getCurrentPid();

      const controller = new AbortController();
      const timeout = setTimeout(() => controller.abort(), 5000);

      const res = await fetch(config.heartbeatTarget, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${config.sharedToken}`,
        },
        body: JSON.stringify({
          machineId: config.machineId,
          appRunning,
          appPid,
          timestamp: Date.now(),
        }),
        signal: controller.signal,
      });
      clearTimeout(timeout);

      if (!res.ok) {
        log('warn', 'Heartbeat rejected by server', { status: res.status });
      }
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      log('error', 'Heartbeat send failed', { error: message });
    }
  }, config.heartbeatIntervalMs);

  log('info', 'Heartbeat sender started', { target: config.heartbeatTarget, intervalMs: config.heartbeatIntervalMs });
}

export function stopHeartbeat(): void {
  if (heartbeatInterval) {
    clearInterval(heartbeatInterval);
    heartbeatInterval = null;
  }
}
