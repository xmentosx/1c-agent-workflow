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

const betaTools = JSON.parse(JSON.stringify(tools));
betaTools[0].outputSchema = { type: 'object', properties: { answer: { type: 'string' }, sources: { type: 'array' } } };
betaTools[1].outputSchema = { type: 'object', properties: { result: { type: 'string' } }, required: ['result'] };
const betaContract = { ...proxy.describeContract(betaTools), legacyCodeCheckerResult: true };
const betaList = { jsonrpc: '2.0', id: 3, result: { tools: betaTools } };
const publicBetaList = JSON.parse(proxy.transformToolsListResponse(Buffer.from(JSON.stringify(betaList)), 'application/json', betaContract));
assert.strictEqual(publicBetaList.result.tools[0].outputSchema.properties.result.type, 'string');
assert.ok(publicBetaList.result.tools[0].outputSchema.required.includes('result'));
assert.deepStrictEqual(publicBetaList.result.tools[0].outputSchema.properties.sources, { type: 'array' });
assert.deepStrictEqual(publicBetaList.result.tools[1].outputSchema, betaTools[1].outputSchema);
assert.deepStrictEqual(betaTools[0].outputSchema.properties, { answer: { type: 'string' }, sources: { type: 'array' } });

const betaCall = { jsonrpc: '2.0', id: 4, result: { content: [{ type: 'text', text: '{"answer":"Готово"}' }], structuredContent: { answer: 'Готово', sources: ['source'] }, isError: false } };
const publicBetaCall = JSON.parse(proxy.transformCodeCheckerCallResponse(Buffer.from(JSON.stringify(betaCall)), 'application/json'));
assert.strictEqual(publicBetaCall.result.content[0].text, 'Готово');
assert.strictEqual(publicBetaCall.result.structuredContent.result, 'Готово');
assert.deepStrictEqual(publicBetaCall.result.structuredContent.sources, ['source']);
assert.strictEqual(betaCall.result.structuredContent.result, undefined);
const errorCall = { jsonrpc: '2.0', id: 5, result: { isError: true, content: [{ type: 'text', text: 'capacity' }], structuredContent: { retryable: true } } };
const publicError = JSON.parse(proxy.transformCodeCheckerCallResponse(Buffer.from(JSON.stringify(errorCall)), 'application/json'));
assert.deepStrictEqual(publicError, errorCall);
assert.throws(() => proxy.transformCodeCheckerCallResponse(Buffer.from(JSON.stringify({ jsonrpc: '2.0', id: 6, result: { structuredContent: { other: 'text' } } })), 'application/json'), /no answer string/);
const betaSse = Buffer.from(`event: message\ndata: ${JSON.stringify(betaCall)}\n\n`);
const publicBetaSse = proxy.transformCodeCheckerCallResponse(betaSse, 'text/event-stream').toString('utf8');
assert.strictEqual(JSON.parse(publicBetaSse.split('\n').find(line => line.startsWith('data:')).slice(5).trim()).result.structuredContent.result, 'Готово');

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
  let initialized = 0;

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
          initialized += 1;
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
    const firstClient = await fetch(`http://127.0.0.1:${proxyPort}/mcp`, {
      method: 'POST',
      headers: { accept: 'application/json, text/event-stream', 'content-type': 'application/json' },
      body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2025-03-26', capabilities: {}, clientInfo: { name: 'fixture-client', version: '1.0' } } }),
    });
    assert.strictEqual(firstClient.status, 200);
    assert.strictEqual((await firstClient.json()).result.serverInfo.name, 'fixture');
    assert.strictEqual(initialized, 2, 'the first client request must trigger one readiness initialize and then its own initialize');
    const recovered = await fetch(`http://127.0.0.1:${proxyPort}/health`);
    assert.strictEqual((await recovered.json()).ready, true);
  } finally {
    if (upstream?.listening) await close(upstream);
    await stopChild(child);
    fs.rmSync(tempRoot, { recursive: true, force: true });
  }
}

