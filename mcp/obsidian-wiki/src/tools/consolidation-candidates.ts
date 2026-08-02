import { createHash } from 'node:crypto';
import { resolveBindings } from '../bindings.js';
import { foldCanonicalFeatureJournals, type FoldedCandidate } from '../journal-fold.js';
import { boundNoteMetadata, readableBindingsForScope } from '../retrieval.js';

const DEFAULT_CANDIDATE_LIMIT = 50;
const MAX_CANDIDATE_LIMIT = 200;
const MAX_BINDINGS = 200;

export type ConsolidationCandidatesInput = {
  candidateLimit?: number;
};

function compareText(left: string, right: string): number {
  return left < right ? -1 : left > right ? 1 : 0;
}

function candidateLimit(value: unknown): number {
  if (value === undefined) return DEFAULT_CANDIDATE_LIMIT;
  if (!Number.isInteger(value) || (value as number) < 1 || (value as number) > MAX_CANDIDATE_LIMIT) {
    throw new Error(`candidateLimit must be an integer between 1 and ${MAX_CANDIDATE_LIMIT}`);
  }
  return value as number;
}

function requiredText(value: unknown, field: string): string {
  if (typeof value !== 'string' || !value) throw new Error(`Canonical candidate ${field} is invalid`);
  return value;
}

function requiredTextArray(value: unknown, field: string): string[] {
  if (!Array.isArray(value) || value.some((item) => typeof item !== 'string' || !item)) {
    throw new Error(`Canonical candidate ${field} is invalid`);
  }
  return value as string[];
}

function candidateDigest(
  journalDigest: string,
  featureSlug: string,
  candidate: FoldedCandidate,
): string {
  const lastEventId = requiredText(candidate.lastEventId, 'lastEventId');
  const identity = [
    journalDigest,
    featureSlug,
    candidate.candidateId,
    candidate.status,
    lastEventId,
  ].join('\0');
  return `sha256:${createHash('sha256').update(identity, 'utf8').digest('hex')}`;
}

export function consolidationCandidatesTool(
  input: ConsolidationCandidatesInput,
  env: NodeJS.ProcessEnv = process.env,
) {
  const limit = candidateLimit(input.candidateLimit);
  const resolution = resolveBindings(env);
  if (resolution.errors.length > 0) {
    throw new Error(`Obsidian Wiki Source bindings are unhealthy: ${resolution.errors.join('; ')}`);
  }
  const readableBindings = readableBindingsForScope(resolution.bindings)
    .sort((left, right) => compareText(left.sourceId, right.sourceId));
  if (readableBindings.length > MAX_BINDINGS) {
    throw new Error(`Wiki consolidation supports at most ${MAX_BINDINGS} readable bindings`);
  }

  const readableWikiIdentities = new Map<string, Set<string>>();
  const seenWikiIds = new Set<string>();
  for (const binding of readableBindings) {
    const identities = new Set<string>();
    for (const note of boundNoteMetadata(binding)) {
      if (note.status !== 'active' || !note.agentVisible) continue;
      if (seenWikiIds.has(note.wikiId)) {
        throw new Error(`Duplicate active wiki_id in readable bound Sources: ${note.wikiId}`);
      }
      seenWikiIds.add(note.wikiId);
      identities.add(note.wikiId);
    }
    readableWikiIdentities.set(binding.sourceId, identities);
  }

  const folded = foldCanonicalFeatureJournals(resolution.projectDir, env);
  const candidates: Array<ReturnType<typeof normalizeCandidate>> = [];
  for (const journal of folded) {
    for (const candidate of journal.candidates) {
      if (candidate.status !== 'pending' && candidate.status !== 'deferred') continue;
      if (candidate.kind === 'correction') {
        const affected = candidate.correction?.affectedWikiIdentity;
        if (
          !affected
          || !readableWikiIdentities.get(affected.sourceId)?.has(affected.wikiId)
        ) {
          throw new Error(
            `Canonical Wiki candidate journal for ${journal.featureSlug} has an unresolved correction outside readable active bound Wiki identities`,
          );
        }
      }
      candidates.push(normalizeCandidate(journal.featureSlug, journal.journalDigest, candidate));
    }
  }
  candidates.sort((left, right) => compareText(
    `${left.featureSlug}\n${left.candidateId}`,
    `${right.featureSlug}\n${right.candidateId}`,
  ));

  return {
    schemaVersion: 1 as const,
    kind: 'grill-adapter.wiki-maintenance-consolidation-input' as const,
    authoritative: false as const,
    status: 'ok' as const,
    candidateLimit: limit,
    scanned: {
      sources: readableBindings.length,
      featureJournals: folded.length,
      candidates: candidates.length,
    },
    bindings: readableBindings.map((binding) => ({
      sourceId: binding.sourceId,
      role: binding.role,
      bindingDigest: binding.bindingDigest,
    })),
    journalSnapshots: folded.map((journal) => ({
      featureSlug: journal.featureSlug,
      journalDigest: journal.journalDigest,
    })),
    candidates: candidates.slice(0, limit),
    truncated: candidates.length > limit,
  };
}

function normalizeCandidate(
  featureSlug: string,
  journalDigest: string,
  candidate: FoldedCandidate,
) {
  return {
    featureSlug,
    candidateId: candidate.candidateId,
    status: candidate.status as 'pending' | 'deferred',
    stage: requiredText(candidate.stage, 'stage'),
    candidateType: requiredText(candidate.candidateType, 'candidateType'),
    kind: candidate.kind,
    claim: requiredText(candidate.claim, 'claim'),
    why: requiredText(candidate.why, 'why'),
    sourceRefs: requiredTextArray(candidate.sourceRefs, 'sourceRefs'),
    taskId: typeof candidate.taskId === 'string' ? candidate.taskId : null,
    carveOut: typeof candidate.carveOut === 'boolean' ? candidate.carveOut : null,
    origin: typeof candidate.origin === 'string' ? candidate.origin : null,
    skillRegistration: candidate.skillRegistration ?? null,
    adrProjection: candidate.adrProjection ?? null,
    correction: candidate.correction ?? null,
    candidateDigest: candidateDigest(journalDigest, featureSlug, candidate),
  };
}
