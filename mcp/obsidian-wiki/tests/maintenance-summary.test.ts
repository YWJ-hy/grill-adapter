import { chmodSync, mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import { consolidationCandidatesTool } from '../src/tools/consolidation-candidates.js';
import { maintenanceSummaryTool } from '../src/tools/maintenance-summary.js';

const createdDirectories: string[] = [];

function writeJson(filePath: string, value: unknown): void {
  mkdirSync(path.dirname(filePath), { recursive: true });
  writeFileSync(filePath, JSON.stringify(value, null, 2), 'utf8');
}

function sourceManifest(sourceId: string, scope: 'project' | 'shared'): string {
  const neutrality = scope === 'shared'
    ? 'blocked_terms:\n  - project-internal\nblocked_patterns:\n  - "secret"\n'
    : '';
  return `---\nwiki_schema: grill-adapter.obsidian-source/v1\nwiki_source_id: ${sourceId}\nscope: ${scope}\nupdate_existing: confirm\ncreate_note: confirm\n${neutrality}---\n\n# ${sourceId}\n`;
}

function note(wikiId: string, summary: string, body: string, options: {
  status?: 'active' | 'archived';
  agentVisible?: boolean;
  verifiedAt?: string;
  reviewAfter?: string;
  expiresAt?: string;
  contradicts?: string[];
} = {}): string {
  const freshness = [
    options.verifiedAt === undefined ? '' : `verified_at: ${options.verifiedAt}\n`,
    options.reviewAfter === undefined ? '' : `review_after: ${options.reviewAfter}\n`,
    options.expiresAt === undefined ? '' : `expires_at: ${options.expiresAt}\n`,
  ].join('');
  const contradicts = options.contradicts?.length
    ? `contradicts:\n${options.contradicts.map((value) => `  - "${value}"`).join('\n')}\n`
    : '';
  return `---\nwiki_schema: grill-adapter.obsidian-note/v1\nwiki_id: ${wikiId}\ntype: constraint\nstatus: ${options.status ?? 'active'}\nagent_visible: ${options.agentVisible ?? true}\nsummary: ${summary}\nconstraint_strength: hard\n${freshness}${contradicts}---\n\n# ${wikiId}\n\n${body}\n`;
}

function event(overrides: Record<string, unknown>): Record<string, unknown> {
  return {
    schemaVersion: 1,
    eventType: 'candidate',
    eventId: 'event-1',
    featureSlug: 'feature-a',
    recordedAt: '2026-07-31T00:00:00Z',
    candidateId: 'candidate-1',
    stage: 'implementation',
    candidateType: 'wiki_note',
    kind: 'decision',
    claim: 'A durable claim that must not be returned.',
    why: 'A private rationale that must not be returned.',
    sourceRefs: ['tests/private-evidence'],
    ...overrides,
  };
}

function writeJournal(projectDir: string, featureSlug: string, events: Record<string, unknown>[]): void {
  const journal = path.join(
    projectDir,
    '.grill-adapter',
    'context',
    featureSlug,
    'wiki-candidates.jsonl',
  );
  mkdirSync(path.dirname(journal), { recursive: true });
  writeFileSync(journal, `${events.map((value) => JSON.stringify(value)).join('\n')}\n`, 'utf8');
}

function fixture(options: { seedNotes?: boolean } = {}) {
  const root = mkdtempSync(path.join(tmpdir(), 'obsidian-maintenance-summary-'));
  createdDirectories.push(root);
  const projectDir = path.join(root, 'project');
  const vaultRoot = path.join(root, 'vault');
  const registryPath = path.join(root, 'registry.json');
  const obsidianCli = path.join(root, process.platform === 'win32' ? 'obsidian.cmd' : 'obsidian');
  const bindings = [
    { sourceId: 'project', role: 'project', vaultRef: 'knowledge', repositoryRef: 'wiki', root: 'Projects/example', access: { read: true, update: 'confirm' } },
    { sourceId: 'shared', role: 'shared', vaultRef: 'knowledge', repositoryRef: 'wiki', root: 'Shared/Engineering', access: { read: true, update: 'confirm' } },
  ];

  for (const entry of [
    { root: 'Projects/example', sourceId: 'project', scope: 'project' as const },
    { root: 'Shared/Engineering', sourceId: 'shared', scope: 'shared' as const },
  ]) {
    const sourceRoot = path.join(vaultRoot, entry.root);
    mkdirSync(path.join(sourceRoot, '_meta'), { recursive: true });
    writeFileSync(
      path.join(sourceRoot, '_meta', 'wiki-source.md'),
      sourceManifest(entry.sourceId, entry.scope),
      'utf8',
    );
  }

  if (options.seedNotes !== false) {
    writeFileSync(
      path.join(vaultRoot, 'Projects/example', 'Fresh.md'),
      note('project/fresh', 'Fresh summary', 'NOTE_BODY_SECRET_FRESH', {
        verifiedAt: '2026-07-01T00:00:00Z',
        reviewAfter: '2026-08-01T00:00:00Z',
        expiresAt: '2027-01-01T00:00:00Z',
        contradicts: ['[[Projects/example/Expired]]'],
      }),
      'utf8',
    );
    writeFileSync(
      path.join(vaultRoot, 'Projects/example', 'ReviewDue.md'),
      note('project/review-due', 'Review-due summary', 'NOTE_BODY_SECRET_REVIEW_DUE', {
        verifiedAt: '2026-01-01T00:00:00Z',
        reviewAfter: '2026-07-01T00:00:00Z',
        expiresAt: '2027-01-01T00:00:00Z',
      }),
      'utf8',
    );
    writeFileSync(
      path.join(vaultRoot, 'Projects/example', 'Expired.md'),
      note('project/expired', 'Expired summary', 'NOTE_BODY_SECRET_EXPIRED', {
        verifiedAt: '2025-01-01T00:00:00Z',
        reviewAfter: '2025-06-01T00:00:00Z',
        expiresAt: '2026-01-01T00:00:00Z',
      }),
      'utf8',
    );
    writeFileSync(
      path.join(vaultRoot, 'Projects/example', 'Hidden.md'),
      note('project/hidden', 'Hidden summary', 'NOTE_BODY_SECRET_HIDDEN', { agentVisible: false }),
      'utf8',
    );
    writeFileSync(
      path.join(vaultRoot, 'Shared/Engineering', 'Shared.md'),
      note('shared/engineering', 'Shared summary', 'NOTE_BODY_SECRET_SHARED'),
      'utf8',
    );
    mkdirSync(path.join(vaultRoot, 'Unbound'), { recursive: true });
    writeFileSync(
      path.join(vaultRoot, 'Unbound', 'Private.md'),
      note('unbound/private', 'Unbound summary', 'NOTE_BODY_SECRET_UNBOUND'),
      'utf8',
    );
  }

  execFileSync('git', ['init', '--initial-branch=main', vaultRoot]);
  execFileSync('git', ['-C', vaultRoot, 'config', 'user.name', 'Test User']);
  execFileSync('git', ['-C', vaultRoot, 'config', 'user.email', 'test@example.invalid']);
  execFileSync('git', ['-C', vaultRoot, 'remote', 'add', 'origin', 'https://github.com/acme/knowledge.git']);
  execFileSync('git', ['-C', vaultRoot, 'add', '.']);
  execFileSync('git', ['-C', vaultRoot, 'commit', '-m', 'fixture']);

  if (process.platform === 'win32') {
    writeFileSync(obsidianCli, '@echo off\r\nif "%1"=="vaults" echo Knowledge\r\n', 'utf8');
  } else {
    writeFileSync(obsidianCli, '#!/usr/bin/env sh\n[ "$1" = "vaults" ] && printf "Knowledge\\n"\n', 'utf8');
    chmodSync(obsidianCli, 0o755);
  }
  writeJson(path.join(projectDir, '.grill-adapter', 'settings.json'), {
    wiki: { provider: 'obsidian', publishing: { mode: 'git-pr' }, obsidian: { bindings } },
  });
  writeJson(registryPath, {
    vaults: { knowledge: { selector: 'Knowledge' } },
    repositories: {
      wiki: {
        worktreeRoot: vaultRoot,
        remote: 'origin',
        expectedRemote: 'github.com/acme/knowledge',
        baseBranch: 'main',
        syncBeforeResearch: false,
      },
    },
  });
  return {
    projectDir,
    env: {
      CLAUDE_PROJECT_DIR: projectDir,
      OBSIDIAN_WIKI_REGISTRY: registryPath,
      OBSIDIAN_WIKI_OBSIDIAN_CLI: obsidianCli,
    } satisfies NodeJS.ProcessEnv,
  };
}

afterEach(() => {
  while (createdDirectories.length) rmSync(createdDirectories.pop()!, { recursive: true, force: true });
});

describe('read-only Wiki maintenance summary', () => {
  it('aggregates bound freshness and canonical candidate lifecycle without returning prose', () => {
    const input = fixture();
    writeJournal(input.projectDir, 'feature-a', [
      event({}),
      event({
        eventId: 'correction-1-event',
        candidateId: 'correction-1',
        kind: 'correction',
        claim: 'CORRECTION_CLAIM_SECRET_ONE',
        sourceRefs: ['tests/evidence-one'],
        correction: {
          affectedWikiIdentity: { sourceId: 'project', wikiId: 'project/fresh' },
          claim: 'CORRECTION_CLAIM_SECRET_ONE',
          evidenceRefs: ['tests/evidence-one'],
          observedImpact: 'OBSERVED_IMPACT_SECRET_ONE',
        },
      }),
      event({
        eventId: 'correction-2-event',
        candidateId: 'correction-2',
        kind: 'correction',
        claim: 'CORRECTION_CLAIM_SECRET_TWO',
        sourceRefs: ['tests/evidence-two'],
        correction: {
          affectedWikiIdentity: { sourceId: 'project', wikiId: 'project/fresh' },
          claim: 'CORRECTION_CLAIM_SECRET_TWO',
          evidenceRefs: ['tests/evidence-two'],
          observedImpact: 'OBSERVED_IMPACT_SECRET_TWO',
        },
      }),
      {
        schemaVersion: 1,
        eventType: 'outcome',
        eventId: 'correction-2-deferred',
        featureSlug: 'feature-a',
        recordedAt: '2026-07-31T00:10:00Z',
        candidateId: 'correction-2',
        status: 'deferred',
        reason: 'OUTCOME_REASON_SECRET',
      },
    ]);

    const asOf = '2026-07-31T12:00:00Z';
    const first = maintenanceSummaryTool({ asOf, identityLimit: 20 }, input.env);
    const second = maintenanceSummaryTool({ asOf, identityLimit: 20 }, input.env);

    expect(second).toEqual(first);
    expect(first).toMatchObject({
      schemaVersion: 1,
      kind: 'grill-adapter.wiki-maintenance-summary',
      authoritative: false,
      status: 'ok',
      asOf,
      identityLimit: 20,
      identityLimitScope: 'per-category-global',
      knowledge: {
        counts: { active: 4, fresh: 2, reviewDue: 1, expired: 1, contradictory: 1 },
        sources: [
          {
            sourceId: 'project',
            role: 'project',
            counts: { active: 3, fresh: 1, reviewDue: 1, expired: 1, contradictory: 1 },
            identities: {
              active: ['project/expired', 'project/fresh', 'project/review-due'],
              reviewDue: ['project/review-due'],
              expired: ['project/expired'],
              contradictory: ['project/fresh'],
            },
          },
          {
            sourceId: 'shared',
            role: 'shared',
            counts: { active: 1, fresh: 1, reviewDue: 0, expired: 0, contradictory: 0 },
            identities: {
              active: ['shared/engineering'],
              reviewDue: [],
              expired: [],
              contradictory: [],
            },
          },
        ],
      },
      repositories: [{
        repositoryRef: 'wiki',
        baseBranch: 'main',
        currentBranch: 'main',
        baseStatus: 'unverified',
        sourceIds: ['project', 'shared'],
      }],
      candidateLifecycle: {
        counts: {
          pending: 2,
          deferred: 1,
          kept: 0,
          skipped: 0,
          superseded: 0,
          capturePending: 3,
          correctionPending: 2,
        },
        capturePending: [
          { featureSlug: 'feature-a', candidateId: 'candidate-1', kind: 'decision', status: 'pending' },
          { featureSlug: 'feature-a', candidateId: 'correction-1', kind: 'correction', status: 'pending' },
          { featureSlug: 'feature-a', candidateId: 'correction-2', kind: 'correction', status: 'deferred' },
        ],
        correctionPending: [
          {
            featureSlug: 'feature-a',
            candidateId: 'correction-1',
            status: 'pending',
            affectedWikiIdentity: { sourceId: 'project', wikiId: 'project/fresh' },
          },
          {
            featureSlug: 'feature-a',
            candidateId: 'correction-2',
            status: 'deferred',
            affectedWikiIdentity: { sourceId: 'project', wikiId: 'project/fresh' },
          },
        ],
      },
    });
    const serialized = JSON.stringify(first);
    for (const forbidden of [
      'NOTE_BODY_SECRET',
      'Fresh summary',
      'Review-due summary',
      'Expired summary',
      'Shared summary',
      'CORRECTION_CLAIM_SECRET',
      'OBSERVED_IMPACT_SECRET',
      'OUTCOME_REASON_SECRET',
      'Unbound summary',
      'project/hidden',
      'unbound/private',
      input.projectDir,
    ]) {
      expect(serialized).not.toContain(forbidden);
    }
  });

  it('returns empty deterministic groups when no Notes or journals exist', () => {
    const input = fixture({ seedNotes: false });
    const result = maintenanceSummaryTool({
      asOf: '2026-07-31T12:00:00Z',
      identityLimit: 10,
    }, input.env);
    expect(result.knowledge.counts).toEqual({
      active: 0,
      fresh: 0,
      reviewDue: 0,
      expired: 0,
      contradictory: 0,
    });
    expect(result.candidateLifecycle.counts.capturePending).toBe(0);
    expect(result.candidateLifecycle.capturePending).toEqual([]);
    expect(result.candidateLifecycle.correctionPending).toEqual([]);
  });

  it('fails closed on a malformed canonical journal', () => {
    const input = fixture();
    const journal = path.join(
      input.projectDir,
      '.grill-adapter',
      'context',
      'broken-feature',
      'wiki-candidates.jsonl',
    );
    mkdirSync(path.dirname(journal), { recursive: true });
    writeFileSync(journal, '{"truncated":true}', 'utf8');
    expect(() => maintenanceSummaryTool({ asOf: '2026-07-31T12:00:00Z' }, input.env))
      .toThrow(/broken-feature.*truncated JSONL record/i);
  });

  it('fails closed without returning an unbound correction identity', () => {
    const input = fixture();
    writeJournal(input.projectDir, 'unbound-correction', [event({
      eventId: 'unbound-correction-event',
      featureSlug: 'unbound-correction',
      candidateId: 'unbound-correction',
      kind: 'correction',
      claim: 'Unbound correction claim.',
      sourceRefs: ['tests/unbound-evidence'],
      correction: {
        affectedWikiIdentity: {
          sourceId: 'SECRET_UNBOUND_SOURCE',
          wikiId: 'SECRET_UNBOUND_WIKI_ID',
        },
        claim: 'Unbound correction claim.',
        evidenceRefs: ['tests/unbound-evidence'],
        observedImpact: 'Unbound correction impact.',
      },
    })]);

    let message = '';
    try {
      maintenanceSummaryTool({ asOf: '2026-07-31T12:00:00Z' }, input.env);
    } catch (error) {
      message = error instanceof Error ? error.message : String(error);
    }
    expect(message).toMatch(/unbound-correction.*outside readable active bound Wiki identities/i);
    expect(message).not.toContain('SECRET_UNBOUND_SOURCE');
    expect(message).not.toContain('SECRET_UNBOUND_WIKI_ID');
  });

  it.skipIf(process.platform === 'win32')('fails closed on a symlinked feature context', () => {
    const input = fixture();
    const outside = path.join(path.dirname(input.projectDir), 'outside-feature');
    mkdirSync(outside, { recursive: true });
    writeFileSync(path.join(outside, 'wiki-candidates.jsonl'), `${JSON.stringify(event({}))}\n`, 'utf8');
    const contextRoot = path.join(input.projectDir, '.grill-adapter', 'context');
    mkdirSync(contextRoot, { recursive: true });
    symlinkSync(outside, path.join(contextRoot, 'linked-feature'));

    expect(() => maintenanceSummaryTool({ asOf: '2026-07-31T12:00:00Z' }, input.env))
      .toThrow(/linked-feature.*symbolic link/i);
  });

  it.skipIf(process.platform === 'win32')('fails closed on a dangling candidate journal symlink', () => {
    const input = fixture();
    const featureRoot = path.join(input.projectDir, '.grill-adapter', 'context', 'dangling-feature');
    mkdirSync(featureRoot, { recursive: true });
    symlinkSync(
      path.join(featureRoot, 'missing-wiki-candidates.jsonl'),
      path.join(featureRoot, 'wiki-candidates.jsonl'),
    );

    expect(() => maintenanceSummaryTool({ asOf: '2026-07-31T12:00:00Z' }, input.env))
      .toThrow(/dangling-feature.*real file/i);
  });

  it('bounds identity arrays while preserving total counts', () => {
    const input = fixture();
    writeJournal(input.projectDir, 'feature-a', [
      event({ candidateId: 'candidate-1', eventId: 'event-1' }),
      event({ candidateId: 'candidate-2', eventId: 'event-2' }),
    ]);
    const result = maintenanceSummaryTool({
      asOf: '2026-07-31T12:00:00Z',
      identityLimit: 1,
    }, input.env);
    expect(result.candidateLifecycle.counts.capturePending).toBe(2);
    expect(result.candidateLifecycle.capturePending).toHaveLength(1);
    expect(result.candidateLifecycle.truncated.capturePending).toBe(true);
    expect(result.knowledge.counts.active).toBe(4);
    expect(result.knowledge.sources.flatMap((source) => source.identities.active)).toHaveLength(1);
    expect(result.knowledge.sources[0].truncated.active).toBe(true);
    expect(result.knowledge.sources[1].identities.active).toEqual([]);
    expect(result.knowledge.sources[1].truncated.active).toBe(true);
  });

  it('requires an explicit normalized freshness clock', () => {
    const input = fixture({ seedNotes: false });
    expect(() => maintenanceSummaryTool({} as never, input.env)).toThrow(/asOf.*required|normalized/i);
    expect(() => maintenanceSummaryTool({ asOf: '2026-07-31' }, input.env)).toThrow(/normalized/i);
  });
});

describe('read-only consolidation candidate input', () => {
  it('returns a bounded deterministic cross-feature snapshot for private semantic grouping', () => {
    const input = fixture();
    writeJournal(input.projectDir, 'feature-b', [event({
      eventId: 'feature-b-correction-event',
      featureSlug: 'feature-b',
      candidateId: 'feature-b-correction',
      kind: 'correction',
      claim: 'Use one retry budget for outbound requests.',
      why: 'Repeated retries amplify a downstream outage.',
      sourceRefs: ['tests/feature-b-evidence'],
      correction: {
        affectedWikiIdentity: { sourceId: 'project', wikiId: 'project/fresh' },
        claim: 'Use one retry budget for outbound requests.',
        evidenceRefs: ['tests/feature-b-evidence'],
        observedImpact: 'The old rule retried at two independent layers.',
      },
    })]);
    writeJournal(input.projectDir, 'feature-a', [
      event({
        eventId: 'feature-a-decision-event',
        candidateId: 'feature-a-decision',
        claim: 'Share one outbound retry budget across transport layers.',
        why: 'Nested retry loops multiply attempts.',
        sourceRefs: ['tests/feature-a-evidence'],
      }),
      event({
        eventId: 'feature-a-independent-event',
        candidateId: 'feature-a-independent',
        claim: 'Validate cache entries before deserialization.',
        why: 'Cache corruption follows a separate recovery path.',
        sourceRefs: ['tests/feature-a-cache-evidence'],
      }),
    ]);

    const first = consolidationCandidatesTool({ candidateLimit: 20 }, input.env);
    const second = consolidationCandidatesTool({ candidateLimit: 20 }, input.env);

    expect(second).toEqual(first);
    expect(first).toMatchObject({
      schemaVersion: 1,
      kind: 'grill-adapter.wiki-maintenance-consolidation-input',
      authoritative: false,
      status: 'ok',
      candidateLimit: 20,
      scanned: { sources: 2, featureJournals: 2, candidates: 3 },
      truncated: false,
    });
    expect(first.bindings).toHaveLength(2);
    expect(first.journalSnapshots.map((entry) => entry.featureSlug)).toEqual([
      'feature-a',
      'feature-b',
    ]);
    expect(first.journalSnapshots.every((entry) => /^sha256:[0-9a-f]{64}$/.test(entry.journalDigest)))
      .toBe(true);
    expect(first.candidates.map((candidate) => [candidate.featureSlug, candidate.candidateId]))
      .toEqual([
        ['feature-a', 'feature-a-decision'],
        ['feature-a', 'feature-a-independent'],
        ['feature-b', 'feature-b-correction'],
      ]);
    expect(first.candidates[0]).toMatchObject({
      status: 'pending',
      stage: 'implementation',
      candidateType: 'wiki_note',
      kind: 'decision',
      claim: 'Share one outbound retry budget across transport layers.',
      why: 'Nested retry loops multiply attempts.',
      sourceRefs: ['tests/feature-a-evidence'],
      correction: null,
    });
    expect(first.candidates[2].correction).toMatchObject({
      affectedWikiIdentity: { sourceId: 'project', wikiId: 'project/fresh' },
      observedImpact: 'The old rule retried at two independent layers.',
    });
    expect(first.candidates.every((candidate) => /^sha256:[0-9a-f]{64}$/.test(candidate.candidateDigest)))
      .toBe(true);

    const serialized = JSON.stringify(first);
    expect(serialized).not.toContain('NOTE_BODY_SECRET');
    expect(serialized).not.toContain('candidateEventId');
    expect(serialized).not.toContain('lastEventId');
    expect(serialized).not.toContain('outcomeReason');
    expect(serialized).not.toContain(input.projectDir);
  });

  it('applies one global limit while preserving total counts and journal snapshots', () => {
    const input = fixture();
    writeJournal(input.projectDir, 'feature-a', [
      event({ candidateId: 'candidate-1', eventId: 'event-1' }),
      event({ candidateId: 'candidate-2', eventId: 'event-2' }),
    ]);
    writeJournal(input.projectDir, 'feature-b', [event({
      featureSlug: 'feature-b', candidateId: 'candidate-3', eventId: 'event-3',
    })]);

    const result = consolidationCandidatesTool({ candidateLimit: 2 }, input.env);

    expect(result.scanned).toMatchObject({ featureJournals: 2, candidates: 3 });
    expect(result.candidates).toHaveLength(2);
    expect(result.journalSnapshots).toHaveLength(2);
    expect(result.truncated).toBe(true);
  });

  it('fails closed on malformed journals and unbound correction identities', () => {
    const malformed = fixture();
    const malformedJournal = path.join(
      malformed.projectDir,
      '.grill-adapter',
      'context',
      'broken-feature',
      'wiki-candidates.jsonl',
    );
    mkdirSync(path.dirname(malformedJournal), { recursive: true });
    writeFileSync(malformedJournal, '{"truncated":true}', 'utf8');
    expect(() => consolidationCandidatesTool({ candidateLimit: 20 }, malformed.env))
      .toThrow(/broken-feature.*truncated JSONL record/i);

    const unbound = fixture();
    writeJournal(unbound.projectDir, 'unbound-correction', [event({
      eventId: 'unbound-event',
      featureSlug: 'unbound-correction',
      candidateId: 'unbound-candidate',
      kind: 'correction',
      claim: 'A private unbound correction.',
      sourceRefs: ['tests/unbound'],
      correction: {
        affectedWikiIdentity: { sourceId: 'missing', wikiId: 'missing/note' },
        claim: 'A private unbound correction.',
        evidenceRefs: ['tests/unbound'],
        observedImpact: 'A private impact.',
      },
    })]);
    expect(() => consolidationCandidatesTool({ candidateLimit: 20 }, unbound.env))
      .toThrow(/unbound-correction.*outside readable active bound Wiki identities/i);
  });
});
