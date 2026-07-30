import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import {
  initConfig,
  loadRegistry,
  parseJsonc,
  resolveBridgeConfig,
  upsertRepository,
  upsertVault,
} from '../src/config.js';

const temporaryDirectories: string[] = [];

afterEach(() => {
  for (const directory of temporaryDirectories.splice(0)) rmSync(directory, { recursive: true, force: true });
});

function temporaryDirectory(): string {
  const directory = mkdtempSync(path.join(os.tmpdir(), 'obsidian-wiki-config-'));
  temporaryDirectories.push(directory);
  return directory;
}

describe('Obsidian Wiki unified configuration', () => {
  it('parses comments and trailing commas without changing string contents', () => {
    expect(parseJsonc(`{
      // comment
      "value": "https://example.test/a//b",
      "items": [1, 2,],
    }`)).toEqual({
      value: 'https://example.test/a//b',
      items: [1, 2],
    });
  });

  it('loads the custom config path and normalizes nested bridge settings', () => {
    const directory = temporaryDirectory();
    const configPath = path.join(directory, 'obsidian-wiki.jsonc');
    const vaultRoot = JSON.stringify(path.join(directory, 'vault'));
    const projectDir = JSON.stringify(path.join(directory, 'app'));
    writeFileSync(configPath, `{
      "vaults": {
        "knowledge": {
          "selector": "Knowledge",
          "bridge": {
            "url": "http://127.0.0.1:27128",
            "vaultRoot": ${vaultRoot},
            "allowedRoots": ["Projects/app"],
            "projectDirs": [${projectDir}]
          }
        }
      },
      "repositories": {
        "wiki": {
          "worktreeRoot": ${vaultRoot},
          "remote": "origin",
          "expectedRemote": "github.com/example/wiki",
          "baseBranch": "main"
        }
      }
    }`);
    const env = { OBSIDIAN_WIKI_CONFIG: configPath };
    const loaded = loadRegistry(env);
    expect(loaded.registryPath).toBe(configPath);
    expect(loaded.registry.vaults.knowledge.bridgePort).toBe(27128);
    expect(resolveBridgeConfig(env, undefined, 'knowledge').config.allowedRoots).toEqual(['Projects/app']);
  });

  it('creates an example and a non-overwriting active config', () => {
    const directory = temporaryDirectory();
    const configPath = path.join(directory, 'nested', 'obsidian-wiki.jsonc');
    const first = initConfig(configPath);
    expect(first.created).toBe(true);
    expect(readFileSync(first.examplePath, 'utf8')).toContain('allowedRoots');
    expect(JSON.parse(readFileSync(configPath, 'utf8'))).toEqual({
      version: 1,
      vaults: {},
      repositories: {},
    });
    writeFileSync(configPath, '{"custom": true}\n');
    expect(initConfig(configPath).created).toBe(false);
    expect(readFileSync(configPath, 'utf8')).toBe('{"custom": true}\n');
  });

  it('honors OBSIDIAN_WIKI_CONFIG when initializing without an explicit path', () => {
    const directory = temporaryDirectory();
    const configPath = path.join(directory, 'configured.jsonc');
    const result = initConfig(undefined, { OBSIDIAN_WIKI_CONFIG: configPath });
    expect(result.configPath).toBe(configPath);
    expect(readFileSync(configPath, 'utf8')).toContain('"vaults": {}');
  });

  it('upserts machine Vault and repository entries idempotently', () => {
    const directory = temporaryDirectory();
    const configPath = path.join(directory, 'obsidian-wiki.jsonc');
    initConfig(configPath);
    const env = { OBSIDIAN_WIKI_CONFIG: configPath };
    const vault = {
      ref: 'knowledge',
      selector: 'Knowledge',
      vaultRoot: path.join(directory, 'vault'),
      bridge: {
        url: 'http://127.0.0.1:27124',
        tokenEnv: 'OBSIDIAN_WIKI_BRIDGE_TOKEN',
        allowedRoots: ['Projects/app'],
        projectDirs: [path.join(directory, 'app')],
      },
    };
    const repository = {
      ref: 'wiki',
      worktreeRoot: path.join(directory, 'vault'),
      remote: 'origin',
      expectedRemote: 'github.com/example/wiki',
      baseBranch: 'main',
    };
    expect(upsertVault(vault, env)).toMatchObject({ created: true, changed: true });
    expect(upsertVault(vault, env)).toMatchObject({ created: false, changed: false });
    expect(upsertRepository(repository, env)).toMatchObject({ created: true, changed: true });
    expect(loadRegistry(env).registry.repositories.wiki.baseBranch).toBe('main');
  });

  it('requires replace for a conflicting existing entry', () => {
    const directory = temporaryDirectory();
    const configPath = path.join(directory, 'obsidian-wiki.jsonc');
    initConfig(configPath);
    const env = { OBSIDIAN_WIKI_CONFIG: configPath };
    const first = { ref: 'knowledge', selector: 'Knowledge' };
    const second = { ref: 'knowledge', selector: 'Other' };
    upsertVault(first, env);
    expect(() => upsertVault(second, env)).toThrow('after explicit authorization');
    expect(upsertVault(second, env, undefined, true)).toMatchObject({ changed: true });
    expect(loadRegistry(env).registry.vaults.knowledge.selector).toBe('Other');
  });
});
