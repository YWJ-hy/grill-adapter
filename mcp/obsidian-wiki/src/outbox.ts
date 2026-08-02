import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  renameSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import * as z from 'zod/v4';
import { resolveBindings, type ResolvedBinding } from './bindings.js';
import { evaluateKnowledgeFreshness, parseAtomicNote } from './note.js';
import { assertPathWithinBinding, normalizeVaultPath } from './retrieval.js';
import { assertSkillCardAvailable, pendingSkillRegistration } from './skill-card.js';
import { consolidationCandidatesTool } from './tools/consolidation-candidates.js';
import { foldCanonicalFeatureJournals } from './journal-fold.js';
import { linkPath } from './tools/graph.js';

const packagedJournalScript = fileURLToPath(new URL('../dist/wiki_candidate_journal.py', import.meta.url));
const sourceJournalScript = fileURLToPath(new URL('../../../scripts/wiki_candidate_journal.py', import.meta.url));

function journalScriptPath(): string {
  return existsSync(packagedJournalScript) ? packagedJournalScript : sourceJournalScript;
}

const HashSchema = z.string().regex(/^sha256:[a-f0-9]{64}$/);
const FeatureSlugSchema = z.string().regex(/^[a-z0-9][a-z0-9._-]*$/);
const JournalSnapshotSchema = z.object({
  featureSlug: FeatureSlugSchema,
  journalDigest: HashSchema,
}).strict();
const QueueDecisionSchema = z.object({
  candidateIds: z.array(z.string().min(1)).min(1),
  candidateDigests: z.array(HashSchema).min(1),
  outcome: z.literal('queue'),
  reason: z.string().min(1).max(1000),
  sourceId: z.string().min(1),
  operation: z.enum(['create', 'update']),
  path: z.string().min(1),
  expectedHash: HashSchema.nullable(),
  content: z.string().min(1),
}).strict().superRefine((decision, context) => {
  if (decision.candidateIds.length !== decision.candidateDigests.length) {
    context.addIssue({ code: 'custom', message: 'candidateIds and candidateDigests must have equal length' });
  }
});
const TerminalDecisionSchema = z.object({
  candidateIds: z.array(z.string().min(1)).min(1),
  candidateDigests: z.array(HashSchema).min(1),
  outcome: z.enum(['skip', 'defer']),
  reason: z.string().min(1).max(1000),
}).strict().superRefine((decision, context) => {
  if (decision.candidateIds.length !== decision.candidateDigests.length) {
    context.addIssue({ code: 'custom', message: 'candidateIds and candidateDigests must have equal length' });
  }
});
export const CapturePlanSchema = z.object({
  schemaVersion: z.literal(1),
  kind: z.literal('grill-adapter.wiki-capture-plan'),
  featureSlug: FeatureSlugSchema,
  journalSnapshots: z.array(JournalSnapshotSchema),
  decisions: z.array(z.discriminatedUnion('outcome', [QueueDecisionSchema, TerminalDecisionSchema])).max(200),
}).strict();

const EntrySchema = z.object({
  entryId: HashSchema,
  planId: HashSchema,
  featureSlug: FeatureSlugSchema,
  contributingFeatureSlugs: z.array(FeatureSlugSchema).optional(),
  candidateIds: z.array(z.string().min(1)).min(1),
  candidateDigests: z.array(HashSchema).min(1),
  repositoryRef: z.string().min(1),
  sourceId: z.string().min(1),
  bindingDigest: z.string().regex(/^[a-f0-9]{64}$/),
  path: z.string().min(1),
  operation: z.enum(['create', 'update']),
  wikiId: z.string().min(1),
  beforeHash: HashSchema.nullable(),
  afterHash: HashSchema,
  baseCommit: z.string().regex(/^[a-f0-9]{40,64}$/),
  objectCommit: z.string().regex(/^[a-f0-9]{40,64}$/),
  authorizationRequired: z.boolean(),
  state: z.enum(['queued', 'pr-open', 'active', 'excluded', 'deferred', 'rejected']),
  supersedes: z.array(HashSchema).optional(),
  correction: z.enum(['exclude', 'defer', 'delete', 'revise', 'merge']).optional(),
  correctionReason: z.string().min(1).max(1000).optional(),
  createdAt: z.string().min(1),
  prUrl: z.string().url().optional(),
}).strict();
const PlanRecordSchema = z.object({
  planId: HashSchema,
  featureSlug: FeatureSlugSchema,
  journalSnapshots: z.array(JournalSnapshotSchema),
  candidateIds: z.array(z.string().min(1)),
  counts: z.object({
    queued: z.number().int().nonnegative(),
    skipped: z.number().int().nonnegative(),
    needsDecision: z.number().int().nonnegative(),
  }).strict(),
  createdAt: z.string().min(1),
}).strict();
const PublishRepositorySchema = z.object({
  repositoryRef: z.string().min(1),
  baseCommit: z.string().regex(/^[a-f0-9]{40,64}$/),
  branch: z.string().min(1),
  commit: z.string().regex(/^[a-f0-9]{40,64}$/).nullable(),
  paths: z.array(z.string().min(1)),
  prUrl: z.string().url().nullable(),
  state: z.enum(['pending', 'pr-open', 'deferred']),
  conflicts: z.array(z.object({
    path: z.string().min(1),
    reason: z.enum(['same-path-base-drift', 'base-identity-drift']),
  }).strict()).optional(),
}).strict();
const PublishRunSchema = z.object({
  runId: HashSchema,
  planDigest: HashSchema,
  createdAt: z.string().min(1),
  repositories: z.array(PublishRepositorySchema).min(1),
}).strict();
const ManifestSchema = z.object({
  schemaVersion: z.literal(1),
  kind: z.literal('grill-adapter.obsidian-wiki-outbox'),
  projectId: z.string().regex(/^[a-f0-9]{64}$/),
  entries: z.array(EntrySchema),
  plans: z.array(PlanRecordSchema),
  publishRuns: z.array(PublishRunSchema).default([]),
}).strict();

type CapturePlan = z.infer<typeof CapturePlanSchema>;
type QueueDecision = z.infer<typeof QueueDecisionSchema>;
type Entry = z.infer<typeof EntrySchema>;
type Manifest = z.infer<typeof ManifestSchema>;
type PublishRun = z.infer<typeof PublishRunSchema>;

const TerminalCorrectionSchema = z.object({
  action: z.enum(['exclude', 'defer', 'delete']),
  entryIds: z.array(HashSchema).min(1),
  reason: z.string().min(1).max(1000),
}).strict();
const ReviseCorrectionSchema = z.object({
  action: z.literal('revise'),
  entryId: HashSchema,
  content: z.string().min(1),
  reason: z.string().min(1).max(1000),
}).strict();
const MergeCorrectionSchema = z.object({
  action: z.literal('merge'),
  entryIds: z.array(HashSchema).min(2),
  targetEntryId: HashSchema,
  content: z.string().min(1),
  reason: z.string().min(1).max(1000),
}).strict();
export const OutboxCorrectionSchema = z.discriminatedUnion('action', [
  TerminalCorrectionSchema,
  ReviseCorrectionSchema,
  MergeCorrectionSchema,
]);
type StagedRepository = {
  entries: Entry[];
  binding: ResolvedBinding;
  ref: string;
  previousHead: string;
  commit: string;
};

function runCommand(
  executable: string,
  args: string[],
  env: NodeJS.ProcessEnv,
  workingDirectory?: string,
): string {
  try {
    return String(execFileSync(executable, args, {
      cwd: workingDirectory,
      env,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
    })).trim();
  } catch (error) {
    const detail = error && typeof error === 'object' && 'stderr' in error
      ? String((error as { stderr?: Buffer | string }).stderr ?? '').trim()
      : '';
    throw new Error(`${executable} ${args.join(' ')} failed${detail ? `: ${detail}` : ''}`);
  }
}

