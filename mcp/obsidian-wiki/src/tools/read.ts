import { createHash } from 'node:crypto';
import { resolveBindings } from '../bindings.js';
import { readBoundNotes, readBoundNotesByWikiIds } from '../retrieval.js';

function snapshotHash(notes: Array<{ sourceId: string; wikiId: string; contentHash: string }>): string {
  const canonical = notes
    .map((note) => `${note.sourceId}\n${note.wikiId}\n${note.contentHash}`)
    .sort()
    .join('\n');
  return `sha256:${createHash('sha256').update(canonical, 'utf8').digest('hex')}`;
}

export function readNotesTool(input: { paths: string[] }, env: NodeJS.ProcessEnv = process.env) {
  const resolution = resolveBindings(env);
  if (resolution.errors.length > 0) {
    throw new Error(`Obsidian Wiki Source bindings are unhealthy: ${resolution.errors.join('; ')}`);
  }
  const notes = readBoundNotes(input.paths, resolution.bindings, env);
  return {
    notes: notes.map((note) => ({
      sourceId: note.sourceId,
      role: note.role,
      path: note.path,
      wikiId: note.wikiId,
      type: note.type,
      status: note.status,
      agentVisible: note.agentVisible,
      summary: note.summary,
      constraintStrength: note.constraintStrength,
      skillRoles: note.skillRoles,
      content: note.content,
      contentHash: note.contentHash,
      bindingDigest: note.bindingDigest,
    })),
    snapshotHash: snapshotHash(notes),
  };
}

export function readNotesByWikiIdsTool(input: { wikiIds: string[] }, env: NodeJS.ProcessEnv = process.env) {
  const resolution = resolveBindings(env);
  if (resolution.errors.length > 0) {
    throw new Error(`Obsidian Wiki Source bindings are unhealthy: ${resolution.errors.join('; ')}`);
  }
  const notes = readBoundNotesByWikiIds(input.wikiIds, resolution.bindings, env);
  return {
    notes: notes.map((note) => ({
      sourceId: note.sourceId,
      role: note.role,
      path: note.path,
      wikiId: note.wikiId,
      type: note.type,
      status: note.status,
      agentVisible: note.agentVisible,
      summary: note.summary,
      constraintStrength: note.constraintStrength,
      skillRoles: note.skillRoles,
      content: note.content,
      contentHash: note.contentHash,
      bindingDigest: note.bindingDigest,
    })),
    snapshotHash: snapshotHash(notes),
  };
}

export function readNoteTool(input: { path: string }, env: NodeJS.ProcessEnv = process.env) {
  const result = readNotesTool({ paths: [input.path] }, env);
  return { note: result.notes[0], snapshotHash: result.snapshotHash };
}
