#!/usr/bin/env node
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { spawn } from 'node:child_process';
import { createServer } from './server.js';
import { statusTool } from './tools/status.js';
import { searchTool, searchWikiIdsTool } from './tools/search.js';
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
  resolveSecretEnvironment,
  setConfigLocation,
  upsertRepository,
  upsertVault,
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

function bridgeEndpoint(resolved: ReturnType<typeof resolveBridgeConfig>): string {
  return resolved.config.url ?? `http://${resolved.config.host}:${resolved.config.port}`;
}

async function fetchBridge(
  endpoint: string,
  init: RequestInit,
  timeoutMs = 5000,
): Promise<Response> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetch(endpoint, { ...init, signal: controller.signal });
  } finally {
    clearTimeout(timer);
  }
}

async function bridgeHealth(endpoint: string): Promise<boolean> {
  try {
    const response = await fetchBridge(new URL('/health', endpoint).toString(), {});
    return response.ok;
  } catch {
    return false;
  }
}

async function stopBridge(
  resolved: ReturnType<typeof resolveBridgeConfig>,
): Promise<{ running: boolean; stopped: boolean; endpoint: string }> {
  const endpoint = bridgeEndpoint(resolved);
  if (!(await bridgeHealth(endpoint))) {
    return { running: false, stopped: false, endpoint };
  }
  const token = resolveSecretEnvironment(resolved.config.tokenEnv, process.env);
  if (!token) throw new Error(`Obsidian Wiki bridge token is unavailable: ${resolved.config.tokenEnv}`);
  try {
    const response = await fetchBridge(new URL('/shutdown', endpoint).toString(), {
      method: 'POST',
      headers: { authorization: `Bearer ${token}` },
    });
    const body = await response.json().catch(() => undefined);
    if (!response.ok) {
      throw new Error(
        body && typeof body === 'object' && 'error' in body
          ? String((body as { error: unknown }).error)
          : `HTTP ${response.status}`,
      );
    }
  } catch (error) {
    if (await bridgeHealth(endpoint)) {
      throw new Error(`Obsidian Wiki bridge stop request failed: ${error instanceof Error ? error.message : String(error)}`);
    }
    return { running: false, stopped: false, endpoint };
  }
  const deadline = Date.now() + 5000;
  while (Date.now() < deadline) {
    if (!(await bridgeHealth(endpoint))) return { running: true, stopped: true, endpoint };
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(`Obsidian Wiki bridge did not stop at ${endpoint}`);
}

async function restartBridge(
  resolved: ReturnType<typeof resolveBridgeConfig>,
  configPath?: string,
): Promise<{ pid: number | undefined; endpoint: string }> {
  const stopped = await stopBridge(resolved);
  return startDetachedBridge(resolved, configPath, stopped.endpoint);
}

async function startDetachedBridge(
  resolved: ReturnType<typeof resolveBridgeConfig>,
  configPath?: string,
  endpoint = bridgeEndpoint(resolved),
): Promise<{ pid: number | undefined; endpoint: string }> {
  if (await bridgeHealth(endpoint)) {
    return { pid: undefined, endpoint };
  }
  const scriptPath = process.argv[1];
  if (!scriptPath) throw new Error('Cannot start Obsidian Wiki bridge without the CLI entrypoint path');
  const childArgs = [scriptPath, 'serve-write-bridge'];
  if (configPath) childArgs.push('--config', configPath);
  const child = spawn(process.execPath, childArgs, {
    detached: true,
    env: process.env,
    stdio: 'ignore',
    windowsHide: true,
  });
  child.unref();
  const deadline = Date.now() + 5000;
  while (Date.now() < deadline) {
    if (await bridgeHealth(endpoint)) return { pid: child.pid, endpoint };
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  try {
    if (child.pid) process.kill(child.pid, 'SIGTERM');
  } catch {
    // The child may have exited while the health check was polling.
  }
  throw new Error(`Obsidian Wiki bridge did not become healthy at ${endpoint}`);
}

function printHelp(): void {
  process.stdout.write(`obsidian-wiki - Obsidian Wiki local runtime manager

Usage:
  obsidian-wiki [--config <path>]                 Start the MCP stdio server
  obsidian-wiki init [--config <path>]            Create a commented JSONC config
  obsidian-wiki config path [--json]              Print the resolved config path
  obsidian-wiki config set-location <path>        Persist a custom config location
  printf '<json>' | obsidian-wiki config upsert-vault [--replace]
                                                    Upsert one machine Vault entry
  printf '<json>' | obsidian-wiki config upsert-repository [--replace]
                                                    Upsert one Git repository entry
  obsidian-wiki config validate [--config <path>]
  obsidian-wiki doctor [--config <path>]           Validate project bindings and runtime health
  printf '<json>' | obsidian-wiki search-by-wiki-ids
  obsidian-wiki bridge start [--config <path>]    Start a detached background write bridge
  obsidian-wiki bridge status [--config <path>]   Check the write bridge health endpoint
  obsidian-wiki bridge stop [--config <path>]    Gracefully stop the write bridge
  obsidian-wiki bridge restart [--config <path>] Restart the detached write bridge
  obsidian-wiki serve-write-bridge                Run the write bridge in the foreground
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
    printJson(initConfig(parsed.configPath, process.env));
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
  if (subcommand === 'config' && (action === 'upsert-vault' || action === 'upsert-repository')) {
    const request = await readJsonRequest();
    const replace = rest.includes('--replace');
    const result = action === 'upsert-vault'
      ? upsertVault(request as never, process.env, parsed.configPath, replace)
      : upsertRepository(request as never, process.env, parsed.configPath, replace);
    printJson(result);
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
    const resolved = resolveBridgeConfig(process.env, parsed.configPath, process.env.OBSIDIAN_WIKI_BRIDGE_VAULT_REF);
    const result = await startDetachedBridge(resolved, parsed.configPath);
    printJson({ ...result, running: true, started: result.pid !== undefined, registryPath: resolved.registryPath });
    return;
  }
  if (subcommand === 'bridge' && action === 'status') {
    const resolved = resolveBridgeConfig(process.env, parsed.configPath, process.env.OBSIDIAN_WIKI_BRIDGE_VAULT_REF);
    const endpoint = bridgeEndpoint(resolved);
    try {
      const response = await fetchBridge(new URL('/health', endpoint).toString(), {});
      const body = await response.json();
      printJson({ ...body, url: endpoint, registryPath: resolved.registryPath });
      if (!response.ok) process.exitCode = 1;
    } catch (error) {
      printJson({ ok: false, url: endpoint, registryPath: resolved.registryPath, error: error instanceof Error ? error.message : String(error) });
      process.exitCode = 1;
    }
    return;
  }
  if (subcommand === 'bridge' && (action === 'stop' || action === 'restart')) {
    const resolved = resolveBridgeConfig(process.env, parsed.configPath, process.env.OBSIDIAN_WIKI_BRIDGE_VAULT_REF);
    if (action === 'stop') {
      const result = await stopBridge(resolved);
      printJson({ ...result, registryPath: resolved.registryPath });
    } else {
      const result = await restartBridge(resolved, parsed.configPath);
      printJson({ ...result, restarted: true, registryPath: resolved.registryPath });
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
  if (subcommand === 'search' || subcommand === 'search-by-wiki-ids') {
    const request = await readJsonRequest();
    if (subcommand === 'search') {
      if (typeof request.query !== 'string' || !request.query.trim()) {
        throw new Error('query must be a non-empty string');
      }
      process.stdout.write(`${JSON.stringify(searchTool({
        query: request.query,
        publishFeatureSlug: typeof request.publishFeatureSlug === 'string' ? request.publishFeatureSlug : undefined,
      }))}\n`);
      return;
    }
    if (
      !Array.isArray(request.wikiIds)
      || request.wikiIds.length === 0
      || request.wikiIds.some((value) => typeof value !== 'string' || !value)
    ) {
      throw new Error('wikiIds must be a non-empty array of non-empty strings');
    }
    process.stdout.write(`${JSON.stringify(searchWikiIdsTool({
      wikiIds: request.wikiIds,
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
