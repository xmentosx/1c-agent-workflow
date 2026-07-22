'use strict';

const assert = require('assert');
const fs = require('fs');
const http = require('http');
const os = require('os');
const path = require('path');
const { spawn } = require('child_process');
const proxyPath = path.resolve(__dirname, '../../vibecoding1c-mcp-host/tools-list-proxy/mcp-tools-list-proxy.js');
const proxy = require(proxyPath);

const tools = [
  {
    name: 'search',
    description: 'Search project metadata. '.repeat(30),
    inputSchema: {
      type: 'object',
      description: 'root help',
      properties: { query: { type: 'string', minLength: 1, description: 'long nested help '.repeat(20) } },
      required: ['query'],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: true },
  },
  {
    name: 'check',
    description: 'Validate code without changing it.',
    inputSchema: { type: 'object', properties: { code: { type: 'string', description: 'source code' } }, required: ['code'] },
    annotations: { readOnlyHint: true, destructiveHint: false },
  },
];
const originalContract = proxy.describeContract(tools);
originalContract.toolDescriptions = {
  search: {
    sourceSha256: proxy.descriptionSha256(tools[0].description),
    compact: proxy.shortenDescription(tools[0].description),
  },
};
const payload = { jsonrpc: '2.0', id: 2, result: { tools } };
const source = Buffer.from(`event: message\ndata: ${JSON.stringify(payload)}\n\n`, 'utf8');
const transformed = proxy.transformToolsListResponse(source, 'text/event-stream', originalContract).toString('utf8');
const transformedPayload = JSON.parse(transformed.split('\n').find(line => line.startsWith('data:')).slice(5).trim());
const compactTools = transformedPayload.result.tools;

assert.strictEqual(compactTools.length, tools.length);
assert.deepStrictEqual(compactTools.map(tool => tool.name), tools.map(tool => tool.name));
assert.deepStrictEqual(compactTools.map(tool => tool.annotations), tools.map(tool => tool.annotations));
assert.strictEqual(proxy.describeContract(compactTools).structuralSha256, originalContract.structuralSha256);
assert.ok(compactTools[0].description.length <= 160);
assert.strictEqual(compactTools[1].description, tools[1].description);
assert.strictEqual(compactTools[0].inputSchema.description, tools[0].inputSchema.description);
assert.strictEqual(compactTools[0].inputSchema.properties.query.description, tools[0].inputSchema.properties.query.description);
assert.strictEqual(compactTools[0].inputSchema.properties.query.minLength, 1);
assert.strictEqual(compactTools[0].inputSchema.additionalProperties, false);
assert.ok(transformed.length < source.length * 0.75);

const changed = JSON.parse(JSON.stringify(payload));
changed.result.tools[0].description = `${tools[0].description} changed`;
const changedBody = Buffer.from(JSON.stringify(changed), 'utf8');
const changedResult = JSON.parse(proxy.transformToolsListResponse(changedBody, 'application/json', originalContract).toString('utf8'));
assert.strictEqual(changedResult.result.tools[0].description, changed.result.tools[0].description);

function listen(server) {
  return new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', () => resolve(server.address().port));
  });
}

function close(server) {
  return new Promise((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
}

function listenOn(server, port) {
  return new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(port, '127.0.0.1', resolve);
  });
}

async function reservePort() {
  const server = http.createServer();
  const port = await listen(server);
  await close(server);
  return port;
}

