#!/usr/bin/env node
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { createServer } from './server.js';
import { statusTool } from './tools/status.js';
import { readNotesByWikiIdsTool, readNotesTool } from './tools/read.js';
import { graphNeighborsTool } from './tools/graph.js';

async function readJsonRequest(): Promise<Record<string, unknown>> {
  const chunks: Buffer[] = [];
  for await (const chunk of process.stdin) chunks.push(Buffer.from(chunk));
  try {
    const value = JSON.parse(Buffer.concat(chunks).toString('utf8'));
    if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('request must be a JSON object');
    return value as Record<string, unknown>;
  } catch (error) {
    throw new Error(`Invalid JSON request: ${error instanceof Error ? error.message : String(error)}`);
  }
}

async function main(): Promise<void> {
  const subcommand = process.argv[2];
  if (subcommand === 'status') {
    process.stdout.write(`${JSON.stringify(statusTool())}\n`);
    return;
  }
  if (subcommand === 'read-notes' || subcommand === 'read-notes-by-wiki-ids' || subcommand === 'graph-neighbors') {
    const request = await readJsonRequest();
    const field = subcommand === 'read-notes' ? 'paths' : 'wikiIds';
    const values = request[field];
    if (!Array.isArray(values) || values.length === 0 || values.some((value) => typeof value !== 'string' || !value)) {
      throw new Error(`${field} must be a non-empty array of non-empty strings`);
    }
    const result = subcommand === 'read-notes'
      ? readNotesTool({ paths: values })
      : subcommand === 'read-notes-by-wiki-ids'
        ? readNotesByWikiIdsTool({ wikiIds: values })
        : graphNeighborsTool({ wikiIds: values });
    process.stdout.write(`${JSON.stringify(result)}\n`);
    return;
  }
  if (subcommand !== undefined) {
    throw new Error('Unknown subcommand. Run with no arguments for MCP stdio, or status, read-notes, read-notes-by-wiki-ids, or graph-neighbors for JSON CLI.');
  }
  const server = createServer();
  await server.connect(new StdioServerTransport());
}

main().catch((error: unknown) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
});
