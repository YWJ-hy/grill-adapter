#!/usr/bin/env node
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { loadMcpConfig } from './config.js';
import { createServer } from './server.js';
import { runGraphNeighborsCliFromStdin, runReadSectionsCliFromStdin } from './cli.js';

async function startServer(): Promise<void> {
  let server: ReturnType<typeof createServer>;
  server = createServer((requestMeta) =>
    loadMcpConfig(server.server, process.env, process.cwd(), requestMeta));
  const transport = new StdioServerTransport();
  await server.connect(transport);
}

async function main(): Promise<void> {
  // No subcommand: Claude Code launches `node dist/index.js` with no args -> stdio MCP server.
  // `read-sections`: same binary invoked as a CLI (`node dist/index.js read-sections`) that reuses
  // the server's loadConfig + readSectionsTool so a non-MCP caller shares one shared-wiki reader.
  // `graph-neighbors`: same pattern over graphNeighborsTool, so the materializer can close a
  // github_mcp hard section's 1-hop depends-on edges against the same remote graph.
  const subcommand = process.argv[2];
  if (subcommand === 'read-sections') {
    await runReadSectionsCliFromStdin();
    return;
  }
  if (subcommand === 'graph-neighbors') {
    await runGraphNeighborsCliFromStdin();
    return;
  }
  if (subcommand !== undefined) {
    throw new Error(
      `Unknown subcommand: ${subcommand}. Run with no arguments to start the MCP stdio server, ` +
        "'read-sections' to read sections, or 'graph-neighbors' to query 1-hop graph neighbors " +
        'from a JSON request on stdin.',
    );
  }
  await startServer();
}

main().catch((error: unknown) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
});
