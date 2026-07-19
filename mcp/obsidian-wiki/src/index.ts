#!/usr/bin/env node
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { createServer } from './server.js';
import { statusTool } from './tools/status.js';

async function main(): Promise<void> {
  const subcommand = process.argv[2];
  if (subcommand === 'status') {
    process.stdout.write(`${JSON.stringify(statusTool())}\n`);
    return;
  }
  if (subcommand !== undefined) {
    throw new Error('Unknown subcommand. Run with no arguments for MCP stdio, or status for binding health JSON.');
  }
  const server = createServer();
  await server.connect(new StdioServerTransport());
}

main().catch((error: unknown) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
});
