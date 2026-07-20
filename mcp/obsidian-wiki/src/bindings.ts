import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { existsSync, lstatSync, readFileSync, realpathSync } from 'node:fs';
import path from 'node:path';
import * as z from 'zod/v4';
import { normalizeWritePolicy, stricterPolicy, type WritePolicy } from './policy.js';
import { isLoopbackHost } from './loopback.js';

const BindingSchema = z.object({
  sourceId: z.string().min(1),
  role: z.enum(['project', 'shared']),
  vaultRef: z.string().min(1),
  repositoryRef: z.string().min(1),
  root: z.string().min(1),
  access: z.object({
    read: z.boolean(),
    update: z.string().optional(),
  }),
});

const ProjectSettingsSchema = z.object({
  wiki: z.object({
    provider: z.literal('obsidian'),
    publishing: z.object({ mode: z.string().min(1) }),
    obsidian: z.object({
      bindings: z.array(BindingSchema).min(1),
      exclude: z.array(z.string()).optional(),
    }),
  }),
});

const VaultSchema = z.object({
  selector: z.string().min(1),
  bridgeUrl: z.string().url().optional(),
  bridgeTokenEnv: z.string().min(1).optional(),
});

const RepositorySchema = z.object({
  worktreeRoot: z.string().min(1),
  remote: z.string().min(1),
  expectedRemote: z.string().min(1),
  baseBranch: z.string().min(1),
  syncBeforeResearch: z.boolean().optional(),
  allowStaleRead: z.boolean().optional(),
});

const RegistrySchema = z.object({
  vaults: z.record(z.string().min(1), VaultSchema),
  repositories: z.record(z.string().min(1), RepositorySchema),
});

type Vault = z.infer<typeof VaultSchema>;
type Repository = z.infer<typeof RepositorySchema>;

type VaultHealth = {
  selector: string;
  writeBridgeConfigured: boolean;
};

type RepositoryHealth = {
  remote: string;
  expectedRemote: string;
  baseBranch: string;
  currentBranch: string;
};

export type SourceManifest = {
  wikiSchema: string;
  sourceId: string;
  scope: 'project' | 'shared';
  agentVisible: boolean | undefined;
  updateExisting: WritePolicy;
  createNote: WritePolicy;
  blockedTerms: string[];
  blockedPatterns: string[];
};

export type ResolvedBinding = {
  sourceId: string;
  role: 'project' | 'shared';
  vaultRef: string;
  vaultSelector: string;
  bridgeUrl: string | undefined;
  bridgeTokenEnv: string | undefined;
  repositoryRef: string;
  repository: Repository;
  vaultHealth: VaultHealth;
  repositoryHealth: RepositoryHealth;
  root: string;
  resolvedRoot: string;
  publishingMode: string;
  effectiveReadPolicy: 'allow' | 'deny';
  effectiveUpdatePolicy: WritePolicy;
  effectiveCreatePolicy: WritePolicy;
  manifest: SourceManifest;
  bindingDigest: string;
};

export type BindingResolution = {
  projectDir: string;
  registryPath: string;
  bindings: ResolvedBinding[];
  errors: string[];
  warnings: string[];
};

export type McpRequestMeta = Record<string, unknown> | undefined;

export function environmentForMcpRequest(
  env: NodeJS.ProcessEnv,
  requestMeta: McpRequestMeta,
  workingDirectory: string = process.cwd(),
): NodeJS.ProcessEnv {
  if (env.CLAUDE_PROJECT_DIR) return env;
  const turnMeta = requestMeta?.['x-codex-turn-metadata'];
  const isCodexRequest = turnMeta !== null && typeof turnMeta === 'object' && !Array.isArray(turnMeta);
  const workspaces = isCodexRequest
    ? (turnMeta as Record<string, unknown>).workspaces
    : undefined;
  const workspaceDirs = workspaces !== null && typeof workspaces === 'object' && !Array.isArray(workspaces)
    ? Object.keys(workspaces).filter((workspace) => path.isAbsolute(workspace))
    : [];
  const configuredProjectDirs = [...new Set(workspaceDirs.map((dir) => path.resolve(dir)))]
    .filter((dir) => existsSync(path.join(dir, '.shared-adapter', 'settings.json')));
  if (!isCodexRequest) {
    const projectDir = path.resolve(workingDirectory);
    if (existsSync(path.join(projectDir, '.shared-adapter', 'settings.json'))) {
      return { ...env, CLAUDE_PROJECT_DIR: projectDir };
    }
  }
  if (configuredProjectDirs.length === 0) {
    throw new Error('No Codex workspace metadata contains .shared-adapter/settings.json for Obsidian Wiki binding resolution');
  }
  if (configuredProjectDirs.length > 1) {
    throw new Error(
      `Multiple Codex workspaces contain .shared-adapter/settings.json; Obsidian Wiki binding is ambiguous: ${configuredProjectDirs.join(', ')}`,
    );
  }
  return { ...env, CLAUDE_PROJECT_DIR: configuredProjectDirs[0] };
}