async function runSingleFlightIntegration() {
  let initialized = 0;
  const upstream = http.createServer((request, response) => {
    const chunks = [];
    request.on('data', chunk => chunks.push(chunk));
    request.on('end', () => {
      const body = chunks.length ? JSON.parse(Buffer.concat(chunks).toString('utf8')) : null;
      if (body && body.method === 'initialize') {
        initialized += 1;
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
  const upstreamPort = await listen(upstream);
  const proxyServer = await proxy.startProxy({
    'upstream-url': `http://127.0.0.1:${upstreamPort}/mcp`,
    'listen-port': '0',
    'server-id': 'fixture',
    'readiness-timeout-ms': '2000',
  }, originalContract);
  const proxyUrl = `http://127.0.0.1:${proxyServer.address().port}/mcp`;
  const headers = { accept: 'application/json, text/event-stream', 'content-type': 'application/json' };
  try {
    const responses = await Promise.all([20, 21].map(id => fetch(proxyUrl, {
      method: 'POST',
      headers,
      body: JSON.stringify({ jsonrpc: '2.0', id, method: 'initialize', params: { protocolVersion: '2025-03-26', capabilities: {}, clientInfo: { name: `fixture-${id}`, version: '1.0' } } }),
    })));
    assert.deepStrictEqual(responses.map(response => response.status), [200, 200]);
    assert.strictEqual(initialized, 3, 'concurrent first requests must share one readiness probe');
  } finally {
    await close(proxyServer);
    await close(upstream);
  }
}

async function runIntegration() {
  const sessions = new Set();
  const calls = [];
  let initialized = 0;
  let deleted = 0;
  let retryListAttempts = 0;
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
        if (body.id === 13) {
          retryListAttempts += 1;
          if (retryListAttempts === 1) {
            request.socket.destroy();
            return;
          }
        }
        response.writeHead(200, { 'content-type': 'application/json' });
        response.end(JSON.stringify({ jsonrpc: '2.0', id: body.id, result: { tools } }));
        return;
      }
      if (body && body.method === 'tools/call') {
        calls.push({ body, sessionId, proxyMarker: request.headers['x-itl-mcp-proxy'] });
        if (body.params && body.params.name === 'disconnect') {
          request.socket.destroy();
          return;
        }
        if (body.params && body.params.name === 'slow') {
          setTimeout(() => {
            response.writeHead(200, { 'content-type': 'application/json' });
            response.end(JSON.stringify({ jsonrpc: '2.0', id: body.id, result: { content: [{ type: 'text', text: 'slow-forwarded' }] } }));
          }, 500);
          return;
        }
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
    'readiness-timeout-ms': '200',
    'upstream-timeout-ms': '2000',
  }, originalContract);
  const proxyPort = proxyServer.address().port;
  const proxyUrl = `http://127.0.0.1:${proxyPort}`;
  const commonHeaders = { accept: 'application/json, text/event-stream', 'content-type': 'application/json' };

  try {
    const health = await fetch(`${proxyUrl}/health`);
    assert.strictEqual(health.status, 200);
    const initialHealth = await health.json();
    assert.strictEqual(initialHealth.status, 'ok');
    assert.strictEqual(initialHealth.ready, false);
    assert.strictEqual(initialized, 0);

    const init = await fetch(`${proxyUrl}/mcp`, {
      method: 'POST', headers: commonHeaders,
      body: JSON.stringify({ jsonrpc: '2.0', id: 10, method: 'initialize', params: { protocolVersion: '2025-03-26', capabilities: {}, clientInfo: { name: 'fixture-client', version: '1.0' } } }),
    });
    assert.strictEqual(init.status, 200);
    const clientSession = init.headers.get('mcp-session-id');
    assert.ok(clientSession);
    await init.text();
    assert.strictEqual(initialized, 2, 'first normal initialize must self-qualify the proxy without an explicit /ready call');
    assert.strictEqual(deleted, 1);
    assert.strictEqual(sessions.size, 1);
    const normalizedHealth = await fetch(`${proxyUrl}/health`);
    const normalizedHealthBody = await normalizedHealth.json();
    assert.strictEqual(normalizedHealthBody.ready, true);
    assert.match(normalizedHealthBody.upstream, /\/mcp\/$/);
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
      proxyMarker: 'tools-list-proxy',
    }]);

    const slowToolCall = await fetch(`${proxyUrl}/mcp`, {
      method: 'POST', headers: sessionHeaders,
      body: JSON.stringify({ jsonrpc: '2.0', id: 14, method: 'tools/call', params: { name: 'slow', arguments: {} } }),
    });
    assert.strictEqual(slowToolCall.status, 200, 'tools/call must use the forwarding timeout rather than the readiness timeout');
    assert.strictEqual((await slowToolCall.json()).result.content[0].text, 'slow-forwarded');

    const retriedList = await fetch(`${proxyUrl}/mcp`, {
      method: 'POST', headers: sessionHeaders,
      body: JSON.stringify({ jsonrpc: '2.0', id: 13, method: 'tools/list', params: {} }),
    });
    assert.strictEqual(retriedList.status, 200);
    assert.strictEqual((await retriedList.json()).result.tools.length, tools.length);
    assert.strictEqual(retryListAttempts, 2, 'tools/list may be retried once after successful requalification');

    const failedToolCall = await fetch(`${proxyUrl}/mcp`, {
      method: 'POST', headers: sessionHeaders,
      body: JSON.stringify({ jsonrpc: '2.0', id: 12, method: 'tools/call', params: { name: 'disconnect', arguments: {} } }),
    });
    assert.strictEqual(failedToolCall.status, 502);
    assert.strictEqual((await failedToolCall.json()).error, 'MCP_UPSTREAM_FAILED');
    assert.strictEqual(calls.filter(call => call.body.params.name === 'disconnect').length, 1, 'tools/call must never be replayed after a transport failure');

    const clientDelete = await fetch(`${proxyUrl}/mcp`, { method: 'DELETE', headers: sessionHeaders });
    assert.strictEqual(clientDelete.status, 200);
    assert.strictEqual(deleted, 4);

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

async function runBetaCodeCheckerIntegration() {
  const typedTool = {
    name: 'ask_1c_ai',
    inputSchema: { type: 'object', properties: { question: { type: 'string' } }, required: ['question'] },
    outputSchema: { type: 'object', properties: { answer: { type: 'string' }, sources: { type: 'array' } } },
  };
  const contract = { ...proxy.describeContract([typedTool]), legacyCodeCheckerResult: true };
  let nextSession = 0;
  const upstream = http.createServer((request, response) => {
    const chunks = [];
    request.on('data', chunk => chunks.push(chunk));
    request.on('end', () => {
      const body = chunks.length ? JSON.parse(Buffer.concat(chunks).toString('utf8')) : null;
      response.setHeader('content-type', 'application/json');
      if (request.method === 'DELETE') { response.end('{}'); return; }
      if (body.method === 'initialize') {
        response.setHeader('mcp-session-id', `beta-session-${++nextSession}`);
        response.end(JSON.stringify({ jsonrpc: '2.0', id: body.id, result: { protocolVersion: '2025-03-26', capabilities: { tools: {} } } }));
        return;
      }
      if (body.method === 'notifications/initialized') { response.statusCode = 202; response.end(); return; }
      if (body.method === 'tools/list') { response.end(JSON.stringify({ jsonrpc: '2.0', id: body.id, result: { tools: [typedTool] } })); return; }
      if (body.method === 'tools/call') {
        response.end(JSON.stringify({ jsonrpc: '2.0', id: body.id, result: {
          content: [{ type: 'text', text: '{"answer":"Ответ beta"}' }],
          structuredContent: { answer: 'Ответ beta', sources: ['new-field'] }, isError: false,
        } }));
        return;
      }
      response.statusCode = 400; response.end('{}');
    });
  });
  const upstreamPort = await listen(upstream);
  const proxyServer = await proxy.startProxy({
    'upstream-url': `http://127.0.0.1:${upstreamPort}/mcp`,
    'listen-port': '0', 'server-id': 'codechecker',
  }, contract);
  const url = `http://127.0.0.1:${proxyServer.address().port}/mcp`;
  const headers = { accept: 'application/json, text/event-stream', 'content-type': 'application/json' };
  try {
    const init = await fetch(url, { method: 'POST', headers, body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2025-03-26', capabilities: {}, clientInfo: { name: 'old-client', version: '1' } } }) });
    assert.strictEqual(init.status, 200);
    headers['mcp-session-id'] = init.headers.get('mcp-session-id');
    const list = await fetch(url, { method: 'POST', headers, body: JSON.stringify({ jsonrpc: '2.0', id: 2, method: 'tools/list', params: {} }) });
    const publicTool = (await list.json()).result.tools[0];
    assert.strictEqual(publicTool.outputSchema.properties.result.type, 'string');
    assert.ok(publicTool.outputSchema.required.includes('result'));
    const call = await fetch(url, { method: 'POST', headers, body: JSON.stringify({ jsonrpc: '2.0', id: 3, method: 'tools/call', params: { name: 'ask_1c_ai', arguments: { question: 'Тест' } } }) });
    const answer = (await call.json()).result;
    assert.strictEqual(answer.content[0].text, 'Ответ beta');
    assert.strictEqual(answer.structuredContent.result, 'Ответ beta');
    assert.deepStrictEqual(answer.structuredContent.sources, ['new-field']);
  } finally {
    await close(proxyServer);
    await close(upstream);
  }
}

async function runBetaSyntaxIntegration() {
  const pluginTool = {
    name: 'plugin_state',
    inputSchema: { type: 'object', properties: {} },
    outputSchema: { type: 'object', properties: { status: { type: 'string' } }, required: ['status'] },
  };
  const syntaxTool = {
    name: 'syntaxcheck',
    inputSchema: { type: 'object', properties: { code: { type: 'string' } }, required: ['code'] },
    outputSchema: {
      type: 'object',
      properties: { diagnostics: { type: 'array' }, summary: { type: 'object' } },
      required: ['diagnostics', 'summary'],
      additionalProperties: false,
    },
  };
  const contract = { ...proxy.describeContract([pluginTool, syntaxTool]), legacySyntaxJsonl: true };
  const toon = [
    'events[3]:',
    '  - type: start',
    '    total_files: 1',
    '    line_base: 1',
    '  - type: file',
    '    path: module.bsl',
    '    diagnostics[1]{code,message,severity,start_line,start_column,end_line,end_column}:',
    '      CodeOutOfRegion,Процедура вне области,Hint,1,10,1,14',
    '    metrics:',
    '      functions: 1',
    '    diagnostic_asides[1]{diagnostic,field,value}:',
    '      0,tags,Unnecessary',
    '  - type: done',
    '    total_diagnostics: 1',
    '    failed_files: 0',
  ].join('\n');
  const typed = { diagnostics: [{ code: 'CodeOutOfRegion' }], summary: { total: 1 } };
  const betaResult = { content: [{ type: 'text', text: toon }], structuredContent: typed, isError: false };
  const upstream = http.createServer((request, response) => {
    const chunks = [];
    request.on('data', chunk => chunks.push(chunk));
    request.on('end', () => {
      const body = chunks.length ? JSON.parse(Buffer.concat(chunks).toString('utf8')) : null;
      response.setHeader('content-type', 'application/json');
      if (request.method === 'DELETE') { response.end('{}'); return; }
      if (body.method === 'initialize') {
        response.setHeader('mcp-session-id', 'syntax-session');
        response.end(JSON.stringify({ jsonrpc: '2.0', id: body.id, result: { protocolVersion: '2025-03-26', capabilities: { tools: {} } } }));
        return;
      }
      if (body.method === 'notifications/initialized') { response.statusCode = 202; response.end(); return; }
      if (body.method === 'tools/list') { response.end(JSON.stringify({ jsonrpc: '2.0', id: body.id, result: { tools: [pluginTool, syntaxTool] } })); return; }
      if (body.method === 'tools/call') {
        const result = body.params.name === 'plugin_state'
          ? { content: [{ type: 'text', text: '{"status":"ok"}' }], structuredContent: { status: 'ok' }, isError: false }
          : betaResult;
        response.end(JSON.stringify({ jsonrpc: '2.0', id: body.id, result })); return;
      }
      response.statusCode = 400; response.end('{}');
    });
  });
  const upstreamPort = await listen(upstream);
  const proxyServer = await proxy.startProxy({
    'upstream-url': `http://127.0.0.1:${upstreamPort}/mcp`,
    'listen-port': '0', 'server-id': 'syntax',
  }, contract);
  const url = `http://127.0.0.1:${proxyServer.address().port}/mcp`;
  const headers = { accept: 'application/json, text/event-stream', 'content-type': 'application/json' };
  try {
    const init = await fetch(url, { method: 'POST', headers, body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2025-03-26', capabilities: {}, clientInfo: { name: 'old-client', version: '1' } } }) });
    assert.strictEqual(init.status, 200);
    headers['mcp-session-id'] = init.headers.get('mcp-session-id');
    const list = await fetch(url, { method: 'POST', headers, body: JSON.stringify({ jsonrpc: '2.0', id: 2, method: 'tools/list', params: {} }) });
    const publicTools = (await list.json()).result.tools;
    const publicTool = publicTools.find(tool => tool.name === 'syntaxcheck');
    assert.deepStrictEqual(publicTools.find(tool => tool.name === 'plugin_state').outputSchema, pluginTool.outputSchema);
    assert.strictEqual(publicTool.outputSchema.properties.result.type, 'string');
    assert.ok(publicTool.outputSchema.required.includes('result'));
    assert.deepStrictEqual(publicTool.outputSchema.properties.diagnostics, syntaxTool.outputSchema.properties.diagnostics);
    assert.strictEqual(publicTool.outputSchema.additionalProperties, false);
    const call = await fetch(url, { method: 'POST', headers, body: JSON.stringify({ jsonrpc: '2.0', id: 3, method: 'tools/call', params: { name: 'syntaxcheck', arguments: { code: 'Процедура Тест()' } } }) });
    assert.strictEqual(call.status, 200);
    const answer = (await call.json()).result;
    assert.strictEqual(answer.content[0].text, answer.structuredContent.result);
    assert.deepStrictEqual(answer.content[0].text.trim().split('\n').map(JSON.parse), [
      { type: 'start', total_files: 1, line_base: 1 },
      { type: 'file', path: 'module.bsl', diagnostics: [{ code: 'CodeOutOfRegion', message: 'Процедура вне области', severity: 'Hint', start_line: 1, start_column: 10, end_line: 1, end_column: 14 }], metrics: { functions: 1 }, diagnostic_asides: [{ diagnostic: 0, field: 'tags', value: 'Unnecessary' }] },
      { type: 'done', total_diagnostics: 1, failed_files: 0 },
    ]);
    assert.deepStrictEqual(answer.structuredContent.diagnostics, typed.diagnostics);
    const pluginCall = await fetch(url, { method: 'POST', headers, body: JSON.stringify({ jsonrpc: '2.0', id: 6, method: 'tools/call', params: { name: 'plugin_state', arguments: {} } }) });
    assert.strictEqual(pluginCall.status, 200);
    assert.deepStrictEqual((await pluginCall.json()).result.structuredContent, { status: 'ok' });
    const error = await proxy.transformSyntaxCallResponse(Buffer.from(JSON.stringify({ jsonrpc: '2.0', id: 4, result: { isError: true, content: [{ type: 'text', text: 'analyzer failed' }] } })), 'application/json');
    assert.strictEqual(JSON.parse(error).result.isError, true);
    await assert.rejects(proxy.transformSyntaxCallResponse(Buffer.from(JSON.stringify({ jsonrpc: '2.0', id: 5, result: { ...betaResult, content: [{ type: 'text', text: 'events: malformed' }] } })), 'application/json'), /valid events/);
  } finally {
    await close(proxyServer);
    await close(upstream);
  }
}

runCliStartupIntegration().then(runSingleFlightIntegration).then(runIntegration).then(runBetaCodeCheckerIntegration).then(runBetaSyntaxIntegration).then(() => {
  process.stdout.write('tools-list proxy unit contract passed\n');
}, error => {
  process.stderr.write(`${error.stack || error.message}\n`);
  process.exitCode = 1;
});
