import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import * as z from 'zod/v4';

const BridgeSchema = z.object({
  url: z.string().url().optional(),
  host: z.string().min(1).optional(),
  port: z.number().int().positive().optional(),
  tokenEnv: z.string().min(1).optional(),
  vaultRoot: z.string().min(1).optional(),
  allowedRoots: z.array(z.string().min(1)).optional(),
  projectDirs: z.array(z.string().min(1)).optional(),
}).optional();

const RawVaultSchema = z.object({
  selector: z.string().min(1),
  vaultRoot: z.string().min(1).optional(),
  bridgeUrl: z.string().url().optional(),
  bridgeTokenEnv: z.string().min(1).optional(),
  bridge: BridgeSchema,
});

export const RepositorySchema = z.object({
  worktreeRoot: z.string().min(1),
  remote: z.string().min(1),
  expectedRemote: z.string().min(1),
  baseBranch: z.string().min(1),
  syncBeforeResearch: z.boolean().optional(),
  allowStaleRead: z.boolean().optional(),
});

export const RawRegistrySchema = z.object({
  version: z.number().int().positive().optional(),
  vaults: z.record(z.string().min(1), RawVaultSchema),
  repositories: z.record(z.string().min(1), RepositorySchema),
});

export type Repository = z.infer<typeof RepositorySchema>;

export type Vault = {
  selector: string;
  vaultRoot?: string;
  bridgeUrl?: string;
  bridgeTokenEnv?: string;
  bridgeHost?: string;
  bridgePort?: number;
  bridgeAllowedRoots?: string[];
  bridgeProjectDirs?: string[];
};

export type Registry = {
  version?: number;
  vaults: Record<string, Vault>;
  repositories: Record<string, Repository>;
};

export type BridgeConfig = {
  vaultRef: string;
  selector: string;
  vaultRoot: string;
  url?: string;
  host: string;
  port: number;
  tokenEnv: string;
  allowedRoots: string[];
  projectDirs: string[];
};

export const DEFAULT_CONFIG_DIR = path.join(os.homedir(), '.config', 'grill-adapter');
export const DEFAULT_CONFIG_PATH = path.join(DEFAULT_CONFIG_DIR, 'obsidian-wiki.jsonc');
export const LEGACY_CONFIG_PATH = path.join(DEFAULT_CONFIG_DIR, 'obsidian-wiki.json');
export const LOCATION_POINTER_PATH = path.join(DEFAULT_CONFIG_DIR, 'obsidian-wiki-location.json');

export const CONFIG_EXAMPLE = `{
  // Schema version for this local machine configuration.
  "version": 1,

  "vaults": {
    "engineering-knowledge": {
      // Name shown by the Obsidian CLI (run: obsidian vaults).
      "selector": "Engineering-Knowledge",

      // Absolute path to the Git worktree opened as this Vault.
      "vaultRoot": "/Users/me/Knowledge/Engineering-Knowledge",

      "bridge": {
        // Loopback URL used by the MCP client to call the write bridge.
        "url": "http://127.0.0.1:27124",

        // Environment variable containing the bridge bearer token.
        "tokenEnv": "OBSIDIAN_WIKI_BRIDGE_TOKEN",

        // Vault-relative Source roots that the bridge may write.
        "allowedRoots": [
          "Projects/my-app"
        ],

        // Absolute project directories allowed to request writes.
        "projectDirs": [
          "/Users/me/dev/my-app"
        ]
      }
    }
  },

  "repositories": {
    "engineering-wiki-all": {
      // Same path as the Vault worktree above.
      "worktreeRoot": "/Users/me/Knowledge/Engineering-Knowledge",
      "remote": "origin",
      "expectedRemote": "github.com/example/engineering-wiki",
      "baseBranch": "main",

      // Research normally proves the base branch is current before reading.
      "syncBeforeResearch": true,
      "allowStaleRead": false
    }
  }
}
`;

