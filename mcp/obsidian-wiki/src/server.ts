import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import * as z from 'zod/v4';
import { statusTool } from './tools/status.js';
import { sourcesTool } from './tools/sources.js';
import { searchTool } from './tools/search.js';
import { readNoteTool, readNotesTool } from './tools/read.js';
import { graphNeighborsTool } from './tools/graph.js';

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
  server.registerTool('obsidian_wiki_search', {
    description: 'Search active, agent-visible atomic Notes only within the current project’s readable bound Sources.',
    inputSchema: z.object({ query: z.string().min(1) }),
    annotations: { readOnlyHint: true, idempotentHint: true },
  }, async (input) => toResult(searchTool(input, env)));
  server.registerTool('obsidian_wiki_read_note', {
    description: 'Read one atomic Note only when its Vault-relative path is under a readable bound Source.',
    inputSchema: z.object({ path: z.string().min(1) }),
    annotations: { readOnlyHint: true, idempotentHint: true },
  }, async (input) => toResult(readNoteTool(input, env)));
  server.registerTool('obsidian_wiki_read_notes', {
    description: 'Batch read atomic Notes with stable content hashes and a snapshot hash, failing closed on inconsistency.',
    inputSchema: z.object({ paths: z.array(z.string().min(1)).min(1) }),
    annotations: { readOnlyHint: true, idempotentHint: true },
  }, async (input) => toResult(readNotesTool(input, env)));
  server.registerTool('obsidian_wiki_graph_neighbors', {
    description: 'Return de-duplicated direct typed neighbors for bound atomic Note wiki IDs without recursive traversal.',
    inputSchema: z.object({ wikiIds: z.array(z.string().min(1)).min(1) }),
    annotations: { readOnlyHint: true, idempotentHint: true },
  }, async (input) => toResult(graphNeighborsTool(input, env)));
  return server;
}
