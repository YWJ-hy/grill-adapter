import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import * as z from 'zod/v4';
import { statusTool } from './tools/status.js';
import { sourcesTool } from './tools/sources.js';
import { searchTool } from './tools/search.js';
import { catalogTool } from './tools/catalog.js';
import { readNoteTool, readNotesByWikiIdsTool, readNotesTool } from './tools/read.js';
import { graphNeighborsTool } from './tools/graph.js';
import { applyNoteChangeTool, proposeNoteChangeTool } from './tools/write.js';
import { maintenanceSummaryTool } from './tools/maintenance-summary.js';
import { consolidationCandidatesTool } from './tools/consolidation-candidates.js';
import { environmentForMcpRequest } from './bindings.js';
import {
  CapturePlanEnvelopeSchema,
  OutboxCorrectionEnvelopeSchema,
  captureDraftView,
  correctOutboxEnvelope,
  outboxReview,
  stageCapturePlanEnvelope,
} from './outbox.js';
import { profileHasTool, resolveMcpToolProfile, type McpToolProfile } from './tool-surface.js';

function toResult(value: unknown) {
  return {
    content: [{ type: 'text' as const, text: JSON.stringify(value, null, 2) }],
    structuredContent: value as Record<string, unknown>,
  };
}
export function createServer(
  env: NodeJS.ProcessEnv = process.env,
  profile: McpToolProfile = resolveMcpToolProfile(env),
): McpServer {
  const server = new McpServer({ name: 'obsidian-wiki-mcp', version: '0.1.1' });
  const enabled = (toolName: string) => profileHasTool(profile, toolName);
  const requestEnv = (requestMeta: Record<string, unknown> | undefined) =>
    environmentForMcpRequest(env, requestMeta);

  if (enabled('obsidian_wiki_status')) server.registerTool('obsidian_wiki_status', {
    description: 'Report bound Source health for the current project.',
    inputSchema: z.object({}),
    annotations: { readOnlyHint: true, idempotentHint: true },
  }, async (_input, extra) => toResult(statusTool(requestEnv(extra._meta))));
  if (enabled('obsidian_wiki_sources')) server.registerTool('obsidian_wiki_sources', {
    description: 'List healthy Sources bound to the current project.',
    inputSchema: z.object({}),
    annotations: { readOnlyHint: true, idempotentHint: true },
  }, async (_input, extra) => toResult(sourcesTool(requestEnv(extra._meta))));
  if (enabled('obsidian_wiki_search')) server.registerTool('obsidian_wiki_search', {
    description: 'Search active, visible, non-expired Notes in bound Sources.',
    inputSchema: z.object({
      query: z.string().min(1),
      sourceId: z.string().min(1).optional(),
      pathPrefix: z.string().optional(),
      limit: z.number().int().min(1).max(50).optional(),
      cursor: z.string().min(1).optional(),
    }),
    annotations: { readOnlyHint: true, idempotentHint: true },
  }, async (input, extra) => toResult(searchTool(input, requestEnv(extra._meta))));
  if (enabled('obsidian_wiki_catalog')) server.registerTool('obsidian_wiki_catalog', {
    description: 'List bounded metadata for one bound Source branch; never returns bodies.',
    inputSchema: z.object({
      sourceId: z.string().min(1),
      pathPrefix: z.string().optional(),
      offset: z.number().int().nonnegative().optional(),
      limit: z.number().int().min(1).max(50).optional(),
      cursor: z.string().min(1).optional(),
    }),
    annotations: { readOnlyHint: true, idempotentHint: true },
  }, async (input, extra) => toResult(catalogTool(input, requestEnv(extra._meta))));
  if (enabled('obsidian_wiki_maintenance_summary')) server.registerTool('obsidian_wiki_maintenance_summary', {
    description: 'Return bounded metadata-only maintenance counts for bound Sources.',
    inputSchema: z.object({
      asOf: z.string().min(1),
      identityLimit: z.number().int().min(1).max(200).optional(),
    }),
    annotations: { readOnlyHint: true, idempotentHint: true },
  }, async (input, extra) => toResult(maintenanceSummaryTool(input, requestEnv(extra._meta))));
  if (enabled('obsidian_wiki_consolidation_candidates')) server.registerTool('obsidian_wiki_consolidation_candidates', {
    description: 'Return bounded unresolved candidates for private consolidation.',
    inputSchema: z.object({ candidateLimit: z.number().int().min(1).max(200).optional() }),
    annotations: { readOnlyHint: true, idempotentHint: true },
  }, async (input, extra) => toResult(consolidationCandidatesTool(input, requestEnv(extra._meta))));
  if (enabled('obsidian_wiki_stage_capture_plan')) server.registerTool('obsidian_wiki_stage_capture_plan', {
    description: 'Validate and queue one full versioned Capture Plan in the current project Outbox.',
    inputSchema: CapturePlanEnvelopeSchema,
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true },
  }, async (input, extra) => toResult(stageCapturePlanEnvelope(input, requestEnv(extra._meta))));
  if (enabled('obsidian_wiki_capture_draft_view')) server.registerTool('obsidian_wiki_capture_draft_view', {
    description: 'Read current-project Outbox metadata and explicitly selected draft bodies for Capture.',
    inputSchema: z.object({ paths: z.array(z.string().min(1)).max(24).optional() }),
    annotations: { readOnlyHint: true, idempotentHint: true },
  }, async (input, extra) => toResult(captureDraftView(input, requestEnv(extra._meta))));
  if (enabled('obsidian_wiki_outbox_review')) server.registerTool('obsidian_wiki_outbox_review', {
    description: 'Review the current project queued Outbox scope and diffs.',
    inputSchema: z.object({}),
    annotations: { readOnlyHint: true, idempotentHint: true },
  }, async (_input, extra) => toResult(outboxReview(requestEnv(extra._meta))));
  if (enabled('obsidian_wiki_outbox_correct')) server.registerTool('obsidian_wiki_outbox_correct', {
    description: 'Append one immutable current-project Outbox correction.',
    inputSchema: OutboxCorrectionEnvelopeSchema,
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true },
  }, async (input, extra) => toResult(correctOutboxEnvelope(input, requestEnv(extra._meta))));
  if (enabled('obsidian_wiki_read_note')) server.registerTool('obsidian_wiki_read_note', {
    description: 'Read one active, visible, non-expired Note under a bound Source.',
    inputSchema: z.object({ path: z.string().min(1) }),
    annotations: { readOnlyHint: true, idempotentHint: true },
  }, async (input, extra) => toResult(readNoteTool(input, requestEnv(extra._meta))));
  if (enabled('obsidian_wiki_read_notes')) server.registerTool('obsidian_wiki_read_notes', {
    description: 'Batch-read Notes with authoritative content and snapshot hashes.',
    inputSchema: z.object({ paths: z.array(z.string().min(1)).min(1) }),
    annotations: { readOnlyHint: true, idempotentHint: true },
  }, async (input, extra) => toResult(readNotesTool(input, requestEnv(extra._meta))));
  if (enabled('obsidian_wiki_read_notes_by_wiki_ids')) server.registerTool('obsidian_wiki_read_notes_by_wiki_ids', {
    description: 'Batch-read Notes by stable wiki_id within bound Sources.',
    inputSchema: z.object({
      wikiIds: z.array(z.string().min(1)).min(1),
      sourceId: z.string().min(1).optional(),
    }),
    annotations: { readOnlyHint: true, idempotentHint: true },
  }, async (input, extra) => toResult(readNotesByWikiIdsTool(input, requestEnv(extra._meta))));
  if (enabled('obsidian_wiki_graph_neighbors')) server.registerTool('obsidian_wiki_graph_neighbors', {
    description: 'Return direct typed neighbors for bound Note wiki IDs.',
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
  if (enabled('obsidian_wiki_propose_note_change')) server.registerTool('obsidian_wiki_propose_note_change', {
    description: 'Legacy/migration-only Note proposal; validates without writing.',
    inputSchema: z.object(noteChangeSchema),
    annotations: { readOnlyHint: true, idempotentHint: true },
  }, async (input, extra) => toResult(await proposeNoteChangeTool(input, requestEnv(extra._meta))));
  if (enabled('obsidian_wiki_apply_note_change')) server.registerTool('obsidian_wiki_apply_note_change', {
    description: 'Legacy/migration-only governed Note apply with CAS.',
    inputSchema: z.object({ ...noteChangeSchema, authorized: z.boolean().optional() }),
    annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: false },
  }, async (input, extra) => toResult(await applyNoteChangeTool(input, requestEnv(extra._meta))));
  return server;
}
