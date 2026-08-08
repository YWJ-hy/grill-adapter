import path from 'node:path';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { describe, expect, it } from 'vitest';
import { stageCapturePlanEnvelope } from '../src/outbox.js';

const defaultToolNames = [
  'obsidian_wiki_status',
  'obsidian_wiki_sources',
  'obsidian_wiki_search',
  'obsidian_wiki_catalog',
  'obsidian_wiki_maintenance_summary',
  'obsidian_wiki_consolidation_candidates',
  'obsidian_wiki_stage_capture_plan',
  'obsidian_wiki_capture_draft_view',
  'obsidian_wiki_outbox_review',
  'obsidian_wiki_outbox_correct',
  'obsidian_wiki_read_note',
  'obsidian_wiki_read_notes',
  'obsidian_wiki_read_notes_by_wiki_ids',
  'obsidian_wiki_graph_neighbors',
];

describe('Obsidian Wiki MCP server', () => {
  it('keeps the default surface focused on formal reads, Capture, and Outbox', async () => {
    const bundle = path.resolve(import.meta.dirname, '..', 'dist', 'index.js');
    const transport = new StdioClientTransport({ command: 'node', args: [bundle], stderr: 'pipe' });
    const client = new Client({ name: 'obsidian-wiki-contract-test', version: '1.0.0' });
    try {
      await client.connect(transport);
      const result = await client.listTools();
      const tools = new Map(result.tools.map((tool) => [tool.name, tool]));

      expect([...tools.keys()]).toEqual(defaultToolNames);
      expect(tools.has('obsidian_wiki_propose_note_change')).toBe(false);
      expect(tools.has('obsidian_wiki_apply_note_change')).toBe(false);

      expect(tools.get('obsidian_wiki_catalog')).toMatchObject({
        annotations: { readOnlyHint: true, idempotentHint: true },
        inputSchema: {
          properties: {
            limit: expect.any(Object),
            cursor: expect.any(Object),
          },
        },
      });
      expect(tools.get('obsidian_wiki_search')).toMatchObject({
        annotations: { readOnlyHint: true, idempotentHint: true },
        inputSchema: {
          properties: {
            limit: expect.any(Object),
            cursor: expect.any(Object),
          },
        },
      });
      expect(tools.get('obsidian_wiki_stage_capture_plan')).toMatchObject({
        inputSchema: {
          properties: {
            plan: { type: 'object' },
          },
        },
      });
      expect(tools.get('obsidian_wiki_stage_capture_plan')!.inputSchema.properties)
        .not.toHaveProperty('schemaVersion');
      expect(tools.get('obsidian_wiki_outbox_correct')!.inputSchema.properties)
        .toMatchObject({ correction: { type: 'object' } });
    } finally {
      await client.close();
    }
  });

  it('keeps full Capture Plan validation behind the compact public envelope', () => {
    expect(() => stageCapturePlanEnvelope({ plan: {} }, {})).toThrow(/schemaVersion|kind|featureSlug/);
  });

  it.each([
    ['research', ['obsidian_wiki_status', 'obsidian_wiki_sources', 'obsidian_wiki_search', 'obsidian_wiki_catalog', 'obsidian_wiki_read_note', 'obsidian_wiki_read_notes', 'obsidian_wiki_read_notes_by_wiki_ids', 'obsidian_wiki_graph_neighbors']],
    ['capture', ['obsidian_wiki_status', 'obsidian_wiki_sources', 'obsidian_wiki_search', 'obsidian_wiki_catalog', 'obsidian_wiki_consolidation_candidates', 'obsidian_wiki_stage_capture_plan', 'obsidian_wiki_capture_draft_view', 'obsidian_wiki_read_notes_by_wiki_ids']],
    ['maintenance-audit', ['obsidian_wiki_status', 'obsidian_wiki_sources', 'obsidian_wiki_maintenance_summary', 'obsidian_wiki_read_notes_by_wiki_ids']],
    ['maintenance-consolidation', ['obsidian_wiki_status', 'obsidian_wiki_sources', 'obsidian_wiki_consolidation_candidates']],
    ['outbox', ['obsidian_wiki_status', 'obsidian_wiki_sources', 'obsidian_wiki_capture_draft_view', 'obsidian_wiki_outbox_review', 'obsidian_wiki_outbox_correct']],
    ['legacy', ['obsidian_wiki_status', 'obsidian_wiki_sources', 'obsidian_wiki_propose_note_change', 'obsidian_wiki_apply_note_change']],
    ['migration', ['obsidian_wiki_status', 'obsidian_wiki_sources', 'obsidian_wiki_propose_note_change', 'obsidian_wiki_apply_note_change']],
  ] as const)('exposes only the %s caller profile', async (profile, expectedNames) => {
    const bundle = path.resolve(import.meta.dirname, '..', 'dist', 'index.js');
    const transport = new StdioClientTransport({
      command: 'node',
      args: [bundle, '--profile', profile],
      stderr: 'pipe',
    });
    const client = new Client({ name: `obsidian-wiki-${profile}-profile-test`, version: '1.0.0' });
    try {
      await client.connect(transport);
      const result = await client.listTools();
      expect(result.tools.map((tool) => tool.name)).toEqual(expectedNames);
    } finally {
      await client.close();
    }
  });
});
