import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import {
  closeSync,
  lstatSync,
  openSync,
  readSync,
  realpathSync,
} from 'node:fs';
import type { ResolvedBinding } from './bindings.js';
import {
  parseAtomicNote,
  parseAtomicNoteMetadata,
  evaluateKnowledgeFreshness,
  type AtomicNote,
  type AtomicNoteMetadata,
} from './note.js';
import { readNote, searchNotes } from './obsidian-cli.js';

export type RetrievedNote = AtomicNote & {
  sourceId: string;
  role: 'project' | 'shared';
  path: string;
  bindingDigest: string;
};

export type BoundNoteScope = {
  sourceId?: string;
  pathPrefix?: string;
};

export type RetrievedNoteMetadata = AtomicNoteMetadata & {
  sourceId: string;
  role: 'project' | 'shared';
  path: string;
  bindingDigest: string;
};

export type BoundSearchCandidate = {
  binding: ResolvedBinding;
  notePath: string;
  sortKey: string;
};

const FRONTMATTER_CHUNK_BYTES = 4096;
const MAX_FRONTMATTER_BYTES = 64 * 1024;
const metadataCache = new Map<string, {
  revision: string;
  notes: RetrievedNoteMetadata[];
}>();

export function normalizeVaultPath(value: string): string {
  if (path.posix.isAbsolute(value)) throw new Error('Obsidian Note path must be Vault-relative');
  const normalized = path.posix.normalize(value.replaceAll('\\', '/'));
  if (normalized === '.' || normalized === '..' || normalized.startsWith('../')) {
    throw new Error('Obsidian Note path escapes its Vault');
  }
  return normalized.replace(/^\.\//, '');
}

export function normalizeSourceRelativePath(value: string): string {
  if (typeof value !== 'string') throw new Error('Obsidian Source pathPrefix must be a string');
  const candidate = value.replaceAll('\\', '/');
  if (path.posix.isAbsolute(candidate) || /^[A-Za-z]:\//.test(candidate)) {
    throw new Error('Obsidian Source pathPrefix must be Source-relative');
  }
  if (candidate.split('/').includes('..')) {
    throw new Error('Obsidian Source pathPrefix escapes its Source');
  }
  const normalized = path.posix.normalize(candidate);
  if (normalized === '.' || normalized === '') return '';
  if (normalized.includes('"')) {
    throw new Error('Obsidian Source pathPrefix cannot contain a quote');
  }
  return normalized.replace(/^\.\//, '').replace(/\/+$/, '');
}

export function noteIsWithinBinding(notePath: string, binding: ResolvedBinding): boolean {
  return notePath === binding.root || notePath.startsWith(`${binding.root}/`);
}

function noteIsWithinPathPrefix(notePath: string, prefix: string): boolean {
  return notePath === prefix || notePath.startsWith(`${prefix}/`);
}

export function sourceRelativePath(notePath: string, binding: ResolvedBinding): string {
  const normalized = assertPathWithinBinding(notePath, binding);
  if (normalized === binding.root) return '';
  return normalized.slice(`${binding.root}/`.length);
}

export function readableBindingsForScope(
  bindings: ResolvedBinding[],
  scope: BoundNoteScope = {},
): ResolvedBinding[] {
  const readable = bindings.filter((binding) => binding.effectiveReadPolicy === 'allow');
  if (scope.pathPrefix !== undefined && scope.sourceId === undefined) {
    throw new Error('Obsidian Source pathPrefix requires sourceId');
  }
  if (scope.sourceId === undefined) return readable;
  const binding = readable.find((candidate) => candidate.sourceId === scope.sourceId);
  if (!binding) {
    throw new Error(`Unknown readable Obsidian Wiki Source: ${scope.sourceId}`);
  }
  return [binding];
}

export function sourcePathPrefix(binding: ResolvedBinding, relativePrefix?: string): string {
  const normalized = relativePrefix === undefined ? '' : normalizeSourceRelativePath(relativePrefix);
  return normalized ? `${binding.root}/${normalized}` : binding.root;
}

export function assertPathWithinBinding(notePath: string, binding: ResolvedBinding): string {
  const normalized = normalizeVaultPath(notePath);
  if (!noteIsWithinBinding(normalized, binding)) {
    throw new Error(`Obsidian Note path is outside bound Source ${binding.sourceId}: ${normalized}`);
  }
  if (normalized === `${binding.root}/_meta` || normalized.startsWith(`${binding.root}/_meta/`)) {
    throw new Error(`Obsidian Note path is metadata and cannot be read: ${normalized}`);
  }
  return normalized;
}

function bindingForPath(notePath: string, bindings: ResolvedBinding[]): ResolvedBinding | undefined {
  return bindings.find((binding) => noteIsWithinBinding(notePath, binding));
}

function retrieved(binding: ResolvedBinding, notePath: string, note: AtomicNote): RetrievedNote {
  return {
    ...note,
    sourceId: binding.sourceId,
    role: binding.role,
    path: notePath,
    bindingDigest: binding.bindingDigest,
  };
}

function retrievedMetadata(
  binding: ResolvedBinding,
  notePath: string,
  note: AtomicNoteMetadata,
): RetrievedNoteMetadata {
  return {
    ...note,
    sourceId: binding.sourceId,
    role: binding.role,
    path: notePath,
    bindingDigest: binding.bindingDigest,
  };
}

function readBoundNoteFromBinding(
  notePath: string,
  binding: ResolvedBinding,
  env: NodeJS.ProcessEnv,
  requireActiveAndVisible = true,
  now: Date = new Date(),
): RetrievedNote {
  const normalizedPath = normalizeVaultPath(notePath);
  if (binding.effectiveReadPolicy !== 'allow') {
    throw new Error(`Obsidian Note is not within a readable bound Source: ${normalizedPath}`);
  }
  assertPathWithinBinding(normalizedPath, binding);
  const result = readNote(binding.vaultSelector, normalizedPath, env);
  const returnedPath = assertPathWithinBinding(result.path, binding);
  if (returnedPath !== normalizedPath) throw new Error(`Obsidian CLI returned a different Note path: ${returnedPath}`);
  const note = retrieved(binding, normalizedPath, parseAtomicNote(result.content, normalizedPath));
  if (requireActiveAndVisible && (note.status !== 'active' || !note.agentVisible)) {
    throw new Error(`Obsidian Note is not active and agent-visible: ${normalizedPath}`);
  }
  const freshness = evaluateKnowledgeFreshness(note, now, `Obsidian Note ${normalizedPath}`);
  if (requireActiveAndVisible && freshness.state === 'expired') {
    throw new Error(`Obsidian Note is expired: ${normalizedPath}`);
  }
  return note;
}

export function readBoundNote(
  notePath: string,
  bindings: ResolvedBinding[],
  env: NodeJS.ProcessEnv,
  requireActiveAndVisible = true,
  now: Date = new Date(),
): RetrievedNote {
  const normalizedPath = normalizeVaultPath(notePath);
  const binding = bindingForPath(normalizedPath, bindings);
  if (!binding) throw new Error(`Obsidian Note is not within a readable bound Source: ${normalizedPath}`);
  return readBoundNoteFromBinding(normalizedPath, binding, env, requireActiveAndVisible, now);
}

type BoundPath = { notePath: string; binding: ResolvedBinding };

function stableBatchRead(notePaths: BoundPath[], env: NodeJS.ProcessEnv, now: Date): RetrievedNote[] {
  const initial = notePaths.map(({ notePath, binding }) => readBoundNoteFromBinding(notePath, binding, env, true, now));
  const reread = notePaths.map(({ notePath, binding }) => readBoundNoteFromBinding(notePath, binding, env, true, now));
  const seenIds = new Set<string>();
  for (let index = 0; index < initial.length; index += 1) {
    const first = initial[index];
    const second = reread[index];
    if (first.path !== second.path || first.wikiId !== second.wikiId || first.contentHash !== second.contentHash) {
      throw new Error(`Obsidian Note changed during stable batch read: ${first.path}`);
    }
    if (seenIds.has(first.wikiId)) throw new Error(`Duplicate wiki_id in readable bound Sources: ${first.wikiId}`);
    seenIds.add(first.wikiId);
  }
  return initial;
}

export function readBoundNotes(
  notePaths: string[],
  bindings: ResolvedBinding[],
  env: NodeJS.ProcessEnv,
  now: Date = new Date(),
): RetrievedNote[] {
  const uniquePaths = [...new Set(notePaths.map(normalizeVaultPath))];
  return stableBatchRead(uniquePaths.map((notePath) => {
    const binding = bindingForPath(notePath, bindings);
    if (!binding) throw new Error(`Obsidian Note is not within a readable bound Source: ${notePath}`);
    return { notePath, binding };
  }), env, now);
}

export function readBoundNotesByWikiIds(
  wikiIds: string[],
  bindings: ResolvedBinding[],
  env: NodeJS.ProcessEnv,
  now: Date = new Date(),
): RetrievedNote[] {
  const uniqueIds = [...new Set(wikiIds)];
  if (uniqueIds.length !== wikiIds.length) throw new Error('Duplicate wiki_id requested for stable batch read');
  const resolved = uniqueIds.map((wikiId) => {
    const matches = searchBoundNotes(`[wiki_id:${wikiId}]`, bindings, env, { now })
      .filter((note) => note.wikiId === wikiId);
    if (matches.length !== 1) throw new Error(`wiki_id ${wikiId} resolved ${matches.length} readable active Notes`);
    return { notePath: matches[0].path, binding: bindings.find((binding) => binding.bindingDigest === matches[0].bindingDigest) };
  });
  if (resolved.some(({ binding }) => !binding)) throw new Error('Obsidian Note resolved without its bound Source');
  return stableBatchRead(resolved as BoundPath[], env, now);
}

export function searchBoundNotes(
  query: string,
  bindings: ResolvedBinding[],
  env: NodeJS.ProcessEnv,
  options: {
    requireActiveAndVisible?: boolean;
    scope?: BoundNoteScope;
    now?: Date;
    includeExpired?: boolean;
  } = {},
): RetrievedNote[] {
  const {
    requireActiveAndVisible = true,
    scope = {},
    now = new Date(),
    includeExpired = false,
  } = options;
  const candidates = searchBoundNoteCandidates(query, bindings, env, scope);
  const notes: RetrievedNote[] = [];
  const seenIds = new Set<string>();
  for (const { binding, notePath } of candidates) {
    const note = readBoundNote(notePath, [binding], env, false, now);
    if (requireActiveAndVisible && (note.status !== 'active' || !note.agentVisible)) continue;
    if (
      requireActiveAndVisible
      && !includeExpired
      && evaluateKnowledgeFreshness(note, now).state === 'expired'
    ) continue;
    if (seenIds.has(note.wikiId)) throw new Error(`Duplicate wiki_id in readable bound Sources: ${note.wikiId}`);
    seenIds.add(note.wikiId);
    notes.push(note);
  }
  return notes;
}

export function searchBoundNoteCandidates(
  query: string,
  bindings: ResolvedBinding[],
  env: NodeJS.ProcessEnv,
  scope: BoundNoteScope = {},
): BoundSearchCandidate[] {
  const readableBindings = readableBindingsForScope(bindings, scope);
  const candidates: BoundSearchCandidate[] = [];
  const seenPaths = new Set<string>();
  for (const binding of readableBindings) {
    const queryPath = sourcePathPrefix(
      binding,
      scope.sourceId === undefined ? undefined : scope.pathPrefix,
    );
    const scopedQuery = `${query} path:"${queryPath}"`;
    for (const entry of searchNotes(binding.vaultSelector, scopedQuery, env)) {
      const notePath = normalizeVaultPath(entry.path);
      const pathKey = `${binding.bindingDigest}\n${notePath}`;
      if (seenPaths.has(pathKey)) continue;
      seenPaths.add(pathKey);
      if (!noteIsWithinBinding(notePath, binding) || !noteIsWithinPathPrefix(notePath, queryPath)) continue;
      if (notePath === `${binding.root}/_meta` || notePath.startsWith(`${binding.root}/_meta/`)) continue;
      candidates.push({
        binding,
        notePath,
        sortKey: JSON.stringify([binding.sourceId, notePath, binding.bindingDigest]),
      });
    }
  }
  return candidates.sort((left, right) => (
    left.sortKey < right.sortKey ? -1 : left.sortKey > right.sortKey ? 1 : 0
  ));
}

export function assertUniqueActiveBoundSearchCandidateIds(
  candidates: BoundSearchCandidate[],
  now: Date = new Date(),
  includeExpired = false,
): void {
  const seenIds = new Set<string>();
  for (const { binding, notePath } of candidates) {
    const absolute = path.resolve(binding.repository.worktreeRoot, ...notePath.split('/'));
    if (!lstatSync(absolute).isFile()) {
      throw new Error(`Obsidian search result is not a regular file: ${notePath}`);
    }
    const resolved = realpathSync(absolute);
    if (!pathWithinRoot(resolved, binding.resolvedRoot)) {
      throw new Error(`Obsidian search result escapes bound Source ${binding.sourceId}: ${notePath}`);
    }
    const note = parseAtomicNoteMetadata(frontmatterOnly(resolved), notePath);
    if (note.status !== 'active' || !note.agentVisible) continue;
    if (
      !includeExpired
      && evaluateKnowledgeFreshness(note, now, `Obsidian Note ${notePath}`).state === 'expired'
    ) continue;
    if (seenIds.has(note.wikiId)) {
      throw new Error(`Duplicate wiki_id in readable bound Sources: ${note.wikiId}`);
    }
    seenIds.add(note.wikiId);
  }
}

function gitOutput(repositoryRoot: string, args: string[]): string {
  return String(execFileSync('git', ['-C', repositoryRoot, ...args], {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
  }));
}

function frontmatterOnly(filePath: string): string {
  const descriptor = openSync(filePath, 'r');
  try {
    const chunks: Buffer[] = [];
    let total = 0;
    while (total < MAX_FRONTMATTER_BYTES) {
      const chunk = Buffer.allocUnsafe(Math.min(FRONTMATTER_CHUNK_BYTES, MAX_FRONTMATTER_BYTES - total));
      const count = readSync(descriptor, chunk, 0, chunk.length, null);
      if (count === 0) break;
      chunks.push(chunk.subarray(0, count));
      total += count;
      const text = Buffer.concat(chunks).toString('utf8').replaceAll('\r\n', '\n');
      const closing = text.indexOf('\n---\n', 4);
      if (closing !== -1) return text.slice(0, closing + 5);
    }
  } finally {
    closeSync(descriptor);
  }
  throw new Error(`${filePath} frontmatter is not terminated within ${MAX_FRONTMATTER_BYTES} bytes`);
}

function pathWithinRoot(filePath: string, root: string): boolean {
  const relative = path.relative(root, filePath);
  return relative === '' || (!path.isAbsolute(relative) && relative !== '..' && !relative.startsWith(`..${path.sep}`));
}

export function boundNoteMetadataRevision(binding: ResolvedBinding): string {
  const repositoryRoot = binding.repository.worktreeRoot;
  const revision = gitOutput(repositoryRoot, ['rev-parse', 'HEAD']).trim();
  const staged = gitOutput(
    repositoryRoot,
    ['diff', '--cached', '--raw', '-z', '--', `:(literal)${binding.root}`],
  );
  const stagedDigest = createHash('sha256').update(staged, 'utf8').digest('hex');
  return `${revision}:index-sha256:${stagedDigest}`;
}

export function boundNoteMetadata(binding: ResolvedBinding): RetrievedNoteMetadata[] {
  if (binding.effectiveReadPolicy !== 'allow') {
    throw new Error(`Obsidian Wiki Source is not readable: ${binding.sourceId}`);
  }
  const key = `${binding.repository.worktreeRoot}\n${binding.bindingDigest}`;
  const revision = boundNoteMetadataRevision(binding);
  const cached = metadataCache.get(key);
  if (cached?.revision === revision) return cached.notes;

  const tracked = gitOutput(
    binding.repository.worktreeRoot,
    ['ls-files', '-z', '--', `:(literal)${binding.root}`],
  ).split('\0').filter(Boolean);
  const notes: RetrievedNoteMetadata[] = [];
  const seenIds = new Set<string>();
  for (const trackedPath of tracked) {
    const notePath = normalizeVaultPath(trackedPath);
    if (!notePath.endsWith('.md')) continue;
    if (!noteIsWithinBinding(notePath, binding)) continue;
    if (notePath === `${binding.root}/_meta` || notePath.startsWith(`${binding.root}/_meta/`)) continue;
    const absolute = path.resolve(binding.repository.worktreeRoot, ...notePath.split('/'));
    if (!lstatSync(absolute).isFile()) {
      throw new Error(`Obsidian catalog entry is not a regular file: ${notePath}`);
    }
    const resolved = realpathSync(absolute);
    if (!pathWithinRoot(resolved, binding.resolvedRoot)) {
      throw new Error(`Obsidian catalog entry escapes bound Source ${binding.sourceId}: ${notePath}`);
    }
    const frontmatter = frontmatterOnly(resolved);
    if (!/^wiki_schema:\s*grill-adapter\.obsidian-note\/v1\s*$/m.test(frontmatter)) continue;
    const note = retrievedMetadata(binding, notePath, parseAtomicNoteMetadata(frontmatter, notePath));
    if (seenIds.has(note.wikiId)) {
      throw new Error(`Duplicate wiki_id in readable bound Source ${binding.sourceId}: ${note.wikiId}`);
    }
    seenIds.add(note.wikiId);
    notes.push(note);
  }
  notes.sort((left, right) => (
    left.path < right.path ? -1 : left.path > right.path ? 1 : 0
  ));
  metadataCache.set(key, { revision, notes });
  return notes;
}

export function assertUniqueBoundSkillCardMetadata(
  note: Pick<RetrievedNoteMetadata, 'skillName' | 'wikiId' | 'path' | 'sourceId'>,
  bindings: ResolvedBinding[],
): void {
  if (!note.skillName) return;
  const matches = readableBindingsForScope(bindings)
    .flatMap((binding) => boundNoteMetadata(binding))
    .filter((candidate) => (
      candidate.status === 'active'
      && candidate.agentVisible
      && candidate.skillName === note.skillName
    ));
  if (
    matches.length !== 1
    || matches[0].wikiId !== note.wikiId
    || matches[0].path !== note.path
    || matches[0].sourceId !== note.sourceId
  ) {
    throw new Error(
      `Skill Card identity ${note.skillName} resolved ${matches.length} active Cards`,
    );
  }
}

export function matchingBoundSkillCards(
  note: Pick<AtomicNote, 'skillName'>,
  bindings: ResolvedBinding[],
  env: NodeJS.ProcessEnv,
  requireActiveAndVisible = true,
): RetrievedNote[] {
  if (!note.skillName) return [];
  return searchBoundNotes(
    `[skill_name:${note.skillName}]`,
    bindings,
    env,
    { requireActiveAndVisible },
  ).filter((candidate) => candidate.skillName === note.skillName);
}

export function matchingBoundAdrProjections(
  note: Pick<AtomicNote, 'adrSourceId'>,
  bindings: ResolvedBinding[],
  env: NodeJS.ProcessEnv,
  requireActiveAndVisible = false,
): RetrievedNote[] {
  if (!note.adrSourceId) return [];
  return searchBoundNotes(
    `[adr_source_id:${note.adrSourceId}]`,
    bindings,
    env,
    { requireActiveAndVisible },
  ).filter((candidate) => candidate.adrSourceId === note.adrSourceId);
}

export function assertUniqueBoundSkillCard(
  note: RetrievedNote,
  bindings: ResolvedBinding[],
  env: NodeJS.ProcessEnv,
): void {
  if (!note.skillName) return;
  const matches = matchingBoundSkillCards(note, bindings, env);
  if (
    matches.length !== 1
    || matches[0].wikiId !== note.wikiId
    || matches[0].path !== note.path
    || matches[0].sourceId !== note.sourceId
  ) {
    throw new Error(
      `Skill Card identity ${note.skillName} resolved ${matches.length} active Cards`,
    );
  }
}
