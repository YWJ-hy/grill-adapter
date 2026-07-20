import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import * as z from 'zod/v4';
import type { McpRequestMeta, SharedWikiConfig } from './config.js';
import { statusTool } from './tools/status.js';
import { treeTool } from './tools/tree.js';
import { readTool } from './tools/read.js';
import { readSectionTool } from './tools/readSection.js';
import { readSectionsTool } from './tools/readSections.js';
import { searchTool } from './tools/search.js';
import { graphNeighborsTool } from './tools/graphNeighbors.js';
import { validatePatchTool } from './tools/validatePatch.js';
import { createPatchPrTool } from './tools/createPatchPr.js';
import { withCloneLock } from './lock.js';

export type SharedWikiConfigSource = SharedWikiConfig | ((requestMeta?: McpRequestMeta) => SharedWikiConfig | Promise<SharedWikiConfig>);

export function createServer(configSource: SharedWikiConfigSource): McpServer {
  const server = new McpServer({ name: 'shared-wiki-mcp', version: '0.1.0' });

  const withConfigLock = async <T>(
    requestMeta: McpRequestMeta,
    callback: (config: SharedWikiConfig) => Promise<T>,
  ): Promise<T> => {
    const config = typeof configSource === 'function' ? await configSource(requestMeta) : configSource;
    return withCloneLock(config, () => callback(config));
  };

  server.registerTool('shared_wiki_status', {
    description: 'Check shared wiki MCP configuration, clone state, tool availability, policy, and wiki validation summary.',
    inputSchema: z.object({}),
    annotations: { readOnlyHint: true, idempotentHint: true },
  }, async (_input, extra) => toResult(await withConfigLock(extra._meta, (config) => statusTool(config))));

  server.registerTool('shared_wiki_tree', {
    description: 'Return the index-driven shared wiki tree with leaf companion section-index metadata.',
    inputSchema: z.object({}),
    annotations: { readOnlyHint: true, idempotentHint: true },
  }, async (_input, extra) => toResult(await withConfigLock(extra._meta, (config) => treeTool(config))));

  server.registerTool('shared_wiki_read', {
    description: 'Read an indexed root/directory index or companion section index. Full leaf documents are blocked by default; use shared_wiki_read_section for leaf content.',
    inputSchema: z.object({
      path: z.string().min(1),
      allowLeafDocumentRead: z.boolean().optional(),
    }),
    annotations: { readOnlyHint: true, idempotentHint: true },
  }, async (input, extra) => toResult(await withConfigLock(extra._meta, (config) => readTool(config, input))));

  server.registerTool('shared_wiki_read_section', {
    description: 'Read a specific marked section from an indexed leaf shared wiki page, optionally with bounded document context from its companion section index.',
    inputSchema: z.object({
      path: z.string().min(1),
      section: z.string().min(1),
      includeDocumentContext: z.boolean().optional(),
    }),
    annotations: { readOnlyHint: true, idempotentHint: true },
  }, async (input, extra) => toResult(await withConfigLock(extra._meta, (config) => readSectionTool(config, input))));

  server.registerTool('shared_wiki_read_sections', {
    description: 'Read multiple marked sections across indexed leaf shared wiki pages in one ordered batch, optionally with bounded document context.',
    inputSchema: z.object({
      sections: z.array(z.object({
        path: z.string().min(1),
        section: z.string().min(1),
        includeDocumentContext: z.boolean().optional(),
      })).min(1).max(100),
      includeDocumentContext: z.boolean().optional(),
      errorMode: z.enum(['strict', 'partial']).optional(),
    }),
    annotations: { readOnlyHint: true, idempotentHint: true },
  }, async (input, extra) => toResult(await withConfigLock(extra._meta, (config) => readSectionsTool(config, input))));

  server.registerTool('shared_wiki_search', {
    description: 'Search indexed shared wiki markdown pages with bounded snippets.',
    inputSchema: z.object({ query: z.string().min(1), maxResults: z.number().int().min(1).max(50).optional() }),
    annotations: { readOnlyHint: true, idempotentHint: true },
  }, async (input, extra) => toResult(await withConfigLock(extra._meta, (config) => searchTool(config, input))));

  server.registerTool('shared_wiki_graph_neighbors', {
    description: 'Return bounded 1-hop graph neighbors (out/in edges with type and an indexed flag) for the given page#section nodes. Does NOT load the whole graph — output scales with the number of requested nodes.',
    inputSchema: z.object({
      nodes: z.array(z.string().min(1)).min(1).max(100),
    }),
    annotations: { readOnlyHint: true, idempotentHint: true },
  }, async (input, extra) => toResult(await withConfigLock(extra._meta, (config) => graphNeighborsTool(config, input))));

  server.registerTool('shared_wiki_validate_patch', {
    description: 'Validate a unified diff against shared wiki policy without pushing or opening a PR.',
    inputSchema: z.object({
      patch: z.string().min(1),
      authorizedCreate: z.boolean().optional(),
      authorizedUpdate: z.boolean().optional(),
    }),
  }, async (input, extra) => toResult(await withConfigLock(extra._meta, (config) => validatePatchTool(config, input))));

  server.registerTool('shared_wiki_create_patch_pr', {
    description: 'Apply a validated shared wiki patch on a new branch, push it, and open a GitHub PR. Never merges.',
    inputSchema: z.object({
      patch: z.string().min(1),
      branchName: z.string().min(1).optional(),
      commitMessage: z.string().min(1),
      prTitle: z.string().min(1),
      prBody: z.string().min(1),
      authorizedCreate: z.boolean().optional(),
      authorizedUpdate: z.boolean().optional(),
      draft: z.boolean().optional(),
    }),
  }, async (input, extra) => toResult(await withConfigLock(extra._meta, (config) => createPatchPrTool(config, input))));

  return server;
}

function toResult(value: unknown) {
  return {
    content: [{ type: 'text' as const, text: JSON.stringify(value, null, 2) }],
    structuredContent: value as Record<string, unknown>,
  };
}
