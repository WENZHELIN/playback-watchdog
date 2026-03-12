import Fastify from 'fastify';
import * as fs from 'node:fs';
import * as net from 'node:net';
import * as path from 'node:path';
import { fileURLToPath } from 'node:url';
import { log } from './logger.js';
import { checkProcess, restartProcess, getCurrentPid } from './process-manager.js';
import { startHeartbeat } from './heartbeat.js';
import type { AgentConfig, RestartRequest } from './types.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const configPath = path.resolve(__dirname, '..', 'config', 'agent.config.json');
const config: AgentConfig = JSON.parse(fs.readFileSync(configPath, 'utf-8'));

// Singleton guard：若 port 已被佔用，代表另一個 instance 在跑，直接退出
async function checkSingleton(port: number): Promise<boolean> {
  return new Promise((resolve) => {
    const tester = net.createServer();
    tester.once('error', () => resolve(false));   // port busy = not singleton
    tester.once('listening', () => { tester.close(); resolve(true); });
    tester.listen(port, '0.0.0.0');
  });
}
const isSingleton = await checkSingleton(config.listenPort);
if (!isSingleton) {
  log('warn', 'Another agent instance already running, exiting.', { port: config.listenPort });
  process.exit(0);
}

const startTime = Date.now();
const server = Fastify({ logger: false });

function verifyToken(authHeader: string | undefined): boolean {
  if (!authHeader || !authHeader.startsWith('Bearer ')) return false;
  return authHeader.slice(7) === config.sharedToken;
}

// GET /api/v1/status
server.get('/api/v1/status', async (request, reply) => {
  if (!verifyToken(request.headers.authorization)) {
    return reply.status(401).send({ error: 'Unauthorized' });
  }

  const appRunning = await checkProcess(config);
  const appPid = getCurrentPid();

  return reply.status(200).send({
    machineId: config.machineId,
    appRunning,
    appPid,
    uptime: Math.floor((Date.now() - startTime) / 1000),
  });
});

// POST /api/v1/restart
server.post('/api/v1/restart', async (request, reply) => {
  if (!verifyToken(request.headers.authorization)) {
    return reply.status(401).send({ error: 'Unauthorized' });
  }

  const body = request.body as RestartRequest;
  if (!body || body.machineId !== config.machineId) {
    return reply.status(400).send({ error: 'machineId mismatch' });
  }

  log('info', 'Restart request received', { machineId: config.machineId, from: request.ip });

  const result = await restartProcess(config);

  if (!result.success) {
    return reply.status(429).send({ error: 'Restart rejected (cooldown or failure)', pid: result.pid });
  }

  return reply.status(200).send({ status: 'restarted', pid: result.pid });
});

async function start(): Promise<void> {
  try {
    await server.listen({ port: config.listenPort, host: config.listenHost });
    log('info', 'Agent server started', {
      machineId: config.machineId,
      port: config.listenPort,
      host: config.listenHost,
    });

    // Start heartbeat sender
    startHeartbeat(config);

    // Initial process check
    const running = await checkProcess(config);
    log('info', 'Initial process check', { processName: config.processName, running, pid: getCurrentPid() });
  } catch (err) {
    log('error', 'Failed to start agent', { error: err instanceof Error ? err.message : String(err) });
    process.exit(1);
  }
}

start();

export { server };
