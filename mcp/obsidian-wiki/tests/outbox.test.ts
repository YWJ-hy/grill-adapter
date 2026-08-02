import { execFileSync } from 'node:child_process';
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import { contentHash } from '../src/note.js';
import {
  captureDraftView,
  correctOutbox,
  outboxReview,
  outboxStatus,
  publishOutbox,
  stageCapturePlan,
} from '../src/outbox.js';
import { resolveBindings } from '../src/bindings.js';
import { consolidationCandidatesTool } from '../src/tools/consolidation-candidates.js';
import { foldCanonicalFeatureJournals } from '../src/journal-fold.js';

const createdDirectories: string[] = [];

function command(commandName: string, args: string[], cwd?: string): string {
  return String(execFileSync(commandName, args, { cwd, encoding: 'utf8' })).trim();
}

function writeJson(filePath: string, value: unknown): void {
  mkdirSync(path.dirname(filePath), { recursive: true });
  writeFileSync(filePath, `${JSON.stringify(value, null, 2)}\n`, 'utf8');
}

function note(summary: string, body: string, wikiId = 'project/example/contract'): string {
  return `---\nwiki_schema: grill-adapter.obsidian-note/v1\nwiki_id: ${wikiId}\ntype: constraint\nstatus: active\nagent_visible: true\nsummary: ${summary}\nconstraint_strength: hard\n---\n\n# Contract\n\n${body}\n`;
}

