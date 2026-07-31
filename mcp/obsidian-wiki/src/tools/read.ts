import { createHash } from 'node:crypto';
import { resolveBindings, type ResolvedBinding } from '../bindings.js';
import {
  assertUniqueBoundSkillCard,
  readBoundNotes,
  readBoundNotesByWikiIds,
  type RetrievedNote,
} from '../retrieval.js';
import { assertSkillCardAvailable } from '../skill-card.js';
import { evaluateKnowledgeFreshness } from '../note.js';

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

function serializedNote(note: ReturnType<typeof readBoundNotes>[number], now: Date) {
  const freshness = evaluateKnowledgeFreshness(note, now);
  return {
    sourceId: note.sourceId,
    role: note.role,
    path: note.path,
    wikiId: note.wikiId,
    type: note.type,
    status: note.status,
    agentVisible: note.agentVisible,
    summary: note.summary,
    verifiedAt: note.verifiedAt,
    reviewAfter: note.reviewAfter,
    expiresAt: note.expiresAt,
    freshnessState: freshness.state,
    maintenanceWarning: freshness.warning,
    constraintStrength: note.constraintStrength,
    skillRoles: note.skillRoles,
    skillName: note.skillName,
    skillVersion: note.skillVersion,
    skillContractHash: note.skillContractHash,
    skillTriggers: note.skillTriggers,
    adrSourceId: note.adrSourceId,
    adrSourcePath: note.adrSourcePath,
    adrSourceContentHash: note.adrSourceContentHash,
    discoveryState: note.skillName ? 'discoverable' : undefined,
    content: note.content,
    contentHash: note.contentHash,
    bindingDigest: note.bindingDigest,
  };
}

function batchReadResult(
  read: (bindings: ResolvedBinding[]) => RetrievedNote[],
  env: NodeJS.ProcessEnv = process.env,
  now: Date = new Date(),
) {
  const resolution = resolveBindings(env);
  if (resolution.errors.length > 0) {
    throw new Error(`Obsidian Wiki Source bindings are unhealthy: ${resolution.errors.join('; ')}`);
  }
  const notes = checkedNotes(
    read(resolution.bindings),
    resolution.projectDir,
    resolution.bindings,
    env,
  );
  const serialized = notes.map((note) => serializedNote(note, now));
  const maintenanceWarnings = serialized
    .map((note) => note.maintenanceWarning)
    .filter((warning): warning is string => warning !== undefined);
  return {
    notes: serialized,
    snapshotHash: snapshotHash(notes),
    ...(maintenanceWarnings.length > 0 ? { maintenanceWarnings } : {}),
  };
}

export function readNotesTool(
  input: { paths: string[] },
  env: NodeJS.ProcessEnv = process.env,
  now: Date = new Date(),
) {
  return batchReadResult(
    (bindings) => readBoundNotes(input.paths, bindings, env, now),
    env,
    now,
  );
}

export function readNotesByWikiIdsTool(
  input: { wikiIds: string[] },
  env: NodeJS.ProcessEnv = process.env,
  now: Date = new Date(),
) {
  return batchReadResult(
    (bindings) => readBoundNotesByWikiIds(input.wikiIds, bindings, env, now),
    env,
    now,
  );
}

export function readNoteTool(
  input: { path: string },
  env: NodeJS.ProcessEnv = process.env,
  now: Date = new Date(),
) {
  const result = readNotesTool({ paths: [input.path] }, env, now);
  return {
    note: result.notes[0],
    snapshotHash: result.snapshotHash,
    ...('maintenanceWarnings' in result ? { maintenanceWarnings: result.maintenanceWarnings } : {}),
  };
}
