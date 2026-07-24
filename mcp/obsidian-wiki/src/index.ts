#!/usr/bin/env node
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { createServer } from './server.js';
import { statusTool } from './tools/status.js';
import { searchTool } from './tools/search.js';
import { readNotesByWikiIdsTool, readNotesTool } from './tools/read.js';
import { graphNeighborsTool } from './tools/graph.js';
import { applyNoteChangeTool, proposeNoteChangeTool, type NoteChangeInput } from './tools/write.js';
import { runWriteBridgeFromEnvironment } from './write-bridge.js';
import { preparePublishBranches, publishFromFoldedJournal } from './publish.js';
import {
  initConfig,
  loadRegistry,
  resolveBridgeConfig,
  resolveConfigPath,
  setConfigLocation,
} from './config.js';

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

function parseCliArguments(argv: string[]): { args: string[]; configPath?: string } {
  const args: string[] = [];
  let configPath: string | undefined;
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === '--config') {
      configPath = argv[++index];
      if (!configPath) throw new Error('--config requires a path');
    } else if (argument.startsWith('--config=')) {
      configPath = argument.slice('--config='.length);
      if (!configPath) throw new Error('--config requires a path');
    } else {
      args.push(argument);
    }
  }
  return { args, configPath };
}

function printJson(value: unknown): void {
  process.stdout.write(`${JSON.stringify(value, null, 2)}\n`);
}

function printHelp(): void {
  process.stdout.write(`obsidian-wiki - Obsidian Wiki local runtime manager

Usage:
  obsidian-wiki [--config <path>]                 Start the MCP stdio server
  obsidian-wiki init [--config <path>]            Create a commented JSONC config
  obsidian-wiki config path [--json]              Print the resolved config path
  obsidian-wiki config set-location <path>        Persist a custom config location
  obsidian-wiki config validate [--config <path>]
  obsidian-wiki doctor [--config <path>]           Validate project bindings and runtime health
  obsidian-wiki bridge start [--config <path>]    Start the foreground write bridge
  obsidian-wiki bridge status [--config <path>]   Check the write bridge health endpoint
  obsidian-wiki serve-write-bridge                Compatibility alias for bridge start
`);
}

async function main(): Promise<void> {
  const parsed = parseCliArguments(process.argv.slice(2));
  if (parsed.configPath) process.env.OBSIDIAN_WIKI_CONFIG = parsed.configPath;
  const [subcommand, action, ...rest] = parsed.args;
  if (subcommand === '--help' || subcommand === '-h') {
    printHelp();
    return;
  }
  if (subcommand === 'init') {
    printJson(initConfig(parsed.configPath));
    return;
  }
  if (subcommand === 'config' && action === 'path') {
    const resolved = resolveConfigPath(process.env, parsed.configPath);
    if (rest.includes('--json')) printJson({ configPath: resolved });
    else process.stdout.write(`${resolved}\n`);
    return;
  }
  if (subcommand === 'config' && action === 'set-location') {
    if (!rest[0]) throw new Error('config set-location requires a path');
    printJson({ configPath: setConfigLocation(rest[0]) });
    return;
  }
  if (subcommand === 'config' && action === 'validate') {
    const loaded = loadRegistry(process.env, parsed.configPath);
    printJson({ valid: true, configPath: loaded.registryPath, vaults: Object.keys(loaded.registry.vaults), repositories: Object.keys(loaded.registry.repositories) });
    return;
  }
  if (subcommand === 'doctor') {
    const result = statusTool(process.env);
    printJson(result);
    if (!result.healthy) process.exitCode = 1;
    return;
  }
  if (subcommand === 'bridge' && action === 'start') {
    await runWriteBridgeFromEnvironment(process.env);
    return;
  }
  if (subcommand === 'bridge' && action === 'status') {
    const resolved = resolveBridgeConfig(process.env, parsed.configPath, process.env.OBSIDIAN_WIKI_BRIDGE_VAULT_REF);
    const endpoint = resolved.config.url ?? `http://${resolved.config.host}:${resolved.config.port}`;
    try {
      const response = await fetch(new URL('/health', endpoint));
      const body = await response.json();
      printJson({ ...body, url: endpoint, registryPath: resolved.registryPath });
      if (!response.ok) process.exitCode = 1;
    } catch (error) {
      printJson({ ok: false, url: endpoint, registryPath: resolved.registryPath, error: error instanceof Error ? error.message : String(error) });
      process.exitCode = 1;
    }
    return;
  }
  if (subcommand === 'serve-write-bridge') {
    await runWriteBridgeFromEnvironment(process.env);
    return;
  }
  if (subcommand === 'status') {
    process.stdout.write(`${JSON.stringify(statusTool(process.env))}\n`);
    return;
  }
  if (subcommand === 'search') {
    const request = await readJsonRequest();
    if (typeof request.query !== 'string' || !request.query.trim()) {
      throw new Error('query must be a non-empty string');
    }
    process.stdout.write(`${JSON.stringify(searchTool({
      query: request.query,
      publishFeatureSlug: typeof request.publishFeatureSlug === 'string' ? request.publishFeatureSlug : undefined,
    }))}\n`);
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
  if (subcommand === 'propose-note-change' || subcommand === 'apply-note-change') {
    const request = await readJsonRequest();
    const input = request as NoteChangeInput;
    const result = subcommand === 'propose-note-change'
      ? await proposeNoteChangeTool(input)
      : await applyNoteChangeTool(input);
    process.stdout.write(`${JSON.stringify(result)}\n`);
    return;
  }
  if (subcommand === 'publish') {
    const request = await readJsonRequest();
    process.stdout.write(`${JSON.stringify(publishFromFoldedJournal(request))}\n`);
    return;
  }
  if (subcommand === 'prepare-publish') {
    const request = await readJsonRequest();
    process.stdout.write(`${JSON.stringify(preparePublishBranches(request))}\n`);
    return;
  }
  if (subcommand !== undefined) {
    throw new Error('Unknown command. Run obsidian-wiki --help for available commands.');
  }
  const server = createServer();
  await server.connect(new StdioServerTransport());
}

main().catch((error: unknown) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
});
