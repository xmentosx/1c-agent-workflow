'use strict';

const fs = require('fs');
const path = require('path');
const {
  compactTool,
  descriptionSha256,
  initializeAndList,
  shortenDescription,
  withoutDescriptions,
} = require('./mcp-tools-list-proxy.js');

function parseArgs(argv) {
  const result = { endpoints: [] };
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    if (token === '--endpoint') result.endpoints.push(argv[++index]);
    else if (token === '--output-dir') result.outputDir = argv[++index];
    else if (token === '--approve-servers') result.approveServers = argv[++index];
    else if (token === '--contract-path') result.contractPath = argv[++index];
    else throw new Error(`Unexpected argument: ${token}`);
  }
  return result;
}

function countDescriptions(value) {
  if (Array.isArray(value)) return value.reduce((sum, item) => sum + countDescriptions(item), 0);
  if (!value || typeof value !== 'object') return 0;
  return Object.entries(value).reduce((sum, [key, item]) => sum + (key === 'description' ? 1 : countDescriptions(item)), 0);
}

function byteLength(value) {
  return Buffer.byteLength(JSON.stringify(value), 'utf8');
}

function endpointSpec(value) {
  const separator = String(value || '').indexOf('=');
  if (separator <= 0) throw new Error(`Invalid --endpoint '${value}', expected id=url.`);
  return { id: value.slice(0, separator), url: value.slice(separator + 1) };
}

function candidateTool(tool) {
  return { ...tool, description: shortenDescription(tool.description) };
}

