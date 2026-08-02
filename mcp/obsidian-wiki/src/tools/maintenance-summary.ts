import { resolveBindings } from '../bindings.js';
import { foldCanonicalFeatureJournals } from '../journal-fold.js';
import { evaluateKnowledgeFreshness } from '../note.js';
import {
  boundNoteMetadata,
  readableBindingsForScope,
} from '../retrieval.js';

const DEFAULT_IDENTITY_LIMIT = 100;
const MAX_IDENTITY_LIMIT = 200;
const MAX_BINDINGS = 200;
const SUMMARY_IDENTITY_CATEGORIES = [
  'active',
  'reviewDue',
  'expired',
  'contradictory',
] as const;

export type MaintenanceSummaryInput = {
  asOf: string;
  identityLimit?: number;
};

type KnowledgeCounts = {
  active: number;
  fresh: number;
  reviewDue: number;
  expired: number;
  contradictory: number;
};

function identityLimit(value: unknown): number {
  if (value === undefined) return DEFAULT_IDENTITY_LIMIT;
  if (!Number.isInteger(value) || (value as number) < 1 || (value as number) > MAX_IDENTITY_LIMIT) {
    throw new Error(`identityLimit must be an integer between 1 and ${MAX_IDENTITY_LIMIT}`);
  }
  return value as number;
}

function emptyKnowledgeCounts(): KnowledgeCounts {
  return { active: 0, fresh: 0, reviewDue: 0, expired: 0, contradictory: 0 };
}

function compareText(left: string, right: string): number {
  return left < right ? -1 : left > right ? 1 : 0;
}

