import Fastify from 'fastify';
import * as fs from 'node:fs';
import * as path from 'node:path';
import { fileURLToPath } from 'node:url';
import { StateManager } from './state-manager.js';
import { log } from './logger.js';
import type { NodeConfig, HeartbeatPayload } from './types.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const configPath = path.resolve(__dirname, '..', 'config', 'nodes.json');
const configs: NodeConfig[] = JSON.parse(fs.readFileSync(configPath, 'utf-8'));

const stateManager = new StateManager(configs);
const tokenMap = new Map<string, string>();
for (const cfg of configs) {
  tokenMap.set(cfg.machineId, cfg.token);
}

const server = Fastify({ logger: false });

// POST /api/v1/heartbeat
server.post('/api/v1/heartbeat', async (request, reply) => {
  const authHeader = request.headers.authorization;
  if (!authHeader || !authHeader.startsWith('Bearer ')) {
    return reply.status(401).send({ error: 'Missing or invalid authorization header' });
  }

  const token = authHeader.slice(7);
  const body = request.body as HeartbeatPayload;

  if (!body || !body.machineId) {
    return reply.status(400).send({ error: 'Missing machineId in body' });
  }

  const expectedToken = tokenMap.get(body.machineId);
  if (!expectedToken || token !== expectedToken) {
    log('warn', 'Heartbeat token mismatch', { machineId: body.machineId });
    return reply.status(401).send({ error: 'Unauthorized' });
  }

  const ok = stateManager.handleHeartbeat(body);
  if (!ok) {
    return reply.status(404).send({ error: 'Unknown machineId' });
  }

  return reply.status(200).send({ status: 'ok' });
});

// GET /api/v1/nodes
server.get('/api/v1/nodes', async (_request, reply) => {
  const states = stateManager.getAllStates();
  return reply.status(200).send(states);
});

// GET /api/v1/nodes/:machineId
server.get<{ Params: { machineId: string } }>('/api/v1/nodes/:machineId', async (request, reply) => {
  const state = stateManager.getState(request.params.machineId);
  if (!state) {
    return reply.status(404).send({ error: 'Node not found' });
  }
  return reply.status(200).send(state);
});

const PORT = parseInt(process.env['PORT'] ?? '3100', 10);
const HOST = process.env['HOST'] ?? '0.0.0.0';

async function start(): Promise<void> {
  try {
    await server.listen({ port: PORT, host: HOST });
    log('info', 'Monitor server started', { port: PORT, host: HOST, nodes: configs.length });
    stateManager.startLoops();
  } catch (err) {
    log('error', 'Failed to start server', { error: err instanceof Error ? err.message : String(err) });
    process.exit(1);
  }
}

start();

export { server, stateManager };
