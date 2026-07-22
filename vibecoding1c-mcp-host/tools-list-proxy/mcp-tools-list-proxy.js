'use strict';

const crypto = require('crypto');
const fs = require('fs');
const http = require('http');
const https = require('https');

function parseArgs(argv) {
  const result = {};
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    if (!token.startsWith('--')) throw new Error(`Unexpected argument: ${token}`);
    const name = token.slice(2);
    if ((index + 1) >= argv.length || argv[index + 1].startsWith('--')) result[name] = true;
    else result[name] = argv[++index];
  }
  return result;
}

function withoutDescriptions(value) {
  if (Array.isArray(value)) return value.map(withoutDescriptions);
  if (!value || typeof value !== 'object') return value;
  const result = {};
  for (const key of Object.keys(value).sort()) {
    if (key === 'description') continue;
    result[key] = withoutDescriptions(value[key]);
  }
  return result;
}

function stableValue(value) {
  if (Array.isArray(value)) return value.map(stableValue);
  if (!value || typeof value !== 'object') return value;
  const result = {};
  for (const key of Object.keys(value).sort()) result[key] = stableValue(value[key]);
  return result;
}

function describeContract(tools) {
  const structural = [...tools]
    .sort((left, right) => String(left.name).localeCompare(String(right.name)))
    .map(tool => stableValue({
      name: tool.name,
      inputSchema: withoutDescriptions(tool.inputSchema || {}),
      outputSchema: withoutDescriptions(tool.outputSchema || null),
      annotations: tool.annotations || null,
    }));
  const serialized = JSON.stringify(structural);
  return {
    toolCount: structural.length,
    structuralSha256: crypto.createHash('sha256').update(serialized, 'utf8').digest('hex'),
    toolNames: structural.map(tool => tool.name),
    noArgumentTools: [...tools].filter(tool => !tool.inputSchema || !Array.isArray(tool.inputSchema.required) || tool.inputSchema.required.length === 0).map(tool => tool.name).sort(),
  };
}

function parseJsonRpcBody(body, contentType) {
  const text = body.toString('utf8');
  if (String(contentType || '').toLowerCase().includes('text/event-stream')) {
    for (const line of text.split(/\r?\n/)) {
      if (!line.startsWith('data:')) continue;
      const candidate = line.slice(5).trim();
      if (!candidate || candidate === '[DONE]') continue;
      return JSON.parse(candidate);
    }
    throw new Error('SSE response contained no JSON-RPC data event.');
  }
  return JSON.parse(text);
}

function requestBuffer(target, method, headers, body, options = {}, redirectCount = 0) {
  return new Promise((resolve, reject) => {
    const transport = target.protocol === 'https:' ? https : http;
    const timeoutMs = Number(options.timeoutMs || 30000);
    const requestHeaders = { ...headers };
    if (body) requestHeaders['content-length'] = Buffer.byteLength(body);
    const request = transport.request({
      protocol: target.protocol,
      hostname: target.hostname,
      port: target.port || undefined,
      path: `${target.pathname}${target.search}`,
      method,
      headers: requestHeaders,
    }, response => {
      if ([301, 302, 307, 308].includes(response.statusCode || 0) && response.headers.location && redirectCount < 3) {
        response.resume();
        const redirected = new URL(response.headers.location, target);
        requestBuffer(redirected, method, headers, body, options, redirectCount + 1).then(resolve, reject);
        return;
      }
      const chunks = [];
      response.on('data', chunk => chunks.push(chunk));
      response.on('end', () => resolve({
        statusCode: response.statusCode || 500,
        headers: response.headers,
        body: Buffer.concat(chunks),
        finalUrl: target.toString(),
      }));
    });
    request.on('error', reject);
    request.setTimeout(timeoutMs, () => request.destroy(new Error(`HTTP request timed out after ${timeoutMs} ms.`)));
    if (body) request.write(body);
    request.end();
  });
}

