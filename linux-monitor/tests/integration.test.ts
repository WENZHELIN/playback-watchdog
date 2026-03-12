import { describe, it, expect, beforeEach, vi } from 'vitest';
import { StateManager } from '../src/state-manager.js';
import type { NodeConfig } from '../src/types.js';

function makeConfig(overrides: Partial<NodeConfig> & { machineId: string }): NodeConfig {
  return {
    displayName: overrides.machineId,
    hostIp: '192.168.1.100',
    agentBaseUrl: 'http://192.168.1.100:4010',
    heartbeatTimeoutMs: 10000,
    pingIntervalMs: 3000,
    statusPollIntervalMs: 3000,
    recoveringTimeoutMs: 30000,
    maxRestartPer10Min: 3,
    restartCooldownMs: 60000,
    token: `token-${overrides.machineId}`,
    ...overrides,
  };
}

const fourNodeConfigs: NodeConfig[] = [
  makeConfig({ machineId: 'node-1', hostIp: '10.0.0.1', agentBaseUrl: 'http://10.0.0.1:4010' }),
  makeConfig({ machineId: 'node-2', hostIp: '10.0.0.2', agentBaseUrl: 'http://10.0.0.2:4010' }),
  makeConfig({ machineId: 'node-3', hostIp: '10.0.0.3', agentBaseUrl: 'http://10.0.0.3:4010' }),
  makeConfig({ machineId: 'node-4', hostIp: '10.0.0.4', agentBaseUrl: 'http://10.0.0.4:4010' }),
];

