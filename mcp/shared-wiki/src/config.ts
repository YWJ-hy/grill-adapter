import { createHash } from 'node:crypto';
import { existsSync, readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import path from 'node:path';
import * as z from 'zod/v4';

const ConfigFileSchema = z.object({
  repoUrl: z.string().min(1).optional(),
  baseBranch: z.string().min(1).optional(),
  remote: z.string().min(1).optional(),
  wikiRoot: z.string().min(1).optional(),
  displayRoot: z.string().min(1).optional(),
  cacheDir: z.string().min(1).optional(),
  draftPr: z.boolean().optional(),
});

// Per-project shared-wiki MCP connection block, read from
// <CLAUDE_PROJECT_DIR>/.shared-superpowers/settings.json -> wiki.sharedMcp.
// cacheDir is intentionally NOT accepted here: it is a machine-local concern and
// must not live in a committed project settings file. Governance (neutrality /
// authorization) is also absent on purpose — that lives inside the shared wiki
// repo and is read from the clone by wiki/policy.ts, not from the consumer project.
const ProjectMcpSchema = z.object({
  repoUrl: z.string().min(1).optional(),
  baseBranch: z.string().min(1).optional(),
  remote: z.string().min(1).optional(),
  wikiRoot: z.string().min(1).optional(),
  displayRoot: z.string().min(1).optional(),
  draftPr: z.boolean().optional(),
});

export type SharedWikiConfig = {
  repoUrl: string;
  baseBranch: string;
  remote: string;
  wikiRoot: string;
  displayRoot: string;
  cacheDir: string;
  cloneDir: string;
  draftPr: boolean;
};

function expandHome(input: string): string {
  if (input === '~') return homedir();
  if (input.startsWith('~/')) return path.join(homedir(), input.slice(2));
  return input;
}

function readConfigFile(configPath: string | undefined): Partial<z.infer<typeof ConfigFileSchema>> {
  if (!configPath) return {};
  const absolutePath = path.resolve(expandHome(configPath));
  if (!existsSync(absolutePath)) {
    throw new Error(`Config file not found: ${absolutePath}`);
  }
  const parsed = JSON.parse(readFileSync(absolutePath, 'utf8')) as unknown;
  return ConfigFileSchema.parse(parsed);
}

// Resolve the per-project shared-wiki connection from the consumer project's
// settings, located via CLAUDE_PROJECT_DIR (injected into every stdio MCP server
// by Claude Code). This lets a single generic, repo-less registration target a
// different shared wiki per project: the server self-configures from the project
// it was launched for. Returns {} when no project dir, no settings file, or no
// wiki.sharedMcp block exists — callers fail closed if nothing else supplies a repo.
function readProjectMcpConfig(env: NodeJS.ProcessEnv): Partial<z.infer<typeof ProjectMcpSchema>> {
  const projectDir = env.CLAUDE_PROJECT_DIR;
  if (!projectDir) return {};
  const settingsPath = path.join(path.resolve(expandHome(projectDir)), '.shared-superpowers', 'settings.json');
  if (!existsSync(settingsPath)) return {};
  let parsed: unknown;
  try {
    parsed = JSON.parse(readFileSync(settingsPath, 'utf8'));
  } catch (error) {
    throw new Error(`Invalid JSON in ${settingsPath}: ${error instanceof Error ? error.message : String(error)}`);
  }
  const sharedMcp = (parsed as { wiki?: { sharedMcp?: unknown } } | null)?.wiki?.sharedMcp;
  if (sharedMcp == null) return {};
  try {
    return ProjectMcpSchema.parse(sharedMcp);
  } catch (error) {
    throw new Error(`Invalid wiki.sharedMcp in ${settingsPath}: ${error instanceof Error ? error.message : String(error)}`);
  }
}

function repoCacheName(repoUrl: string): string {
  const digest = createHash('sha256').update(repoUrl).digest('hex').slice(0, 16);
  return `repo-${digest}`;
}

function normalizeRelativeRoot(value: string, field: string): string {
  if (path.isAbsolute(value)) {
    throw new Error(`${field} must be a relative path`);
  }
  const normalized = path.posix.normalize(value.replaceAll('\\', '/'));
  if (normalized === '..' || normalized.startsWith('../')) {
    throw new Error(`${field} must stay inside the shared wiki repository`);
  }
  return normalized === '.' ? '.' : normalized.replace(/^\.\//, '');
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): SharedWikiConfig {
  const fileConfig = readConfigFile(env.SHARED_WIKI_MCP_CONFIG);
  const projectConfig = readProjectMcpConfig(env);

  // Precedence per field: explicit env var > explicit SHARED_WIKI_MCP_CONFIG file >
  // per-project settings (CLAUDE_PROJECT_DIR) > built-in default. Existing global
  // setups keep working because they set SHARED_WIKI_MCP_CONFIG, which still wins;
  // the new generic registration sets none of these and resolves the repo entirely
  // from the project's wiki.sharedMcp block. With no source supplying a repo URL we
  // throw (fail closed) so a misconfigured project never silently targets the wrong
  // wiki — Claude Code reports the dead server and the agent treats shared wiki as
  // unavailable. cacheDir is never taken from the project block (machine-local).
  const repoUrl = env.SHARED_WIKI_MCP_REPO_URL ?? fileConfig.repoUrl ?? projectConfig.repoUrl;
  if (!repoUrl) {
    throw new Error('Missing shared wiki repo URL. Set wiki.sharedMcp.repoUrl in <project>/.shared-superpowers/settings.json (resolved from CLAUDE_PROJECT_DIR), or SHARED_WIKI_MCP_REPO_URL / repoUrl in SHARED_WIKI_MCP_CONFIG.');
  }

  const baseCacheDir = expandHome(env.SHARED_WIKI_MCP_CACHE_DIR ?? fileConfig.cacheDir ?? '~/.cache/grill-adapter/shared-wiki-mcp');
  const cacheDir = path.resolve(baseCacheDir);
  const wikiRoot = normalizeRelativeRoot(env.SHARED_WIKI_MCP_WIKI_ROOT ?? fileConfig.wikiRoot ?? projectConfig.wikiRoot ?? '.', 'wikiRoot');
  const displayRoot = normalizeRelativeRoot(env.SHARED_WIKI_MCP_DISPLAY_ROOT ?? fileConfig.displayRoot ?? projectConfig.displayRoot ?? '.shared-superpowers/wiki', 'displayRoot');

  return {
    repoUrl,
    baseBranch: env.SHARED_WIKI_MCP_BASE_BRANCH ?? fileConfig.baseBranch ?? projectConfig.baseBranch ?? 'main',
    remote: env.SHARED_WIKI_MCP_REMOTE ?? fileConfig.remote ?? projectConfig.remote ?? 'origin',
    wikiRoot,
    displayRoot,
    cacheDir,
    cloneDir: path.join(cacheDir, repoCacheName(repoUrl)),
    draftPr: fileConfig.draftPr ?? projectConfig.draftPr ?? true,
  };
}
