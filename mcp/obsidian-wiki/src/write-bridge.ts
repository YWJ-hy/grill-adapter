import { timingSafeEqual, randomUUID } from 'node:crypto';
import { createServer, type IncomingMessage, type ServerResponse } from 'node:http';
import {
  existsSync,
  linkSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import path from 'node:path';
import * as z from 'zod/v4';
import { contentHash, parseAtomicNote } from './note.js';
import { assertSkillCardAvailable } from './skill-card.js';
import { parseSourceManifest, type SourceManifest } from './bindings.js';
import { isLoopbackHost } from './loopback.js';
import { normalizeWritePolicy, stricterPolicy, type WritePolicy } from './policy.js';
import { atomicExchange } from './atomic-exchange.js';
import { resolveBridgeConfig } from './config.js';

const HASH = /^sha256:[a-f0-9]{64}$/;
const MAX_REQUEST_BYTES = 2 * 1024 * 1024;

const ChangeSchema = z.object({
  vaultSelector: z.string().min(1),
  projectDir: z.string().min(1),
  sourceId: z.string().min(1),
  vaultRef: z.string().min(1),
  sourceRoot: z.string().min(1),
  operation: z.enum(['create', 'update']),
  path: z.string().min(1),
  content: z.string().min(1),
  expectedHash: z.string().regex(HASH).nullable(),
  expectedWikiId: z.string().min(1),
  authorized: z.boolean(),
});

type ChangeRequest = z.infer<typeof ChangeSchema>;

export type WriteBridgeOptions = {
  vaultRoot: string;
  vaultSelector: string;
  allowedRoots: string[];
  projectDirs: string[];
  token: string;
  host?: string;
  port?: number;
  beforeAtomicExchange?: (targetPath: string) => void;
  afterAtomicExchange?: (targetPath: string) => void;
};

export type WriteBridgeHandle = {
  url: string;
  close: () => Promise<void>;
};

class BridgeError extends Error {
  constructor(readonly status: number, message: string) {
    super(message);
  }
}

function normalizeRelativePath(value: string, description: string): string {
  if (path.posix.isAbsolute(value) || path.win32.isAbsolute(value)) {
    throw new BridgeError(403, `${description} must be Vault-relative`);
  }
  const normalized = path.posix.normalize(value.replaceAll('\\', '/')).replace(/^\.\//, '');
  if (!normalized || normalized === '.' || normalized === '..' || normalized.startsWith('../')) {
    throw new BridgeError(403, `${description} escapes the Vault`);
  }
  return normalized;
}

function inside(candidate: string, root: string): boolean {
  return candidate === root || candidate.startsWith(`${root}${path.sep}`);
}

type ValidatedChange = {
  request: ChangeRequest;
  targetPath: string;
  resolvedSourceRoot: string;
  beforeContent: string | null;
  proposedWikiId: string;
  diff: {
    beforeHash: string | null;
    afterHash: string;
    beforeContent: string | null;
    afterContent: string;
  };
};

function nearestExistingDirectory(directory: string): string {
  let candidate = directory;
  while (!existsSync(candidate)) {
    const parent = path.dirname(candidate);
    if (parent === candidate) throw new BridgeError(403, 'Note parent has no existing Vault ancestor');
    candidate = parent;
  }
  if (!lstatSync(candidate).isDirectory()) throw new BridgeError(400, 'Note parent ancestor is not a directory');
  return realpathSync(candidate);
}

type GovernedRoot = {
  resolvedRoot: string;
  manifestPath: string;
};

const BridgeSettingsSchema = z.object({
  wiki: z.object({
    provider: z.literal('obsidian'),
    obsidian: z.object({
      bindings: z.array(z.object({
        sourceId: z.string().min(1),
        role: z.enum(['project', 'shared']),
        vaultRef: z.string().min(1),
        root: z.string().min(1),
        access: z.object({ read: z.boolean(), update: z.string().optional() }),
      })),
    }),
  }),
});

function atomicNoteFiles(root: GovernedRoot): string[] {
  const files: string[] = [];
  const visit = (directory: string) => {
    for (const entry of readdirSync(directory, { withFileTypes: true })) {
      if (entry.name === '_meta') continue;
      const target = path.join(directory, entry.name);
      if (entry.isSymbolicLink()) throw new BridgeError(403, `Symbolic links are not allowed in writable Source content: ${target}`);
      if (entry.isDirectory()) visit(target);
      else if (entry.isFile() && entry.name.endsWith('.md')) files.push(target);
    }
  };
  visit(root.resolvedRoot);
  return files;
}

function validateTypedLinksAndIdentity(
  proposed: ReturnType<typeof parseAtomicNote>,
  operation: 'create' | 'update',
  targetPath: string,
  vaultRoot: string,
  roots: Map<string, GovernedRoot>,
  projectRoots: Map<string, GovernedRoot>,
  targetScope: 'project' | 'shared',
): void {
  const noteFiles = [...roots.values()].flatMap(atomicNoteFiles);
  const existingNotes = noteFiles.map((file) => ({
    file,
    note: parseAtomicNote(readFileSync(file, 'utf8'), file),
  }));
  const identityMatches = existingNotes.filter(({ note }) => note.wikiId === proposed.wikiId);
  if (proposed.adrSourceId && targetScope !== 'project') {
    throw new BridgeError(403, 'ADR execution projections may only be written to a project Source');
  }
  const adrProjectionMatches = proposed.adrSourceId
    ? existingNotes.filter(({ note }) => note.adrSourceId === proposed.adrSourceId)
    : [];
  if (operation === 'create' && identityMatches.length > 0) {
    throw new BridgeError(409, `Proposed wiki_id already exists in an allowed Source: ${proposed.wikiId}`);
  }
  if (operation === 'create' && adrProjectionMatches.length > 0) {
    throw new BridgeError(
      409,
      `ADR source identity ${proposed.adrSourceId} already exists in an allowed Note; update that projection`,
    );
  }
  if (operation === 'update' && (
    identityMatches.length !== 1
    || realpathSync(identityMatches[0].file) !== realpathSync(targetPath)
  )) {
    throw new BridgeError(409, `Updated wiki_id does not resolve uniquely to its existing Note: ${proposed.wikiId}`);
  }
  const targetNote = operation === 'update' ? identityMatches[0].note : undefined;
  if (targetNote?.adrSourceId && !proposed.adrSourceId) {
    throw new BridgeError(409, 'An existing ADR execution projection cannot be converted to a plain Note');
  }
  if (targetNote?.adrSourceId && targetNote.adrSourceId !== proposed.adrSourceId) {
    throw new BridgeError(409, 'ADR source identity must be preserved on update');
  }
  if (
    operation === 'update'
    && adrProjectionMatches.some(({ file }) => realpathSync(file) !== realpathSync(targetPath))
  ) {
    throw new BridgeError(
      409,
      `ADR source identity ${proposed.adrSourceId} already exists in another allowed Note`,
    );
  }
  if (targetNote?.skillProvider && !proposed.skillProvider) {
    throw new BridgeError(409, 'An existing Skill Card cannot be converted to a plain Note');
  }
  if (
    targetNote?.skillProvider
    && (
      targetNote.skillProvider !== proposed.skillProvider
      || targetNote.skillName !== proposed.skillName
    )
  ) {
    throw new BridgeError(409, 'Skill Card provider/name identity must be preserved on update');
  }
  if (proposed.skillProvider) {
    const projectNotes = [...projectRoots.values()]
      .flatMap(atomicNoteFiles)
      .map((file) => ({ file, note: parseAtomicNote(readFileSync(file, 'utf8'), file) }));
    const cardMatches = projectNotes.filter(({ note }) => (
      note.skillProvider === proposed.skillProvider && note.skillName === proposed.skillName
    ));
    const conflictingCards = operation === 'create'
      ? cardMatches
      : cardMatches.filter(({ file }) => realpathSync(file) !== realpathSync(targetPath));
    if (conflictingCards.length > 0) {
      throw new BridgeError(
        409,
        `Skill Card identity ${proposed.skillProvider}/${proposed.skillName} already exists in an allowed Source`,
      );
    }
  }
  for (const links of Object.values(proposed.edges)) {
    for (const link of links) {
      const target = /^\[\[([^#|\]]+)/.exec(link)?.[1]?.trim();
      if (!target) throw new BridgeError(400, `Typed edge must use an Obsidian link: ${link}`);
      const vaultPath = normalizeRelativePath(target.endsWith('.md') ? target : `${target}.md`, 'Typed edge');
      const resolvedTarget = path.resolve(vaultRoot, ...vaultPath.split('/'));
      const owningRoot = [...roots.values()].find((root) => inside(resolvedTarget, root.resolvedRoot));
      if (!owningRoot || !existsSync(resolvedTarget) || !lstatSync(resolvedTarget).isFile()) {
        throw new BridgeError(400, `Typed edge does not resolve to an allowed atomic Note: ${link}`);
      }
      parseAtomicNote(readFileSync(resolvedTarget, 'utf8'), vaultPath);
    }
  }
}

function enforceGovernance(
  change: ValidatedChange,
  root: GovernedRoot,
  apply: boolean,
  vaultRoot: string,
  roots: Map<string, GovernedRoot>,
  allowedProjects: Set<string>,
): void {
  const { request } = change;
  let projectDir: string;
  try {
    projectDir = realpathSync(request.projectDir);
  } catch {
    throw new BridgeError(403, 'Project is not allowed by this bridge');
  }
  if (!allowedProjects.has(projectDir)) throw new BridgeError(403, 'Project is not allowed by this bridge');
  const settingsPath = path.join(projectDir, '.shared-adapter', 'settings.json');
  let settings: z.infer<typeof BridgeSettingsSchema>;
  try {
    settings = BridgeSettingsSchema.parse(JSON.parse(readFileSync(settingsPath, 'utf8')));
  } catch (error) {
    throw new BridgeError(403, `Project binding cannot be validated: ${error instanceof Error ? error.message : String(error)}`);
  }
  const binding = settings.wiki.obsidian.bindings.find((candidate) => (
    candidate.sourceId === request.sourceId
    && candidate.vaultRef === request.vaultRef
    && path.posix.normalize(candidate.root.replaceAll('\\', '/')).replace(/^\.\//, '') === request.sourceRoot
  ));
  if (!binding || !binding.access.read) throw new BridgeError(403, 'Source is not a readable binding of the allowed project');
  const projectRootNames = new Set(
    settings.wiki.obsidian.bindings
      .filter((candidate) => candidate.access.read)
      .map((candidate) => path.posix.normalize(candidate.root.replaceAll('\\', '/')).replace(/^\.\//, '')),
  );
  const projectRoots = new Map(
    [...roots].filter(([rootName]) => projectRootNames.has(rootName)),
  );
  let manifest: SourceManifest;
  try {
    manifest = parseSourceManifest(readFileSync(root.manifestPath, 'utf8'), root.manifestPath);
  } catch (error) {
    throw new BridgeError(403, `Source manifest cannot be validated: ${error instanceof Error ? error.message : String(error)}`);
  }
  if (manifest.sourceId !== request.sourceId || manifest.scope !== binding.role) {
    throw new BridgeError(403, 'Source identity does not match the current project binding and manifest');
  }
  let bindingPolicy: WritePolicy;
  try {
    bindingPolicy = normalizeWritePolicy(binding.access.update, `binding ${request.sourceId} access.update`);
  } catch (error) {
    throw new BridgeError(403, `Project binding policy cannot be validated: ${error instanceof Error ? error.message : String(error)}`);
  }
  const manifestPolicy: WritePolicy = request.operation === 'create' ? manifest.createNote : manifest.updateExisting;
  const policy = stricterPolicy(bindingPolicy, manifestPolicy);
  if (policy === 'deny') throw new BridgeError(403, `Effective Source policy denies ${request.operation} operations`);
  if (apply && policy === 'confirm' && !request.authorized) throw new BridgeError(403, `Effective Source policy requires explicit authorization for ${request.operation}`);
  if (manifest.scope === 'shared') {
    const candidate = `${request.path}\n${request.content}`;
    const blockedTerm = manifest.blockedTerms.find((term) => term && candidate.includes(term));
    if (blockedTerm) throw new BridgeError(403, `Shared Source neutrality validation failed for blocked term ${JSON.stringify(blockedTerm)}`);
    for (const pattern of manifest.blockedPatterns) {
      try {
        if (pattern && new RegExp(pattern).test(candidate)) {
          throw new BridgeError(403, `Shared Source neutrality validation failed for blocked pattern ${JSON.stringify(pattern)}`);
        }
      } catch (error) {
        if (error instanceof BridgeError) throw error;
        throw new BridgeError(400, `Source manifest has invalid blocked pattern ${JSON.stringify(pattern)}: ${error instanceof Error ? error.message : String(error)}`);
      }
    }
  }
  const proposed = parseAtomicNote(request.content, request.path);
  try {
    assertSkillCardAvailable(proposed, projectDir, { mode: 'write' });
  } catch (error) {
    throw new BridgeError(
      403,
      error instanceof Error ? error.message : String(error),
    );
  }
  validateTypedLinksAndIdentity(
    proposed,
    request.operation,
    change.targetPath,
    vaultRoot,
    roots,
    projectRoots,
    manifest.scope,
  );
}

function validateChange(
  raw: unknown,
  options: WriteBridgeOptions,
  vaultRoot: string,
  allowedRoots: Map<string, GovernedRoot>,
): ValidatedChange {
  const parsed = ChangeSchema.safeParse(raw);
  if (!parsed.success) throw new BridgeError(400, `Invalid Note change: ${parsed.error.issues.map((issue) => issue.message).join('; ')}`);
  const request = parsed.data;
  if (request.vaultSelector !== options.vaultSelector) throw new BridgeError(403, 'Vault selector is not allowed by this bridge');

  const sourceRoot = normalizeRelativePath(request.sourceRoot, 'Source root');
  const governedRoot = allowedRoots.get(sourceRoot);
  if (!governedRoot) throw new BridgeError(403, `Source root is not allowed by this bridge: ${sourceRoot}`);
  const resolvedSourceRoot = governedRoot.resolvedRoot;
  const notePath = normalizeRelativePath(request.path, 'Note path');
  if (notePath !== sourceRoot && !notePath.startsWith(`${sourceRoot}/`)) {
    throw new BridgeError(403, `Note path is outside the allowed Source root: ${notePath}`);
  }
  const relativeToSource = notePath.slice(sourceRoot.length).replace(/^\//, '');
  if (!relativeToSource || relativeToSource === '_meta' || relativeToSource.startsWith('_meta/')) {
    throw new BridgeError(403, `Note path is metadata and cannot be written: ${notePath}`);
  }
  if (!notePath.endsWith('.md')) throw new BridgeError(400, 'Atomic Note path must end in .md');

  const targetPath = path.resolve(vaultRoot, ...notePath.split('/'));
  if (!inside(targetPath, resolvedSourceRoot)) throw new BridgeError(403, `Note path escapes its Source root: ${notePath}`);
  const parent = path.dirname(targetPath);
  const resolvedParent = nearestExistingDirectory(parent);
  if (!inside(resolvedParent, resolvedSourceRoot)) throw new BridgeError(403, `Note parent escapes its Source root: ${notePath}`);

  const proposed = parseAtomicNote(request.content, notePath);
  if (proposed.wikiId !== request.expectedWikiId) throw new BridgeError(409, 'Proposed Note wiki_id does not match expectedWikiId');
  const exists = existsSync(targetPath);
  let beforeContent: string | null = null;
  if (request.operation === 'create') {
    if (request.expectedHash !== null) throw new BridgeError(400, 'Create requires expectedHash: null');
    if (exists) throw new BridgeError(409, `Cannot create an existing Note: ${notePath}`);
  } else {
    if (!request.expectedHash) throw new BridgeError(400, 'Update requires expectedHash');
    if (!exists || !lstatSync(targetPath).isFile()) throw new BridgeError(409, `Cannot update a missing Note: ${notePath}`);
    const resolvedTarget = realpathSync(targetPath);
    if (!inside(resolvedTarget, resolvedSourceRoot)) throw new BridgeError(403, `Note path escapes its Source root: ${notePath}`);
    beforeContent = readFileSync(resolvedTarget, 'utf8');
    const existing = parseAtomicNote(beforeContent, notePath);
    if (existing.wikiId !== request.expectedWikiId || existing.wikiId !== proposed.wikiId) {
      throw new BridgeError(409, 'Existing and proposed Note wiki_id must preserve identity');
    }
    if (contentHash(beforeContent) !== request.expectedHash) throw new BridgeError(409, 'Expected hash conflict: Note changed concurrently');
  }

  return {
    request: { ...request, sourceRoot, path: notePath },
    targetPath,
    resolvedSourceRoot,
    beforeContent,
    proposedWikiId: proposed.wikiId,
    diff: {
      beforeHash: beforeContent === null ? null : contentHash(beforeContent),
      afterHash: proposed.contentHash,
      beforeContent,
      afterContent: proposed.content,
    },
  };
}

function authenticate(request: IncomingMessage, token: string): void {
  const supplied = request.headers.authorization;
  if (!supplied?.startsWith('Bearer ')) throw new BridgeError(401, 'Write bridge authentication failed');
  const actual = Buffer.from(supplied.slice('Bearer '.length), 'utf8');
  const expected = Buffer.from(token, 'utf8');
  if (actual.length !== expected.length || !timingSafeEqual(actual, expected)) {
    throw new BridgeError(401, 'Write bridge authentication failed');
  }
}

async function readJson(request: IncomingMessage): Promise<unknown> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of request) {
    const value = Buffer.from(chunk);
    size += value.length;
    if (size > MAX_REQUEST_BYTES) throw new BridgeError(413, 'Write bridge request is too large');
    chunks.push(value);
  }
  try {
    return JSON.parse(Buffer.concat(chunks).toString('utf8'));
  } catch (error) {
    throw new BridgeError(400, `Write bridge request must be JSON: ${error instanceof Error ? error.message : String(error)}`);
  }
}

function respond(response: ServerResponse, status: number, body: unknown): void {
  response.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' });
  response.end(JSON.stringify(body));
}

function applyValidated(
  change: ValidatedChange,
  beforeAtomicExchange?: (targetPath: string) => void,
  afterAtomicExchange?: (targetPath: string) => void,
): { wikiId: string; path: string; contentHash: string } {
  if (change.request.operation === 'create') {
    mkdirSync(path.dirname(change.targetPath), { recursive: true, mode: 0o700 });
    if (!inside(realpathSync(path.dirname(change.targetPath)), change.resolvedSourceRoot)) {
      throw new BridgeError(403, 'Created Note parent escaped its Source root');
    }
  }
  const temporaryPath = path.join(path.dirname(change.targetPath), `.${path.basename(change.targetPath)}.${randomUUID()}.tmp`);
  const lockPath = `${change.targetPath}.grill-adapter-write.lock`;
  let ownsLock = false;
  try {
    try {
      writeFileSync(lockPath, `${process.pid}\n`, { encoding: 'utf8', flag: 'wx', mode: 0o600 });
      ownsLock = true;
    } catch (error) {
      throw new BridgeError(409, `Note has another active bridge write: ${error instanceof Error ? error.message : String(error)}`);
    }
    writeFileSync(temporaryPath, change.diff.afterContent, { encoding: 'utf8', flag: 'wx', mode: 0o600 });
    // The final expected-state check happens after all preparation, immediately before replacement.
    if (change.request.operation === 'create') {
      try {
        linkSync(temporaryPath, change.targetPath);
      } catch (error) {
        throw new BridgeError(409, `Expected hash conflict: Note was created concurrently: ${error instanceof Error ? error.message : String(error)}`);
      }
    } else {
      if (!existsSync(change.targetPath) || contentHash(readFileSync(change.targetPath, 'utf8')) !== change.request.expectedHash) {
        throw new BridgeError(409, 'Expected hash conflict: Note changed concurrently');
      }
      beforeAtomicExchange?.(change.targetPath);
      atomicExchange(change.targetPath, temporaryPath);
      afterAtomicExchange?.(change.targetPath);
      const swappedOutHash = contentHash(readFileSync(temporaryPath, 'utf8'));
      const writtenHash = contentHash(readFileSync(change.targetPath, 'utf8'));
      if (swappedOutHash !== change.request.expectedHash || writtenHash !== change.diff.afterHash) {
        let expectedTargetHash = change.diff.afterHash;
        while (contentHash(readFileSync(change.targetPath, 'utf8')) === expectedTargetHash) {
          atomicExchange(change.targetPath, temporaryPath);
          const displacedHash = contentHash(readFileSync(temporaryPath, 'utf8'));
          if (displacedHash === expectedTargetHash) break;
          expectedTargetHash = contentHash(readFileSync(change.targetPath, 'utf8'));
        }
        throw new BridgeError(409, 'Expected hash conflict: Note changed during atomic exchange');
      }
    }
  } finally {
    rmSync(temporaryPath, { force: true });
    if (ownsLock) rmSync(lockPath, { force: true });
  }
  const written = readFileSync(change.targetPath, 'utf8');
  const note = parseAtomicNote(written, change.request.path);
  if (note.wikiId !== change.proposedWikiId || note.contentHash !== change.diff.afterHash) {
    throw new BridgeError(500, 'Post-write Note identity verification failed');
  }
  return { wikiId: note.wikiId, path: change.request.path, contentHash: note.contentHash };
}

export async function startWriteBridge(options: WriteBridgeOptions): Promise<WriteBridgeHandle> {
  const host = options.host ?? '127.0.0.1';
  if (!isLoopbackHost(host)) throw new Error('Obsidian Wiki write bridge must bind to a loopback host');
  if (!options.token) throw new Error('Obsidian Wiki write bridge token must not be empty');
  if (!path.isAbsolute(options.vaultRoot)) throw new Error('Obsidian Wiki write bridge Vault root must be absolute');
  const vaultRoot = realpathSync(options.vaultRoot);
  const allowedProjects = new Set(options.projectDirs.map((projectDir) => {
    if (!path.isAbsolute(projectDir)) throw new Error('Obsidian Wiki write bridge project directories must be absolute');
    return realpathSync(projectDir);
  }));
  if (allowedProjects.size === 0) throw new Error('Obsidian Wiki write bridge requires at least one allowed project directory');
  const allowedRoots = new Map<string, GovernedRoot>();
  for (const rawRoot of options.allowedRoots) {
    const root = normalizeRelativePath(rawRoot, 'Allowed Source root');
    const resolved = realpathSync(path.resolve(vaultRoot, ...root.split('/')));
    if (!inside(resolved, vaultRoot)) throw new Error(`Allowed Source root escapes the Vault: ${root}`);
    const manifestPath = path.join(resolved, '_meta', 'wiki-source.md');
    if (!existsSync(manifestPath) || !lstatSync(manifestPath).isFile()) throw new Error(`Allowed Source root has no manifest: ${root}`);
    parseSourceManifest(readFileSync(manifestPath, 'utf8'), manifestPath);
    allowedRoots.set(root, { resolvedRoot: resolved, manifestPath });
  }
  if (allowedRoots.size === 0) throw new Error('Obsidian Wiki write bridge requires at least one allowed Source root');

  const server = createServer(async (request, response) => {
    try {
      if (request.method === 'GET' && request.url === '/health') {
        respond(response, 200, { ok: true, service: 'obsidian-wiki-write-bridge' });
        return;
      }
      if (request.method !== 'POST') throw new BridgeError(405, 'Write bridge accepts POST requests only');
      const route = request.url;
      if (route !== '/v1/notes/validate' && route !== '/v1/notes/apply') throw new BridgeError(404, 'Unknown write bridge route');
      authenticate(request, options.token);
      const change = validateChange(await readJson(request), options, vaultRoot, allowedRoots);
      enforceGovernance(change, allowedRoots.get(change.request.sourceRoot)!, route.endsWith('/apply'), vaultRoot, allowedRoots, allowedProjects);
      const base = { ok: true, operation: change.request.operation, sourceRoot: change.request.sourceRoot, path: change.request.path, diff: change.diff };
      respond(response, 200, route.endsWith('/apply')
        ? { ...base, postWrite: applyValidated(change, options.beforeAtomicExchange, options.afterAtomicExchange) }
        : base);
    } catch (error) {
      const status = error instanceof BridgeError ? error.status : 500;
      respond(response, status, { ok: false, error: error instanceof Error ? error.message : String(error) });
    }
  });

  await new Promise<void>((resolve, reject) => {
    server.once('error', reject);
    server.listen(options.port ?? 0, host, () => resolve());
  });
  const address = server.address();
  if (!address || typeof address === 'string') throw new Error('Write bridge did not expose a TCP address');
  const displayHost = host.includes(':') ? `[${host}]` : host;
  return {
    url: `http://${displayHost}:${address.port}`,
    close: () => new Promise<void>((resolve, reject) => server.close((error) => error ? reject(error) : resolve())),
  };
}

export async function runWriteBridgeFromEnvironment(env: NodeJS.ProcessEnv = process.env): Promise<void> {
  let configured: ReturnType<typeof resolveBridgeConfig> | undefined;
  const hasLegacyBridgeEnvironment = Boolean(
    env.OBSIDIAN_WIKI_BRIDGE_VAULT_ROOT
      && env.OBSIDIAN_WIKI_BRIDGE_VAULT_SELECTOR
      && env.OBSIDIAN_WIKI_BRIDGE_ALLOWED_ROOTS
      && env.OBSIDIAN_WIKI_BRIDGE_PROJECT_DIRS,
  );
  if (!hasLegacyBridgeEnvironment) {
    configured = resolveBridgeConfig(env, undefined, env.OBSIDIAN_WIKI_BRIDGE_VAULT_REF);
  }
  const tokenEnv = env.OBSIDIAN_WIKI_BRIDGE_TOKEN_ENV
    ?? configured?.config.tokenEnv
    ?? 'OBSIDIAN_WIKI_BRIDGE_TOKEN';
  const token = env[tokenEnv];
  const vaultRoot = env.OBSIDIAN_WIKI_BRIDGE_VAULT_ROOT ?? configured?.config.vaultRoot;
  const vaultSelector = env.OBSIDIAN_WIKI_BRIDGE_VAULT_SELECTOR ?? configured?.config.selector;
  const rootsRaw = env.OBSIDIAN_WIKI_BRIDGE_ALLOWED_ROOTS;
  const projectsRaw = env.OBSIDIAN_WIKI_BRIDGE_PROJECT_DIRS;
  const roots = rootsRaw ? JSON.parse(rootsRaw) : configured?.config.allowedRoots;
  const projects = projectsRaw ? JSON.parse(projectsRaw) : configured?.config.projectDirs;
  if (!vaultRoot || !vaultSelector || !roots || !projects || !token) {
    throw new Error('Write bridge requires a unified Obsidian Wiki config or OBSIDIAN_WIKI_BRIDGE_VAULT_ROOT, OBSIDIAN_WIKI_BRIDGE_VAULT_SELECTOR, OBSIDIAN_WIKI_BRIDGE_ALLOWED_ROOTS, OBSIDIAN_WIKI_BRIDGE_PROJECT_DIRS, and its token environment variable');
  }
  if (!Array.isArray(roots) || roots.some((value) => typeof value !== 'string')) {
    throw new Error('Obsidian Wiki bridge allowedRoots must be an array of strings');
  }
  if (!Array.isArray(projects) || projects.some((value) => typeof value !== 'string')) {
    throw new Error('Obsidian Wiki bridge projectDirs must be an array of strings');
  }
  const bridge = await startWriteBridge({
    vaultRoot,
    vaultSelector,
    allowedRoots: roots,
    projectDirs: projects,
    token,
    host: env.OBSIDIAN_WIKI_BRIDGE_HOST ?? configured?.config.host ?? '127.0.0.1',
    port: Number(env.OBSIDIAN_WIKI_BRIDGE_PORT ?? configured?.config.port ?? '27124'),
  });
  process.stdout.write(`${JSON.stringify({ url: bridge.url, vaultSelector, allowedRoots: roots, registryPath: configured?.registryPath })}\n`);
  await new Promise<void>((resolve) => {
    process.once('SIGINT', resolve);
    process.once('SIGTERM', resolve);
  });
  await bridge.close();
}