function git(args: string[], env: NodeJS.ProcessEnv, workingDirectory: string): string {
  return runCommand('git', args, env, workingDirectory);
}

function digest(value: string | Buffer): string {
  return `sha256:${createHash('sha256').update(value).digest('hex')}`;
}

function projectId(projectDir: string): string {
  return createHash('sha256').update(realpathSync(projectDir), 'utf8').digest('hex');
}

function stableJson(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(stableJson).join(',')}]`;
  if (value !== null && typeof value === 'object') {
    const record = value as Record<string, unknown>;
    return `{${Object.keys(record).sort().map((key) => `${JSON.stringify(key)}:${stableJson(record[key])}`).join(',')}}`;
  }
  return JSON.stringify(value);
}

function statePaths(resolution: ReturnType<typeof resolveBindings>) {
  const id = projectId(resolution.projectDir);
  const root = path.join(path.dirname(resolution.registryPath), 'outbox', 'v1', id);
  return { id, root, manifest: path.join(root, 'manifest.json') };
}

function emptyManifest(id: string): Manifest {
  return {
    schemaVersion: 1,
    kind: 'grill-adapter.obsidian-wiki-outbox',
    projectId: id,
    entries: [],
    plans: [],
    publishRuns: [],
  };
}

function readManifest(resolution: ReturnType<typeof resolveBindings>): Manifest {
  const state = statePaths(resolution);
  if (!existsSync(state.manifest)) return emptyManifest(state.id);
  const manifest = ManifestSchema.parse(JSON.parse(readFileSync(state.manifest, 'utf8')));
  if (manifest.projectId !== state.id) throw new Error('Outbox project identity drift');
  return manifest;
}

function writeManifest(resolution: ReturnType<typeof resolveBindings>, manifest: Manifest): void {
  const state = statePaths(resolution);
  mkdirSync(state.root, { recursive: true });
  const temporary = `${state.manifest}.tmp-${process.pid}`;
  writeFileSync(temporary, `${JSON.stringify(manifest, null, 2)}\n`, { encoding: 'utf8', flag: 'wx' });
  renameSync(temporary, state.manifest);
}

function safeRefSegment(value: string): string {
  const segment = value.toLowerCase().replace(/[^a-z0-9._-]+/g, '-').replace(/^-+|-+$/g, '');
  if (!segment) throw new Error(`repositoryRef cannot form an Outbox ref segment: ${value}`);
  return segment;
}

function hiddenRef(id: string, repositoryRef: string): string {
  return `refs/grill-adapter/outbox/${id}/${safeRefSegment(repositoryRef)}`;
}

function gitFile(revision: string, notePath: string, env: NodeJS.ProcessEnv, workingDirectory: string): string | undefined {
  try {
    return String(execFileSync('git', ['show', `${revision}:${notePath}`], {
      cwd: workingDirectory,
      env,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
    }));
  } catch {
    return undefined;
  }
}

type RevisionNote = {
  binding: ResolvedBinding;
  path: string;
  note: ReturnType<typeof parseAtomicNote>;
};

function boundRevisionNotes(
  bindings: ResolvedBinding[],
  overlayBinding: ResolvedBinding,
  overlayCommit: string,
  env: NodeJS.ProcessEnv,
): RevisionNote[] {
  const notes: RevisionNote[] = [];
  for (const binding of bindings) {
    if (binding.effectiveReadPolicy !== 'allow') continue;
    const sameRepository = realpathSync(binding.repository.worktreeRoot)
      === realpathSync(overlayBinding.repository.worktreeRoot);
    const revision = sameRepository ? overlayCommit : binding.repository.baseBranch;
    const tracked = git(
      ['ls-tree', '-r', '--name-only', '-z', revision, '--', `:(literal)${binding.root}`],
      env,
      binding.repository.worktreeRoot,
    ).split('\0').filter(Boolean);
    for (const trackedPath of tracked) {
      const notePath = normalizeVaultPath(trackedPath);
      if (!notePath.endsWith('.md')) continue;
      if (notePath === `${binding.root}/_meta` || notePath.startsWith(`${binding.root}/_meta/`)) continue;
      const contents = gitFile(revision, notePath, env, binding.repository.worktreeRoot);
      if (!contents || !/^wiki_schema:\s*grill-adapter\.obsidian-note\/v1\s*$/m.test(contents)) continue;
      notes.push({ binding, path: notePath, note: parseAtomicNote(contents, notePath) });
    }
  }
  return notes;
}

function enforceNeutrality(binding: ResolvedBinding, notePath: string, content: string): void {
  if (binding.role !== 'shared') return;
  const candidate = `${notePath}\n${content}`;
  const violations: string[] = [];
  for (const term of binding.manifest.blockedTerms) {
    if (term && candidate.includes(term)) violations.push(`blocked term ${JSON.stringify(term)}`);
  }
  for (const source of binding.manifest.blockedPatterns) {
    if (source && new RegExp(source).test(candidate)) violations.push(`blocked pattern ${JSON.stringify(source)}`);
  }
  if (violations.length > 0) throw new Error(`Shared Source neutrality validation failed: ${violations.join('; ')}`);
}

function validateSnapshot(plan: CapturePlan, env: NodeJS.ProcessEnv): void {
  const input = consolidationCandidatesTool({ candidateLimit: 200 }, env);
  if (input.truncated) throw new Error('Capture input exceeds the bounded 200-candidate staging limit');
  const expectedSnapshots = [...input.journalSnapshots]
    .sort((left, right) => left.featureSlug.localeCompare(right.featureSlug, 'en'));
  const actualSnapshots = [...plan.journalSnapshots]
    .sort((left, right) => left.featureSlug.localeCompare(right.featureSlug, 'en'));
  if (stableJson(actualSnapshots) !== stableJson(expectedSnapshots)) {
    throw new Error('Capture Plan journal snapshot drift');
  }
  const candidates = new Map(input.candidates.map((candidate) => (
    [`${candidate.featureSlug}\n${candidate.candidateId}`, candidate]
  )));
  const used = new Set<string>();
  for (const decision of plan.decisions) {
    for (let index = 0; index < decision.candidateIds.length; index += 1) {
      const candidateId = decision.candidateIds[index];
      const key = `${plan.featureSlug}\n${candidateId}`;
      const candidate = candidates.get(key);
      if (!candidate || candidate.candidateDigest !== decision.candidateDigests[index]) {
        throw new Error(`Capture Plan candidate snapshot drift: ${candidateId}`);
      }
      if (used.has(key)) throw new Error(`Capture Plan candidate appears in more than one decision: ${candidateId}`);
      used.add(key);
    }
  }
  const expected = input.candidates
    .filter((candidate) => candidate.featureSlug === plan.featureSlug)
    .map((candidate) => `${candidate.featureSlug}\n${candidate.candidateId}`)
    .sort();
  const actual = [...used].sort();
  if (stableJson(actual) !== stableJson(expected)) {
    throw new Error(`Capture Plan must cover every unresolved candidate for ${plan.featureSlug} exactly once`);
  }
}

function withFileLock<T>(lockPath: string, callback: () => T): T {
  mkdirSync(path.dirname(lockPath), { recursive: true });
  try {
    writeFileSync(lockPath, `${process.pid}\n`, { encoding: 'utf8', flag: 'wx' });
  } catch (error) {
    let ownerIsActive = true;
    try {
      const owner = Number.parseInt(readFileSync(lockPath, 'utf8').trim(), 10);
      if (!Number.isSafeInteger(owner) || owner <= 0) {
        ownerIsActive = false;
      } else {
        process.kill(owner, 0);
      }
    } catch (ownerError) {
      ownerIsActive = Boolean(
        ownerError && typeof ownerError === 'object' && 'code' in ownerError
        && (ownerError as NodeJS.ErrnoException).code === 'EPERM',
      );
    }
    if (ownerIsActive) throw error;
    rmSync(lockPath, { force: true });
    writeFileSync(lockPath, `${process.pid}\n`, { encoding: 'utf8', flag: 'wx' });
  }
  try {
    return callback();
  } finally {
    rmSync(lockPath, { force: true });
  }
}

function withOutboxLock<T>(
  resolution: ReturnType<typeof resolveBindings>,
  callback: () => T,
): T {
  return withFileLock(path.join(statePaths(resolution).root, 'outbox.lock'), callback);
}

function withRepositoryLock<T>(
  resolution: ReturnType<typeof resolveBindings>,
  binding: ResolvedBinding,
  callback: () => T,
): T {
  const lockRoot = path.join(path.dirname(resolution.registryPath), 'outbox', 'locks');
  const lockId = createHash('sha256').update(realpathSync(binding.repository.worktreeRoot), 'utf8').digest('hex');
  const lockPath = path.join(lockRoot, `${lockId}.lock`);
  return withFileLock(lockPath, callback);
}

function validateQueuedChange(
  decision: QueueDecision,
  binding: ResolvedBinding,
  parentCommit: string,
  projectDir: string,
  allBindings: ResolvedBinding[],
  overlayEntries: Entry[],
  env: NodeJS.ProcessEnv,
) {
  const notePath = assertPathWithinBinding(decision.path, binding);
  const proposed = parseAtomicNote(decision.content, notePath);
  if (evaluateKnowledgeFreshness(proposed).state === 'expired') {
    throw new Error(`Queued Note is already expired: ${notePath}`);
  }
  assertSkillCardAvailable(proposed, projectDir, { mode: 'write' });
  enforceNeutrality(binding, notePath, proposed.content);
  const overlayIdentityMatches = overlayEntries.filter((entry) => (
    entry.wikiId === proposed.wikiId && (entry.path !== notePath || entry.sourceId !== binding.sourceId)
  ));
  const revisionNotes = boundRevisionNotes(allBindings, binding, parentCommit, env);
  const identityMatches = revisionNotes.filter(({ note }) => note.wikiId === proposed.wikiId);
  if (overlayIdentityMatches.length > 0) {
    throw new Error(`Queued wiki_id already exists at another Outbox target: ${proposed.wikiId}`);
  }
  const existing = gitFile(parentCommit, notePath, env, binding.repository.worktreeRoot);
  if (decision.operation === 'create') {
    if (decision.expectedHash !== null) throw new Error('Creating a queued Note requires expectedHash: null');
    if (existing !== undefined) throw new Error(`Queued create path already exists in the project Outbox overlay: ${notePath}`);
    if (identityMatches.length > 0) throw new Error(`Queued wiki_id already exists in formal base or project overlay: ${proposed.wikiId}`);
  } else {
    if (!existing) throw new Error(`Queued update path does not exist in the project Outbox overlay: ${notePath}`);
    const parsedExisting = parseAtomicNote(existing, notePath);
    if (parsedExisting.contentHash !== decision.expectedHash) {
      throw new Error(`Expected hash conflict for queued Note ${notePath}`);
    }
    if (parsedExisting.wikiId !== proposed.wikiId) {
      throw new Error(`Queued Note wiki_id must preserve existing identity ${parsedExisting.wikiId}`);
    }
    if (
      identityMatches.length !== 1
      || identityMatches[0].path !== notePath
      || identityMatches[0].binding.sourceId !== binding.sourceId
    ) {
      throw new Error(`Queued wiki_id does not resolve uniquely to its project overlay target: ${proposed.wikiId}`);
    }
    if (parsedExisting.adrSourceId && parsedExisting.adrSourceId !== proposed.adrSourceId) {
      throw new Error(`Queued ADR projection must preserve authority identity for ${notePath}`);
    }
    if (parsedExisting.skillName && parsedExisting.skillName !== proposed.skillName) {
      throw new Error(`Queued Skill Card must preserve skill identity for ${notePath}`);
    }
  }
  if (proposed.adrSourceId && binding.role !== 'project') {
    throw new Error('Queued ADR execution projections may only target a project Source');
  }
  const conflictingAdr = revisionNotes.filter(({ note, path: candidatePath, binding: candidateBinding }) => (
    proposed.adrSourceId
    && note.adrSourceId === proposed.adrSourceId
    && (candidatePath !== notePath || candidateBinding.sourceId !== binding.sourceId)
  ));
  if (conflictingAdr.length > 0) {
    throw new Error(`Queued ADR source identity already exists in another bound Note: ${proposed.adrSourceId}`);
  }
  const conflictingSkillCards = revisionNotes.filter(({ note, path: candidatePath, binding: candidateBinding }) => (
    proposed.skillName
    && note.skillName === proposed.skillName
    && (candidatePath !== notePath || candidateBinding.sourceId !== binding.sourceId)
  ));
  if (conflictingSkillCards.length > 0) {
    throw new Error(`Queued Skill Card identity already exists in another bound Note: ${proposed.skillName}`);
  }
  const overlayPaths = new Set(overlayEntries.map((entry) => entry.path));
  for (const links of Object.values(proposed.edges)) {
    for (const link of links) {
      const target = linkPath(link);
      if (overlayPaths.has(target)) continue;
      const targets = revisionNotes.filter((candidate) => candidate.path === target);
      if (targets.length !== 1) {
        throw new Error(`Queued Note typed edge ${link} is invalid: target resolved ${targets.length} bound Notes`);
      }
    }
  }
  const policy = decision.operation === 'create'
    ? binding.effectiveCreatePolicy
    : binding.effectiveUpdatePolicy;
  const rootAuthorization = decision.operation === 'create'
    ? binding.rootCreateAuthorization
    : binding.rootUpdateAuthorization;
  if (policy === 'deny' || rootAuthorization === 'refuse') {
    throw new Error(`Obsidian Wiki policy refuses ${decision.operation} operations`);
  }
  return {
    notePath,
    proposed,
    beforeHash: existing ? parseAtomicNote(existing, notePath).contentHash : null,
    authorizationRequired: policy === 'confirm' || rootAuthorization === 'ask',
  };
}

function stageRepository(
  plan: CapturePlan,
  planId: string,
  decisions: QueueDecision[],
  binding: ResolvedBinding,
  resolution: ReturnType<typeof resolveBindings>,
  manifest: Manifest,
  env: NodeJS.ProcessEnv,
): StagedRepository {
  return withRepositoryLock(resolution, binding, () => {
    const ref = hiddenRef(manifest.projectId, binding.repositoryRef);
    const recordedHead = [...manifest.entries]
      .reverse()
      .find((entry) => entry.repositoryRef === binding.repositoryRef)?.objectCommit;
    const refHead = git(['for-each-ref', '--format=%(objectname)', ref], env, binding.repository.worktreeRoot);
    const baseCommit = git(['rev-parse', binding.repository.baseBranch], env, binding.repository.worktreeRoot);
    const expectedParent = recordedHead || baseCommit;
    if ((recordedHead ?? '') !== refHead) {
      const subject = git(['show', '-s', '--format=%s', refHead], env, binding.repository.worktreeRoot);
      const actualParent = git(['rev-parse', `${refHead}^`], env, binding.repository.worktreeRoot);
      if (subject !== `grill-adapter outbox ${planId}` || actualParent !== expectedParent) {
        throw new Error(`Outbox hidden ref drift for ${binding.repositoryRef}`);
      }
      const priorEntries = effectiveEntries(manifest);
      const entries = decisions.map((decision) => {
        const validated = validateQueuedChange(
          decision,
          binding,
          expectedParent,
          resolution.projectDir,
          resolution.bindings,
          priorEntries,
          env,
        );
        const recovered = gitFile(refHead, validated.notePath, env, binding.repository.worktreeRoot);
        if (!recovered || parseAtomicNote(recovered, validated.notePath).contentHash !== validated.proposed.contentHash) {
          throw new Error(`Interrupted Outbox object does not match Capture Plan for ${validated.notePath}`);
        }
        return {
          entryId: digest(`${planId}\0${binding.repositoryRef}\0${validated.notePath}\0${validated.proposed.contentHash}`),
          planId,
          featureSlug: plan.featureSlug,
          candidateIds: decision.candidateIds,
          candidateDigests: decision.candidateDigests,
          repositoryRef: binding.repositoryRef,
          sourceId: binding.sourceId,
          bindingDigest: binding.bindingDigest,
          path: validated.notePath,
          operation: decision.operation,
          wikiId: validated.proposed.wikiId,
          beforeHash: validated.beforeHash,
          afterHash: validated.proposed.contentHash,
          baseCommit,
          objectCommit: refHead,
          authorizationRequired: validated.authorizationRequired,
          state: 'queued' as const,
          createdAt: new Date().toISOString(),
        };
      });
      const expectedPaths = entries.map((entry) => entry.path).sort();
      if (!samePaths(revisionPaths(expectedParent, refHead, env, binding.repository.worktreeRoot), expectedPaths)) {
        throw new Error(`Interrupted Outbox object path scope does not match Capture Plan for ${binding.repositoryRef}`);
      }
      return { entries, binding, ref, previousHead: expectedParent === baseCommit ? '' : expectedParent, commit: refHead };
    }
    const parentCommit = refHead || baseCommit;
    const temporaryRoot = mkdtempSync(path.join(tmpdir(), 'grill-adapter-outbox-'));
    const entries: Entry[] = [];
    const priorEntries = effectiveEntries(manifest);
    const decisionPaths = decisions.map((decision) => normalizeVaultPath(decision.path));
    if (new Set(decisionPaths).size !== decisionPaths.length) {
      throw new Error(`Capture Plan has duplicate final paths for ${binding.repositoryRef}`);
    }
    try {
      git(['worktree', 'add', '--quiet', '--detach', temporaryRoot, parentCommit], env, binding.repository.worktreeRoot);
      for (const decision of decisions) {
        const validated = validateQueuedChange(
          decision,
          binding,
          parentCommit,
          resolution.projectDir,
          resolution.bindings,
          [...priorEntries, ...entries],
          env,
        );
        const target = path.join(temporaryRoot, ...validated.notePath.split('/'));
        mkdirSync(path.dirname(target), { recursive: true });
        writeFileSync(target, validated.proposed.content, 'utf8');
        entries.push({
          entryId: digest(`${planId}\0${binding.repositoryRef}\0${validated.notePath}\0${validated.proposed.contentHash}`),
          planId,
          featureSlug: plan.featureSlug,
          candidateIds: decision.candidateIds,
          candidateDigests: decision.candidateDigests,
          repositoryRef: binding.repositoryRef,
          sourceId: binding.sourceId,
          bindingDigest: binding.bindingDigest,
          path: validated.notePath,
          operation: decision.operation,
          wikiId: validated.proposed.wikiId,
          beforeHash: validated.beforeHash,
          afterHash: validated.proposed.contentHash,
          baseCommit,
          objectCommit: parentCommit,
          authorizationRequired: validated.authorizationRequired,
          state: 'queued',
          createdAt: new Date().toISOString(),
        });
      }
      git(['add', '--', ...entries.map((entry) => entry.path)], env, temporaryRoot);
      const tree = git(['write-tree'], env, temporaryRoot);
      const commit = git(['commit-tree', tree, '-p', parentCommit, '-m', `grill-adapter outbox ${planId}`], env, temporaryRoot);
      git(['update-ref', ref, commit, refHead || '0'.repeat(commit.length)], env, binding.repository.worktreeRoot);
      for (const entry of entries) entry.objectCommit = commit;
      return { entries, binding, ref, previousHead: refHead, commit };
    } finally {
      try {
        git(['worktree', 'remove', '--force', temporaryRoot], env, binding.repository.worktreeRoot);
      } catch {
        rmSync(temporaryRoot, { recursive: true, force: true });
      }
    }
  });
}

function rollbackStagedRepository(
  staged: StagedRepository,
  resolution: ReturnType<typeof resolveBindings>,
  env: NodeJS.ProcessEnv,
): void {
  withRepositoryLock(resolution, staged.binding, () => {
    if (staged.previousHead) {
      git(
        ['update-ref', staged.ref, staged.previousHead, staged.commit],
        env,
        staged.binding.repository.worktreeRoot,
      );
    } else {
      git(
        ['update-ref', '-d', staged.ref, staged.commit],
        env,
        staged.binding.repository.worktreeRoot,
      );
    }
  });
}

function healthyResolution(env: NodeJS.ProcessEnv) {
  const resolution = resolveBindings(env);
  if (resolution.errors.length > 0) {
    throw new Error(`Obsidian Wiki Source bindings are unhealthy: ${resolution.errors.join('; ')}`);
  }
  return resolution;
}

function recordPlanOutcomes(
  plan: CapturePlan,
  planId: string,
  manifest: Manifest,
  resolution: ReturnType<typeof resolveBindings>,
  env: NodeJS.ProcessEnv,
): void {
  const journal = foldCanonicalFeatureJournals(resolution.projectDir, env)
    .find((candidate) => candidate.featureSlug === plan.featureSlug);
  if (!journal) {
    if (plan.decisions.length === 0) return;
    throw new Error(`Capture Plan feature journal is unavailable: ${plan.featureSlug}`);
  }
  const candidates = new Map(journal.candidates.map((candidate) => [candidate.candidateId, candidate]));
  const journalPath = path.join(
    resolution.projectDir,
    '.grill-adapter',
    'context',
    plan.featureSlug,
    'wiki-candidates.jsonl',
  );
  const python = env.OBSIDIAN_WIKI_PYTHON ?? 'python3';
  for (const decision of plan.decisions) {
    for (const candidateId of decision.candidateIds) {
      const candidate = candidates.get(candidateId);
      if (!candidate) throw new Error(`Capture Plan candidate disappeared before outcome recording: ${candidateId}`);
      const eventId = `outbox-${planId.slice(7, 23)}-${createHash('sha256').update(candidateId).digest('hex').slice(0, 16)}`;
      if (candidate.lastEventId === eventId) continue;
      if (candidate.status === 'kept' || candidate.status === 'skipped' || candidate.status === 'superseded') {
        continue;
      }
      const args = [
        journalScriptPath(),
        'outcome',
        '--journal', journalPath,
        '--feature-slug', plan.featureSlug,
        '--event-id', eventId,
        '--candidate-id', candidateId,
        '--status', decision.outcome === 'queue' ? 'kept' : decision.outcome === 'skip' ? 'skipped' : 'deferred',
        '--reason', decision.reason,
      ];
      if (decision.outcome === 'queue') {
        const entry = manifest.entries.find((item) => (
          item.planId === planId && item.candidateIds.includes(candidateId)
        ));
        if (!entry) throw new Error(`Queued Capture candidate has no immutable Outbox entry: ${candidateId}`);
        const binding = resolution.bindings.find((item) => (
          item.repositoryRef === entry.repositoryRef && item.sourceId === entry.sourceId
        ));
        if (!binding) throw new Error(`Queued Capture candidate references an unbound Source: ${candidateId}`);
        const contents = gitFile(entry.objectCommit, entry.path, env, binding.repository.worktreeRoot);
        if (!contents) throw new Error(`Queued Capture object is missing ${entry.path}`);
        const note = parseAtomicNote(contents, entry.path);
        args.push(
          '--write-state', 'queued',
          '--operation', entry.operation,
          '--source-id', entry.sourceId,
          '--repository-ref', entry.repositoryRef,
          '--binding-digest', entry.bindingDigest,
          '--wiki-id', entry.wikiId,
          '--path', entry.path,
          '--after-hash', entry.afterHash,
        );
        if (entry.beforeHash !== null) args.push('--before-hash', entry.beforeHash);
        const registration = pendingSkillRegistration(note);
        if (registration) {
          args.push(
            '--skill-name', registration.name,
            '--skill-version', registration.version,
            '--skill-contract-hash', registration.contractHash,
            '--skill-summary', registration.summary,
          );
          for (const role of registration.roles) args.push('--skill-role', role);
          for (const trigger of registration.triggers) args.push('--skill-trigger', trigger);
        }
        if (note.adrSourceId) {
          args.push(
            '--adr-authority-type', 'project-adr',
            '--adr-projection-type', 'execution-constraints',
            '--adr-source-id', note.adrSourceId,
            '--adr-source-path', note.adrSourcePath!,
            '--adr-source-content-hash', note.adrSourceContentHash!,
            '--adr-target-scope', 'project',
          );
        }
      }
      runCommand(python, args, env, resolution.projectDir);
      candidate.status = decision.outcome === 'queue' ? 'kept' : decision.outcome === 'skip' ? 'skipped' : 'deferred';
      candidate.lastEventId = eventId;
    }
  }
}

function stageCapturePlanLocked(
  input: unknown,
  resolution: ReturnType<typeof resolveBindings>,
  env: NodeJS.ProcessEnv,
) {
  const plan = CapturePlanSchema.parse(input);
  const manifest = readManifest(resolution);
  const planId = digest(stableJson(plan));
  const existing = manifest.plans.find((candidate) => candidate.planId === planId);
  if (existing) {
    recordPlanOutcomes(plan, planId, manifest, resolution, env);
    return { status: 'ok' as const, planId, counts: existing.counts, caveats: [] as string[] };
  }
  validateSnapshot(plan, env);

  const alreadyHandled = new Set(manifest.plans.flatMap((record) => (
    record.candidateIds.map((candidateId) => `${record.featureSlug}\n${candidateId}`)
  )));
  for (const candidateId of plan.decisions.flatMap((decision) => decision.candidateIds)) {
    if (alreadyHandled.has(`${plan.featureSlug}\n${candidateId}`)) {
      throw new Error(`Capture candidate is already represented by an Outbox plan: ${candidateId}`);
    }
  }
  const queued = plan.decisions.filter((decision): decision is QueueDecision => decision.outcome === 'queue');
  const byRepository = new Map<string, { binding: ResolvedBinding; decisions: QueueDecision[] }>();
  for (const decision of queued) {
    const binding = resolution.bindings.find((candidate) => candidate.sourceId === decision.sourceId);
    if (!binding) throw new Error(`Capture Plan references an unbound Source: ${decision.sourceId}`);
    const group = byRepository.get(binding.repositoryRef) ?? { binding, decisions: [] };
    group.decisions.push(decision);
    byRepository.set(binding.repositoryRef, group);
  }
  const counts = {
    queued: queued.length,
    skipped: plan.decisions.filter((decision) => decision.outcome === 'skip').length,
    needsDecision: plan.decisions.filter((decision) => decision.outcome === 'defer').length,
  };
  const stagedRepositories: StagedRepository[] = [];
  try {
    for (const group of byRepository.values()) {
      const staged = stageRepository(plan, planId, group.decisions, group.binding, resolution, manifest, env);
      stagedRepositories.push(staged);
      manifest.entries.push(...staged.entries);
    }
    manifest.plans.push({
      planId,
      featureSlug: plan.featureSlug,
      journalSnapshots: plan.journalSnapshots,
      candidateIds: plan.decisions.flatMap((decision) => decision.candidateIds),
      counts,
      createdAt: new Date().toISOString(),
    });
    writeManifest(resolution, manifest);
  } catch (error) {
    const rollbackErrors: string[] = [];
    for (const staged of [...stagedRepositories].reverse()) {
      try {
        rollbackStagedRepository(staged, resolution, env);
      } catch (rollbackError) {
        rollbackErrors.push(rollbackError instanceof Error ? rollbackError.message : String(rollbackError));
      }
    }
    if (rollbackErrors.length > 0) {
      throw new Error(
        `Outbox staging failed and hidden-ref rollback was incomplete: ${rollbackErrors.join('; ')}`,
        { cause: error },
      );
    }
    throw error;
  }
  recordPlanOutcomes(plan, planId, manifest, resolution, env);
  return { status: 'ok' as const, planId, counts, caveats: [] as string[] };
}

export function stageCapturePlan(input: unknown, env: NodeJS.ProcessEnv = process.env) {
  const resolution = healthyResolution(env);
  return withOutboxLock(resolution, () => stageCapturePlanLocked(input, resolution, env));
}

function effectiveEntries(manifest: Manifest): Entry[] {
  const superseded = new Set(manifest.entries.flatMap((entry) => entry.supersedes ?? []));
  const latest = new Map<string, Entry>();
  for (const entry of manifest.entries) {
    if (!superseded.has(entry.entryId)) latest.set(`${entry.repositoryRef}\n${entry.path}`, entry);
  }
  return [...latest.values()].sort((left, right) => (
    `${left.repositoryRef}\n${left.path}`.localeCompare(`${right.repositoryRef}\n${right.path}`, 'en')
  ));
}

function currentCorrectionTargets(manifest: Manifest, entryIds: string[]): Entry[] {
  if (new Set(entryIds).size !== entryIds.length) throw new Error('Outbox correction entryIds must be unique');
  const current = new Map(effectiveEntries(manifest).map((entry) => [entry.entryId, entry]));
  return entryIds.map((entryId) => {
    const entry = current.get(entryId);
    if (!entry) throw new Error(`Outbox correction target is not a current entry: ${entryId}`);
    if (entry.state === 'pr-open' || entry.state === 'active') {
      throw new Error(`Outbox correction cannot change ${entry.state} entry ${entryId}`);
    }
    return entry;
  });
}

function terminalCorrectionEntry(
  target: Entry,
  planId: string,
  action: 'exclude' | 'defer' | 'delete',
  reason: string,
): Entry {
  return {
    ...target,
    entryId: digest(`${planId}\0${target.entryId}`),
    planId,
    state: action === 'exclude' ? 'excluded' : action === 'defer' ? 'deferred' : 'rejected',
    supersedes: [target.entryId],
    correction: action,
    correctionReason: reason,
    createdAt: new Date().toISOString(),
    prUrl: undefined,
  };
}

function correctOutboxLocked(
  input: unknown,
  resolution: ReturnType<typeof resolveBindings>,
  env: NodeJS.ProcessEnv,
) {
  const request = OutboxCorrectionSchema.parse(input);
  const manifest = readManifest(resolution);
  const correctionId = digest(stableJson(request));
  const prior = manifest.entries.filter((entry) => entry.planId === correctionId && entry.correction !== undefined);
  if (prior.length > 0) {
    return {
      schemaVersion: 1 as const,
      kind: 'grill-adapter.obsidian-wiki-outbox-correction' as const,
      correctionId,
      action: request.action,
      entryIds: prior.map((entry) => entry.entryId),
    };
  }

  if (request.action !== 'revise' && request.action !== 'merge') {
    const targets = currentCorrectionTargets(manifest, request.entryIds);
    const entries = targets.map((target) => terminalCorrectionEntry(target, correctionId, request.action, request.reason));
    manifest.entries.push(...entries);
    writeManifest(resolution, manifest);
    return {
      schemaVersion: 1 as const,
      kind: 'grill-adapter.obsidian-wiki-outbox-correction' as const,
      correctionId,
      action: request.action,
      entryIds: entries.map((entry) => entry.entryId),
    };
  }

  const requestedIds = request.action === 'merge' ? request.entryIds : [request.entryId];
  const targets = currentCorrectionTargets(manifest, requestedIds);
  const target = request.action === 'merge'
    ? targets.find((entry) => entry.entryId === request.targetEntryId)
    : targets[0];
  if (!target) throw new Error('Outbox merge targetEntryId must be included in entryIds');
  if (targets.some((entry) => entry.repositoryRef !== target.repositoryRef || entry.sourceId !== target.sourceId)) {
    throw new Error('Outbox merge corrections must remain within one repository and Source');
  }
  const binding = resolution.bindings.find((candidate) => (
    candidate.repositoryRef === target.repositoryRef && candidate.sourceId === target.sourceId
  ));
  if (!binding) throw new Error(`Outbox correction references an unbound Source: ${target.sourceId}`);
  const candidateIds = [...new Set(targets.flatMap((entry) => entry.candidateIds))];
  const digestByCandidate = new Map<string, string>();
  for (const entry of targets) {
    entry.candidateIds.forEach((candidateId, index) => digestByCandidate.set(candidateId, entry.candidateDigests[index]));
  }
  const decision: QueueDecision = {
    candidateIds,
    candidateDigests: candidateIds.map((candidateId) => digestByCandidate.get(candidateId)!),
    outcome: 'queue',
    reason: request.reason,
    sourceId: target.sourceId,
    operation: 'update',
    path: target.path,
    expectedHash: target.afterHash,
    content: request.content,
  };
  const correctionPlan: CapturePlan = {
    schemaVersion: 1,
    kind: 'grill-adapter.wiki-capture-plan',
    featureSlug: target.featureSlug,
    journalSnapshots: [],
    decisions: [decision],
  };
  const staged = stageRepository(
    correctionPlan,
    correctionId,
    [decision],
    binding,
    resolution,
    manifest,
    env,
  );
  const revised = staged.entries[0];
  revised.candidateIds = candidateIds;
  revised.candidateDigests = decision.candidateDigests;
  revised.contributingFeatureSlugs = [...new Set(targets.flatMap((entry) => (
    entry.contributingFeatureSlugs ?? [entry.featureSlug]
  )))].sort();
  revised.supersedes = targets.map((entry) => entry.entryId);
  revised.correction = request.action;
  revised.correctionReason = request.reason;
  const tombstones = request.action === 'merge'
    ? targets.filter((entry) => entry.entryId !== target.entryId).map((entry) => (
      terminalCorrectionEntry(entry, correctionId, 'delete', request.reason)
    ))
    : [];
  manifest.entries.push(revised, ...tombstones);
  try {
    writeManifest(resolution, manifest);
  } catch (error) {
    rollbackStagedRepository(staged, resolution, env);
    throw error;
  }
  return {
    schemaVersion: 1 as const,
    kind: 'grill-adapter.obsidian-wiki-outbox-correction' as const,
    correctionId,
    action: request.action,
    entryIds: [revised.entryId, ...tombstones.map((entry) => entry.entryId)],
  };
}

export function correctOutbox(input: unknown, env: NodeJS.ProcessEnv = process.env) {
  const resolution = healthyResolution(env);
  return withOutboxLock(resolution, () => correctOutboxLocked(input, resolution, env));
}

function outboxStatusLocked(
  resolution: ReturnType<typeof resolveBindings>,
  env: NodeJS.ProcessEnv,
) {
  const manifest = readManifest(resolution);
  let changed = false;
  for (const entry of manifest.entries) {
    if (entry.state !== 'pr-open') continue;
    const binding = resolution.bindings.find((candidate) => (
      candidate.repositoryRef === entry.repositoryRef && candidate.sourceId === entry.sourceId
    ));
    if (!binding || !binding.repositoryHealth.baseSynchronized) continue;
    const active = gitFile(binding.repository.baseBranch, entry.path, env, binding.repository.worktreeRoot);
    if (!active) continue;
    const note = parseAtomicNote(active, entry.path);
    if (note.wikiId === entry.wikiId && note.contentHash === entry.afterHash) {
      entry.state = 'active';
      changed = true;
    }
  }
  if (changed) writeManifest(resolution, manifest);
  const entries = effectiveEntries(manifest);
  return {
    schemaVersion: 1 as const,
    kind: 'grill-adapter.obsidian-wiki-outbox-status' as const,
    authoritative: false as const,
    counts: {
      queued: entries.filter((entry) => entry.state === 'queued').length,
      prOpen: entries.filter((entry) => entry.state === 'pr-open').length,
      active: entries.filter((entry) => entry.state === 'active').length,
      conflicted: entries.filter((entry) => entry.state === 'deferred').length,
    },
    repositories: [...new Set(entries.map((entry) => entry.repositoryRef))].sort().map((repositoryRef) => ({
      repositoryRef,
      queued: entries.filter((entry) => entry.repositoryRef === repositoryRef && entry.state === 'queued').length,
      prOpen: entries.filter((entry) => entry.repositoryRef === repositoryRef && entry.state === 'pr-open').length,
      conflicted: entries.filter((entry) => entry.repositoryRef === repositoryRef && entry.state === 'deferred').length,
    })),
    features: [...new Set(entries.map((entry) => entry.featureSlug))].sort().map((featureSlug) => ({
      featureSlug,
      queued: entries.filter((entry) => entry.featureSlug === featureSlug && entry.state === 'queued').length,
    })),
  };
}

export function outboxStatus(env: NodeJS.ProcessEnv = process.env) {
  const resolution = healthyResolution(env);
  return withOutboxLock(resolution, () => outboxStatusLocked(resolution, env));
}

function reviewEntries(
  resolution: ReturnType<typeof resolveBindings>,
  manifest: Manifest,
  entries: Entry[],
  env: NodeJS.ProcessEnv,
) {
  const repositories = [...new Set(entries.map((entry) => entry.repositoryRef))].sort().map((repositoryRef) => {
    const binding = resolution.bindings.find((candidate) => candidate.repositoryRef === repositoryRef);
    if (!binding) throw new Error(`Outbox references an unbound repository: ${repositoryRef}`);
    const changes = entries.filter((entry) => entry.repositoryRef === repositoryRef).map((entry) => {
      const diff = git(
        ['diff', '--no-ext-diff', '--unified=3', entry.baseCommit, entry.objectCommit, '--', entry.path],
        env,
        binding.repository.worktreeRoot,
      );
      return {
        entryId: entry.entryId,
        entryIds: manifest.entries
          .filter((candidate) => candidate.repositoryRef === repositoryRef && candidate.path === entry.path)
          .map((candidate) => candidate.entryId),
        featureSlugs: [...new Set(manifest.entries
          .filter((candidate) => candidate.repositoryRef === repositoryRef && candidate.path === entry.path)
          .flatMap((candidate) => candidate.contributingFeatureSlugs ?? [candidate.featureSlug]))].sort(),
        sourceId: entry.sourceId,
        wikiId: entry.wikiId,
        path: entry.path,
        operation: entry.operation,
        beforeHash: entry.beforeHash,
        afterHash: entry.afterHash,
        authorizationRequired: entry.authorizationRequired,
        diff,
      };
    });
    return { repositoryRef, changes };
  });
  const planDigest = digest(stableJson(repositories.map((repository) => ({
    repositoryRef: repository.repositoryRef,
    changes: repository.changes.map(({ diff: _diff, ...change }) => change),
  }))));
  return {
    schemaVersion: 1 as const,
    kind: 'grill-adapter.obsidian-wiki-outbox-review' as const,
    authoritative: false as const,
    planDigest,
    repositories,
  };
}

export function outboxReview(env: NodeJS.ProcessEnv = process.env) {
  const resolution = healthyResolution(env);
  const manifest = readManifest(resolution);
  return reviewEntries(
    resolution,
    manifest,
    effectiveEntries(manifest).filter((entry) => entry.state === 'queued'),
    env,
  );
}

const CaptureDraftViewInputSchema = z.object({
  paths: z.array(z.string().min(1)).max(24).optional(),
}).strict();

export function captureDraftView(input: unknown, env: NodeJS.ProcessEnv = process.env) {
  const request = CaptureDraftViewInputSchema.parse(input);
  const resolution = healthyResolution(env);
  const entries = effectiveEntries(readManifest(resolution))
    .filter((entry) => entry.state === 'queued' || entry.state === 'pr-open');
  const requested = request.paths === undefined
    ? []
    : request.paths.map(normalizeVaultPath);
  const available = new Map(entries.map((entry) => [entry.path, entry]));
  for (const notePath of requested) {
    if (!available.has(notePath)) throw new Error(`Capture draft path is not in the current project Outbox: ${notePath}`);
  }
  return {
    schemaVersion: 1 as const,
    kind: 'grill-adapter.obsidian-wiki-capture-draft-view' as const,
    authoritative: false as const,
    entries: entries.map((entry) => ({
      sourceId: entry.sourceId,
      repositoryRef: entry.repositoryRef,
      wikiId: entry.wikiId,
      path: entry.path,
      contentHash: entry.afterHash,
      state: entry.state,
      featureSlug: entry.featureSlug,
    })),
    selectedNotes: requested.map((notePath) => {
      const entry = available.get(notePath)!;
      const binding = resolution.bindings.find((candidate) => (
        candidate.sourceId === entry.sourceId && candidate.repositoryRef === entry.repositoryRef
      ));
      if (!binding) throw new Error(`Capture draft references an unbound Source: ${entry.sourceId}`);
      const content = gitFile(entry.objectCommit, notePath, env, binding.repository.worktreeRoot);
      if (!content) throw new Error(`Capture draft object is missing ${notePath}`);
      const note = parseAtomicNote(content, notePath);
      if (note.wikiId !== entry.wikiId || note.contentHash !== entry.afterHash) {
        throw new Error(`Capture draft object identity drift for ${notePath}`);
      }
      return {
        sourceId: entry.sourceId,
        repositoryRef: entry.repositoryRef,
        wikiId: entry.wikiId,
        path: entry.path,
        contentHash: entry.afterHash,
        content: note.content,
      };
    }),
  };
}

const PublishRequestSchema = z.object({
  planDigest: HashSchema,
  confirmed: z.literal(true),
}).strict();

function samePaths(actual: string[], expected: string[]): boolean {
  return actual.length === expected.length && actual.every((value, index) => value === expected[index]);
}

function revisionPaths(
  baseCommit: string,
  revision: string,
  env: NodeJS.ProcessEnv,
  worktreeRoot: string,
): string[] {
  return git(['diff', '--name-only', baseCommit, revision, '--'], env, worktreeRoot)
    .split(/\r?\n/).filter(Boolean).map(normalizeVaultPath).sort();
}

function validatePublishedContents(
  entries: Entry[],
  revision: string,
  binding: ResolvedBinding,
  env: NodeJS.ProcessEnv,
): void {
  for (const entry of entries) {
    const contents = gitFile(revision, entry.path, env, binding.repository.worktreeRoot);
    if (!contents) throw new Error(`Outbox publish revision does not contain ${entry.path}`);
    const note = parseAtomicNote(contents, entry.path);
    if (note.wikiId !== entry.wikiId || note.contentHash !== entry.afterHash) {
      throw new Error(`Outbox publish content identity drift for ${entry.path}`);
    }
  }
}

function validateReplayBase(
  entries: Entry[],
  revision: string,
  binding: ResolvedBinding,
  env: NodeJS.ProcessEnv,
): void {
  for (const entry of entries) {
    const contents = gitFile(revision, entry.path, env, binding.repository.worktreeRoot);
    if (entry.beforeHash === null) {
      if (contents !== undefined) throw new Error(`Outbox create path changed on synchronized base: ${entry.path}`);
      continue;
    }
    if (!contents) throw new Error(`Outbox update path disappeared from synchronized base: ${entry.path}`);
    const note = parseAtomicNote(contents, entry.path);
    if (note.wikiId !== entry.wikiId || note.contentHash !== entry.beforeHash) {
      throw new Error(`Outbox same-path base drift for ${entry.path}`);
    }
  }
}

function buildPublishBody(run: PublishRun, repositoryRef: string): string {
  const repository = run.repositories.find((candidate) => candidate.repositoryRef === repositoryRef)!;
  const peers = run.repositories
    .filter((candidate) => candidate.repositoryRef !== repositoryRef)
    .map((candidate) => candidate.prUrl ?? `${candidate.repositoryRef}: pending`);
  return [
    `Obsidian Wiki Outbox batch: ${run.runId}`,
    '',
    'Changed Notes:',
    ...repository.paths.map((notePath) => `- ${notePath}`),
    '',
    'Peer PRs:',
    ...(peers.length > 0 ? peers.map((peer) => `- ${peer}`) : ['- none']),
    '',
    'This draft is not available to formal Wiki research until merge and base synchronization.',
  ].join('\n');
}

function runGh(
  args: string[],
  env: NodeJS.ProcessEnv,
  workingDirectory: string,
): string {
  return runCommand(env.OBSIDIAN_WIKI_GH_CLI || 'gh', args, env, workingDirectory);
}

function publishRepository(
  run: PublishRun,
  repositoryRun: PublishRun['repositories'][number],
  entries: Entry[],
  binding: ResolvedBinding,
  resolution: ReturnType<typeof resolveBindings>,
  manifest: Manifest,
  env: NodeJS.ProcessEnv,
): void {
  withRepositoryLock(resolution, binding, () => {
    let publishEntries = entries;
    const worktreeRoot = binding.repository.worktreeRoot;
    if (entries.some((entry) => entry.bindingDigest !== binding.bindingDigest)) {
      throw new Error(`repository ${repositoryRun.repositoryRef} binding drift requires a refreshed Capture plan`);
    }
    if (git(['status', '--porcelain'], env, worktreeRoot)) {
      throw new Error(`repository ${repositoryRun.repositoryRef} formal base worktree must be clean`);
    }
    if (git(['branch', '--show-current'], env, worktreeRoot) !== binding.repository.baseBranch) {
      throw new Error(`repository ${repositoryRun.repositoryRef} formal worktree must remain on ${binding.repository.baseBranch}`);
    }
    git(['fetch', '--quiet', binding.repository.remote, binding.repository.baseBranch], env, worktreeRoot);
    const localBase = git(['rev-parse', binding.repository.baseBranch], env, worktreeRoot);
    const remoteBase = git(['rev-parse', `${binding.repository.remote}/${binding.repository.baseBranch}`], env, worktreeRoot);
    if (localBase !== remoteBase) {
      throw new Error(`repository ${repositoryRun.repositoryRef} base drift requires a refreshed Outbox review`);
    }
    if (localBase !== repositoryRun.baseCommit) {
      try {
        git(['merge-base', '--is-ancestor', repositoryRun.baseCommit, localBase], env, worktreeRoot);
      } catch {
        throw new Error(`repository ${repositoryRun.repositoryRef} base drift is not a replayable fast-forward`);
      }
      const upstreamPaths = new Set(revisionPaths(repositoryRun.baseCommit, localBase, env, worktreeRoot));
      const conflicts = publishEntries.flatMap((entry) => {
        try {
          validateReplayBase([entry], localBase, binding, env);
          return [];
        } catch {
          return [{
            entry,
            reason: upstreamPaths.has(entry.path)
              ? 'same-path-base-drift' as const
              : 'base-identity-drift' as const,
          }];
        }
      });
      if (conflicts.length > 0) {
        const conflictIds = new Set(conflicts.map(({ entry }) => entry.entryId));
        const conflictPlanId = digest(stableJson({
          runId: run.runId,
          repositoryRef: repositoryRun.repositoryRef,
          localBase,
          conflicts: conflicts.map(({ entry, reason }) => ({ entryId: entry.entryId, reason })),
        }));
        for (const { entry, reason } of conflicts) {
          if (!manifest.entries.some((candidate) => (
            candidate.planId === conflictPlanId && candidate.supersedes?.includes(entry.entryId)
          ))) {
            manifest.entries.push(terminalCorrectionEntry(
              entry,
              conflictPlanId,
              'defer',
              reason === 'same-path-base-drift'
                ? 'Synchronized base changed the same Note path.'
                : 'Synchronized base no longer proves the queued Note identity.',
            ));
          }
        }
        repositoryRun.conflicts = conflicts.map(({ entry, reason }) => ({ path: entry.path, reason }));
        publishEntries = publishEntries.filter((entry) => !conflictIds.has(entry.entryId));
        repositoryRun.paths = repositoryRun.paths.filter((notePath) => (
          publishEntries.some((entry) => entry.path === notePath)
        ));
      }
      repositoryRun.baseCommit = localBase;
      if (publishEntries.length === 0) {
        repositoryRun.state = 'deferred';
        writeManifest(resolution, manifest);
        return;
      }
      writeManifest(resolution, manifest);
    }

    if (repositoryRun.commit === null) {
      const existingCommit = git(['for-each-ref', '--format=%(objectname)', `refs/heads/${repositoryRun.branch}`], env, worktreeRoot);
      if (existingCommit) {
        if (!samePaths(revisionPaths(localBase, existingCommit, env, worktreeRoot), repositoryRun.paths)) {
          throw new Error(`Outbox publish branch path allowlist drift for ${repositoryRun.repositoryRef}`);
        }
        validatePublishedContents(publishEntries, existingCommit, binding, env);
        repositoryRun.commit = existingCommit;
        writeManifest(resolution, manifest);
      } else {
        const temporaryRoot = mkdtempSync(path.join(tmpdir(), 'grill-adapter-publish-'));
        try {
          git(['worktree', 'add', '--quiet', '--detach', temporaryRoot, localBase], env, worktreeRoot);
          git(['switch', '-c', repositoryRun.branch], env, temporaryRoot);
          for (const entry of publishEntries) {
            git(['restore', '--source', entry.objectCommit, '--staged', '--worktree', '--', entry.path], env, temporaryRoot);
          }
          const staged = git(['diff', '--cached', '--name-only', '--'], env, temporaryRoot)
            .split(/\r?\n/).filter(Boolean).map(normalizeVaultPath).sort();
          if (!samePaths(staged, repositoryRun.paths)) {
            throw new Error(`Outbox publish staged paths differ from the confirmed allowlist for ${repositoryRun.repositoryRef}`);
          }
          git(['commit', '-m', 'docs(wiki): publish Outbox batch'], env, temporaryRoot);
          repositoryRun.commit = git(['rev-parse', 'HEAD'], env, temporaryRoot);
          validatePublishedContents(publishEntries, repositoryRun.commit, binding, env);
          writeManifest(resolution, manifest);
        } finally {
          try {
            git(['worktree', 'remove', '--force', temporaryRoot], env, worktreeRoot);
          } catch {
            rmSync(temporaryRoot, { recursive: true, force: true });
          }
        }
      }
    }
    if (!repositoryRun.commit) throw new Error(`Outbox publish commit is unavailable for ${repositoryRun.repositoryRef}`);
    if (!samePaths(revisionPaths(localBase, repositoryRun.commit, env, worktreeRoot), repositoryRun.paths)) {
      throw new Error(`Outbox publish commit differs from the confirmed path allowlist for ${repositoryRun.repositoryRef}`);
    }
    validatePublishedContents(publishEntries, repositoryRun.commit, binding, env);
    const remoteCommit = git(['ls-remote', '--heads', binding.repository.remote, `refs/heads/${repositoryRun.branch}`], env, worktreeRoot)
      .split(/\s+/)[0] ?? '';
    if (remoteCommit && remoteCommit !== repositoryRun.commit) {
      throw new Error(`Outbox remote publish branch drift for ${repositoryRun.repositoryRef}`);
    }
    if (!remoteCommit) git(['push', '--set-upstream', binding.repository.remote, repositoryRun.branch], env, worktreeRoot);

    const existingPr = runGh(
      ['pr', 'list', '--head', repositoryRun.branch, '--state', 'all', '--json', 'url', '--jq', '.[0].url'],
      env,
      worktreeRoot,
    );
    if (existingPr) {
      repositoryRun.prUrl = z.string().url().parse(existingPr);
    } else {
      const bodyPath = path.join(statePaths(resolution).root, `${safeRefSegment(repositoryRun.repositoryRef)}-pr.md`);
      mkdirSync(path.dirname(bodyPath), { recursive: true });
      writeFileSync(bodyPath, `${buildPublishBody(run, repositoryRun.repositoryRef)}\n`, 'utf8');
      try {
        repositoryRun.prUrl = z.string().url().parse(runGh([
          'pr', 'create', '--draft', '--base', binding.repository.baseBranch,
          '--head', repositoryRun.branch, '--title', 'docs(wiki): publish Outbox batch',
          '--body-file', bodyPath,
        ], env, worktreeRoot));
      } finally {
        rmSync(bodyPath, { force: true });
      }
    }
    repositoryRun.state = 'pr-open';
    for (const entry of manifest.entries) {
      if (entry.repositoryRef === repositoryRun.repositoryRef && repositoryRun.paths.includes(entry.path)) {
        entry.state = 'pr-open';
        entry.prUrl = repositoryRun.prUrl;
      }
    }
    writeManifest(resolution, manifest);
  });
}

function publishOutboxLocked(
  input: unknown,
  resolution: ReturnType<typeof resolveBindings>,
  env: NodeJS.ProcessEnv,
) {
  const request = PublishRequestSchema.parse(input);
  const manifest = readManifest(resolution);
  let run = manifest.publishRuns.find((candidate) => candidate.planDigest === request.planDigest);
  if (!run) {
    const review = reviewEntries(
      resolution,
      manifest,
      effectiveEntries(manifest).filter((entry) => entry.state === 'queued'),
      env,
    );
    if (review.repositories.length === 0) throw new Error('Current project Outbox has no queued changes to publish');
    if (review.planDigest !== request.planDigest) throw new Error('Outbox publish confirmation digest is stale');
    const runId = digest(`${request.planDigest}\0${manifest.projectId}`);
    run = {
      runId,
      planDigest: request.planDigest,
      createdAt: new Date().toISOString(),
      repositories: review.repositories.map((repository) => {
        const entries = effectiveEntries(manifest).filter((entry) => (
          entry.state === 'queued' && entry.repositoryRef === repository.repositoryRef
        ));
        const baseCommits = [...new Set(entries.map((entry) => entry.baseCommit))];
        if (baseCommits.length !== 1) throw new Error(`Outbox base identity is inconsistent for ${repository.repositoryRef}`);
        return {
          repositoryRef: repository.repositoryRef,
          baseCommit: baseCommits[0],
          branch: `grill-adapter/wiki/outbox-${manifest.projectId.slice(0, 8)}-${safeRefSegment(repository.repositoryRef)}-${request.planDigest.slice(7, 15)}`,
          commit: null,
          paths: repository.changes.map((change) => change.path).sort(),
          prUrl: null,
          state: 'pending' as const,
        };
      }),
    };
    manifest.publishRuns.push(run);
    writeManifest(resolution, manifest);
  }
  for (const repositoryRun of run.repositories) {
    if (repositoryRun.state === 'pr-open' || repositoryRun.state === 'deferred') continue;
    const binding = resolution.bindings.find((candidate) => candidate.repositoryRef === repositoryRun.repositoryRef);
    if (!binding) throw new Error(`Outbox publish references an unbound repository: ${repositoryRun.repositoryRef}`);
    const entries = effectiveEntries(manifest).filter((entry) => (
      entry.state === 'queued'
      && entry.repositoryRef === repositoryRun.repositoryRef
      && repositoryRun.paths.includes(entry.path)
    ));
    publishRepository(run, repositoryRun, entries, binding, resolution, manifest, env);
  }
  return {
    schemaVersion: 1 as const,
    kind: 'grill-adapter.obsidian-wiki-outbox-publish' as const,
    runId: run.runId,
    planDigest: run.planDigest,
    repositories: run.repositories,
  };
}

export function publishOutbox(input: unknown, env: NodeJS.ProcessEnv = process.env) {
  const resolution = healthyResolution(env);
  return withOutboxLock(resolution, () => publishOutboxLocked(input, resolution, env));
}