function summaryClock(value: unknown): { asOf: string; now: Date } {
  if (
    typeof value !== 'string'
    || !/^[0-9]{4}-(?:0[1-9]|1[0-2])-(?:0[1-9]|[12][0-9]|3[01])T(?:[01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]Z$/.test(value)
    || value.startsWith('0000-')
  ) {
    throw new Error('asOf must be a normalized UTC timestamp (YYYY-MM-DDTHH:mm:ssZ)');
  }
  const now = new Date(value);
  if (Number.isNaN(now.getTime()) || now.toISOString().replace('.000Z', 'Z') !== value) {
    throw new Error('asOf must be a normalized UTC timestamp (YYYY-MM-DDTHH:mm:ssZ)');
  }
  return { asOf: value, now };
}

export function maintenanceSummaryTool(
  input: MaintenanceSummaryInput,
  env: NodeJS.ProcessEnv = process.env,
) {
  const limit = identityLimit(input.identityLimit);
  const { asOf, now } = summaryClock(input.asOf);
  const resolution = resolveBindings(env);
  if (resolution.errors.length > 0) {
    throw new Error(`Obsidian Wiki Source bindings are unhealthy: ${resolution.errors.join('; ')}`);
  }
  const readableBindings = readableBindingsForScope(resolution.bindings)
    .sort((left, right) => compareText(left.sourceId, right.sourceId));
  if (readableBindings.length > MAX_BINDINGS) {
    throw new Error(`Wiki maintenance summary supports at most ${MAX_BINDINGS} readable bindings`);
  }
  const seenWikiIds = new Set<string>();
  const readableWikiIdentities = new Map<string, Set<string>>();
  const knowledgeCounts = emptyKnowledgeCounts();
  const sourceRows = readableBindings.map((binding) => {
    const counts = emptyKnowledgeCounts();
    const active: string[] = [];
    const reviewDue: string[] = [];
    const expired: string[] = [];
    const contradictory: string[] = [];
    for (const note of boundNoteMetadata(binding)) {
      if (note.status !== 'active' || !note.agentVisible) continue;
      if (seenWikiIds.has(note.wikiId)) {
        throw new Error(`Duplicate active wiki_id in readable bound Sources: ${note.wikiId}`);
      }
      seenWikiIds.add(note.wikiId);
      const sourceIdentities = readableWikiIdentities.get(binding.sourceId) ?? new Set<string>();
      sourceIdentities.add(note.wikiId);
      readableWikiIdentities.set(binding.sourceId, sourceIdentities);
      counts.active += 1;
      active.push(note.wikiId);
      const freshness = evaluateKnowledgeFreshness(note, now, `Obsidian Note ${note.wikiId}`);
      if (freshness.state === 'fresh') counts.fresh += 1;
      if (freshness.state === 'review-due') {
        counts.reviewDue += 1;
        reviewDue.push(note.wikiId);
      }
      if (freshness.state === 'expired') {
        counts.expired += 1;
        expired.push(note.wikiId);
      }
      if (note.edges.contradicts.length > 0) {
        counts.contradictory += 1;
        contradictory.push(note.wikiId);
      }
    }
    for (const key of Object.keys(knowledgeCounts) as Array<keyof KnowledgeCounts>) {
      knowledgeCounts[key] += counts[key];
    }
    for (const values of [active, reviewDue, expired, contradictory]) values.sort(compareText);
    return {
      sourceId: binding.sourceId,
      role: binding.role,
      bindingDigest: binding.bindingDigest,
      counts,
      identityValues: { active, reviewDue, expired, contradictory },
    };
  });
  const remainingIdentities = Object.fromEntries(
    SUMMARY_IDENTITY_CATEGORIES.map((category) => [category, limit]),
  ) as Record<(typeof SUMMARY_IDENTITY_CATEGORIES)[number], number>;
  const sources = sourceRows.map(({ identityValues, ...source }) => {
    const identities = Object.fromEntries(SUMMARY_IDENTITY_CATEGORIES.map((category) => {
      const values = identityValues[category];
      const visible = values.slice(0, remainingIdentities[category]);
      remainingIdentities[category] -= visible.length;
      return [category, visible];
    })) as Record<(typeof SUMMARY_IDENTITY_CATEGORIES)[number], string[]>;
    return {
      ...source,
      identities,
      truncated: Object.fromEntries(SUMMARY_IDENTITY_CATEGORIES.map((category) => [
        category,
        identities[category].length < identityValues[category].length,
      ])) as Record<(typeof SUMMARY_IDENTITY_CATEGORIES)[number], boolean>,
    };
  });

  const repositoryMap = new Map<string, {
    repositoryRef: string;
    baseBranch: string;
    currentBranch: string;
    baseStatus: 'synchronized' | 'unverified';
    sourceIds: string[];
  }>();
  for (const binding of readableBindings) {
    const existing = repositoryMap.get(binding.repositoryRef);
    const candidate = {
      repositoryRef: binding.repositoryRef,
      baseBranch: binding.repositoryHealth.baseBranch,
      currentBranch: binding.repositoryHealth.currentBranch,
      baseStatus: binding.repositoryHealth.baseSynchronized
        ? 'synchronized' as const
        : 'unverified' as const,
      sourceIds: [binding.sourceId],
    };
    if (!existing) {
      repositoryMap.set(binding.repositoryRef, candidate);
      continue;
    }
    if (
      existing.baseBranch !== candidate.baseBranch
      || existing.currentBranch !== candidate.currentBranch
      || existing.baseStatus !== candidate.baseStatus
    ) {
      throw new Error(`Bound Sources disagree on repository health for ${binding.repositoryRef}`);
    }
    existing.sourceIds.push(binding.sourceId);
  }
  const repositories = [...repositoryMap.values()]
    .map((repository) => ({
      ...repository,
      sourceIds: repository.sourceIds.sort(compareText),
    }))
    .sort((left, right) => compareText(left.repositoryRef, right.repositoryRef));

  const folded = foldCanonicalFeatureJournals(resolution.projectDir, env);
  const lifecycleCounts = {
    pending: 0,
    deferred: 0,
    kept: 0,
    skipped: 0,
    superseded: 0,
    capturePending: 0,
    correctionPending: 0,
  };
  const capturePending: Array<{
    featureSlug: string;
    candidateId: string;
    kind: string;
    status: 'pending' | 'deferred';
  }> = [];
  const correctionPending: Array<{
    featureSlug: string;
    candidateId: string;
    status: 'pending' | 'deferred';
    affectedWikiIdentity: { sourceId: string; wikiId: string };
  }> = [];
  for (const journal of folded) {
    for (const candidate of journal.candidates) {
      lifecycleCounts[candidate.status] += 1;
      if (candidate.status !== 'pending' && candidate.status !== 'deferred') continue;
      lifecycleCounts.capturePending += 1;
      capturePending.push({
        featureSlug: journal.featureSlug,
        candidateId: candidate.candidateId,
        kind: candidate.kind,
        status: candidate.status,
      });
      if (candidate.kind === 'correction') {
        if (!candidate.correction) {
          throw new Error(
            `Canonical Wiki candidate journal for ${journal.featureSlug} has a correction without identity metadata`,
          );
        }
        const affected = candidate.correction.affectedWikiIdentity;
        if (!readableWikiIdentities.get(affected.sourceId)?.has(affected.wikiId)) {
          throw new Error(
            `Canonical Wiki candidate journal for ${journal.featureSlug} has an unresolved correction outside readable active bound Wiki identities`,
          );
        }
        lifecycleCounts.correctionPending += 1;
        correctionPending.push({
          featureSlug: journal.featureSlug,
          candidateId: candidate.candidateId,
          status: candidate.status,
          affectedWikiIdentity: candidate.correction.affectedWikiIdentity,
        });
      }
    }
  }
  const compareCandidate = (
    left: { featureSlug: string; candidateId: string },
    right: { featureSlug: string; candidateId: string },
  ) => compareText(
    `${left.featureSlug}\n${left.candidateId}`,
    `${right.featureSlug}\n${right.candidateId}`,
  );
  capturePending.sort(compareCandidate);
  correctionPending.sort(compareCandidate);

  return {
    schemaVersion: 1 as const,
    kind: 'grill-adapter.wiki-maintenance-summary' as const,
    authoritative: false as const,
    status: 'ok' as const,
    asOf,
    identityLimit: limit,
    identityLimitScope: 'per-category-global' as const,
    knowledge: {
      counts: knowledgeCounts,
      sources,
    },
    repositories,
    candidateLifecycle: {
      counts: lifecycleCounts,
      capturePending: capturePending.slice(0, limit),
      correctionPending: correctionPending.slice(0, limit),
      truncated: {
        capturePending: capturePending.length > limit,
        correctionPending: correctionPending.length > limit,
      },
    },
    caveats: [...resolution.warnings].sort(compareText),
  };
}