async function waitFor(check, message) {
  let lastError;
  for (let attempt = 0; attempt < 60; attempt += 1) {
    try {
      if (await check()) return;
    } catch (error) {
      lastError = error;
    }
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  throw new Error(`${message}${lastError ? `: ${lastError.message}` : ''}`);
}

function stopChild(child) {
  if (child.exitCode !== null) return Promise.resolve();
  return new Promise(resolve => {
    child.once('exit', resolve);
    child.kill();
  });
}

async function runCliStartupIntegration() {
  const proxyPort = await reservePort();
  const upstreamPort = await reservePort();
  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'itl-proxy-startup-'));
  const contractPath = path.join(tempRoot, 'tools-contract.json');
  fs.writeFileSync(contractPath, JSON.stringify({
    schemaVersion: 2,
    descriptionPolicy: { mode: 'approved-top-level-only' },
    servers: { fixture: originalContract },
  }));
  const child = spawn(process.execPath, [
    proxyPath,
    '--listen-port', String(proxyPort),
    '--upstream-url', `http://127.0.0.1:${upstreamPort}/mcp`,
    '--server-id', 'fixture',
    '--contract-path', contractPath,
    '--readiness-timeout-ms', '1000',
  ], { stdio: ['ignore', 'pipe', 'pipe'] });
  let childOutput = '';
  child.stdout.on('data', chunk => { childOutput += chunk.toString('utf8'); });
  child.stderr.on('data', chunk => { childOutput += chunk.toString('utf8'); });
  let upstream;

  try {
    await waitFor(async () => {
      if (child.exitCode !== null) throw new Error(`proxy exited early: ${childOutput}`);
      const response = await fetch(`http://127.0.0.1:${proxyPort}/health`);
      return response.status === 200;
    }, 'proxy did not expose process liveness before upstream startup');
    assert.match(childOutput, /proxy listening/);

    const unready = await fetch(`http://127.0.0.1:${proxyPort}/ready`);
    assert.strictEqual(unready.status, 503);
    assert.strictEqual((await unready.json()).status, 'unready');

    upstream = http.createServer((request, response) => {
      const chunks = [];
      request.on('data', chunk => chunks.push(chunk));
      request.on('end', () => {
        const body = chunks.length ? JSON.parse(Buffer.concat(chunks).toString('utf8')) : null;
        if (body && body.method === 'initialize') {
          response.writeHead(200, { 'content-type': 'application/json' });
          response.end(JSON.stringify({ jsonrpc: '2.0', id: body.id, result: { protocolVersion: '2025-03-26', capabilities: { tools: {} }, serverInfo: { name: 'fixture', version: '1.0' } } }));
          return;
        }
        if (body && body.method === 'notifications/initialized') {
          response.writeHead(202);
          response.end();
          return;
        }
        if (body && body.method === 'tools/list') {
          response.writeHead(200, { 'content-type': 'application/json' });
          response.end(JSON.stringify({ jsonrpc: '2.0', id: body.id, result: { tools } }));
          return;
        }
        response.writeHead(400);
        response.end();
      });
    });
    await listenOn(upstream, upstreamPort);
    await waitFor(async () => {
      const response = await fetch(`http://127.0.0.1:${proxyPort}/ready`);
      return response.status === 200 && (await response.json()).status === 'ready';
    }, 'proxy readiness did not recover after upstream startup');
  } finally {
    if (upstream?.listening) await close(upstream);
    await stopChild(child);
    fs.rmSync(tempRoot, { recursive: true, force: true });
  }
}

