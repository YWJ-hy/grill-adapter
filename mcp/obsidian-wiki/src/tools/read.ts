import { createHash } from 'node:crypto';
import { resolveBindings, type ResolvedBinding } from '../bindings.js';
import {
  assertUniqueBoundSkillCard,
  readBoundNotes,
  readBoundNotesByWikiIds,
  type RetrievedNote,
} from '../retrieval.js';
import { assertSkillCardAvailable } from '../skill-card.js';

function snapshotHash(notes: Array<{ sourceId: string; wikiId: string; contentHash: string }>): string {
  const canonical = notes
    .map((note) => `${note.sourceId}\n${note.wikiId}\n${note.contentHash}`)
    .sort()
    .join('\n');
  return `sha256:${createHash('sha256').update(canonical, 'utf8').digest('hex')}`;
}

function checkedNotes<T extends RetrievedNote>(
  notes: T[],
  projectDir: string,
  bindings: ResolvedBinding[],
  env: NodeJS.ProcessEnv,
): T[] {
  for (const note of notes) {
    const binding = bindings.find((candidate) => candidate.bindingDigest === note.bindingDigest);
    assertSkillCardAvailable(note, projectDir, {
      mode: 'discovery',
      baseSynchronized: binding?.repositoryHealth.baseSynchronized === true,
    });
    assertUniqueBoundSkillCard(note, bindings, env);
  }
  return notes;
}

function serializedNote(note: ReturnType<typeof readBoundNotes>[number]) {
  return {
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
    skillProvider: note.skillProvider,
    skillName: note.skillName,
    skillVersion: note.skillVersion,
    skillContractHash: note.skillContractHash,
    skillTriggers: note.skillTriggers,
    discoveryState: note.skillProvider ? 'discoverable' : undefined,
    content: note.content,
    contentHash: note.contentHash,
    bindingDigest: note.bindingDigest,
  };
}

export function readNotesTool(input: { paths: string[] }, env: NodeJS.ProcessEnv = process.env) {
  const resolution = resolveBindings(env);
  if (resolution.errors.length > 0) {
    throw new Error(`Obsidian Wiki Source bindings are unhealthy: ${resolution.errors.join('; ')}`);
  }
  const notes = checkedNotes(
    readBoundNotes(input.paths, resolution.bindings, env),
    resolution.projectDir,
    resolution.bindings,
    env,
  );
  return {
    notes: notes.map(serializedNote),
    snapshotHash: snapshotHash(notes),
  };
}

export function readNotesByWikiIdsTool(input: { wikiIds: string[] }, env: NodeJS.ProcessEnv = process.env) {
  const resolution = resolveBindings(env);
  if (resolution.errors.length > 0) {
    throw new Error(`Obsidian Wiki Source bindings are unhealthy: ${resolution.errors.join('; ')}`);
  }
  const notes = checkedNotes(
    readBoundNotesByWikiIds(input.wikiIds, resolution.bindings, env),
    resolution.projectDir,
    resolution.bindings,
    env,
  );
  return {
    notes: notes.map(serializedNote),
    snapshotHash: snapshotHash(notes),
  };
}

export function readNoteTool(input: { path: string }, env: NodeJS.ProcessEnv = process.env) {
  const result = readNotesTool({ paths: [input.path] }, env);
  return { note: result.notes[0], snapshotHash: result.snapshotHash };
}