async function initializeAndList(upstreamUrl, options = {}) {
  let target = new URL(upstreamUrl);
  const commonHeaders = { accept: 'application/json, text/event-stream', 'content-type': 'application/json' };
  const initializeBody = JSON.stringify({
    jsonrpc: '2.0', id: 1, method: 'initialize',
    params: { protocolVersion: '2025-03-26', capabilities: {}, clientInfo: { name: 'itl-tools-contract-probe', version: '1.0.0' } },
  });
  let sessionId;
  let sessionHeaders;
  let primaryError;
  try {
    const initialized = await requestBuffer(target, 'POST', commonHeaders, initializeBody, options);
    target = new URL(initialized.finalUrl);
    if (initialized.statusCode < 200 || initialized.statusCode >= 300) {
      throw new Error(`initialize failed with HTTP ${initialized.statusCode}: ${initialized.body.toString('utf8').slice(0, 500)}`);
    }
    const initializePayload = parseJsonRpcBody(initialized.body, initialized.headers['content-type']);
    if (initializePayload.error) throw new Error(`initialize failed: ${JSON.stringify(initializePayload.error)}`);
    sessionId = initialized.headers['mcp-session-id'];
    sessionHeaders = { ...commonHeaders };
    if (sessionId) sessionHeaders['mcp-session-id'] = sessionId;
    const protocolVersion = initializePayload.result && initializePayload.result.protocolVersion;
    if (protocolVersion) sessionHeaders['mcp-protocol-version'] = protocolVersion;

    const notification = await requestBuffer(
      target,
      'POST',
      sessionHeaders,
      JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }),
      options,
    );
    if (notification.statusCode < 200 || notification.statusCode >= 300) {
      throw new Error(`notifications/initialized failed with HTTP ${notification.statusCode}: ${notification.body.toString('utf8').slice(0, 500)}`);
    }

    const tools = [];
    let cursor;
    let requestId = 2;
    do {
      const params = cursor ? { cursor } : {};
      const response = await requestBuffer(
        target,
        'POST',
        sessionHeaders,
        JSON.stringify({ jsonrpc: '2.0', id: requestId++, method: 'tools/list', params }),
        options,
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw new Error(`tools/list failed with HTTP ${response.statusCode}: ${response.body.toString('utf8').slice(0, 500)}`);
      }
      const payload = parseJsonRpcBody(response.body, response.headers['content-type']);
      if (payload.error) throw new Error(`tools/list failed: ${JSON.stringify(payload.error)}`);
      const result = payload.result || {};
      tools.push(...(Array.isArray(result.tools) ? result.tools : []));
      cursor = result.nextCursor || null;
    } while (cursor);
    return { tools, upstreamUrl: target.toString() };
  } catch (error) {
    primaryError = error;
    throw error;
  } finally {
    if (sessionId && sessionHeaders) {
      try {
        const terminated = await requestBuffer(target, 'DELETE', sessionHeaders, '', options);
        if (terminated.statusCode < 200 || terminated.statusCode >= 300) {
          throw new Error(`session DELETE failed with HTTP ${terminated.statusCode}: ${terminated.body.toString('utf8').slice(0, 500)}`);
        }
      } catch (error) {
        if (!primaryError) throw error;
      }
    }
  }
}

function shortenDescription(value) {
  const normalized = String(value || '').replace(/\s+/g, ' ').trim();
  if (normalized.length <= 160) return normalized;
  const firstSentence = normalized.match(/^.{1,157}?[.!?](?:\s|$)/);
  if (firstSentence && firstSentence[0].trim().length >= 40) return firstSentence[0].trim().slice(0, 160);
  return `${normalized.slice(0, 157).trimEnd()}...`;
}

function descriptionSha256(value) {
  const normalized = String(value || '').replace(/\s+/g, ' ').trim();
  return crypto.createHash('sha256').update(normalized, 'utf8').digest('hex');
}

function compactTool(tool, expected = {}) {
  const result = { ...tool };
  const approved = expected && expected.toolDescriptions && expected.toolDescriptions[tool.name];
  if (!approved) return result;
  if (descriptionSha256(tool.description) !== approved.sourceSha256) return result;
  const compact = String(approved.compact || '').trim();
  const maximum = Number(expected.descriptionPolicy && expected.descriptionPolicy.maximumApprovedDescriptionCharacters || 240);
  if (!compact || compact.length > maximum) throw new Error(`Approved description for '${tool.name}' must contain 1..${maximum} characters.`);
  result.description = compact;
  return result;
}