async function runIntegration() {
  const sessions = new Set();
  const calls = [];
  let initialized = 0;
  let deleted = 0;
  const upstream = http.createServer((request, response) => {
    const chunks = [];
    request.on('data', chunk => chunks.push(chunk));
    request.on('end', () => {
      if (request.url === '/mcp') {
        response.writeHead(307, { location: '/mcp/' });
        response.end();
        return;
      }
      assert.strictEqual(request.url, '/mcp/');
      const body = chunks.length ? JSON.parse(Buffer.concat(chunks).toString('utf8')) : null;
      const sessionId = request.headers['mcp-session-id'];
      if (request.method === 'DELETE') {
        assert.ok(sessions.delete(sessionId));
        deleted += 1;
        response.writeHead(200, { 'content-type': 'application/json' });
        response.end(JSON.stringify({ ok: true }));
        return;
      }
      if (body && body.method === 'initialize') {
        const created = `fixture-session-${++initialized}`;
        sessions.add(created);
        response.writeHead(200, { 'content-type': 'application/json', 'mcp-session-id': created });
        response.end(JSON.stringify({ jsonrpc: '2.0', id: body.id, result: { protocolVersion: '2025-03-26', capabilities: { tools: {} }, serverInfo: { name: 'fixture', version: '1.0' } } }));
        return;
      }
      assert.ok(sessions.has(sessionId));
      if (body && body.method === 'notifications/initialized') {
        response.writeHead(202);
        response.end();
        return;
      }
      if (body && body.method === 'tools/list') {
        response.writeHead(200, { 'content-type': 'application/json' });
        response.end(JSON.stringify({ jsonrpc: '2.0', id: body.id, result: { tools } }));
        return;
      }
      if (body && body.method === 'tools/call') {
        calls.push({ body, sessionId });
        response.writeHead(200, { 'content-type': 'application/json' });
        response.end(JSON.stringify({ jsonrpc: '2.0', id: body.id, result: { content: [{ type: 'text', text: 'forwarded' }] } }));
        return;
      }
      response.writeHead(400);
      response.end();
    });
  });
  const upstreamPort = await listen(upstream);
  const proxyServer = await proxy.startProxy({
    'upstream-url': `http://127.0.0.1:${upstreamPort}/mcp`,
    'listen-port': '0',
    'server-id': 'fixture',
    'readiness-timeout-ms': '2000',
  }, originalContract);
  const proxyPort = proxyServer.address().port;
  const proxyUrl = `http://127.0.0.1:${proxyPort}`;
  const commonHeaders = { accept: 'application/json, text/event-stream', 'content-type': 'application/json' };

  try {
    const health = await fetch(`${proxyUrl}/health`);
    assert.strictEqual(health.status, 200);
    assert.strictEqual((await health.json()).status, 'ok');
    assert.strictEqual(initialized, 0);

    const ready = await fetch(`${proxyUrl}/ready`);
    assert.strictEqual(ready.status, 200);
    assert.strictEqual((await ready.json()).status, 'ready');
    assert.strictEqual(initialized, 1);
    assert.strictEqual(deleted, 1);
    assert.strictEqual(sessions.size, 0);
    const normalizedHealth = await fetch(`${proxyUrl}/health`);
    assert.match((await normalizedHealth.json()).upstream, /\/mcp\/$/);

    const init = await fetch(`${proxyUrl}/mcp`, {
      method: 'POST', headers: commonHeaders,
      body: JSON.stringify({ jsonrpc: '2.0', id: 10, method: 'initialize', params: { protocolVersion: '2025-03-26', capabilities: {}, clientInfo: { name: 'fixture-client', version: '1.0' } } }),
    });
    assert.strictEqual(init.status, 200);
    const clientSession = init.headers.get('mcp-session-id');
    assert.ok(clientSession);
    await init.text();
    const sessionHeaders = { ...commonHeaders, 'mcp-session-id': clientSession };
    const notification = await fetch(`${proxyUrl}/mcp`, {
      method: 'POST', headers: sessionHeaders,
      body: JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }),
    });
    assert.strictEqual(notification.status, 202);
    const toolCall = await fetch(`${proxyUrl}/mcp`, {
      method: 'POST', headers: sessionHeaders,
      body: JSON.stringify({ jsonrpc: '2.0', id: 11, method: 'tools/call', params: { name: 'check', arguments: { code: 'x' } } }),
    });
    assert.strictEqual(toolCall.status, 200);
    assert.strictEqual((await toolCall.json()).result.content[0].text, 'forwarded');
    assert.deepStrictEqual(calls, [{
      body: { jsonrpc: '2.0', id: 11, method: 'tools/call', params: { name: 'check', arguments: { code: 'x' } } },
      sessionId: clientSession,
    }]);

    const clientDelete = await fetch(`${proxyUrl}/mcp`, { method: 'DELETE', headers: sessionHeaders });
    assert.strictEqual(clientDelete.status, 200);
    assert.strictEqual(deleted, 2);

    await close(upstream);
    const unready = await fetch(`${proxyUrl}/ready`);
    assert.strictEqual(unready.status, 503);
    const unreadyBody = await unready.json();
    assert.strictEqual(unreadyBody.status, 'unready');
    assert.ok(unreadyBody.error.length > 0 && unreadyBody.error.length <= 500);
  } finally {
    if (upstream.listening) await close(upstream);
    await close(proxyServer);
  }
}

runCliStartupIntegration().then(runIntegration).then(() => {
  process.stdout.write('tools-list proxy unit contract passed\n');
}, error => {
  process.stderr.write(`${error.stack || error.message}\n`);
  process.exitCode = 1;
});