function stripJsoncComments(contents: string): string {
  let output = '';
  let inString = false;
  let escaped = false;
  let lineComment = false;
  let blockComment = false;
  for (let index = 0; index < contents.length; index += 1) {
    const character = contents[index];
    const next = contents[index + 1];
    if (lineComment) {
      if (character === '\n' || character === '\r') {
        lineComment = false;
        output += character;
      } else {
        output += ' ';
      }
      continue;
    }
    if (blockComment) {
      if (character === '*' && next === '/') {
        blockComment = false;
        output += '  ';
        index += 1;
      } else {
        output += character === '\n' || character === '\r' ? character : ' ';
      }
      continue;
    }
    if (inString) {
      output += character;
      if (escaped) escaped = false;
      else if (character === '\\') escaped = true;
      else if (character === '"') inString = false;
      continue;
    }
    if (character === '"') {
      inString = true;
      output += character;
    } else if (character === '/' && next === '/') {
      lineComment = true;
      output += '  ';
      index += 1;
    } else if (character === '/' && next === '*') {
      blockComment = true;
      output += '  ';
      index += 1;
    } else {
      output += character;
    }
  }
  return output;
}

function stripTrailingCommas(contents: string): string {
  let output = '';
  let inString = false;
  let escaped = false;
  for (let index = 0; index < contents.length; index += 1) {
    const character = contents[index];
    if (inString) {
      output += character;
      if (escaped) escaped = false;
      else if (character === '\\') escaped = true;
      else if (character === '"') inString = false;
      continue;
    }
    if (character === '"') {
      inString = true;
      output += character;
      continue;
    }
    if (character === ',') {
      let lookahead = index + 1;
      while (lookahead < contents.length && /\s/.test(contents[lookahead])) lookahead += 1;
      if (contents[lookahead] === '}' || contents[lookahead] === ']') continue;
    }
    output += character;
  }
  return output;
}

export function parseJsonc(contents: string, filePath = 'configuration'): unknown {
  try {
    return JSON.parse(stripTrailingCommas(stripJsoncComments(contents)));
  } catch (error) {
    throw new Error(`Invalid JSONC in ${filePath}: ${error instanceof Error ? error.message : String(error)}`);
  }
}

function requireRegularFile(filePath: string, description: string): void {
  if (!existsSync(filePath)) throw new Error(`${description} not found: ${filePath}`);
}

function readLocationPointer(): string | undefined {
  if (!existsSync(LOCATION_POINTER_PATH)) return undefined;
  const raw = parseJsonc(readFileSync(LOCATION_POINTER_PATH, 'utf8'), LOCATION_POINTER_PATH);
  if (!raw || typeof raw !== 'object' || Array.isArray(raw) || typeof (raw as { configPath?: unknown }).configPath !== 'string') {
    throw new Error(`Invalid Obsidian Wiki config location pointer: ${LOCATION_POINTER_PATH}`);
  }
  return path.resolve((raw as { configPath: string }).configPath);
}

export function resolveConfigPath(
  env: NodeJS.ProcessEnv = process.env,
  explicitPath?: string,
): string {
  const configured = explicitPath
    ?? env.OBSIDIAN_WIKI_CONFIG
    ?? env.OBSIDIAN_WIKI_REGISTRY
    ?? readLocationPointer();
  if (configured) return path.resolve(configured);
  if (existsSync(DEFAULT_CONFIG_PATH)) return DEFAULT_CONFIG_PATH;
  return LEGACY_CONFIG_PATH;
}

function normalizeVault(raw: z.infer<typeof RawVaultSchema>): Vault {
  const bridge = raw.bridge;
  const bridgeUrl = raw.bridgeUrl ?? bridge?.url;
  const bridgeTokenEnv = raw.bridgeTokenEnv ?? bridge?.tokenEnv;
  const bridgeUrlValue = bridgeUrl ? new URL(bridgeUrl) : undefined;
  return {
    selector: raw.selector,
    vaultRoot: raw.vaultRoot ?? bridge?.vaultRoot,
    bridgeUrl,
    bridgeTokenEnv,
    bridgeHost: bridge?.host ?? bridgeUrlValue?.hostname,
    bridgePort: bridge?.port ?? (bridgeUrlValue ? Number(bridgeUrlValue.port || '27124') : undefined),
    bridgeAllowedRoots: bridge?.allowedRoots,
    bridgeProjectDirs: bridge?.projectDirs,
  };
}