function fixture(projectName = 'project') {
  const root = mkdtempSync(path.join(tmpdir(), 'obsidian-outbox-'));
  createdDirectories.push(root);
  const projectDir = path.join(root, projectName);
  const worktreeRoot = path.join(root, 'knowledge');
  const remoteRoot = path.join(root, 'knowledge.git');
  const registryPath = path.join(root, 'state', 'obsidian-wiki.jsonc');
  const obsidianCli = path.join(root, 'obsidian');
  const ghCli = path.join(root, 'gh');
  const ghState = path.join(root, 'gh-state.json');
  const sourceRoot = 'Projects/example';
  const notePath = `${sourceRoot}/contract.md`;
  const original = note('Original contract.', 'Original base content.');
  const updated = note('Queued contract.', 'Private queued marker.');

  command('git', ['init', '--bare', remoteRoot]);
  command('git', ['init', '--initial-branch=main', worktreeRoot]);
  command('git', ['config', 'user.name', 'Test User'], worktreeRoot);
  command('git', ['config', 'user.email', 'test@example.invalid'], worktreeRoot);
  command('git', ['remote', 'add', 'origin', remoteRoot], worktreeRoot);
  mkdirSync(path.join(worktreeRoot, sourceRoot, '_meta'), { recursive: true });
  writeFileSync(
    path.join(worktreeRoot, sourceRoot, '_meta', 'wiki-source.md'),
    '---\nwiki_schema: grill-adapter.obsidian-source/v1\nwiki_source_id: project\nscope: project\nupdate_existing: direct\ncreate_note: direct\n---\n',
    'utf8',
  );
  writeFileSync(path.join(worktreeRoot, notePath), original, 'utf8');
  command('git', ['add', '.'], worktreeRoot);
  command('git', ['commit', '-m', 'base'], worktreeRoot);
  command('git', ['push', '-u', 'origin', 'main'], worktreeRoot);

  writeFileSync(obsidianCli, '#!/usr/bin/env sh\n[ "$1" = "vaults" ] && printf "Knowledge\\n"\n', 'utf8');
  chmodSync(obsidianCli, 0o755);
  writeFileSync(ghCli, `#!/usr/bin/env node
const fs = require('fs');
const args = process.argv.slice(2);
const statePath = process.env.FAKE_GH_STATE;
const state = fs.existsSync(statePath) ? JSON.parse(fs.readFileSync(statePath, 'utf8')) : { calls: [], prs: {} };
state.calls.push(args);
if (args[0] !== 'pr') process.exit(2);
if (args[1] === 'list') {
  const head = args[args.indexOf('--head') + 1];
  process.stdout.write(state.prs[head] || '');
} else if (args[1] === 'create') {
  const head = args[args.indexOf('--head') + 1];
  const url = 'https://github.com/acme/knowledge/pull/42';
  state.createCount = (state.createCount || 0) + 1;
  state.prs[head] = url;
  const failCreateNumber = Number(process.env.FAKE_GH_FAIL_CREATE_NUMBER || 0);
  if (failCreateNumber === state.createCount && !state.failedCreateNumber) {
    state.failedCreateNumber = true;
    fs.writeFileSync(statePath, JSON.stringify(state));
    process.exit(1);
  }
  if (process.env.FAKE_GH_FAIL_AFTER_CREATE_ONCE === '1' && !state.failedAfterCreate) {
    state.failedAfterCreate = true;
    fs.writeFileSync(statePath, JSON.stringify(state));
    process.exit(1);
  }
  process.stdout.write(url + '\\n');
} else if (args[1] === 'edit') {
  process.stdout.write(args[2] + '\\n');
} else process.exit(2);
fs.writeFileSync(statePath, JSON.stringify(state));
`, 'utf8');
  chmodSync(ghCli, 0o755);
  writeJson(path.join(projectDir, '.grill-adapter', 'settings.json'), {
    wiki: {
      provider: 'obsidian',
      publishing: { mode: 'git-pr' },
      obsidian: {
        bindings: [{
          sourceId: 'project', role: 'project', vaultRef: 'knowledge', repositoryRef: 'wiki',
          root: sourceRoot, access: { read: true, update: 'direct' },
        }],
      },
    },
  });
  writeJson(registryPath, {
    vaults: { knowledge: { selector: 'Knowledge' } },
    repositories: {
      wiki: {
        worktreeRoot, remote: 'origin', expectedRemote: remoteRoot,
        baseBranch: 'main', syncBeforeResearch: true,
      },
    },
  });
  const env: NodeJS.ProcessEnv = {
    ...process.env,
    CLAUDE_PROJECT_DIR: projectDir,
    OBSIDIAN_WIKI_REGISTRY: registryPath,
    OBSIDIAN_WIKI_OBSIDIAN_CLI: obsidianCli,
    OBSIDIAN_WIKI_GH_CLI: ghCli,
    FAKE_GH_STATE: ghState,
  };
  const binding = resolveBindings(env).bindings[0];
  const journalPath = path.join(
    projectDir,
    '.grill-adapter',
    'context',
    'feature-a',
    'wiki-candidates.jsonl',
  );
  mkdirSync(path.dirname(journalPath), { recursive: true });
  writeFileSync(journalPath, `${JSON.stringify({
    schemaVersion: 1,
    eventType: 'candidate',
    eventId: 'event-a',
    featureSlug: 'feature-a',
    recordedAt: '2026-08-02T09:00:00Z',
    candidateId: 'candidate-a',
    stage: 'review',
    candidateType: 'wiki_note',
    kind: 'contract',
    claim: 'Private candidate marker.',
    why: 'This cross-layer contract must remain stable.',
    sourceRefs: ['src/contract.ts'],
    taskId: null,
    carveOut: false,
  })}\n`, 'utf8');
  const snapshot = consolidationCandidatesTool({ candidateLimit: 200 }, env);
  return {
    env,
    projectDir,
    worktreeRoot,
    remoteRoot,
    ghState,
    notePath,
    original,
    updated,
    binding,
    plan: {
      schemaVersion: 1,
      kind: 'grill-adapter.wiki-capture-plan',
      featureSlug: 'feature-a',
      journalSnapshots: snapshot.journalSnapshots,
      decisions: [{
        candidateIds: ['candidate-a'],
        candidateDigests: [snapshot.candidates[0].candidateDigest],
        outcome: 'queue',
        reason: 'Durable cross-layer contract.',
        sourceId: 'project',
        operation: 'update',
        path: notePath,
        expectedHash: contentHash(original),
        content: updated,
      }],
    },
  };
}

afterEach(() => {
  while (createdDirectories.length) rmSync(createdDirectories.pop()!, { recursive: true, force: true });
});

