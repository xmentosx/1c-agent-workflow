'use strict';

const assert = require('assert');
const path = require('path');
const proxy = require(path.resolve(__dirname, '../../vibecoding1c-mcp-host/tools-list-proxy/mcp-tools-list-proxy.js'));

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
const payload = { jsonrpc: '2.0', id: 2, result: { tools } };
const source = Buffer.from(`event: message\ndata: ${JSON.stringify(payload)}\n\n`, 'utf8');
const transformed = proxy.transformToolsListResponse(source, 'text/event-stream', originalContract).toString('utf8');
const transformedPayload = JSON.parse(transformed.split('\n').find(line => line.startsWith('data:')).slice(5).trim());
const compactTools = transformedPayload.result.tools;

assert.strictEqual(compactTools.length, tools.length);
assert.deepStrictEqual(compactTools.map(tool => tool.name), tools.map(tool => tool.name));
assert.deepStrictEqual(compactTools.map(tool => tool.annotations), tools.map(tool => tool.annotations));
assert.strictEqual(proxy.describeContract(compactTools).structuralSha256, originalContract.structuralSha256);
assert.ok(compactTools.every(tool => tool.description.length <= 160));
assert.strictEqual(compactTools[0].inputSchema.description, undefined);
assert.strictEqual(compactTools[0].inputSchema.properties.query.description, undefined);
assert.strictEqual(compactTools[0].inputSchema.properties.query.minLength, 1);
assert.strictEqual(compactTools[0].inputSchema.additionalProperties, false);
assert.ok(transformed.length < source.length * 0.6);

process.stdout.write('tools-list proxy unit contract passed\n');
