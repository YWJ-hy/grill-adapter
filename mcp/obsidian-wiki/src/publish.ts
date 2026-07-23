import { randomUUID } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import {
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import path from 'node:path';
import * as z from 'zod/v4';
import { resolveBindings, type ResolvedBinding } from './bindings.js';
import { parseAtomicNote } from './note.js';
import { assertPathWithinBinding, normalizeVaultPath } from './retrieval.js';

const HashSchema = z.string().regex(/^sha256:[a-f0-9]{64}$/);
const AdrProjectionSchema = z.object({
  authorityType: z.literal('project-adr'),
  projectionType: z.literal('execution-constraints'),
  sourceId: z.string().regex(/^project-adr:[a-f0-9]{64}$/),
  sourcePath: z.string().min(1),
  sourceContentHash: HashSchema,
  targetScope: z.literal('project'),
});
const ReceiptIdentitySchema = z.object({
  provider: z.literal('obsidian'),
  operation: z.enum(['create', 'update']),
  sourceId: z.string().min(1),
  repositoryRef: z.string().min(1),
  bindingDigest: z.string().regex(/^[a-f0-9]{64}$/),
  wikiId: z.string().min(1),
  path: z.string().min(1),
  beforeHash: HashSchema.nullable(),
  afterHash: HashSchema,
  adrProjection: AdrProjectionSchema.optional(),
});
const AppliedReceiptSchema = ReceiptIdentitySchema.extend({ state: z.literal('applied') });
const WriteReceiptSchema = z.discriminatedUnion('state', [
  ReceiptIdentitySchema.extend({ state: z.literal('proposed') }),
  AppliedReceiptSchema,
]);

const FoldedJournalSchema = z.object({
  schemaVersion: z.literal(1),
  featureSlug: z.string().regex(/^[a-z0-9][a-z0-9._-]*$/),
  candidates: z.array(z.object({
    candidateId: z.string().min(1),
    status: z.enum(['pending', 'superseded', 'kept', 'skipped', 'deferred']),
    adrProjection: AdrProjectionSchema.optional(),
    writeReceipt: WriteReceiptSchema.optional(),
  }).superRefine((candidate, context) => {
    const candidateIdentity = candidate.adrProjection;
    const receiptIdentity = candidate.writeReceipt?.adrProjection;
    if (
      candidate.writeReceipt !== undefined
      && JSON.stringify(candidateIdentity) !== JSON.stringify(receiptIdentity)
    ) {
      context.addIssue({
        code: 'custom',
        message: 'ADR projection candidate and write receipt authority identity must match',
      });
    }
  })),
});

const RepositoryRunSchema = z.object({
  repositoryRef: z.string().min(1),
  baseBranch: z.string().min(1),
  branch: z.string().min(1),
  paths: z.array(z.string().min(1)).min(1),
  stagedTree: z.string().regex(/^[a-f0-9]{40,64}$/).nullable().default(null),
  commit: z.string().regex(/^[a-f0-9]{40,64}$/).nullable(),
  prUrl: z.string().url().nullable(),
  state: z.enum(['pending', 'published']),
});

const PublishManifestSchema = z.object({
  schemaVersion: z.literal(1),
  kind: z.literal('grill-adapter.obsidian-wiki-publish'),
  runId: z.string().uuid(),
  featureSlug: z.string().regex(/^[a-z0-9][a-z0-9._-]*$/),
  repositories: z.array(RepositoryRunSchema).min(1),
});
const PublishPreparationSchema = z.object({
  featureSlug: z.string().regex(/^[a-z0-9][a-z0-9._-]*$/),
  operations: z.array(z.object({
    sourceId: z.string().min(1),
    repositoryRef: z.string().min(1),
    bindingDigest: z.string().regex(/^[a-f0-9]{64}$/),
    path: z.string().min(1),
  })).min(1),
});

type Receipt = z.infer<typeof AppliedReceiptSchema>;

type RepositoryRun = z.infer<typeof RepositoryRunSchema>;
type PublishManifest = z.infer<typeof PublishManifestSchema>;

export type PublishResult = PublishManifest;

const PublishLockFile = '.grill-adapter-wiki.publish.lock';

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

function gitFile(revision: string, notePath: string, env: NodeJS.ProcessEnv, workingDirectory: string): string {
  try {
    return String(execFileSync('git', ['show', `${revision}:${notePath}`], {
      cwd: workingDirectory,
      env,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
    }));
  } catch {
    throw new Error(`Git revision ${revision} does not contain ${notePath}`);
  }
}

function changedPaths(worktreeRoot: string, env: NodeJS.ProcessEnv): string[] {
  const tracked = git(['diff', 'HEAD', '--name-status', '--'], env, worktreeRoot)
    .split(/\r?\n/)
    .filter(Boolean)
    .map((line) => {
      const match = /^([MA])\t(.+)$/.exec(line);
      if (!match) throw new Error(`unsupported staged Wiki change: ${line}`);
      return normalizeVaultPath(match[2]);
    });
  const untracked = git(['ls-files', '--others', '--exclude-standard'], env, worktreeRoot)
    .split(/\r?\n/)
    .filter(Boolean)
    .map(normalizeVaultPath)
    .filter((notePath) => notePath !== PublishLockFile);
  return [...tracked, ...untracked].sort();
}

function samePaths(actual: string[], expected: string[]): boolean {
  return actual.length === expected.length && actual.every((value, index) => value === expected[index]);
}

function writeManifest(manifestPath: string, manifest: PublishManifest): void {
  mkdirSync(path.dirname(manifestPath), { recursive: true });
  const temporaryPath = `${manifestPath}.tmp-${process.pid}`;
  writeFileSync(temporaryPath, `${JSON.stringify(manifest, null, 2)}\n`, { encoding: 'utf8', flag: 'wx' });
  renameSync(temporaryPath, manifestPath);
}

function manifestPathFor(projectDir: string, featureSlug: string): string {
  return path.join(projectDir, '.adapter', 'context', `${featureSlug}.wiki-publish.json`);
}

function readPublishManifest(manifestPath: string): PublishManifest | undefined {
  return existsSync(manifestPath)
    ? PublishManifestSchema.parse(JSON.parse(readFileSync(manifestPath, 'utf8'))) as PublishManifest
    : undefined;
}

export function publishBranchOptions(
  featureSlug: string,
  env: NodeJS.ProcessEnv = process.env,
): Record<string, string> {
  const parsedFeature = z.string().regex(/^[a-z0-9][a-z0-9._-]*$/).parse(featureSlug);
  const projectDir = path.resolve(env.CLAUDE_PROJECT_DIR ?? process.cwd());
  const manifest = readPublishManifest(manifestPathFor(projectDir, parsedFeature));
  if (!manifest || manifest.featureSlug !== parsedFeature) {
    throw new Error(`publish transaction is unavailable for ${parsedFeature}`);
  }
  return Object.fromEntries(manifest.repositories.map((run) => [run.repositoryRef, run.branch]));
}

export function preparePublishBranches(input: unknown, env: NodeJS.ProcessEnv = process.env): PublishResult {
  const request = PublishPreparationSchema.parse(input);
  const projectDir = path.resolve(env.CLAUDE_PROJECT_DIR ?? process.cwd());
  const manifestPath = manifestPathFor(projectDir, request.featureSlug);
  const existing = readPublishManifest(manifestPath);
  const allowedRepositoryBranches = existing
    ? Object.fromEntries(existing.repositories.map((run) => [run.repositoryRef, run.branch]))
    : undefined;
  const resolution = resolveBindings(env, projectDir, {
    allowStagedWikiChanges: existing !== undefined,
    allowedRepositoryBranches,
  });
  if (resolution.errors.length > 0) {
    throw new Error(`Obsidian Wiki Source bindings are unhealthy: ${resolution.errors.join('; ')}`);
  }
  const byRepository = new Map<string, { binding: ResolvedBinding; paths: string[] }>();
  for (const operation of request.operations) {
    const binding = resolution.bindings.find((candidate) => candidate.sourceId === operation.sourceId);
    if (!binding) throw new Error(`publish preparation references an unbound Source: ${operation.sourceId}`);
    if (binding.repositoryRef !== operation.repositoryRef) {
      throw new Error(`publish preparation repositoryRef drift for ${operation.path}`);
    }
    if (binding.bindingDigest !== operation.bindingDigest) {
      throw new Error(`publish preparation binding digest drift for ${operation.path}`);
    }
    if (binding.publishingMode !== 'git-pr') {
      throw new Error(`Obsidian Wiki publishing requires publishing mode git-pr for ${operation.sourceId}`);
    }
    const notePath = assertPathWithinBinding(operation.path, binding);
    const group = byRepository.get(operation.repositoryRef) ?? { binding, paths: [] };
    group.paths.push(notePath);
    byRepository.set(operation.repositoryRef, group);
  }
  for (const group of byRepository.values()) {
    group.paths = [...new Set(group.paths)].sort();
  }

  const runId = existing?.runId ?? randomUUID();
  const manifest: PublishManifest = existing ?? {
    schemaVersion: 1,
    kind: 'grill-adapter.obsidian-wiki-publish',
    runId,
    featureSlug: request.featureSlug,
    repositories: [...byRepository.entries()].map(([repositoryRef, group]) => ({
      repositoryRef,
      baseBranch: group.binding.repository.baseBranch,
      branch: `grill-adapter/wiki/${request.featureSlug}-${safeSegment(repositoryRef)}-${runId.slice(0, 8)}`,
      paths: group.paths,
      stagedTree: null,
      commit: null,
      prUrl: null,
      state: 'pending',
    })),
  };
  const expected = [...byRepository.entries()].map(([repositoryRef, group]) => ({
    repositoryRef,
    baseBranch: group.binding.repository.baseBranch,
    paths: group.paths,
  }));
  const actual = manifest.repositories.map(({ repositoryRef, baseBranch, paths }) => ({ repositoryRef, baseBranch, paths }));
  if (manifest.featureSlug !== request.featureSlug || JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error('publish transaction manifest differs from the prepared migration operations');
  }
  if (!existing) writeManifest(manifestPath, manifest);

  for (const run of manifest.repositories) {
    const binding = byRepository.get(run.repositoryRef)!.binding;
    const worktreeRoot = binding.repository.worktreeRoot;
    const currentBranch = git(['branch', '--show-current'], env, worktreeRoot);
    const baseCommit = git(['rev-parse', run.baseBranch], env, worktreeRoot);
    const branchCommit = git(['for-each-ref', '--format=%(objectname)', `refs/heads/${run.branch}`], env, worktreeRoot);
    if (branchCommit && branchCommit !== baseCommit) {
      throw new Error(`publish preparation branch drift for ${run.repositoryRef}`);
    }
    if (currentBranch === run.baseBranch) {
      if (changedPaths(worktreeRoot, env).length > 0) {
        throw new Error(`repository ${run.repositoryRef} must be clean before preparing its publish branch`);
      }
      git(branchCommit ? ['switch', run.branch] : ['switch', '-c', run.branch], env, worktreeRoot);
    } else if (currentBranch !== run.branch) {
      throw new Error(`repository ${run.repositoryRef} is not on its prepared publish branch`);
    }
    const changes = changedPaths(worktreeRoot, env);
    if (changes.some((notePath) => !run.paths.includes(notePath))) {
      throw new Error(`repository ${run.repositoryRef} contains changes outside its prepared path allowlist`);
    }
  }
  return manifest;
}

function receiptBinding(receipt: Receipt, bindings: ResolvedBinding[]): ResolvedBinding {
  const binding = bindings.find((candidate) => candidate.sourceId === receipt.sourceId);
  if (!binding) throw new Error(`write receipt references an unbound Source: ${receipt.sourceId}`);
  if (binding.repositoryRef !== receipt.repositoryRef) {
    throw new Error(`write receipt repositoryRef drift for ${receipt.path}`);
  }
  if (binding.bindingDigest !== receipt.bindingDigest) {
    throw new Error(`write receipt binding digest drift for ${receipt.path}`);
  }
  if (binding.publishingMode !== 'git-pr') {
    throw new Error(`Obsidian Wiki publishing requires publishing mode git-pr for ${receipt.sourceId}`);
  }
  assertPathWithinBinding(receipt.path, binding);
  return binding;
}

function validateReceipt(
  receipt: Receipt,
  binding: ResolvedBinding,
  env: NodeJS.ProcessEnv,
  publishedCommit?: string,
): void {
  const notePath = normalizeVaultPath(receipt.path);
  const worktreeRoot = binding.repository.worktreeRoot;
  const contents = publishedCommit
    ? gitFile(publishedCommit, notePath, env, worktreeRoot)
    : readFileSync(path.join(worktreeRoot, ...notePath.split('/')), 'utf8');
  const note = parseAtomicNote(contents, notePath);
  if (note.wikiId !== receipt.wikiId) throw new Error(`write receipt wiki_id drift for ${notePath}`);
  if (note.contentHash !== receipt.afterHash) throw new Error(`write receipt afterHash drift for ${notePath}`);
  if (receipt.adrProjection) {
    if (binding.role !== 'project' || binding.manifest.scope !== 'project') {
      throw new Error(`ADR execution projection receipt must reference a project Source: ${notePath}`);
    }
    const actualProjection = note.adrSourceId
      ? {
        authorityType: 'project-adr',
        projectionType: 'execution-constraints',
        sourceId: note.adrSourceId,
        sourcePath: note.adrSourcePath,
        sourceContentHash: note.adrSourceContentHash,
        targetScope: 'project',
      }
      : undefined;
    if (JSON.stringify(actualProjection) !== JSON.stringify(receipt.adrProjection)) {
      throw new Error(`ADR execution projection authority drift for ${notePath}`);
    }
  }
  if (receipt.operation === 'create') {
    try {
      gitFile(binding.repository.baseBranch, notePath, env, worktreeRoot);
      throw new Error(`create receipt path already exists on base: ${notePath}`);
    } catch (error) {
      if (error instanceof Error && error.message.includes('already exists')) throw error;
    }
    if (receipt.beforeHash !== null) throw new Error(`create receipt beforeHash must be null: ${notePath}`);
    return;
  }
  if (receipt.beforeHash === null) throw new Error(`update receipt requires beforeHash: ${notePath}`);
  const baseNote = parseAtomicNote(gitFile(binding.repository.baseBranch, notePath, env, worktreeRoot), notePath);
  if (baseNote.contentHash !== receipt.beforeHash) throw new Error(`write receipt beforeHash drift for ${notePath}`);
}

function commitPaths(commit: string, env: NodeJS.ProcessEnv, worktreeRoot: string): string[] {
  return git(['diff-tree', '--no-commit-id', '--name-only', '-r', commit], env, worktreeRoot)
    .split(/\r?\n/).filter(Boolean).map(normalizeVaultPath).sort();
}

function revisionPathsFromBase(
  baseBranch: string,
  revision: string,
  env: NodeJS.ProcessEnv,
  worktreeRoot: string,
): string[] {
  return git(['diff', '--name-only', baseBranch, revision, '--'], env, worktreeRoot)
    .split(/\r?\n/).filter(Boolean).map(normalizeVaultPath).sort();
}

function buildPrBody(manifest: PublishManifest, run: RepositoryRun): string {
  const peers = manifest.repositories
    .filter((candidate) => candidate.repositoryRef !== run.repositoryRef)
    .map((candidate) => candidate.prUrl ?? `${candidate.repositoryRef}: pending`);
  return [
    `Obsidian Wiki publish run: ${manifest.runId}`,
    '',
    'Changed Notes:',
    ...run.paths.map((notePath) => `- ${notePath}`),
    '',
    'Peer PRs:',
    ...(peers.length > 0 ? peers.map((peer) => `- ${peer}`) : ['- none']),
    '',
    'This draft is not runtime-visible until it is merged and the configured base worktree is synchronized and revalidated.',
  ].join('\n');
}

function parsePrUrl(value: string): string {
  return z.string().url().parse(value);
}

function safeSegment(value: string): string {
  const normalized = value.toLowerCase().replace(/[^a-z0-9._-]+/g, '-').replace(/^-+|-+$/g, '');
  if (!normalized) throw new Error(`repositoryRef cannot form a publish branch segment: ${value}`);
  return normalized;
}

function withTemporaryPrBody<T>(
  manifestPath: string,
  run: RepositoryRun,
  body: string,
  callback: (bodyPath: string) => T,
): T {
  const bodyPath = `${manifestPath}.${safeSegment(run.repositoryRef)}.md`;
  writeFileSync(bodyPath, `${body}\n`, 'utf8');
  try {
    return callback(bodyPath);
  } finally {
    rmSync(bodyPath, { force: true });
  }
}

function coordinatePeerPrs(
  manifest: PublishManifest,
  bindingsByRepository: Map<string, ResolvedBinding>,
  manifestPath: string,
  env: NodeJS.ProcessEnv,
): void {
  for (const run of manifest.repositories) {
    if (!run.prUrl) throw new Error(`publish run has no PR URL for ${run.repositoryRef}`);
    const binding = bindingsByRepository.get(run.repositoryRef);
    if (!binding) throw new Error(`publish run has no binding for ${run.repositoryRef}`);
    withTemporaryPrBody(manifestPath, run, buildPrBody(manifest, run), (bodyPath) => (
      runCommand(
        env.OBSIDIAN_WIKI_GH_CLI || 'gh',
        ['pr', 'edit', run.prUrl!, '--body-file', bodyPath],
        env,
        binding.repository.worktreeRoot,
      )
    ));
  }
}

function publishRepository(
  manifest: PublishManifest,
  run: RepositoryRun,
  binding: ResolvedBinding,
  receipts: Receipt[],
  manifestPath: string,
  env: NodeJS.ProcessEnv,
): void {
  const repository = binding.repository;
  const worktreeRoot = repository.worktreeRoot;
  const lockPath = path.join(worktreeRoot, PublishLockFile);
  let enteredPublishBranch = false;
  writeFileSync(lockPath, `${manifest.runId}\n`, { encoding: 'utf8', flag: 'wx' });
  try {
    if (run.commit === null) {
      if (run.stagedTree) {
        for (const receipt of receipts) validateReceipt(receipt, binding, env, run.stagedTree);
        if (changedPaths(worktreeRoot, env).length > 0) {
          throw new Error(`repository ${run.repositoryRef} base worktree must be clean while resuming a staged publish tree`);
        }
        if (!samePaths(revisionPathsFromBase(run.baseBranch, run.stagedTree, env, worktreeRoot), run.paths)) {
          throw new Error(`repository ${run.repositoryRef} staged publish tree differs from the applied receipt allowlist`);
        }
      } else {
        for (const receipt of receipts) validateReceipt(receipt, binding, env);
        if (!samePaths(changedPaths(worktreeRoot, env), run.paths)) {
          throw new Error(`repository ${run.repositoryRef} changes differ from the applied receipt allowlist under publish lock`);
        }
      }
      const existingBranch = git(['for-each-ref', '--format=%(objectname)', `refs/heads/${run.branch}`], env, worktreeRoot);
      const baseCommit = git(['rev-parse', run.baseBranch], env, worktreeRoot);
      if (existingBranch && existingBranch !== baseCommit) {
        const parent = git(['rev-parse', `${existingBranch}^`], env, worktreeRoot);
        if (parent !== baseCommit || !samePaths(commitPaths(existingBranch, env, worktreeRoot), run.paths)) {
          throw new Error(`existing publish branch drift for ${run.repositoryRef}`);
        }
        for (const receipt of receipts) validateReceipt(receipt, binding, env, existingBranch);
        run.commit = existingBranch;
        run.stagedTree = null;
        writeManifest(manifestPath, manifest);
      } else {
        git(existingBranch ? ['switch', run.branch] : ['switch', '-c', run.branch], env, worktreeRoot);
        enteredPublishBranch = true;
        if (run.stagedTree) {
          git(['restore', '--source', run.stagedTree, '--staged', '--worktree', '--', ...run.paths], env, worktreeRoot);
        } else {
          git(['add', '--', ...run.paths], env, worktreeRoot);
          run.stagedTree = git(['write-tree'], env, worktreeRoot);
          writeManifest(manifestPath, manifest);
        }
        const staged = git(['diff', '--cached', '--name-only', '--'], env, worktreeRoot).split(/\r?\n/).filter(Boolean).sort();
        if (!samePaths(staged, run.paths)) {
          throw new Error(`staged paths differ from the receipt allowlist for ${run.repositoryRef}`);
        }
        git(['commit', '-m', `docs(wiki): publish ${manifest.featureSlug}`], env, worktreeRoot);
        const committed = git(['rev-parse', 'HEAD'], env, worktreeRoot);
        for (const receipt of receipts) validateReceipt(receipt, binding, env, committed);
        run.commit = committed;
        run.stagedTree = null;
        writeManifest(manifestPath, manifest);
      }
    } else {
      const localBranchCommit = git(['rev-parse', run.branch], env, worktreeRoot);
      if (localBranchCommit !== run.commit) throw new Error(`publish branch drift for ${run.repositoryRef}`);
      if (!samePaths(commitPaths(run.commit, env, worktreeRoot), run.paths)) {
        throw new Error(`publish commit paths differ from the receipt allowlist for ${run.repositoryRef}`);
      }
      for (const receipt of receipts) validateReceipt(receipt, binding, env, run.commit);
      git(['switch', run.branch], env, worktreeRoot);
      enteredPublishBranch = true;
    }
    if (git(['branch', '--show-current'], env, worktreeRoot) !== run.branch) {
      git(['switch', run.branch], env, worktreeRoot);
      enteredPublishBranch = true;
    }
    const remoteBranch = git(['ls-remote', '--heads', repository.remote, `refs/heads/${run.branch}`], env, worktreeRoot)
      .split(/\s+/)[0] ?? '';
    if (remoteBranch && remoteBranch !== run.commit) throw new Error(`remote publish branch drift for ${run.repositoryRef}`);
    if (!remoteBranch) git(['push', '--set-upstream', repository.remote, run.branch], env, worktreeRoot);

    const gh = env.OBSIDIAN_WIKI_GH_CLI || 'gh';
    const existing = runCommand(gh, ['pr', 'list', '--head', run.branch, '--state', 'all', '--json', 'url', '--jq', '.[0].url'], env, worktreeRoot);
    run.prUrl = parsePrUrl(existing || withTemporaryPrBody(
      manifestPath,
      run,
      buildPrBody(manifest, run),
      (bodyPath) => runCommand(gh, [
        'pr', 'create', '--draft', '--base', run.baseBranch, '--head', run.branch,
        '--title', `docs(wiki): publish ${manifest.featureSlug}`, '--body-file', bodyPath,
      ], env, worktreeRoot),
    ));
    run.state = 'published';
    writeManifest(manifestPath, manifest);
  } finally {
    const branch = git(['branch', '--show-current'], env, worktreeRoot);
    if (branch !== run.baseBranch) git(['switch', run.baseBranch], env, worktreeRoot);
    if (enteredPublishBranch && run.commit === null) {
      git(['restore', '--source', run.baseBranch, '--staged', '--worktree', '--', ...run.paths], env, worktreeRoot);
    }
    if (git(['branch', '--show-current'], env, worktreeRoot) !== run.baseBranch) {
      throw new Error(`repository ${run.repositoryRef} could not restore base branch ${run.baseBranch}`);
    }
    if (enteredPublishBranch && changedPaths(worktreeRoot, env).length > 0) {
      throw new Error(`repository ${run.repositoryRef} could not restore a clean base worktree`);
    }
    rmSync(lockPath, { force: true });
  }
}

export function publishFromFoldedJournal(input: unknown, env: NodeJS.ProcessEnv = process.env): PublishResult {
  const journal = FoldedJournalSchema.parse(input);
  const receipts = journal.candidates.flatMap((candidate) => (
    candidate.status === 'kept' && candidate.writeReceipt?.state === 'applied' ? [candidate.writeReceipt] : []
  ));
  if (receipts.length === 0) throw new Error('folded journal has no kept applied Obsidian write receipts');
  const receiptPaths = new Set<string>();
  for (const receipt of receipts) {
    const key = `${receipt.repositoryRef}\n${normalizeVaultPath(receipt.path)}`;
    if (receiptPaths.has(key)) throw new Error(`duplicate applied receipt path: ${receipt.path}`);
    receiptPaths.add(key);
  }

  const projectDir = path.resolve(env.CLAUDE_PROJECT_DIR ?? process.cwd());
  const manifestPath = manifestPathFor(projectDir, journal.featureSlug);
  const existingManifest = readPublishManifest(manifestPath);
  const allowedRepositoryBranches = existingManifest
    ? Object.fromEntries(existingManifest.repositories.map((run) => [run.repositoryRef, run.branch]))
    : undefined;
  const resolution = resolveBindings(env, projectDir, {
    allowStagedWikiChanges: true,
    allowedRepositoryBranches,
  });
  if (resolution.errors.length > 0) {
    throw new Error(`Obsidian Wiki Source bindings are unhealthy: ${resolution.errors.join('; ')}`);
  }
  if (existingManifest && existingManifest.featureSlug !== journal.featureSlug) {
    throw new Error('publish manifest featureSlug does not match the folded journal');
  }
  const byRepository = new Map<string, Array<{ receipt: Receipt; binding: ResolvedBinding }>>();
  for (const receipt of receipts) {
    const binding = receiptBinding(receipt, resolution.bindings);
    const group = byRepository.get(receipt.repositoryRef) ?? [];
    group.push({ receipt, binding });
    byRepository.set(receipt.repositoryRef, group);
  }

  for (const [repositoryRef, group] of byRepository) {
    const binding = group[0].binding;
    const expected = group.map(({ receipt }) => normalizeVaultPath(receipt.path)).sort();
    const priorRun = existingManifest?.repositories.find((candidate) => candidate.repositoryRef === repositoryRef);
    if (priorRun?.commit) {
      for (const { receipt } of group) validateReceipt(receipt, binding, env, priorRun.commit);
      if (changedPaths(binding.repository.worktreeRoot, env).length > 0) {
        throw new Error(`repository ${repositoryRef} base worktree must be clean while resuming a fixed publish commit`);
      }
      if (!samePaths(commitPaths(priorRun.commit, env, binding.repository.worktreeRoot), expected)) {
        throw new Error(`repository ${repositoryRef} publish commit differs from the applied receipt allowlist`);
      }
    } else if (priorRun?.stagedTree) {
      for (const { receipt } of group) validateReceipt(receipt, binding, env, priorRun.stagedTree);
      if (changedPaths(binding.repository.worktreeRoot, env).length > 0) {
        throw new Error(`repository ${repositoryRef} base worktree must be clean while resuming a staged publish tree`);
      }
      if (!samePaths(
        revisionPathsFromBase(binding.repository.baseBranch, priorRun.stagedTree, env, binding.repository.worktreeRoot),
        expected,
      )) {
        throw new Error(`repository ${repositoryRef} staged publish tree differs from the applied receipt allowlist`);
      }
    } else {
      const existingBranch = priorRun
        ? git(
          ['for-each-ref', '--format=%(objectname)', `refs/heads/${priorRun.branch}`],
          env,
          binding.repository.worktreeRoot,
        )
        : '';
      const baseCommit = git(['rev-parse', binding.repository.baseBranch], env, binding.repository.worktreeRoot);
      if (priorRun && existingBranch && existingBranch !== baseCommit) {
        if (changedPaths(binding.repository.worktreeRoot, env).length > 0) {
          throw new Error(`repository ${repositoryRef} worktree must be clean while recovering an unrecorded publish commit`);
        }
        if (!samePaths(commitPaths(existingBranch, env, binding.repository.worktreeRoot), expected)) {
          throw new Error(`repository ${repositoryRef} unrecorded publish commit differs from the applied receipt allowlist`);
        }
        for (const { receipt } of group) validateReceipt(receipt, binding, env, existingBranch);
        priorRun.commit = existingBranch;
        priorRun.stagedTree = null;
        writeManifest(manifestPath, existingManifest!);
      } else {
        for (const { receipt } of group) validateReceipt(receipt, binding, env);
        const actual = changedPaths(binding.repository.worktreeRoot, env);
        if (!samePaths(actual, expected)) {
          throw new Error(`repository ${repositoryRef} changes differ from the applied receipt allowlist`);
        }
      }
    }
    git(['fetch', '--quiet', binding.repository.remote, binding.repository.baseBranch], env, binding.repository.worktreeRoot);
    const localBase = git(['rev-parse', binding.repository.baseBranch], env, binding.repository.worktreeRoot);
    const remoteBase = git(['rev-parse', `${binding.repository.remote}/${binding.repository.baseBranch}`], env, binding.repository.worktreeRoot);
    if (localBase !== remoteBase) throw new Error(`repository ${repositoryRef} base branch is not synchronized with its remote`);
  }

  const runId = existingManifest?.runId ?? randomUUID();
  const manifest: PublishManifest = existingManifest ?? {
    schemaVersion: 1,
    kind: 'grill-adapter.obsidian-wiki-publish',
    runId,
    featureSlug: journal.featureSlug,
    repositories: [...byRepository.entries()].map(([repositoryRef, group]) => ({
      repositoryRef,
      baseBranch: group[0].binding.repository.baseBranch,
      branch: `grill-adapter/wiki/${journal.featureSlug}-${safeSegment(repositoryRef)}-${runId.slice(0, 8)}`,
      paths: group.map(({ receipt }) => normalizeVaultPath(receipt.path)).sort(),
      stagedTree: null,
      commit: null,
      prUrl: null,
      state: 'pending',
    })),
  };
  const expectedRepositories = [...byRepository.entries()].map(([repositoryRef, group]) => ({
    repositoryRef,
    baseBranch: group[0].binding.repository.baseBranch,
    paths: group.map(({ receipt }) => normalizeVaultPath(receipt.path)).sort(),
  }));
  const actualRepositories = manifest.repositories.map(({ repositoryRef, baseBranch, paths }) => ({ repositoryRef, baseBranch, paths }));
  if (JSON.stringify(actualRepositories) !== JSON.stringify(expectedRepositories)) {
    throw new Error('publish manifest repositories differ from the folded journal receipts');
  }
  if (!existingManifest) writeManifest(manifestPath, manifest);
  const bindingsByRepository = new Map(
    [...byRepository.entries()].map(([repositoryRef, group]) => [repositoryRef, group[0].binding]),
  );
  for (const run of manifest.repositories) {
    if (run.state === 'published') continue;
    const group = byRepository.get(run.repositoryRef)!;
    publishRepository(manifest, run, group[0].binding, group.map(({ receipt }) => receipt), manifestPath, env);
  }
  coordinatePeerPrs(manifest, bindingsByRepository, manifestPath, env);
  return manifest;
}