describe('machine-local Wiki Outbox', () => {
  it('queues a capture plan in a hidden Git ref while formal base stays clean', () => {
    const input = fixture();

    const result = stageCapturePlan(input.plan, input.env);

    expect(result).toMatchObject({ status: 'ok', counts: { queued: 1, skipped: 0, needsDecision: 0 } });
    expect(result.planId).toMatch(/^sha256:[a-f0-9]{64}$/);
    expect(command('git', ['status', '--porcelain'], input.worktreeRoot)).toBe('');
    expect(command('git', ['branch', '--show-current'], input.worktreeRoot)).toBe('main');
    expect(readFileSync(path.join(input.worktreeRoot, input.notePath), 'utf8')).toBe(input.original);
    const hiddenRef = command('git', ['for-each-ref', '--format=%(refname)', 'refs/grill-adapter/outbox'], input.worktreeRoot);
    expect(hiddenRef).toContain('refs/grill-adapter/outbox/');
    expect(command('git', ['show', `${hiddenRef}:${input.notePath}`], input.worktreeRoot)).toBe(input.updated.trimEnd());
    const folded = foldCanonicalFeatureJournals(input.projectDir, input.env);
    expect(folded[0].candidates[0]).toMatchObject({
      candidateId: 'candidate-a',
      status: 'kept',
      writeReceipt: { state: 'queued', path: input.notePath },
    });
  });

  it('enforces root-specific refusal and preserves omitted-root authorization defaults', () => {
    const input = fixture();
    expect(input.binding.rootUpdateAuthorization).toBe('skip');
    expect(input.binding.rootCreateAuthorization).toBe('ask');

    const settingsPath = path.join(input.projectDir, '.grill-adapter', 'settings.json');
    const settings = JSON.parse(readFileSync(settingsPath, 'utf8'));
    settings.wiki.roots = {
      project: {
        updateAuthorization: { updateExistingPage: 'refuse', createNewDocument: 'ask' },
      },
      shared: {
        updateAuthorization: { updateExistingPage: 'skip', createNewDocument: 'ask' },
        sharedNeutrality: { blockedTerms: [], blockedPatterns: [] },
      },
    };
    writeJson(settingsPath, settings);

    expect(() => stageCapturePlan(input.plan, input.env)).toThrow(/policy refuses update/);
    expect(outboxStatus(input.env).counts.queued).toBe(0);
    expect(command('git', ['for-each-ref', '--format=%(refname)', 'refs/grill-adapter/outbox'], input.worktreeRoot)).toBe('');
  });

  it('recovers an interrupted plan-owned hidden ref whose manifest was not persisted', () => {
    const input = fixture();
    const journalPath = path.join(
      input.projectDir,
      '.grill-adapter',
      'context',
      'feature-a',
      'wiki-candidates.jsonl',
    );
    const pendingJournal = readFileSync(journalPath, 'utf8');
    const first = stageCapturePlan(input.plan, input.env);
    const outboxRoot = path.join(path.dirname(String(input.env.OBSIDIAN_WIKI_REGISTRY)), 'outbox', 'v1');
    const projectState = readdirSync(outboxRoot).find((entry) => entry.length === 64)!;
    rmSync(path.join(outboxRoot, projectState, 'manifest.json'));
    writeFileSync(journalPath, pendingJournal, 'utf8');

    const recovered = stageCapturePlan(input.plan, input.env);

    expect(recovered.planId).toBe(first.planId);
    expect(outboxStatus(input.env).counts.queued).toBe(1);
    expect(captureDraftView({ paths: [input.notePath] }, input.env).selectedNotes[0].content)
      .toContain('Private queued marker.');

    writeFileSync(path.join(outboxRoot, projectState, 'outbox.lock'), '2147483647\n', 'utf8');
    expect(outboxStatus(input.env).counts.queued).toBe(1);
  });

  it('returns current-project status and a digest-bound review without leaking draft bodies into status', () => {
    const first = fixture();
    stageCapturePlan(first.plan, first.env);

    const status = outboxStatus(first.env);
    const review = outboxReview(first.env);

    expect(status).toMatchObject({ counts: { queued: 1, prOpen: 0, active: 0, conflicted: 0 } });
    expect(JSON.stringify(status)).not.toContain('Private queued marker');
    expect(review.planDigest).toMatch(/^sha256:[a-f0-9]{64}$/);
    expect(review.repositories).toHaveLength(1);
    expect(review.repositories[0].changes[0].diff).toContain('Private queued marker');
  });

  it('records exclude, defer, and revise review actions as superseding immutable entries', () => {
    const excluded = fixture();
    stageCapturePlan(excluded.plan, excluded.env);
    const excludedId = outboxReview(excluded.env).repositories[0].changes[0].entryIds.at(-1)!;
    const firstCorrection = correctOutbox({
      action: 'exclude', entryIds: [excludedId], reason: 'Keep this draft out of the next batch.',
    }, excluded.env);
    expect(firstCorrection.action).toBe('exclude');
    expect(outboxReview(excluded.env).repositories).toHaveLength(0);

    const deferred = fixture();
    stageCapturePlan(deferred.plan, deferred.env);
    const deferredId = outboxReview(deferred.env).repositories[0].changes[0].entryIds.at(-1)!;
    correctOutbox({
      action: 'defer', entryIds: [deferredId], reason: 'Contradictory claims need a user decision.',
    }, deferred.env);
    expect(outboxStatus(deferred.env).counts).toMatchObject({ queued: 0, conflicted: 1 });

    const revised = fixture();
    stageCapturePlan(revised.plan, revised.env);
    const originalId = outboxReview(revised.env).repositories[0].changes[0].entryIds.at(-1)!;
    const revisedContent = note('User revised contract.', 'User-approved revised wording.');
    const revision = correctOutbox({
      action: 'revise', entryId: originalId, content: revisedContent, reason: 'Use the reviewed wording.',
    }, revised.env);
    const review = outboxReview(revised.env);
    expect(revision.action).toBe('revise');
    expect(review.repositories[0].changes[0].diff).toContain('User-approved revised wording.');
    expect(review.repositories[0].changes[0].entryIds).toEqual(expect.arrayContaining([originalId, revision.entryIds[0]]));
  });

  it('merges semantically equivalent cross-feature drafts while retaining both provenances', () => {
    const input = fixture();
    stageCapturePlan(input.plan, input.env);
    const secondPath = 'Projects/example/equivalent.md';
    const journalPath = path.join(
      input.projectDir,
      '.grill-adapter',
      'context',
      'feature-b',
      'wiki-candidates.jsonl',
    );
    mkdirSync(path.dirname(journalPath), { recursive: true });
    writeFileSync(journalPath, `${JSON.stringify({
      schemaVersion: 1,
      eventType: 'candidate',
      eventId: 'event-equivalent',
      featureSlug: 'feature-b',
      recordedAt: '2026-08-02T10:00:00Z',
      candidateId: 'candidate-equivalent',
      stage: 'review',
      candidateType: 'wiki_note',
      kind: 'contract',
      claim: 'Equivalent durable claim.',
      why: 'Later evidence proves this is the same contract.',
      sourceRefs: ['src/equivalent.ts'],
      taskId: null,
      carveOut: false,
    })}\n`, 'utf8');
    const snapshot = consolidationCandidatesTool({ candidateLimit: 200 }, input.env);
    stageCapturePlan({
      schemaVersion: 1,
      kind: 'grill-adapter.wiki-capture-plan',
      featureSlug: 'feature-b',
      journalSnapshots: snapshot.journalSnapshots,
      decisions: [{
        candidateIds: ['candidate-equivalent'],
        candidateDigests: [snapshot.candidates.find((candidate) => candidate.candidateId === 'candidate-equivalent')!.candidateDigest],
        outcome: 'queue',
        reason: 'Initially captured as a separate claim.',
        sourceId: 'project',
        operation: 'create',
        path: secondPath,
        expectedHash: null,
        content: note('Equivalent draft.', 'Duplicate wording.', 'project/example/equivalent'),
      }],
    }, input.env);
    const initialReview = outboxReview(input.env);
    const changes = initialReview.repositories[0].changes;
    const target = changes.find((change) => change.path === input.notePath)!;
    const duplicate = changes.find((change) => change.path === secondPath)!;

    correctOutbox({
      action: 'merge',
      entryIds: [target.entryIds.at(-1)!, duplicate.entryIds.at(-1)!],
      targetEntryId: target.entryIds.at(-1)!,
      content: note('Consolidated contract.', 'One semantically consolidated durable claim.'),
      reason: 'Final evidence proves semantic equivalence.',
    }, input.env);

    const review = outboxReview(input.env);
    expect(review.repositories[0].changes).toHaveLength(1);
    expect(review.repositories[0].changes[0].path).toBe(input.notePath);
    expect(review.repositories[0].changes[0].featureSlugs).toEqual(['feature-a', 'feature-b']);
    expect(review.repositories[0].changes[0].diff).toContain('One semantically consolidated durable claim.');
  });

  it('folds sequential cross-feature updates to one final Note diff while retaining provenance', () => {
    const input = fixture();
    stageCapturePlan(input.plan, input.env);
    const final = note('Final queued contract.', 'Second private queued marker.');
    const journalPath = path.join(
      input.projectDir,
      '.grill-adapter',
      'context',
      'feature-b',
      'wiki-candidates.jsonl',
    );
    mkdirSync(path.dirname(journalPath), { recursive: true });
    writeFileSync(journalPath, `${JSON.stringify({
      schemaVersion: 1,
      eventType: 'candidate',
      eventId: 'event-b',
      featureSlug: 'feature-b',
      recordedAt: '2026-08-02T10:00:00Z',
      candidateId: 'candidate-b',
      stage: 'review',
      candidateType: 'wiki_note',
      kind: 'contract',
      claim: 'Second private candidate marker.',
      why: 'This later task refines the same durable contract.',
      sourceRefs: ['src/contract.ts'],
      taskId: null,
      carveOut: false,
    })}\n`, 'utf8');
    const snapshot = consolidationCandidatesTool({ candidateLimit: 200 }, input.env);

    stageCapturePlan({
      schemaVersion: 1,
      kind: 'grill-adapter.wiki-capture-plan',
      featureSlug: 'feature-b',
      journalSnapshots: snapshot.journalSnapshots,
      decisions: [{
        candidateIds: ['candidate-b'],
        candidateDigests: [snapshot.candidates.find((candidate) => candidate.candidateId === 'candidate-b')!.candidateDigest],
        outcome: 'queue',
        reason: 'Same-theme refinement.',
        sourceId: 'project',
        operation: 'update',
        path: input.notePath,
        expectedHash: contentHash(input.updated),
        content: final,
      }],
    }, input.env);

    const review = outboxReview(input.env);
    expect(review.repositories[0].changes).toHaveLength(1);
    expect(review.repositories[0].changes[0].entryIds).toHaveLength(2);
    expect(review.repositories[0].changes[0].featureSlugs).toEqual(['feature-a', 'feature-b']);
    expect(review.repositories[0].changes[0].diff).toContain('Second private queued marker');
    expect(review.repositories[0].changes[0].diff).not.toContain('Private queued marker.');
    expect(outboxStatus(input.env).counts.queued).toBe(1);
  });

  it('publishes one confirmed allowlisted batch as a draft PR and keeps formal base clean', () => {
    const input = fixture();
    stageCapturePlan(input.plan, input.env);
    const review = outboxReview(input.env);

    const result = publishOutbox({ planDigest: review.planDigest, confirmed: true }, input.env);

    expect(result.repositories).toHaveLength(1);
    expect(result.repositories[0]).toMatchObject({
      repositoryRef: 'wiki',
      state: 'pr-open',
      prUrl: 'https://github.com/acme/knowledge/pull/42',
    });
    expect(command('git', ['status', '--porcelain'], input.worktreeRoot)).toBe('');
    expect(command('git', ['branch', '--show-current'], input.worktreeRoot)).toBe('main');
    expect(readFileSync(path.join(input.worktreeRoot, input.notePath), 'utf8')).toBe(input.original);
    const branch = result.repositories[0].branch;
    expect(command('git', [`--git-dir=${input.remoteRoot}`, 'diff', '--name-only', `main..${branch}`]))
      .toBe(input.notePath);
    const gh = JSON.parse(readFileSync(input.ghState, 'utf8'));
    expect(gh.calls.find((args: string[]) => args[1] === 'create')).toContain('--draft');
    expect(outboxStatus(input.env).counts).toMatchObject({ queued: 0, prOpen: 1 });
  });

  it('rejects malformed snapshots without creating Outbox state', () => {
    const input = fixture();
    const drifted = {
      ...input.plan,
      journalSnapshots: input.plan.journalSnapshots.map((snapshot) => ({
        ...snapshot,
        journalDigest: `sha256:${'0'.repeat(64)}`,
      })),
    };

    expect(() => stageCapturePlan(drifted, input.env)).toThrow(/snapshot drift/);
    expect(outboxStatus(input.env).counts).toMatchObject({ queued: 0, prOpen: 0, active: 0 });
    expect(command('git', ['for-each-ref', '--format=%(refname)', 'refs/grill-adapter/outbox'], input.worktreeRoot)).toBe('');
    expect(command('git', ['status', '--porcelain'], input.worktreeRoot)).toBe('');
  });

  it('requires the exact current review digest', () => {
    const input = fixture();
    stageCapturePlan(input.plan, input.env);

    expect(() => publishOutbox({
      planDigest: `sha256:${'f'.repeat(64)}`,
      confirmed: true,
    }, input.env)).toThrow(/digest is stale/);
    expect(outboxStatus(input.env).counts).toMatchObject({ queued: 1, prOpen: 0 });
  });

  it('defers a same-path base conflict without publishing it', () => {
    const input = fixture();
    stageCapturePlan(input.plan, input.env);
    const review = outboxReview(input.env);
    writeFileSync(path.join(input.worktreeRoot, input.notePath), note('Upstream contract.', 'Conflicting upstream content.'), 'utf8');
    command('git', ['add', input.notePath], input.worktreeRoot);
    command('git', ['commit', '-m', 'upstream conflict'], input.worktreeRoot);
    command('git', ['push', 'origin', 'main'], input.worktreeRoot);

    const result = publishOutbox({ planDigest: review.planDigest, confirmed: true }, input.env);

    expect(result.repositories[0]).toMatchObject({
      repositoryRef: 'wiki',
      state: 'deferred',
      conflicts: [{ path: input.notePath, reason: 'same-path-base-drift' }],
    });
    expect(outboxStatus(input.env).counts).toMatchObject({ queued: 0, prOpen: 0, conflicted: 1 });
    expect(command('git', [`--git-dir=${input.remoteRoot}`, 'for-each-ref', '--format=%(refname)', 'refs/heads/grill-adapter/wiki']))
      .toBe('');
  });

  it('replays a confirmed batch onto disjoint synchronized base changes', () => {
    const input = fixture();
    stageCapturePlan(input.plan, input.env);
    const review = outboxReview(input.env);
    writeFileSync(path.join(input.worktreeRoot, 'unrelated.txt'), 'upstream\n', 'utf8');
    command('git', ['add', 'unrelated.txt'], input.worktreeRoot);
    command('git', ['commit', '-m', 'disjoint upstream change'], input.worktreeRoot);
    command('git', ['push', 'origin', 'main'], input.worktreeRoot);

    const result = publishOutbox({ planDigest: review.planDigest, confirmed: true }, input.env);

    const branch = result.repositories[0].branch;
    expect(command('git', [`--git-dir=${input.remoteRoot}`, 'diff', '--name-only', `main..${branch}`]))
      .toBe(input.notePath);
    expect(outboxStatus(input.env).counts).toMatchObject({ queued: 0, prOpen: 1 });
  });

  it('resumes after PR creation without creating another PR', () => {
    const input = fixture();
    input.env.FAKE_GH_FAIL_AFTER_CREATE_ONCE = '1';
    stageCapturePlan(input.plan, input.env);
    const review = outboxReview(input.env);

    expect(() => publishOutbox({ planDigest: review.planDigest, confirmed: true }, input.env)).toThrow();
    const result = publishOutbox({ planDigest: review.planDigest, confirmed: true }, input.env);

    expect(result.repositories[0].state).toBe('pr-open');
    const gh = JSON.parse(readFileSync(input.ghState, 'utf8'));
    expect(gh.calls.filter((args: string[]) => args[1] === 'create')).toHaveLength(1);
  });

  it('marks published entries active only after merge and synchronized base verification', () => {
    const input = fixture();
    stageCapturePlan(input.plan, input.env);
    const review = outboxReview(input.env);
    const published = publishOutbox({ planDigest: review.planDigest, confirmed: true }, input.env);
    expect(outboxStatus(input.env).counts).toMatchObject({ prOpen: 1, active: 0 });

    command('git', ['merge', '--ff-only', published.repositories[0].branch], input.worktreeRoot);
    command('git', ['push', 'origin', 'main'], input.worktreeRoot);

    expect(outboxStatus(input.env).counts).toMatchObject({ queued: 0, prOpen: 0, active: 1 });
    expect(readFileSync(path.join(input.worktreeRoot, input.notePath), 'utf8')).toBe(input.updated);
  });

  it('isolates Outbox overlays for projects sharing one registry and Wiki repository', () => {
    const first = fixture('project-one');
    stageCapturePlan(first.plan, first.env);
    const secondProjectDir = path.join(path.dirname(first.projectDir), 'project-two');
    writeJson(path.join(secondProjectDir, '.grill-adapter', 'settings.json'), {
      wiki: {
        provider: 'obsidian',
        publishing: { mode: 'git-pr' },
        obsidian: {
          bindings: [{
            sourceId: 'project', role: 'project', vaultRef: 'knowledge', repositoryRef: 'wiki',
            root: 'Projects/example', access: { read: true, update: 'direct' },
          }],
        },
      },
    });
    const secondJournal = path.join(
      secondProjectDir,
      '.grill-adapter',
      'context',
      'feature-a',
      'wiki-candidates.jsonl',
    );
    mkdirSync(path.dirname(secondJournal), { recursive: true });
    writeFileSync(secondJournal, `${JSON.stringify({
      schemaVersion: 1,
      eventType: 'candidate',
      eventId: 'event-a',
      featureSlug: 'feature-a',
      recordedAt: '2026-08-02T09:00:00Z',
      candidateId: 'candidate-a',
      stage: 'review',
      candidateType: 'wiki_note',
      kind: 'contract',
      claim: 'Second project private candidate.',
      why: 'Project-local refinement.',
      sourceRefs: ['src/contract.ts'],
      taskId: null,
      carveOut: false,
    })}\n`, 'utf8');
    const secondEnv = { ...first.env, CLAUDE_PROJECT_DIR: secondProjectDir };
    const secondSnapshot = consolidationCandidatesTool({ candidateLimit: 200 }, secondEnv);
    const secondDraft = note('Second project draft.', 'Second project private queued marker.');
    stageCapturePlan({
      schemaVersion: 1,
      kind: 'grill-adapter.wiki-capture-plan',
      featureSlug: 'feature-a',
      journalSnapshots: secondSnapshot.journalSnapshots,
      decisions: [{
        candidateIds: ['candidate-a'],
        candidateDigests: [secondSnapshot.candidates[0].candidateDigest],
        outcome: 'queue',
        reason: 'Project-local durable contract.',
        sourceId: 'project',
        operation: 'update',
        path: first.notePath,
        expectedHash: contentHash(first.original),
        content: secondDraft,
      }],
    }, secondEnv);

    expect(outboxStatus(first.env).counts.queued).toBe(1);
    expect(outboxStatus(secondEnv).counts.queued).toBe(1);
    expect(captureDraftView({ paths: [first.notePath] }, first.env).selectedNotes[0].content)
      .toContain('Private queued marker.');
    expect(captureDraftView({ paths: [first.notePath] }, secondEnv).selectedNotes[0].content)
      .toContain('Second project private queued marker.');
    expect(outboxReview(first.env).repositories[0].changes[0].diff)
      .not.toContain('Second project private queued marker.');
  });

  it('resumes one confirmed multi-repository batch after partial PR success', () => {
    const input = fixture();
    const root = path.dirname(input.projectDir);
    const secondWorktree = path.join(root, 'shared-knowledge');
    const secondRemote = path.join(root, 'shared-knowledge.git');
    const secondSource = 'Shared/engineering';
    const secondPath = `${secondSource}/contract.md`;
    const secondOriginal = note('Shared original.', 'Shared base content.', 'shared/example/contract');
    const secondUpdated = note('Shared queued.', 'Shared queued content.', 'shared/example/contract');
    command('git', ['init', '--bare', secondRemote]);
    command('git', ['init', '--initial-branch=main', secondWorktree]);
    command('git', ['config', 'user.name', 'Test User'], secondWorktree);
    command('git', ['config', 'user.email', 'test@example.invalid'], secondWorktree);
    command('git', ['remote', 'add', 'origin', secondRemote], secondWorktree);
    mkdirSync(path.join(secondWorktree, secondSource, '_meta'), { recursive: true });
    writeFileSync(path.join(secondWorktree, secondSource, '_meta', 'wiki-source.md'), [
      '---',
      'wiki_schema: grill-adapter.obsidian-source/v1',
      'wiki_source_id: shared',
      'scope: shared',
      'update_existing: direct',
      'create_note: direct',
      'blocked_terms:',
      '  - PrivateProduct',
      'blocked_patterns:',
      '  - PrivatePattern',
      '---',
      '',
    ].join('\n'), 'utf8');
    writeFileSync(path.join(secondWorktree, secondPath), secondOriginal, 'utf8');
    command('git', ['add', '.'], secondWorktree);
    command('git', ['commit', '-m', 'base'], secondWorktree);
    command('git', ['push', '-u', 'origin', 'main'], secondWorktree);

    const settingsPath = path.join(input.projectDir, '.grill-adapter', 'settings.json');
    const settings = JSON.parse(readFileSync(settingsPath, 'utf8'));
    settings.wiki.obsidian.bindings.push({
      sourceId: 'shared', role: 'shared', vaultRef: 'knowledge', repositoryRef: 'shared-wiki',
      root: secondSource, access: { read: true, update: 'direct' },
    });
    writeJson(settingsPath, settings);
    const registryPath = String(input.env.OBSIDIAN_WIKI_REGISTRY);
    const registry = JSON.parse(readFileSync(registryPath, 'utf8'));
    registry.repositories['shared-wiki'] = {
      worktreeRoot: secondWorktree,
      remote: 'origin',
      expectedRemote: secondRemote,
      baseBranch: 'main',
      syncBeforeResearch: true,
    };
    writeJson(registryPath, registry);
    const journalPath = path.join(
      input.projectDir,
      '.grill-adapter',
      'context',
      'feature-a',
      'wiki-candidates.jsonl',
    );
    const secondCandidate = {
      schemaVersion: 1,
      eventType: 'candidate',
      eventId: 'event-shared',
      featureSlug: 'feature-a',
      recordedAt: '2026-08-02T09:01:00Z',
      candidateId: 'candidate-shared',
      stage: 'review',
      candidateType: 'wiki_note',
      kind: 'contract',
      claim: 'Shared durable contract.',
      why: 'Shared final evidence.',
      sourceRefs: ['src/shared.ts'],
      taskId: null,
      carveOut: false,
    };
    writeFileSync(journalPath, `${readFileSync(journalPath, 'utf8')}${JSON.stringify(secondCandidate)}\n`, 'utf8');
    const snapshot = consolidationCandidatesTool({ candidateLimit: 200 }, input.env);
    const multiRepositoryPlan = {
      schemaVersion: 1,
      kind: 'grill-adapter.wiki-capture-plan',
      featureSlug: 'feature-a',
      journalSnapshots: snapshot.journalSnapshots,
      decisions: [
        {
          ...input.plan.decisions[0],
          candidateDigests: [snapshot.candidates.find((candidate) => candidate.candidateId === 'candidate-a')!.candidateDigest],
        },
        {
          candidateIds: ['candidate-shared'],
          candidateDigests: [snapshot.candidates.find((candidate) => candidate.candidateId === 'candidate-shared')!.candidateDigest],
          outcome: 'queue',
          reason: 'Shared durable contract.',
          sourceId: 'shared',
          operation: 'update',
          path: secondPath,
          expectedHash: contentHash(secondOriginal),
          content: secondUpdated,
        },
      ],
    };
    expect(() => stageCapturePlan({
      ...multiRepositoryPlan,
      decisions: multiRepositoryPlan.decisions.map((decision, index) => (
        index === 1 ? { ...decision, expectedHash: `sha256:${'0'.repeat(64)}` } : decision
      )),
    }, input.env)).toThrow(/Expected hash conflict/);
    expect(outboxStatus(input.env).counts.queued).toBe(0);
    expect(command('git', ['for-each-ref', '--format=%(refname)', 'refs/grill-adapter/outbox'], input.worktreeRoot)).toBe('');
    expect(command('git', ['for-each-ref', '--format=%(refname)', 'refs/grill-adapter/outbox'], secondWorktree)).toBe('');

    stageCapturePlan(multiRepositoryPlan, input.env);
    const review = outboxReview(input.env);
    input.env.FAKE_GH_FAIL_CREATE_NUMBER = '2';

    expect(() => publishOutbox({ planDigest: review.planDigest, confirmed: true }, input.env)).toThrow();
    const resumed = publishOutbox({ planDigest: review.planDigest, confirmed: true }, input.env);

    expect(resumed.repositories).toHaveLength(2);
    expect(resumed.repositories.every((repository) => repository.state === 'pr-open')).toBe(true);
    const gh = JSON.parse(readFileSync(input.ghState, 'utf8'));
    expect(gh.calls.filter((args: string[]) => args[1] === 'create')).toHaveLength(2);
  });
});
