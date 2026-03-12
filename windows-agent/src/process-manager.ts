import { exec, spawn } from 'node:child_process';
import { log } from './logger.js';
import type { AgentConfig } from './types.js';

let currentPid: number | null = null;
let lastRestartAt: number | null = null;

export function getCurrentPid(): number | null {
  return currentPid;
}

export function getLastRestartAt(): number | null {
  return lastRestartAt;
}

export async function checkProcess(config: AgentConfig): Promise<boolean> {
  return new Promise((resolve) => {
    const cmd = `tasklist /FI "IMAGENAME eq ${config.processName}" /FO CSV /NH`;
    exec(cmd, { timeout: 5000 }, (err, stdout) => {
      if (err) {
        log('error', 'tasklist command failed', { error: err.message });
        resolve(false);
        return;
      }

      const lines = stdout.trim().split('\n').filter(line => line.includes(config.processName));
      if (lines.length === 0) {
        currentPid = null;
        resolve(false);
        return;
      }

      // Parse PID from CSV: "processName","PID","Session Name","Session#","Mem Usage"
      try {
        const parts = lines[0].split(',');
        if (parts.length >= 2) {
          const pidStr = parts[1].replace(/"/g, '').trim();
          currentPid = parseInt(pidStr, 10);
        }
      } catch {
        // PID parse failed, but process exists
      }

      resolve(true);
    });
  });
}

export async function restartProcess(config: AgentConfig): Promise<{ success: boolean; pid: number | null }> {
  const now = Date.now();

  // Cooldown check
  if (lastRestartAt && now - lastRestartAt < config.restartCooldownMs) {
    const remainMs = config.restartCooldownMs - (now - lastRestartAt);
    log('warn', 'Restart rejected: cooldown active', { machineId: config.machineId, remainMs });
    return { success: false, pid: currentPid };
  }

  log('info', 'Killing process before restart', { processName: config.processName });

  // Kill existing process
  await new Promise<void>((resolve) => {
    exec(`taskkill /F /IM ${config.processName}`, { timeout: 10000 }, (err) => {
      if (err) {
        log('warn', 'taskkill failed (process may not exist)', { error: err.message });
      }
      resolve();
    });
  });

  // Wait a moment for process to fully exit
  await new Promise(resolve => setTimeout(resolve, 2000));

  // Spawn new process
  try {
    const child = spawn(config.processPath, [], {
      cwd: config.workingDir,
      detached: true,
      stdio: 'ignore',
    });
    child.unref();

    currentPid = child.pid ?? null;
    lastRestartAt = now;

    log('info', 'Process restarted', { machineId: config.machineId, pid: currentPid, processPath: config.processPath });
    return { success: true, pid: currentPid };
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    log('error', 'Failed to spawn process', { machineId: config.machineId, error: message });
    return { success: false, pid: null };
  }
}
