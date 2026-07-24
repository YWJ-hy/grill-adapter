import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import {
  initConfig,
  loadRegistry,
  parseJsonc,
  resolveBridgeConfig,
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
    writeFileSync(configPath, `{
      "vaults": {
        "knowledge": {
          "selector": "Knowledge",
          "bridge": {
            "url": "http://127.0.0.1:27128",
            "vaultRoot": "${directory}/vault",
            "allowedRoots": ["Projects/app"],
            "projectDirs": ["${directory}/app"]
          }
        }
      },
      "repositories": {
        "wiki": {
          "worktreeRoot": "${directory}/vault",
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
    writeFileSync(configPath, '{"custom": true}\n');
    expect(initConfig(configPath).created).toBe(false);
    expect(readFileSync(configPath, 'utf8')).toBe('{"custom": true}\n');
  });
});
