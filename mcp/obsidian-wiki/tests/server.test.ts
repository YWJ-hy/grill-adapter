import path from 'node:path';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { describe, expect, it } from 'vitest';

describe('Obsidian Wiki MCP server', () => {
  it('exposes proposal and authenticated apply tools from the committed bundle entrypoint', async () => {
    const bundle = path.resolve(import.meta.dirname, '..', 'dist', 'index.js');
    const transport = new StdioClientTransport({ command: 'node', args: [bundle], stderr: 'pipe' });
    const client = new Client({ name: 'obsidian-wiki-contract-test', version: '1.0.0' });
    try {
      await client.connect(transport);
      const result = await client.listTools();
      const tools = new Map(result.tools.map((tool) => [tool.name, tool]));

      expect(tools.get('obsidian_wiki_propose_note_change')).toMatchObject({
        annotations: { readOnlyHint: true, idempotentHint: true },
      });
      expect(tools.get('obsidian_wiki_apply_note_change')).toMatchObject({
        annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: false },
      });
    } finally {
      await client.close();
    }
  });
});