export function loadRegistry(
  env: NodeJS.ProcessEnv = process.env,
  explicitPath?: string,
): { registry: Registry; registryPath: string } {
  const registryPath = resolveConfigPath(env, explicitPath);
  requireRegularFile(registryPath, 'Obsidian Wiki registry');
  const parsed = RawRegistrySchema.parse(parseJsonc(readFileSync(registryPath, 'utf8'), registryPath));
  return {
    registry: {
      version: parsed.version,
      vaults: Object.fromEntries(Object.entries(parsed.vaults).map(([ref, vault]) => [ref, normalizeVault(vault)])),
      repositories: parsed.repositories,
    },
    registryPath,
  };
}

export function resolveBridgeConfig(
  env: NodeJS.ProcessEnv = process.env,
  explicitPath?: string,
  requestedVaultRef?: string,
): { config: BridgeConfig; registryPath: string } {
  const loaded = loadRegistry(env, explicitPath);
  const candidates = Object.entries(loaded.registry.vaults)
    .filter(([, vault]) => vault.vaultRoot && (vault.bridgeAllowedRoots?.length ?? 0) > 0 && (vault.bridgeProjectDirs?.length ?? 0) > 0);
  const selected = requestedVaultRef
    ? candidates.find(([ref]) => ref === requestedVaultRef)
    : candidates.length === 1 ? candidates[0] : undefined;
  if (!selected) {
    const available = candidates.map(([ref]) => ref).join(', ') || 'none';
    throw new Error(`Cannot select a configured Obsidian Wiki bridge Vault${requestedVaultRef ? `: ${requestedVaultRef}` : ''}. Available: ${available}`);
  }
  const [vaultRef, vault] = selected;
  const tokenEnv = env.OBSIDIAN_WIKI_BRIDGE_TOKEN_ENV ?? vault.bridgeTokenEnv ?? 'OBSIDIAN_WIKI_BRIDGE_TOKEN';
  return {
    registryPath: loaded.registryPath,
    config: {
      vaultRef,
      selector: vault.selector,
      vaultRoot: vault.vaultRoot!,
      url: vault.bridgeUrl,
      host: env.OBSIDIAN_WIKI_BRIDGE_HOST ?? vault.bridgeHost ?? '127.0.0.1',
      port: Number(env.OBSIDIAN_WIKI_BRIDGE_PORT ?? vault.bridgePort ?? '27124'),
      tokenEnv,
      allowedRoots: vault.bridgeAllowedRoots!,
      projectDirs: vault.bridgeProjectDirs!,
    },
  };
}

export function initConfig(configPath?: string): { configPath: string; examplePath: string; created: boolean } {
  const target = path.resolve(configPath ?? DEFAULT_CONFIG_PATH);
  const examplePath = target.endsWith('.jsonc')
    ? target.replace(/\.jsonc$/, '.example.jsonc')
    : target.endsWith('.json')
      ? target.replace(/\.json$/, '.example.json')
    : `${target}.example.jsonc`;
  mkdirSync(path.dirname(target), { recursive: true });
  if (!existsSync(examplePath)) writeFileSync(examplePath, CONFIG_EXAMPLE, { encoding: 'utf8', mode: 0o600 });
  const created = !existsSync(target);
  if (created) writeFileSync(target, CONFIG_EXAMPLE, { encoding: 'utf8', mode: 0o600 });
  return { configPath: target, examplePath, created };
}

export function setConfigLocation(configPath: string): string {
  const target = path.resolve(configPath);
  mkdirSync(DEFAULT_CONFIG_DIR, { recursive: true });
  writeFileSync(
    LOCATION_POINTER_PATH,
    `${JSON.stringify({ configPath: target }, null, 2)}\n`,
    { encoding: 'utf8', mode: 0o600 },
  );
  return target;
}