function transformPayload(payload, expected) {
  if (Array.isArray(payload)) return payload.map(item => transformPayload(item, expected));
  if (!payload || typeof payload !== 'object' || !payload.result || !Array.isArray(payload.result.tools)) return payload;
  const actual = describeContract(payload.result.tools);
  if (actual.toolCount !== expected.toolCount || actual.structuralSha256 !== expected.structuralSha256) {
    throw new Error(`MCP tools contract drift: expected ${expected.toolCount}/${expected.structuralSha256}, got ${actual.toolCount}/${actual.structuralSha256}`);
  }
  return { ...payload, result: { ...payload.result, tools: payload.result.tools.map(tool => compactTool(tool, expected)) } };
}

function transformToolsListResponse(body, contentType, expected) {
  const text = body.toString('utf8');
  if (String(contentType || '').toLowerCase().includes('text/event-stream')) {
    return Buffer.from(text.split(/(\r?\n)/).map(line => {
      if (!line.startsWith('data:')) return line;
      const data = line.slice(5).trim();
      if (!data || data === '[DONE]') return line;
      return `data: ${JSON.stringify(transformPayload(JSON.parse(data), expected))}`;
    }).join(''), 'utf8');
  }
  return Buffer.from(JSON.stringify(transformPayload(JSON.parse(text), expected)), 'utf8');
}

function requestMethod(body) {
  try {
    const payload = JSON.parse(body.toString('utf8'));
    if (Array.isArray(payload)) return payload.some(item => item && item.method === 'tools/list') ? 'tools/list' : '';
    return payload && payload.method ? payload.method : '';
  } catch (_) { return ''; }
}

function filteredHeaders(headers) {
  const blocked = new Set(['host', 'connection', 'content-length', 'transfer-encoding']);
  const result = {};
  for (const [name, value] of Object.entries(headers)) if (!blocked.has(name.toLowerCase()) && value !== undefined) result[name] = value;
  return result;
}

async function probeReadiness(upstreamUrl, expected, options = {}) {
  const probe = await initializeAndList(upstreamUrl, options);
  const actual = describeContract(probe.tools);
  if (actual.toolCount !== expected.toolCount || actual.structuralSha256 !== expected.structuralSha256) {
    throw new Error(`MCP tools contract drift: expected ${expected.toolCount}/${expected.structuralSha256}, got ${actual.toolCount}/${actual.structuralSha256}`);
  }
  return { upstreamUrl: probe.upstreamUrl, toolCount: actual.toolCount, structuralSha256: actual.structuralSha256 };
}

function safeErrorMessage(error) {
  return String(error && error.message || error || 'Unknown readiness error.').replace(/[\r\n]+/g, ' ').slice(0, 500);
}

