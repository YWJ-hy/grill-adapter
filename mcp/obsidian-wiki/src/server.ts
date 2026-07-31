import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import * as z from 'zod/v4';
import { statusTool } from './tools/status.js';
import { sourcesTool } from './tools/sources.js';
import { searchTool } from './tools/search.js';
import { catalogTool } from './tools/catalog.js';
import { readNoteTool, readNotesByWikiIdsTool, readNotesTool } from './tools/read.js';
import { graphNeighborsTool } from './tools/graph.js';
import { applyNoteChangeTool, proposeNoteChangeTool } from './tools/write.js';
import { environmentForMcpRequest } from './bindings.js';

function toResult(value: unknown) {
  return {
    content: [{ type: 'text' as const, text: JSON.stringify(value, null, 2) }],
    structuredContent: value as Record<string, unknown>,
  };
}

export function createServer(env: NodeJS.ProcessEnv = process.env): McpServer {
  const server = new McpServer({ name: 'obsidian-wiki-mcp', version: '0.1.1' });
  const requestEnv = (requestMeta: Record<string, unknown> | undefined) =>
    environmentForMcpRequest(env, requestMeta);
  server.registerTool('obsidian_wiki_status', {
    description: 'Report the current project’s resolved Obsidian Wiki Source binding health without reading unbound Vault content.',
    inputSchema: z.object({}),
    annotations: { readOnlyHint: true, idempotentHint: true },
  }, async (_input, extra) => toResult(statusTool(requestEnv(extra._meta))));
  server.registerTool('obsidian_wiki_sources', {
    description: 'List only the healthy Obsidian Wiki Sources bound to the current project.',
    inputSchema: z.object({}),
    annotations: { readOnlyHint: true, idempotentHint: true },
  }, async (_input, extra) => toResult(sourcesTool(requestEnv(extra._meta))));
  server.registerTool('obsidian_wiki_search', {
    description: 'Search active, agent-visible atomic Notes within readable bound Sources, optionally scoped to one Source-relative directory.',
    inputSchema: z.object({
      query: z.string().min(1),
      sourceId: z.string().min(1).optional(),
      pathPrefix: z.string().optional(),
      limit: z.number().int().min(1).max(50).optional(),
      cursor: z.string().min(1).optional(),
    }),
    annotations: { readOnlyHint: true, idempotentHint: true },
  }, async (input, extra) => toResult(searchTool(input, requestEnv(extra._meta))));
  server.registerTool('obsidian_wiki_catalog', {
    description: 'List a bounded metadata-only directory view for one readable bound Obsidian Wiki Source; it never returns Note bodies.',
    inputSchema: z.object({
      sourceId: z.string().min(1),
      pathPrefix: z.string().optional(),
      offset: z.number().int().nonnegative().optional(),
      limit: z.number().int().min(1).max(50).optional(),
      cursor: z.string().min(1).optional(),
    }),
    annotations: { readOnlyHint: true, idempotentHint: true },
  }, async (input, extra) => toResult(catalogTool(input, requestEnv(extra._meta))));
  server.registerTool('obsidian_wiki_read_note', {
    description: 'Read one atomic Note only when its Vault-relative path is under a readable bound Source.',
    inputSchema: z.object({ path: z.string().min(1) }),
    annotations: { readOnlyHint: true, idempotentHint: true },
  }, async (input, extra) => toResult(readNoteTool(input, requestEnv(extra._meta))));
  server.registerTool('obsidian_wiki_read_notes', {
    description: 'Batch read atomic Notes with stable content hashes and a snapshot hash, failing closed on inconsistency.',
    inputSchema: z.object({ paths: z.array(z.string().min(1)).min(1) }),
    annotations: { readOnlyHint: true, idempotentHint: true },
  }, async (input, extra) => toResult(readNotesTool(input, requestEnv(extra._meta))));
  server.registerTool('obsidian_wiki_read_notes_by_wiki_ids', {
    description: 'Batch read atomic Notes by stable wiki_id, resolving exactly one readable active Note per ID.',
    inputSchema: z.object({ wikiIds: z.array(z.string().min(1)).min(1) }),
    annotations: { readOnlyHint: true, idempotentHint: true },
  }, async (input, extra) => toResult(readNotesByWikiIdsTool(input, requestEnv(extra._meta))));
  server.registerTool('obsidian_wiki_graph_neighbors', {
    description: 'Return de-duplicated direct typed neighbors for bound atomic Note wiki IDs without recursive traversal.',
    inputSchema: z.object({ wikiIds: z.array(z.string().min(1)).min(1) }),
    annotations: { readOnlyHint: true, idempotentHint: true },
  }, async (input, extra) => toResult(graphNeighborsTool(input, requestEnv(extra._meta))));
  const noteChangeSchema = {
    sourceId: z.string().min(1),
    operation: z.enum(['create', 'update']),
    path: z.string().min(1),
    content: z.string().min(1),
    expectedHash: z.string().nullable(),
  };
  server.registerTool('obsidian_wiki_propose_note_change', {
    description: 'Validate a bound atomic Note create/update and return its structured diff without writing.',
    inputSchema: z.object(noteChangeSchema),
    annotations: { readOnlyHint: true, idempotentHint: true },
  }, async (input, extra) => toResult(await proposeNoteChangeTool(input, requestEnv(extra._meta))));
  server.registerTool('obsidian_wiki_apply_note_change', {
    description: 'Apply an already reviewed bound atomic Note change through the authenticated loopback bridge with expected-hash CAS.',
    inputSchema: z.object({ ...noteChangeSchema, authorized: z.boolean().optional() }),
    annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: false },
  }, async (input, extra) => toResult(await applyNoteChangeTool(input, requestEnv(extra._meta))));
  return server;
}