describe('Integration Tests', () => {
  let sm: StateManager;

  beforeEach(() => {
    sm = new StateManager(fourNodeConfigs);
    vi.restoreAllMocks();
  });

  // Test 1: All 4 nodes healthy heartbeat -> all healthy
  it('AC-01/02: 4 nodes with normal heartbeat should all be healthy', () => {
    const now = Date.now();
    for (const cfg of fourNodeConfigs) {
      // Simulate ping success
      sm._setState(cfg.machineId, {
        hostReachable: true,
        lastPingOkAt: now,
        agentReachable: true,
        lastStatusAt: now,
      });

      // Send heartbeat
      sm.handleHeartbeat({
        machineId: cfg.machineId,
        appRunning: true,
        appPid: 1000 + fourNodeConfigs.indexOf(cfg),
        timestamp: now,
      });
    }

    const states = sm.getAllStates();
    for (const state of states) {
      expect(state.health).toBe('healthy');
      expect(state.appRunning).toBe(true);
    }
  });

  // Test 2: Node-2 heartbeat timeout (ping ok) -> only node-2 degraded + restart
  it('AC-03/04: node-2 heartbeat timeout should only affect node-2, trigger restart', async () => {
    const now = Date.now();

    // Set all nodes to healthy state first
    for (const cfg of fourNodeConfigs) {
      sm._setState(cfg.machineId, {
        hostReachable: true,
        lastPingOkAt: now,
        agentReachable: true,
        lastStatusAt: now,
        lastHeartbeatAt: now,
        appRunning: true,
        appPid: 1000,
      });
      sm.evaluateHealth(cfg.machineId);
    }

    // Verify all healthy
    for (const state of sm.getAllStates()) {
      expect(state.health).toBe('healthy');
    }

    // Now simulate node-2 heartbeat timeout with app not running
    sm._setState('node-2', {
      lastHeartbeatAt: now - 15000, // 15 seconds ago, exceeds 10s timeout
      agentReachable: true,         // agent still reachable via /status
      appRunning: false,            // but app is not running
    });
    sm.evaluateHealth('node-2');

    // node-2 should be degraded (ping ok + appRunning=false)
    const state2 = sm.getState('node-2')!;
    expect(state2.health).toBe('degraded');

    // Other nodes should still be healthy
    expect(sm.getState('node-1')!.health).toBe('healthy');
    expect(sm.getState('node-3')!.health).toBe('healthy');
    expect(sm.getState('node-4')!.health).toBe('healthy');

    // Mock fetch for restart dispatch
    const fetchSpy = vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(JSON.stringify({ status: 'restarted', pid: 2000 }), { status: 200 })
    );

    const restarted = await sm.dispatchRestart('node-2');
    expect(restarted).toBe(true);
    expect(fetchSpy).toHaveBeenCalledTimes(1);

    // Verify restart was only for node-2
    const callUrl = fetchSpy.mock.calls[0][0] as string;
    expect(callUrl).toContain('10.0.0.2');

    // node-2 should now be recovering
    expect(sm.getState('node-2')!.health).toBe('recovering');
  });

  // Test 3: Node-1 ping fails -> offline, no restart
  it('AC-05: node-1 ping failure should be offline, no restart dispatched', async () => {
    const now = Date.now();

    // Set all nodes healthy
    for (const cfg of fourNodeConfigs) {
      sm._setState(cfg.machineId, {
        hostReachable: true,
        lastPingOkAt: now,
        agentReachable: true,
        lastStatusAt: now,
        lastHeartbeatAt: now,
        appRunning: true,
        appPid: 1000,
      });
      sm.evaluateHealth(cfg.machineId);
    }

    // Node-1 ping fails
    sm._setState('node-1', { hostReachable: false });
    sm.evaluateHealth('node-1');

    expect(sm.getState('node-1')!.health).toBe('offline');

    // Restart should NOT be dispatched for offline nodes
    const fetchSpy = vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(JSON.stringify({ status: 'restarted' }), { status: 200 })
    );

    const restarted = await sm.dispatchRestart('node-1');
    expect(restarted).toBe(false);
    expect(fetchSpy).not.toHaveBeenCalled();

    // Other nodes remain healthy
    expect(sm.getState('node-2')!.health).toBe('healthy');
    expect(sm.getState('node-3')!.health).toBe('healthy');
    expect(sm.getState('node-4')!.health).toBe('healthy');
  });

  // Test 4: Node-3 appRunning=false -> degraded, only restart node-3
  it('AC-04: node-3 appRunning=false should be degraded, restart only node-3', async () => {
    const now = Date.now();

    // Set all nodes healthy
    for (const cfg of fourNodeConfigs) {
      sm._setState(cfg.machineId, {
        hostReachable: true,
        lastPingOkAt: now,
        agentReachable: true,
        lastStatusAt: now,
        lastHeartbeatAt: now,
        appRunning: true,
        appPid: 1000,
      });
      sm.evaluateHealth(cfg.machineId);
    }

    // Node-3 reports appRunning=false via heartbeat
    sm.handleHeartbeat({
      machineId: 'node-3',
      appRunning: false,
      appPid: null,
      timestamp: now,
    });

    expect(sm.getState('node-3')!.health).toBe('degraded');
    expect(sm.getState('node-3')!.appRunning).toBe(false);

    // Other nodes still healthy
    expect(sm.getState('node-1')!.health).toBe('healthy');
    expect(sm.getState('node-2')!.health).toBe('healthy');
    expect(sm.getState('node-4')!.health).toBe('healthy');

    // Restart should target only node-3
    const fetchSpy = vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(JSON.stringify({ status: 'restarted', pid: 3000 }), { status: 200 })
    );

    const r3 = await sm.dispatchRestart('node-3');
    expect(r3).toBe(true);
    expect(fetchSpy).toHaveBeenCalledTimes(1);
    expect((fetchSpy.mock.calls[0][0] as string)).toContain('10.0.0.3');

    // Attempt restart on healthy nodes should do nothing
    const r1 = await sm.dispatchRestart('node-1');
    expect(r1).toBe(false);
    expect(fetchSpy).toHaveBeenCalledTimes(1); // no additional calls
  });

  // Test 5: Node-4 consecutive restarts exceed limit -> throttle
  it('AC-06: node-4 restart throttle after exceeding limit', async () => {
    const now = Date.now();

    sm._setState('node-4', {
      hostReachable: true,
      lastPingOkAt: now,
      agentReachable: true,
      lastStatusAt: now,
      lastHeartbeatAt: now - 15000,
      appRunning: false,
      appPid: null,
    });
    sm.evaluateHealth('node-4');
    expect(sm.getState('node-4')!.health).toBe('degraded');

    // Simulate 3 recent restarts in the 10-minute window
    const timestamps = [
      now - 8 * 60 * 1000,  // 8 min ago
      now - 5 * 60 * 1000,  // 5 min ago
      now - 2 * 60 * 1000,  // 2 min ago
    ];
    sm._setRestartTimestamps('node-4', timestamps);
    sm._setState('node-4', {
      restartCount10m: 3,
      lastRestartAt: now - 2 * 60 * 1000,
    });

    const fetchSpy = vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(JSON.stringify({ status: 'restarted' }), { status: 200 })
    );

    // Re-evaluate to degraded (need to set it back since evaluateHealth may have changed it)
    sm._setState('node-4', { health: 'degraded' });

    const restarted = await sm.dispatchRestart('node-4');
    expect(restarted).toBe(false); // Should be throttled
    expect(fetchSpy).not.toHaveBeenCalled();

    // Verify restartCount10m reflects the throttle state
    expect(sm.getState('node-4')!.restartCount10m).toBeGreaterThanOrEqual(3);

    // Other nodes unaffected
    for (const cfg of fourNodeConfigs) {
      if (cfg.machineId === 'node-4') continue;
      const state = sm.getState(cfg.machineId)!;
      // They haven't been set up so they're still offline (initial state)
      expect(state.health).toBe('offline');
    }
  });
});
