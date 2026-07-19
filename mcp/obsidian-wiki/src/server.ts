import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import * as z from 'zod/v4';
import { statusTool } from './tools/status.js';
import { sourcesTool } from './tools/sources.js';

function toResult(value: unknown) {
  return {
    content: [{ type: 'text' as const, text: JSON.stringify(value, null, 2) }],
    structuredContent: value as Record<string, unknown>,
  };
}

export function createServer(env: NodeJS.ProcessEnv = process.env): McpServer {
  const server = new McpServer({ name: 'obsidian-wiki-mcp', version: '0.1.0' });
  server.registerTool('obsidian_wiki_status', {
    description: 'Report the current project’s resolved Obsidian Wiki Source binding health without reading unbound Vault content.',
    inputSchema: z.object({}),
    annotations: { readOnlyHint: true, idempotentHint: true },
  }, async () => toResult(statusTool(env)));
  server.registerTool('obsidian_wiki_sources', {
    description: 'List only the healthy Obsidian Wiki Sources bound to the current project.',
    inputSchema: z.object({}),
    annotations: { readOnlyHint: true, idempotentHint: true },
  }, async () => toResult(sourcesTool(env)));
  return server;
}
