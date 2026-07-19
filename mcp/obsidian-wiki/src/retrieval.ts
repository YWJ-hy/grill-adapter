import path from 'node:path';
import type { ResolvedBinding } from './bindings.js';
import { parseAtomicNote, type AtomicNote } from './note.js';
import { readNote, searchNotes } from './obsidian-cli.js';

export type RetrievedNote = AtomicNote & {
  sourceId: string;
  role: 'project' | 'shared';
  path: string;
  bindingDigest: string;
};

function normalizeVaultPath(value: string): string {
  if (path.posix.isAbsolute(value)) throw new Error('Obsidian Note path must be Vault-relative');
  const normalized = path.posix.normalize(value.replaceAll('\\', '/'));
  if (normalized === '.' || normalized === '..' || normalized.startsWith('../')) {
    throw new Error('Obsidian Note path escapes its Vault');
  }
  return normalized.replace(/^\.\//, '');
}

function noteIsWithinBinding(notePath: string, binding: ResolvedBinding): boolean {
  return notePath === binding.root || notePath.startsWith(`${binding.root}/`);
}

function assertPathWithinBinding(notePath: string, binding: ResolvedBinding): string {
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

function readBoundNoteFromBinding(notePath: string, binding: ResolvedBinding, env: NodeJS.ProcessEnv, requireActiveAndVisible = true): RetrievedNote {
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
  return note;
}

export function readBoundNote(notePath: string, bindings: ResolvedBinding[], env: NodeJS.ProcessEnv, requireActiveAndVisible = true): RetrievedNote {
  const normalizedPath = normalizeVaultPath(notePath);
  const binding = bindingForPath(normalizedPath, bindings);
  if (!binding) throw new Error(`Obsidian Note is not within a readable bound Source: ${normalizedPath}`);
  return readBoundNoteFromBinding(normalizedPath, binding, env, requireActiveAndVisible);
}

type BoundPath = { notePath: string; binding: ResolvedBinding };

function stableBatchRead(notePaths: BoundPath[], env: NodeJS.ProcessEnv): RetrievedNote[] {
  const initial = notePaths.map(({ notePath, binding }) => readBoundNoteFromBinding(notePath, binding, env));
  const reread = notePaths.map(({ notePath, binding }) => readBoundNoteFromBinding(notePath, binding, env));
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

export function readBoundNotes(notePaths: string[], bindings: ResolvedBinding[], env: NodeJS.ProcessEnv): RetrievedNote[] {
  const uniquePaths = [...new Set(notePaths.map(normalizeVaultPath))];
  return stableBatchRead(uniquePaths.map((notePath) => {
    const binding = bindingForPath(notePath, bindings);
    if (!binding) throw new Error(`Obsidian Note is not within a readable bound Source: ${notePath}`);
    return { notePath, binding };
  }), env);
}

export function readBoundNotesByWikiIds(wikiIds: string[], bindings: ResolvedBinding[], env: NodeJS.ProcessEnv): RetrievedNote[] {
  const uniqueIds = [...new Set(wikiIds)];
  if (uniqueIds.length !== wikiIds.length) throw new Error('Duplicate wiki_id requested for stable batch read');
  const resolved = uniqueIds.map((wikiId) => {
    const matches = searchBoundNotes(`[wiki_id:${wikiId}]`, bindings, env).filter((note) => note.wikiId === wikiId);
    if (matches.length !== 1) throw new Error(`wiki_id ${wikiId} resolved ${matches.length} readable active Notes`);
    return { notePath: matches[0].path, binding: bindings.find((binding) => binding.bindingDigest === matches[0].bindingDigest) };
  });
  if (resolved.some(({ binding }) => !binding)) throw new Error('Obsidian Note resolved without its bound Source');
  return stableBatchRead(resolved as BoundPath[], env);
}

export function searchBoundNotes(query: string, bindings: ResolvedBinding[], env: NodeJS.ProcessEnv): RetrievedNote[] {
  const readableBindings = bindings.filter((binding) => binding.effectiveReadPolicy === 'allow');
  const notes: RetrievedNote[] = [];
  const seenPaths = new Set<string>();
  const seenIds = new Set<string>();
  for (const binding of readableBindings) {
    const scopedQuery = `${query} path:"${binding.root}"`;
    for (const entry of searchNotes(binding.vaultSelector, scopedQuery, env)) {
      const notePath = normalizeVaultPath(entry.path);
      const pathKey = `${binding.bindingDigest}\n${notePath}`;
      if (seenPaths.has(pathKey)) continue;
      seenPaths.add(pathKey);
      if (!noteIsWithinBinding(notePath, binding)) continue;
      if (notePath === `${binding.root}/_meta` || notePath.startsWith(`${binding.root}/_meta/`)) continue;
      const note = readBoundNote(notePath, [binding], env, false);
      if (note.status !== 'active' || !note.agentVisible) continue;
      if (seenIds.has(note.wikiId)) throw new Error(`Duplicate wiki_id in readable bound Sources: ${note.wikiId}`);
      seenIds.add(note.wikiId);
      notes.push(note);
    }
  }
  return notes;
}
