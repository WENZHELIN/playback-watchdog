import * as net from 'node:net';
import { log } from './logger.js';
import type { NodeConfig, PlaybackNodeState, NodeHealth, HeartbeatPayload, AgentStatusResponse } from './types.js';

export class StateManager {
  private states: Map<string, PlaybackNodeState> = new Map();
  private configs: Map<string, NodeConfig> = new Map();
  private restartTimestamps: Map<string, number[]> = new Map();
  private recoveringStartedAt: Map<string, number> = new Map();
  private intervals: NodeJS.Timeout[] = [];

  constructor(configs: NodeConfig[]) {
    for (const cfg of configs) {
      this.configs.set(cfg.machineId, cfg);
      this.states.set(cfg.machineId, {
        machineId: cfg.machineId,
        displayName: cfg.displayName,
        hostIp: cfg.hostIp,
        agentBaseUrl: cfg.agentBaseUrl,
        hostReachable: false,
        agentReachable: null,
        appRunning: null,
        appPid: null,
        lastPingOkAt: null,
        lastHeartbeatAt: null,
        lastStatusAt: null,
        lastRestartAt: null,
        restartCount10m: 0,
        health: 'offline',
        lastError: null,
      });
      this.restartTimestamps.set(cfg.machineId, []);
    }
  }

  getState(machineId: string): PlaybackNodeState | undefined {
    return this.states.get(machineId);
  }

  getAllStates(): PlaybackNodeState[] {
    return Array.from(this.states.values());
  }

  getConfig(machineId: string): NodeConfig | undefined {
    return this.configs.get(machineId);
  }

  getAllConfigs(): NodeConfig[] {
    return Array.from(this.configs.values());
  }

  handleHeartbeat(payload: HeartbeatPayload): boolean {
    const state = this.states.get(payload.machineId);
    const config = this.configs.get(payload.machineId);
    if (!state || !config) return false;

    state.lastHeartbeatAt = Date.now();
    state.appRunning = payload.appRunning;
    state.appPid = payload.appPid;

    log('info', 'Heartbeat received', {
      machineId: payload.machineId,
      appRunning: payload.appRunning,
      appPid: payload.appPid,
    });

    this.evaluateHealth(payload.machineId);
    return true;
  }

  async pingNode(machineId: string): Promise<void> {
    const config = this.configs.get(machineId);
    const state = this.states.get(machineId);
    if (!config || !state) return;

    const port = parseInt(new URL(config.agentBaseUrl).port, 10) || 4010;

    try {
      await this.tcpConnect(config.hostIp, port, 3000);
      state.hostReachable = true;
      state.lastPingOkAt = Date.now();
    } catch {
      state.hostReachable = false;
      log('warn', 'Ping failed', { machineId, hostIp: config.hostIp, port });
    }

    this.evaluateHealth(machineId);
  }

  private tcpConnect(host: string, port: number, timeoutMs: number): Promise<void> {
    return new Promise((resolve, reject) => {
      const socket = new net.Socket();
      const timer = setTimeout(() => {
        socket.destroy();
        reject(new Error('TCP connect timeout'));
      }, timeoutMs);

      socket.connect(port, host, () => {
        clearTimeout(timer);
        socket.destroy();
        resolve();
      });

      socket.on('error', (err) => {
        clearTimeout(timer);
        socket.destroy();
        reject(err);
      });
    });
  }

  async pollStatus(machineId: string): Promise<void> {
    const config = this.configs.get(machineId);
    const state = this.states.get(machineId);
    if (!config || !state) return;

    try {
      const controller = new AbortController();
      const timeout = setTimeout(() => controller.abort(), 5000);

      const res = await fetch(`${config.agentBaseUrl}/api/v1/status`, {
        signal: controller.signal,
        headers: { 'Authorization': `Bearer ${config.token}` },
      });
      clearTimeout(timeout);

      if (!res.ok) throw new Error(`Status poll returned ${res.status}`);

      const data = await res.json() as AgentStatusResponse;
      state.agentReachable = true;
      state.lastStatusAt = Date.now();
      state.appRunning = data.appRunning;
      state.appPid = data.appPid;

      log('info', 'Status poll ok', { machineId, appRunning: data.appRunning, appPid: data.appPid });
    } catch (err) {
      state.agentReachable = false;
      const message = err instanceof Error ? err.message : String(err);
      log('warn', 'Status poll failed', { machineId, error: message });
    }

    this.evaluateHealth(machineId);
  }