function normalizeRoot(value: string): string {
  if (path.isAbsolute(value)) throw new Error('binding root must be a relative path');
  const normalized = path.posix.normalize(value.replaceAll('\\', '/'));
  if (normalized === '.' || normalized === '..' || normalized.startsWith('../')) {
    throw new Error('binding root must name a directory inside the Vault');
  }
  return normalized.replace(/^\.\//, '');
}

function requireRegularFile(filePath: string, message: string): void {
  if (!existsSync(filePath) || !lstatSync(filePath).isFile()) throw new Error(message);
}

function parseScalar(raw: string): string | boolean {
  const value = raw.trim();
  if (value === 'true') return true;
  if (value === 'false') return false;
  return value.replace(/^['"]|['"]$/g, '');
}

function parseStringList(lines: string[], start: number): { values: string[]; end: number } {
  const values: string[] = [];
  let index = start;
  while (index < lines.length && /^\s+-\s+/.test(lines[index])) {
    values.push(String(parseScalar(lines[index].replace(/^\s+-\s+/, ''))));
    index += 1;
  }
  return { values, end: index };
}

export function parseSourceManifest(contents: string, manifestPath = '_meta/wiki-source.md'): SourceManifest {
  const normalized = contents.replaceAll('\r\n', '\n');
  if (!normalized.startsWith('---\n')) throw new Error(`${manifestPath} must start with YAML frontmatter`);
  const closing = normalized.indexOf('\n---\n', 4);
  if (closing === -1) throw new Error(`${manifestPath} frontmatter is not terminated`);
  const values: Record<string, string | boolean | string[]> = {};
  const lines = normalized.slice(4, closing).split('\n');
  for (let index = 0; index < lines.length; index += 1) {
    const match = /^([a-z_]+):\s*(.*)$/.exec(lines[index]);
    if (!match) throw new Error(`${manifestPath} has unsupported frontmatter syntax on line ${index + 2}`);
    const [, key, raw] = match;
    if (raw === '') {
      const list = parseStringList(lines, index + 1);
      values[key] = list.values;
      index = list.end - 1;
    } else {
      values[key] = parseScalar(raw);
    }
  }

  if (values.wiki_schema !== 'grill-adapter.obsidian-source/v1') {
    throw new Error(`${manifestPath} must declare wiki_schema: grill-adapter.obsidian-source/v1`);
  }
  const sourceId = values.wiki_source_id;
  const scope = values.scope;
  if (typeof sourceId !== 'string' || !sourceId) throw new Error(`${manifestPath} must declare wiki_source_id`);
  if (scope !== 'project' && scope !== 'shared') throw new Error(`${manifestPath} must declare scope: project or shared`);
  if (scope === 'shared' && (!Array.isArray(values.blocked_terms) || !Array.isArray(values.blocked_patterns))) {
    throw new Error(`${manifestPath} for a shared Source must declare blocked_terms and blocked_patterns`);
  }

  return {
    wikiSchema: values.wiki_schema,
    sourceId,
    scope,
    agentVisible: typeof values.agent_visible === 'boolean' ? values.agent_visible : undefined,
    updateExisting: normalizeWritePolicy(typeof values.update_existing === 'string' ? values.update_existing : undefined, `${manifestPath} update_existing`),
    createNote: normalizeWritePolicy(typeof values.create_note === 'string' ? values.create_note : undefined, `${manifestPath} create_note`),
    blockedTerms: Array.isArray(values.blocked_terms) ? values.blocked_terms.map(String) : [],
    blockedPatterns: Array.isArray(values.blocked_patterns) ? values.blocked_patterns.map(String) : [],
  };
}

function readJsonFile(filePath: string, description: string): unknown {
  requireRegularFile(filePath, `${description} not found: ${filePath}`);
  try {
    return JSON.parse(readFileSync(filePath, 'utf8'));
  } catch (error) {
    throw new Error(`Invalid JSON in ${filePath}: ${error instanceof Error ? error.message : String(error)}`);
  }
}

function bindingDigest(binding: Omit<ResolvedBinding, 'bindingDigest'>): string {
  const canonical = [
    binding.vaultRef,
    binding.sourceId,
    binding.role,
    binding.root,
    binding.publishingMode,
    binding.repositoryRef,
    binding.repository.baseBranch,
    binding.effectiveReadPolicy,
  ].join('\n');
  return createHash('sha256').update(canonical).digest('hex');
}

function commandOutput(command: string, args: string[], workingDirectory?: string): string {
  try {
    return String(execFileSync(command, args, {
      cwd: workingDirectory,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
    })).trim();
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    throw new Error(`${command} ${args.join(' ')} failed: ${message}`);
  }
}

function normalizeRemoteIdentity(value: string, field: string): string {
  const trimmed = value.trim();
  if (!trimmed) throw new Error(`${field} must not be empty`);
  if (/^[a-z][a-z0-9+.-]*:\/\/[^/]*@/i.test(trimmed) && !/^ssh:\/\/git@/i.test(trimmed)) {
    throw new Error(`${field} must not contain credentials`);
  }

  const scpStyle = !trimmed.includes('://') ? /^(?:([^@:/]+)@)?([^:/]+):(.+)$/.exec(trimmed) : undefined;
  if (scpStyle) {
    const [, username, host, repositoryPath] = scpStyle;
    if (username && username !== 'git') throw new Error(`${field} must not contain credentials`);
    return `${host.toLowerCase()}/${repositoryPath}`.replace(/\/+$/, '').replace(/\.git$/, '');
  }

  try {
    const url = new URL(trimmed);
    if ((url.protocol === 'http:' || url.protocol === 'https:') && (url.username || url.password)) {
      throw new Error(`${field} must not contain credentials`);
    }
    if (url.protocol === 'ssh:' && url.username && url.username !== 'git') {
      throw new Error(`${field} must not contain credentials`);
    }
    if (!url.hostname) throw new Error(`${field} must identify a repository host`);
    return `${url.hostname.toLowerCase()}${url.pathname}`.replace(/\/+$/, '').replace(/\.git$/, '');
  } catch (error) {
    if (error instanceof Error && error.message.includes(field)) throw error;
  }

  return trimmed.replace(/^git@/, '').replace(/\/+$/, '').replace(/\.git$/, '').toLowerCase();
}

function stagedWikiChangesAreAllowed(worktreeRoot: string, roots: string[]): boolean {
  const tracked = commandOutput('git', ['-C', worktreeRoot, 'diff', 'HEAD', '--name-status', '--'])
    .split(/\r?\n/).filter(Boolean).map((entry) => {
      const match = /^([MA])\t(.+)$/.exec(entry);
      return match ? match[2] : undefined;
    });
  const untracked = commandOutput('git', ['-C', worktreeRoot, 'ls-files', '--others', '--exclude-standard'])
    .split(/\r?\n/).filter(Boolean);
  const entries = [...tracked, ...untracked];
  return entries.length > 0 && entries.every((entry) => {
    if (entry === undefined) return false;
    const changedPath = entry.replace(/^"|"$/g, '').replaceAll('\\', '/');
    if (!changedPath.endsWith('.md')) return false;
    return roots.some((root) => (
      changedPath.startsWith(`${root}/`)
      && changedPath !== `${root}/_meta`
      && !changedPath.startsWith(`${root}/_meta/`)
    ));
  });
}

function validateRepository(repository: Repository, allowedStagedRoots: string[] = []): RepositoryHealth {
  if (!existsSync(repository.worktreeRoot)) {
    throw new Error(`repository worktree not found: ${repository.worktreeRoot}`);
  }
  const worktreeRoot = realpathSync(repository.worktreeRoot);
  const configuredRemote = normalizeRemoteIdentity(repository.expectedRemote, 'repository expectedRemote');
  const insideWorktree = commandOutput('git', ['-C', worktreeRoot, 'rev-parse', '--is-inside-work-tree']);
  if (insideWorktree !== 'true') throw new Error(`repository worktree is not a Git worktree: ${worktreeRoot}`);

  const actualRemote = commandOutput('git', ['-C', worktreeRoot, 'remote', 'get-url', repository.remote]);
  if (normalizeRemoteIdentity(actualRemote, `repository remote ${repository.remote}`) !== configuredRemote) {
    throw new Error(`repository remote ${repository.remote} does not match expectedRemote`);
  }

  const currentBranch = commandOutput('git', ['-C', worktreeRoot, 'branch', '--show-current']);
  if (currentBranch !== repository.baseBranch) {
    throw new Error(`repository must be on baseBranch ${repository.baseBranch}, found ${currentBranch || 'detached HEAD'}`);
  }
  if (existsSync(path.join(worktreeRoot, '.grill-adapter-wiki.publish.lock'))) {
    throw new Error('repository has an active Obsidian Wiki publish lock');
  }

  const operationMarkers = ['MERGE_HEAD', 'REBASE_HEAD', 'CHERRY_PICK_HEAD', 'REVERT_HEAD', 'BISECT_LOG'];
  for (const marker of operationMarkers) {
    const markerPath = commandOutput('git', ['-C', worktreeRoot, 'rev-parse', '--git-path', marker]);
    if (existsSync(path.resolve(worktreeRoot, markerPath))) throw new Error(`repository has an active Git operation: ${marker}`);
  }

  const worktreeStatus = commandOutput('git', ['-C', worktreeRoot, 'status', '--porcelain=v1', '--untracked-files=all']);
  const hasAllowedStagedChanges = worktreeStatus !== '' && stagedWikiChangesAreAllowed(worktreeRoot, allowedStagedRoots);
  if (worktreeStatus && !hasAllowedStagedChanges) {
    throw new Error('repository worktree must be clean or contain only staged Obsidian Note changes under bound Source roots');
  }
  if (!hasAllowedStagedChanges && repository.syncBeforeResearch !== false) {
    try {
      const remoteBase = `${repository.remote}/${repository.baseBranch}`;
      commandOutput('git', ['-C', worktreeRoot, 'fetch', '--quiet', repository.remote, repository.baseBranch]);
      commandOutput('git', ['-C', worktreeRoot, 'merge', '--ff-only', remoteBase]);
      const localRevision = commandOutput('git', ['-C', worktreeRoot, 'rev-parse', 'HEAD']);
      const remoteRevision = commandOutput('git', ['-C', worktreeRoot, 'rev-parse', remoteBase]);
      if (localRevision !== remoteRevision) throw new Error(`local ${repository.baseBranch} is not current with ${remoteBase}`);
    } catch (error) {
      if (!repository.allowStaleRead) {
        throw new Error(`repository cannot prove a fresh baseBranch: ${error instanceof Error ? error.message : String(error)}`);
      }
    }
  }

  return {
    remote: repository.remote,
    expectedRemote: configuredRemote,
    baseBranch: repository.baseBranch,
    currentBranch,
  };
}

function validateVault(vault: Vault, env: NodeJS.ProcessEnv): VaultHealth {
  if ((vault.bridgeUrl === undefined) !== (vault.bridgeTokenEnv === undefined)) {
    throw new Error('Vault write bridge requires both bridgeUrl and bridgeTokenEnv');
  }
  if (vault.bridgeUrl) {
    const url = new URL(vault.bridgeUrl);
    if (url.protocol !== 'http:' || !isLoopbackHost(url.hostname)) {
      throw new Error('Vault bridgeUrl must use HTTP on a loopback host');
    }
    if (url.username || url.password || (url.pathname !== '/' && url.pathname !== '')) {
      throw new Error('Vault bridgeUrl must not contain credentials or a path');
    }
  }
  const executable = env.OBSIDIAN_WIKI_OBSIDIAN_CLI || 'obsidian';
  const listedVaults = commandOutput(executable, ['vault']);
  if (!listedVaults.split(/\r?\n/).some((line) => line.trim() === vault.selector)) {
    throw new Error(`Obsidian Vault selector is not available: ${vault.selector}`);
  }
  return { selector: vault.selector, writeBridgeConfigured: vault.bridgeUrl !== undefined };
}

export function resolveBindings(
  env: NodeJS.ProcessEnv = process.env,
  workingDirectory: string = process.cwd(),
  options: { allowStagedWikiChanges?: boolean } = {},
): BindingResolution {
  const projectDir = path.resolve(env.CLAUDE_PROJECT_DIR ?? workingDirectory);
  const settingsPath = path.join(projectDir, '.shared-adapter', 'settings.json');
  const settings = ProjectSettingsSchema.parse(readJsonFile(settingsPath, 'Project settings'));
  const registryPath = path.resolve(env.OBSIDIAN_WIKI_REGISTRY ?? path.join(process.env.HOME ?? '', '.config', 'grill-adapter', 'obsidian-wiki.json'));
  const registry = RegistrySchema.parse(readJsonFile(registryPath, 'Obsidian Wiki registry'));
  const errors: string[] = [];
  const warnings: string[] = [];
  const bindings: ResolvedBinding[] = [];
  const sourceIds = new Set<string>();
  const roots = new Set<string>();
  let projectBindings = 0;

  for (const candidate of settings.wiki.obsidian.bindings) {
    try {
      if (sourceIds.has(candidate.sourceId)) throw new Error(`duplicate sourceId: ${candidate.sourceId}`);
      sourceIds.add(candidate.sourceId);
      if (candidate.role === 'project' && ++projectBindings > 1) throw new Error('at most one binding may have role: project');
      const root = normalizeRoot(candidate.root);
      const rootIdentity = `${candidate.vaultRef}\n${root}`;
      if (roots.has(rootIdentity)) throw new Error(`duplicate root for vault ${candidate.vaultRef}: ${root}`);
      const overlappingRoot = [...roots].find((identity) => {
        const [vaultRef, existingRoot] = identity.split('\n', 2);
        return vaultRef === candidate.vaultRef && (root.startsWith(`${existingRoot}/`) || existingRoot.startsWith(`${root}/`));
      });
      if (overlappingRoot) throw new Error(`overlapping root for vault ${candidate.vaultRef}: ${root}`);
      roots.add(rootIdentity);
      const vault = registry.vaults[candidate.vaultRef];
      if (!vault) throw new Error(`unresolved vaultRef: ${candidate.vaultRef}`);
      const repository = registry.repositories[candidate.repositoryRef];
      if (!repository) throw new Error(`unresolved repositoryRef: ${candidate.repositoryRef}`);
      const vaultHealth = validateVault(vault, env);
      const stagedRoots = options.allowStagedWikiChanges
        ? settings.wiki.obsidian.bindings
          .filter((binding) => binding.repositoryRef === candidate.repositoryRef)
          .map((binding) => normalizeRoot(binding.root))
        : [];
      const repositoryHealth = validateRepository(repository, stagedRoots);
      const worktreeRoot = realpathSync(repository.worktreeRoot);
      const configuredRoot = path.join(worktreeRoot, root);
      if (!existsSync(configuredRoot)) {
        throw new Error(`Source manifest missing for ${candidate.sourceId}`);
      }
      const resolvedRoot = realpathSync(configuredRoot);
      if (resolvedRoot !== worktreeRoot && !resolvedRoot.startsWith(`${worktreeRoot}${path.sep}`)) {
        throw new Error(`binding root escapes repository worktree: ${root}`);
      }
      const manifestPath = path.join(resolvedRoot, '_meta', 'wiki-source.md');
      requireRegularFile(manifestPath, `Source manifest missing for ${candidate.sourceId}`);
      const resolvedManifestPath = realpathSync(manifestPath);
      if (!resolvedManifestPath.startsWith(`${resolvedRoot}${path.sep}`)) {
        throw new Error(`Source manifest escapes binding root: ${candidate.sourceId}`);
      }
      const manifest = parseSourceManifest(readFileSync(resolvedManifestPath, 'utf8'), resolvedManifestPath);
      if (manifest.sourceId !== candidate.sourceId) {
        throw new Error(`Source manifest ID mismatch: binding ${candidate.sourceId}, manifest ${manifest.sourceId}`);
      }
      if (manifest.scope !== candidate.role) {
        throw new Error(`Source manifest scope mismatch: binding ${candidate.role}, manifest ${manifest.scope}`);
      }
      const bindingUpdate = normalizeWritePolicy(candidate.access.update, `binding ${candidate.sourceId} access.update`);
      const resolved = {
        sourceId: candidate.sourceId,
        role: candidate.role,
        vaultRef: candidate.vaultRef,
        vaultSelector: vault.selector,
        bridgeUrl: vault.bridgeUrl,
        bridgeTokenEnv: vault.bridgeTokenEnv,
        repositoryRef: candidate.repositoryRef,
        repository,
        vaultHealth,
        repositoryHealth,
        root,
        resolvedRoot,
        publishingMode: settings.wiki.publishing.mode,
        effectiveReadPolicy: candidate.access.read ? 'allow' as const : 'deny' as const,
        effectiveUpdatePolicy: stricterPolicy(bindingUpdate, manifest.updateExisting),
        effectiveCreatePolicy: stricterPolicy(bindingUpdate, manifest.createNote),
        manifest,
      };
      bindings.push({ ...resolved, bindingDigest: bindingDigest(resolved) });
    } catch (error) {
      errors.push(`${candidate.sourceId}: ${error instanceof Error ? error.message : String(error)}`);
    }
  }

  if (bindings.length === 0 && errors.length === 0) errors.push('No Obsidian Wiki bindings were resolved');
  return { projectDir, registryPath, bindings, errors, warnings };
}