function markdownReport(catalog) {
  const lines = [
    '# MCP tools/list context audit',
    '',
    `Generated: ${catalog.generatedAt}`,
    '',
    '| Server | Tools | Original bytes | All candidates | Approved policy | Approved reduction | Nested descriptions preserved |',
    '|---|---:|---:|---:|---:|---:|---:|',
  ];
  for (const server of catalog.servers) {
    lines.push(`| ${server.id} | ${server.toolCount} | ${server.metrics.originalBytes} | ${server.metrics.candidateBytes} | ${server.metrics.approvedBytes} | ${server.metrics.approvedReductionPercent}% | ${server.metrics.nestedDescriptionCount} |`);
  }
  lines.push(`| **TOTAL** | **${catalog.totals.toolCount}** | **${catalog.totals.originalBytes}** | **${catalog.totals.candidateBytes}** | **${catalog.totals.approvedBytes}** | **${catalog.totals.approvedReductionPercent}%** | **${catalog.totals.nestedDescriptionCount}** |`);
  lines.push('', 'The approved policy changes only approved top-level tool descriptions. JSON Schema descriptions remain intact; unapproved or changed descriptions pass through unchanged.', '');
  for (const server of catalog.servers) {
    lines.push(`## ${server.id}`, '', '| Tool | Original chars | Candidate chars | Approved output chars | Policy | Source hash | Candidate description |', '|---|---:|---:|---:|---|---|---|');
    for (const tool of server.tools) {
      const description = tool.candidateDescription.replace(/\|/g, '\\|');
      lines.push(`| ${tool.name} | ${tool.originalDescription.length} | ${tool.candidateDescription.length} | ${tool.approvedDescription.length} | ${tool.policy} | \`${tool.sourceSha256.slice(0, 12)}\` | ${description} |`);
    }
    lines.push('');
  }
  return `${lines.join('\n')}\n`;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (!args.outputDir || args.endpoints.length === 0) throw new Error('--output-dir and at least one --endpoint are required.');
  const approved = new Set(String(args.approveServers || '').split(',').map(item => item.trim()).filter(Boolean));
  const contract = args.contractPath ? JSON.parse(fs.readFileSync(args.contractPath, 'utf8')) : null;
  const catalog = { schemaVersion: 1, generatedAt: new Date().toISOString(), servers: [] };
  const approvalCandidates = { schemaVersion: 1, generatedAt: catalog.generatedAt, servers: {} };
  for (const spec of args.endpoints.map(endpointSpec)) {
    const response = await initializeAndList(spec.url);
    const original = response.tools;
    const candidate = original.map(candidateTool);
    const originalBytes = byteLength(original);
    const candidateBytes = byteLength(candidate);
    const tools = original.map((tool, index) => ({
      name: tool.name,
      sourceSha256: descriptionSha256(tool.description),
      originalDescription: String(tool.description || ''),
      candidateDescription: String(candidate[index].description || ''),
      inputSchema: tool.inputSchema || null,
      outputSchema: tool.outputSchema || null,
      annotations: tool.annotations || null,
    }));
    const serverContract = contract && contract.servers && contract.servers[spec.id];
    const approvedCandidate = serverContract
      ? original.map(tool => compactTool(tool, { ...serverContract, descriptionPolicy: contract.descriptionPolicy || {} }))
      : (approved.has(spec.id) ? candidate : original);
    tools.forEach((tool, index) => {
      tool.approvedDescription = String(approvedCandidate[index].description || '');
      tool.policy = tool.approvedDescription === tool.originalDescription ? 'passthrough' : 'approved';
    });
    const approvedBytes = byteLength(approvedCandidate);
    const server = {
      id: spec.id,
      url: response.upstreamUrl,
      toolCount: tools.length,
      metrics: {
        originalBytes,
        candidateBytes,
        savedBytes: originalBytes - candidateBytes,
        reductionPercent: Number(((originalBytes - candidateBytes) * 100 / originalBytes).toFixed(1)),
        approvedBytes,
        approvedSavedBytes: originalBytes - approvedBytes,
        approvedReductionPercent: Number(((originalBytes - approvedBytes) * 100 / originalBytes).toFixed(1)),
        nestedDescriptionCount: original.reduce((sum, tool) => sum + countDescriptions(tool.inputSchema) + countDescriptions(tool.outputSchema), 0),
      },
      structuralTools: original.map(tool => ({ name: tool.name, inputSchema: withoutDescriptions(tool.inputSchema || {}), outputSchema: withoutDescriptions(tool.outputSchema || null), annotations: tool.annotations || null })),
      tools,
      approvedTools: approvedCandidate.map(tool => ({ name: tool.name, description: String(tool.description || '') })),
    };
    catalog.servers.push(server);
    if (approved.has(spec.id)) {
      approvalCandidates.servers[spec.id] = Object.fromEntries(tools.map(tool => [tool.name, { sourceSha256: tool.sourceSha256, compact: tool.candidateDescription }]));
    }
  }
  catalog.totals = catalog.servers.reduce((total, server) => {
    total.toolCount += server.toolCount;
    total.originalBytes += server.metrics.originalBytes;
    total.candidateBytes += server.metrics.candidateBytes;
    total.savedBytes += server.metrics.savedBytes;
    total.approvedBytes += server.metrics.approvedBytes;
    total.approvedSavedBytes += server.metrics.approvedSavedBytes;
    total.nestedDescriptionCount += server.metrics.nestedDescriptionCount;
    return total;
  }, { toolCount: 0, originalBytes: 0, candidateBytes: 0, savedBytes: 0, approvedBytes: 0, approvedSavedBytes: 0, nestedDescriptionCount: 0 });
  catalog.totals.reductionPercent = Number((catalog.totals.savedBytes * 100 / catalog.totals.originalBytes).toFixed(1));
  catalog.totals.approvedReductionPercent = Number((catalog.totals.approvedSavedBytes * 100 / catalog.totals.originalBytes).toFixed(1));
  fs.mkdirSync(args.outputDir, { recursive: true });
  fs.writeFileSync(path.join(args.outputDir, 'catalog.json'), `${JSON.stringify(catalog, null, 2)}\n`, 'utf8');
  fs.writeFileSync(path.join(args.outputDir, 'report.md'), markdownReport(catalog), 'utf8');
  fs.writeFileSync(path.join(args.outputDir, 'approved-descriptions.candidate.json'), `${JSON.stringify(approvalCandidates, null, 2)}\n`, 'utf8');
  process.stdout.write(`${JSON.stringify(catalog.totals)}\n`);
}

if (require.main === module) main().catch(error => { process.stderr.write(`${error.stack || error.message}\n`); process.exitCode = 1; });

module.exports = { candidateTool, countDescriptions, endpointSpec, markdownReport };