  evaluateHealth(machineId: string): void {
    const state = this.states.get(machineId);
    const config = this.configs.get(machineId);
    if (!state || !config) return;

    const now = Date.now();
    const prevHealth = state.health;

    // Update sliding window restart count
    const timestamps = this.restartTimestamps.get(machineId) ?? [];
    const windowStart = now - 10 * 60 * 1000;
    const recent = timestamps.filter(t => t > windowStart);
    this.restartTimestamps.set(machineId, recent);
    state.restartCount10m = recent.length;

    // If recovering, check timeout
    if (state.health === 'recovering') {
      const recStart = this.recoveringStartedAt.get(machineId);
      if (recStart && now - recStart > config.recoveringTimeoutMs) {
        state.health = 'degraded';
        this.recoveringStartedAt.delete(machineId);
        log('warn', 'Recovering timeout, transitioning to degraded', { machineId });
      }
      // Stay in recovering until timeout or heartbeat confirms healthy
      if (state.health === 'recovering') {
        // Check if app is now running (confirmed via heartbeat or status poll)
        if (state.appRunning === true && state.lastHeartbeatAt && now - state.lastHeartbeatAt < config.heartbeatTimeoutMs) {
          state.health = 'healthy';
          this.recoveringStartedAt.delete(machineId);
          log('info', 'Recovered successfully', { machineId });
        }
        return;
      }
    }

    // Offline: ping failed
    if (!state.hostReachable) {
      state.health = 'offline';
      if (prevHealth !== 'offline') {
        log('warn', 'Node offline', { machineId });
      }
      return;
    }

    // agent_down: ping ok but agent not reachable (status poll failed) and no heartbeat
    const heartbeatTimedOut = !state.lastHeartbeatAt || (now - state.lastHeartbeatAt > config.heartbeatTimeoutMs);
    if (state.hostReachable && state.agentReachable === false && heartbeatTimedOut) {
      state.health = 'agent_down';
      if (prevHealth !== 'agent_down') {
        log('warn', 'Agent down (host reachable but agent unreachable)', { machineId });
      }
      return;
    }

    // healthy: ping ok + heartbeat fresh + appRunning
    if (state.hostReachable && !heartbeatTimedOut && state.appRunning === true) {
      state.health = 'healthy';
      return;
    }

    // warning: ping ok + status ok + heartbeat incomplete (but app seems ok)
    if (state.hostReachable && state.agentReachable === true && heartbeatTimedOut && state.appRunning === true) {
      state.health = 'warning';
      if (prevHealth !== 'warning') {
        log('warn', 'Heartbeat missing but agent reports app running', { machineId });
      }
      return;
    }

    // degraded: ping ok + (heartbeat timeout or app not running)
    if (state.hostReachable && (heartbeatTimedOut || state.appRunning === false)) {
      state.health = 'degraded';
      if (prevHealth !== 'degraded') {
        log('warn', 'Node degraded', { machineId, heartbeatTimedOut, appRunning: state.appRunning });
      }
      return;
    }
  }

  async dispatchRestart(machineId: string): Promise<boolean> {
    const state = this.states.get(machineId);
    const config = this.configs.get(machineId);
    if (!state || !config) return false;

    // Don't restart if offline, recovering, or agent_down
    if (state.health === 'offline' || state.health === 'recovering' || state.health === 'agent_down') {
      log('info', 'Restart skipped (wrong state)', { machineId, health: state.health });
      return false;
    }

    // Don't restart if not degraded
    if (state.health !== 'degraded') {
      return false;
    }

    // Throttle check
    const now = Date.now();
    const timestamps = this.restartTimestamps.get(machineId) ?? [];
    const windowStart = now - 10 * 60 * 1000;
    const recent = timestamps.filter(t => t > windowStart);

    if (recent.length >= config.maxRestartPer10Min) {
      log('warn', 'Restart throttled', { machineId, restartCount10m: recent.length, max: config.maxRestartPer10Min });
      return false;
    }

    // Cooldown check
    if (state.lastRestartAt && now - state.lastRestartAt < config.restartCooldownMs) {
      log('info', 'Restart cooldown active', { machineId, lastRestartAt: state.lastRestartAt });
      return false;
    }

    // Dispatch restart
    try {
      const controller = new AbortController();
      const timeout = setTimeout(() => controller.abort(), 10000);

      const res = await fetch(`${config.agentBaseUrl}/api/v1/restart`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${config.token}`,
        },
        body: JSON.stringify({ machineId: config.machineId }),
        signal: controller.signal,
      });
      clearTimeout(timeout);

      if (!res.ok) {
        const body = await res.text();
        throw new Error(`Restart request returned ${res.status}: ${body}`);
      }

      state.lastRestartAt = now;
      recent.push(now);
      this.restartTimestamps.set(machineId, recent);
      state.restartCount10m = recent.length;
      state.health = 'recovering';
      this.recoveringStartedAt.set(machineId, now);

      log('info', 'Restart dispatched', { machineId, restartCount10m: recent.length });
      return true;
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      state.lastError = message;
      log('error', 'Restart dispatch failed', { machineId, error: message });
      return false;
    }
  }

  startLoops(): void {
    for (const [machineId, config] of this.configs) {
      // Ping loop
      const pingInterval = setInterval(() => {
        this.pingNode(machineId).catch(() => {});
      }, config.pingIntervalMs);
      this.intervals.push(pingInterval);

      // Status poller
      const statusInterval = setInterval(() => {
        this.pollStatus(machineId).catch(() => {});
      }, config.statusPollIntervalMs);
      this.intervals.push(statusInterval);
    }

    // Timeout detector + restart dispatcher (every 1 second)
    const detectorInterval = setInterval(() => {
      for (const [machineId] of this.configs) {
        this.evaluateHealth(machineId);
        const state = this.states.get(machineId);
        if (state?.health === 'degraded') {
          this.dispatchRestart(machineId).catch(() => {});
        }
      }
    }, 1000);
    this.intervals.push(detectorInterval);

    log('info', 'Monitor loops started', { nodeCount: this.configs.size });
  }

  stopLoops(): void {
    for (const interval of this.intervals) {
      clearInterval(interval);
    }
    this.intervals = [];
    log('info', 'Monitor loops stopped');
  }

  // For testing: directly set state fields
  _setState(machineId: string, partial: Partial<PlaybackNodeState>): void {
    const state = this.states.get(machineId);
    if (state) {
      Object.assign(state, partial);
    }
  }

  _setRecoveringStartedAt(machineId: string, ts: number): void {
    this.recoveringStartedAt.set(machineId, ts);
  }

  _getRestartTimestamps(machineId: string): number[] {
    return this.restartTimestamps.get(machineId) ?? [];
  }

  _setRestartTimestamps(machineId: string, timestamps: number[]): void {
    this.restartTimestamps.set(machineId, timestamps);
  }
}