async function startProxy(args, expected) {
  const upstream = new URL(args['upstream-url']);
  const listenPort = Number(args['listen-port'] || 8080);
  const readinessTimeoutMs = Number(args['readiness-timeout-ms'] || 30000);
  const server = http.createServer((incoming, outgoing) => {
    if (incoming.method === 'GET' && incoming.url === '/health') {
      outgoing.writeHead(200, { 'content-type': 'application/json' });
      outgoing.end(JSON.stringify({ status: 'ok', serverId: args['server-id'], upstream: upstream.toString() }));
      return;
    }
    if (incoming.method === 'GET' && incoming.url === '/ready') {
      probeReadiness(upstream.toString(), expected, { timeoutMs: readinessTimeoutMs }).then(result => {
        outgoing.writeHead(200, { 'content-type': 'application/json', 'cache-control': 'no-store' });
        outgoing.end(JSON.stringify({ status: 'ready', serverId: args['server-id'], upstream: result.upstreamUrl, toolCount: result.toolCount }));
      }, error => {
        outgoing.writeHead(503, { 'content-type': 'application/json', 'cache-control': 'no-store' });
        outgoing.end(JSON.stringify({ status: 'unready', serverId: args['server-id'], error: safeErrorMessage(error) }));
      });
      return;
    }
    const chunks = [];
    let size = 0;
    incoming.on('data', chunk => {
      size += chunk.length;
      if (size > 10 * 1024 * 1024) incoming.destroy(new Error('Request body exceeds 10 MiB.'));
      else chunks.push(chunk);
    });
    incoming.on('error', error => {
      if (!outgoing.headersSent) outgoing.writeHead(400, { 'content-type': 'text/plain; charset=utf-8' });
      outgoing.end(error.message);
    });
    incoming.on('end', () => {
      const body = Buffer.concat(chunks);
      const transport = upstream.protocol === 'https:' ? https : http;
      const headers = filteredHeaders(incoming.headers);
      headers.host = upstream.host;
      if (body.length) headers['content-length'] = body.length;
      const upstreamRequest = transport.request({
        protocol: upstream.protocol, hostname: upstream.hostname, port: upstream.port || undefined,
        path: `${upstream.pathname}${upstream.search}`, method: incoming.method, headers,
      }, upstreamResponse => {
        const responseHeaders = filteredHeaders(upstreamResponse.headers);
        if (requestMethod(body) !== 'tools/list') {
          outgoing.writeHead(upstreamResponse.statusCode || 502, responseHeaders);
          upstreamResponse.pipe(outgoing);
          return;
        }
        const responseChunks = [];
        upstreamResponse.on('data', chunk => responseChunks.push(chunk));
        upstreamResponse.on('end', () => {
          try {
            const transformed = transformToolsListResponse(Buffer.concat(responseChunks), upstreamResponse.headers['content-type'], expected);
            if (responseHeaders['content-type'] && !String(responseHeaders['content-type']).toLowerCase().includes('charset=')) {
              responseHeaders['content-type'] = `${responseHeaders['content-type']}; charset=utf-8`;
            }
            responseHeaders['content-length'] = transformed.length;
            outgoing.writeHead(upstreamResponse.statusCode || 200, responseHeaders);
            outgoing.end(transformed);
          } catch (error) {
            outgoing.writeHead(502, { 'content-type': 'application/json' });
            outgoing.end(JSON.stringify({ error: 'MCP_TOOLS_CONTRACT_DRIFT', message: error.message }));
          }
        });
      });
      upstreamRequest.on('error', error => {
        if (!outgoing.headersSent) outgoing.writeHead(502, { 'content-type': 'application/json' });
        outgoing.end(JSON.stringify({ error: 'MCP_UPSTREAM_FAILED', message: error.message }));
      });
      if (body.length) upstreamRequest.write(body);
      upstreamRequest.end();
    });
  });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(listenPort, '0.0.0.0', resolve);
  });
  process.stdout.write(`MCP tools-list proxy listening server=${args['server-id']} port=${listenPort} upstream=${upstream}\n`);
  return server;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (!args['upstream-url'] || !args['server-id']) throw new Error('--upstream-url and --server-id are required.');
  if (args.probe) {
    const readinessTimeoutMs = Number(args['readiness-timeout-ms'] || 30000);
    const probe = await initializeAndList(args['upstream-url'], { timeoutMs: readinessTimeoutMs });
    const actual = describeContract(probe.tools);
    const compactLengths = probe.tools.map(tool => ({ name: tool.name, length: shortenDescription(tool.description).length }));
    process.stdout.write(`${JSON.stringify({ serverId: args['server-id'], ...actual, maximumCompactDescriptionLength: Math.max(0, ...compactLengths.map(item => item.length)), overBudgetAfterCompact: compactLengths.filter(item => item.length > 160) })}\n`);
    return;
  }
  if (!args['contract-path']) throw new Error('--contract-path is required unless --probe is used.');
  const contract = JSON.parse(fs.readFileSync(args['contract-path'], 'utf8'));
  const serverContract = contract.servers && contract.servers[args['server-id']];
  if (!serverContract) throw new Error(`No approved contract for server '${args['server-id']}'.`);
  const expected = { ...serverContract, descriptionPolicy: contract.descriptionPolicy || {} };
  await startProxy(args, expected);
}

if (require.main === module) {
  main().catch(error => {
    process.stderr.write(`${error.stack || error.message}\n`);
    process.exitCode = 1;
  });
}

module.exports = {
  compactTool,
  describeContract,
  descriptionSha256,
  initializeAndList,
  probeReadiness,
  requestBuffer,
  shortenDescription,
  startProxy,
  transformToolsListResponse,
  withoutDescriptions,
};
