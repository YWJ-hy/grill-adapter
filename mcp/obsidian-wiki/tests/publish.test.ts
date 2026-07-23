import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import { resolveBindings } from '../src/bindings.js';
import { contentHash } from '../src/note.js';
import { publishFromFoldedJournal } from '../src/publish.js';

const createdDirectories: string[] = [];

type TestFoldedJournal = {
  schemaVersion: 1;
  featureSlug: string;
  candidates: Array<{
    candidateId: string;
    status: 'kept' | 'deferred';
    adrProjection?: AdrProjection;
    writeReceipt: {
      provider: 'obsidian';
      state: 'applied' | 'proposed';
      operation: 'create' | 'update';
      sourceId: string;
      repositoryRef: string;
      bindingDigest: string;
      wikiId: string;
      path: string;
      beforeHash: string | null;
      afterHash: string;
      adrProjection?: AdrProjection;
    };
  }>;
};

type AdrProjection = {
  authorityType: 'project-adr';
  projectionType: 'execution-constraints';
  sourceId: string;
  sourcePath: string;
  sourceContentHash: string;
  targetScope: 'project';
};

function command(commandName: string, args: string[], cwd?: string): string {
  return String(execFileSync(commandName, args, { cwd, encoding: 'utf8' })).trim();
}

function writeJson(filePath: string, value: unknown): void {
  mkdirSync(path.dirname(filePath), { recursive: true });
  writeFileSync(filePath, JSON.stringify(value, null, 2), 'utf8');
}

function note(wikiId: string, summary: string, body: string): string {
  return `---\nwiki_schema: grill-adapter.obsidian-note/v1\nwiki_id: ${wikiId}\ntype: constraint\nstatus: active\nagent_visible: true\nsummary: ${summary}\nconstraint_strength: hard\n---\n\n# Contract\n\n${body}\n`;
}

function adrProjectionNote(wikiId: string, projection: AdrProjection, body: string): string {
  return `---\nwiki_schema: grill-adapter.obsidian-note/v1\nwiki_id: ${wikiId}\ntype: constraint\nstatus: active\nagent_visible: true\nsummary: Derived ADR execution constraints.\nconstraint_strength: hard\nadr_source_id: ${projection.sourceId}\nadr_source_path: ${projection.sourcePath}\nadr_source_content_hash: ${projection.sourceContentHash}\n---\n\n# Derived ADR execution constraints\n\n${body}\n`;
}

function manifest(sourceId: string, scope: 'project' | 'shared' = 'project'): string {
  const neutrality = scope === 'shared' ? 'blocked_terms:\n  - acme-internal\nblocked_patterns:\n  - "internal"\n' : '';
  return `---\nwiki_schema: grill-adapter.obsidian-source/v1\nwiki_source_id: ${sourceId}\nscope: ${scope}\nupdate_existing: direct\ncreate_note: direct\n${neutrality}---\n\n# ${sourceId}\n`;
}

function fixture() {
  const root = mkdtempSync(path.join(tmpdir(), 'obsidian-publish-'));
  createdDirectories.push(root);
  const projectDir = path.join(root, 'project');
  const worktreeRoot = path.join(root, 'knowledge');
  const remoteRoot = path.join(root, 'knowledge.git');
  const registryPath = path.join(root, 'registry.json');
  const obsidianCli = path.join(root, 'obsidian');
  const ghCli = path.join(root, 'gh');
  const ghState = path.join(root, 'gh-state.json');
  const sourceRoot = 'Projects/example';
  const notePath = `${sourceRoot}/contract.md`;
  const original = note('project/example/contract', 'Original contract.', 'Original base content.');
  const updated = note('project/example/contract', 'Updated contract.', 'Reviewed staged content.');

  command('git', ['init', '--bare', remoteRoot]);
  command('git', ['init', '--initial-branch=main', worktreeRoot]);
  command('git', ['config', 'user.name', 'Test User'], worktreeRoot);
  command('git', ['config', 'user.email', 'test@example.invalid'], worktreeRoot);
  command('git', ['remote', 'add', 'origin', remoteRoot], worktreeRoot);
  mkdirSync(path.join(worktreeRoot, sourceRoot, '_meta'), { recursive: true });
  writeFileSync(path.join(worktreeRoot, sourceRoot, '_meta', 'wiki-source.md'), manifest('project'), 'utf8');
  writeFileSync(path.join(worktreeRoot, notePath), original, 'utf8');
  writeFileSync(path.join(worktreeRoot, 'README.md'), 'Knowledge repository.\n', 'utf8');
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
  state.createCount = (state.createCount || 0) + 1;
  const url = 'https://github.com/acme/knowledge/pull/' + (41 + state.createCount);
  state.prs[head] = url;
  const bodyPath = args[args.indexOf('--body-file') + 1];
  state.bodies = state.bodies || {};
  state.bodies[url] = fs.readFileSync(bodyPath, 'utf8');
  const failNumber = Number(process.env.FAKE_GH_FAIL_CREATE_NUMBER || (process.env.FAKE_GH_FAIL_AFTER_CREATE === '1' ? 1 : 0));
  if (state.createCount === failNumber && !state.failedAfterCreate) {
    state.failedAfterCreate = true;
    fs.writeFileSync(statePath, JSON.stringify(state));
    process.exit(1);
  }
  if (!state.mutated && process.env.FAKE_GH_MUTATE_PATH) {
    fs.writeFileSync(process.env.FAKE_GH_MUTATE_PATH, process.env.FAKE_GH_MUTATE_CONTENT);
    state.mutated = true;
  }
  process.stdout.write(url + '\\n');
} else if (args[1] === 'edit') {
  const bodyPath = args[args.indexOf('--body-file') + 1];
  state.bodies = state.bodies || {};
  state.bodies[args[2]] = fs.readFileSync(bodyPath, 'utf8');
  process.stdout.write(args[2] + '\\n');
} else {
  process.exit(2);
}
fs.writeFileSync(statePath, JSON.stringify(state));
`, 'utf8');
  chmodSync(ghCli, 0o755);

  writeJson(path.join(projectDir, '.shared-adapter', 'settings.json'), {
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
        baseBranch: 'main', syncBeforeResearch: false,
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
  writeFileSync(path.join(worktreeRoot, notePath), updated, 'utf8');

  const folded: TestFoldedJournal = {
    schemaVersion: 1,
    featureSlug: 'publish-contracts',
    candidates: [{
      candidateId: 'candidate-1',
      status: 'kept',
      writeReceipt: {
        provider: 'obsidian', state: 'applied', operation: 'update', sourceId: 'project',
        repositoryRef: 'wiki', bindingDigest: binding.bindingDigest,
        wikiId: 'project/example/contract', path: notePath,
        beforeHash: contentHash(original), afterHash: contentHash(updated),
      },
    }],
  };
  return {
    env, projectDir, worktreeRoot, remoteRoot, ghState, notePath, original, updated,
    folded,
  };
}

function addSecondRepository(input: ReturnType<typeof fixture>): { worktreeRoot: string; remoteRoot: string; notePath: string } {
  const root = path.dirname(input.worktreeRoot);
  const worktreeRoot = path.join(root, 'shared-knowledge');
  const remoteRoot = path.join(root, 'shared-knowledge.git');
  const sourceRoot = 'Shared/Engineering';
  const notePath = `${sourceRoot}/review.md`;
  const original = note('shared/engineering/review', 'Original review contract.', 'Original shared content.');
  const updated = note('shared/engineering/review', 'Updated review contract.', 'Reviewed shared content.');
  command('git', ['init', '--bare', remoteRoot]);
  command('git', ['init', '--initial-branch=main', worktreeRoot]);
  command('git', ['config', 'user.name', 'Test User'], worktreeRoot);
  command('git', ['config', 'user.email', 'test@example.invalid'], worktreeRoot);
  command('git', ['remote', 'add', 'origin', remoteRoot], worktreeRoot);
  mkdirSync(path.join(worktreeRoot, sourceRoot, '_meta'), { recursive: true });
  writeFileSync(path.join(worktreeRoot, sourceRoot, '_meta', 'wiki-source.md'), manifest('shared', 'shared'), 'utf8');
  writeFileSync(path.join(worktreeRoot, notePath), original, 'utf8');
  command('git', ['add', '.'], worktreeRoot);
  command('git', ['commit', '-m', 'base'], worktreeRoot);
  command('git', ['push', '-u', 'origin', 'main'], worktreeRoot);

  const settingsPath = path.join(input.projectDir, '.shared-adapter', 'settings.json');
  const settings = JSON.parse(readFileSync(settingsPath, 'utf8'));
  settings.wiki.obsidian.bindings.push({
    sourceId: 'shared', role: 'shared', vaultRef: 'knowledge', repositoryRef: 'wiki-shared',
    root: sourceRoot, access: { read: true, update: 'direct' },
  });
  writeJson(settingsPath, settings);
  const registryPath = input.env.OBSIDIAN_WIKI_REGISTRY!;
  const registry = JSON.parse(readFileSync(registryPath, 'utf8'));
  registry.repositories['wiki-shared'] = {
    worktreeRoot, remote: 'origin', expectedRemote: remoteRoot,
    baseBranch: 'main', syncBeforeResearch: false,
  };
  writeJson(registryPath, registry);
  const binding = resolveBindings(input.env).bindings.find((candidate) => candidate.sourceId === 'shared')!;
  writeFileSync(path.join(worktreeRoot, notePath), updated, 'utf8');
  input.folded.candidates.push({
    candidateId: 'candidate-2',
    status: 'kept',
    writeReceipt: {
      provider: 'obsidian', state: 'applied', operation: 'update', sourceId: 'shared',
      repositoryRef: 'wiki-shared', bindingDigest: binding.bindingDigest,
      wikiId: 'shared/engineering/review', path: notePath,
      beforeHash: contentHash(original), afterHash: contentHash(updated),
    },
  });
  return { worktreeRoot, remoteRoot, notePath };
}

afterEach(() => {
  while (createdDirectories.length) rmSync(createdDirectories.pop()!, { recursive: true, force: true });
});

describe('Obsidian Wiki GitHub publishing', () => {
  it('exposes publishing through the bundled JSON CLI', () => {
    const input = fixture();

    const output = String(execFileSync(process.execPath, [path.resolve('dist/index.js'), 'publish'], {
      cwd: path.resolve('.'),
      env: input.env,
      input: JSON.stringify(input.folded),
      encoding: 'utf8',
      stdio: ['pipe', 'pipe', 'pipe'],
    }));

    const result = JSON.parse(output);
    expect(result.kind).toBe('grill-adapter.obsidian-wiki-publish');
    expect(result.repositories[0].state).toBe('published');
  });

  it('publishes only applied receipt paths as a draft PR and restores the base worktree', () => {
    const input = fixture();

    const result = publishFromFoldedJournal(input.folded, input.env);

    expect(result.repositories).toHaveLength(1);
    expect(result.repositories[0]).toMatchObject({
      repositoryRef: 'wiki',
      prUrl: 'https://github.com/acme/knowledge/pull/42',
      state: 'published',
    });
    const branch = result.repositories[0].branch;
    const commit = command('git', [`--git-dir=${input.remoteRoot}`, 'rev-parse', `refs/heads/${branch}`]);
    expect(command('git', [`--git-dir=${input.remoteRoot}`, 'diff-tree', '--no-commit-id', '--name-only', '-r', commit]))
      .toBe(input.notePath);
    expect(command('git', ['branch', '--show-current'], input.worktreeRoot)).toBe('main');
    expect(readFileSync(path.join(input.worktreeRoot, input.notePath), 'utf8')).toBe(input.original);
    expect(existsSync(path.join(input.worktreeRoot, '.grill-adapter-wiki.publish.lock'))).toBe(false);
    expect(existsSync(path.join(input.projectDir, '.adapter', 'context', 'publish-contracts.wiki-publish.json'))).toBe(true);
    const gh = JSON.parse(readFileSync(input.ghState, 'utf8'));
    expect(gh.calls.filter((args: string[]) => args[0] === 'pr' && args[1] === 'create')).toHaveLength(1);
    expect(gh.calls.find((args: string[]) => args[1] === 'create')).toContain('--draft');

    const integrator = path.join(path.dirname(input.worktreeRoot), 'integrator');
    command('git', ['clone', '--branch', 'main', input.remoteRoot, integrator]);
    command('git', ['config', 'user.name', 'Integrator'], integrator);
    command('git', ['config', 'user.email', 'integrator@example.invalid'], integrator);
    command('git', ['merge', '--ff-only', `origin/${branch}`], integrator);
    command('git', ['push', 'origin', 'main'], integrator);
    command('git', ['fetch', 'origin', 'main'], input.worktreeRoot);
    command('git', ['merge', '--ff-only', 'origin/main'], input.worktreeRoot);
    expect(resolveBindings(input.env).errors).toEqual([]);
    expect(readFileSync(path.join(input.worktreeRoot, input.notePath), 'utf8')).toBe(input.updated);
  });

  it('rejects repository changes outside the applied receipt allowlist', () => {
    const input = fixture();
    writeFileSync(
      path.join(input.worktreeRoot, 'Projects/example/unrelated.md'),
      note('project/example/unrelated', 'Unrelated.', 'This Note has no applied receipt.'),
      'utf8',
    );

    expect(() => publishFromFoldedJournal(input.folded, input.env))
      .toThrow(/changes differ from the applied receipt allowlist/);
    expect(existsSync(path.join(input.projectDir, '.adapter', 'context', 'publish-contracts.wiki-publish.json'))).toBe(false);
    expect(command('git', ['branch', '--show-current'], input.worktreeRoot)).toBe('main');
  });

  it('verifies ADR authority identity against the project Source and staged Note', () => {
    const projection: AdrProjection = {
      authorityType: 'project-adr',
      projectionType: 'execution-constraints',
      sourceId: `project-adr:${'1'.repeat(64)}`,
      sourcePath: 'docs/adr/0001-publish.md',
      sourceContentHash: `sha256:${'2'.repeat(64)}`,
      targetScope: 'project',
    };

    const valid = fixture();
    const projected = adrProjectionNote(
      'project/example/contract',
      projection,
      'Future publishers must validate the staged Note against its ADR identity.',
    );
    writeFileSync(path.join(valid.worktreeRoot, valid.notePath), projected, 'utf8');
    valid.folded.candidates[0].adrProjection = projection;
    valid.folded.candidates[0].writeReceipt.adrProjection = projection;
    valid.folded.candidates[0].writeReceipt.afterHash = contentHash(projected);
    expect(() => publishFromFoldedJournal(valid.folded, valid.env)).not.toThrow();

    const stripped = fixture();
    stripped.folded.candidates[0].adrProjection = projection;
    stripped.folded.candidates[0].writeReceipt.adrProjection = projection;
    expect(() => publishFromFoldedJournal(stripped.folded, stripped.env))
      .toThrow(/ADR execution projection authority drift/);

    const shared = fixture();
    addSecondRepository(shared);
    const sharedCandidate = shared.folded.candidates[1];
    sharedCandidate.adrProjection = projection;
    sharedCandidate.writeReceipt.adrProjection = projection;
    expect(() => publishFromFoldedJournal(shared.folded, shared.env))
      .toThrow(/ADR execution projection receipt must reference a project Source/);
  });

  it('ignores a skipped ADR projection while publishing kept applied receipts', () => {
    const input = fixture();
    input.folded.candidates.push({
      candidateId: 'candidate-skipped-adr',
      status: 'skipped',
      adrProjection: {
        authorityType: 'project-adr',
        projectionType: 'execution-constraints',
        sourceId: `project-adr:${'3'.repeat(64)}`,
        sourcePath: 'docs/adr/0002-no-execution-constraints.md',
        sourceContentHash: `sha256:${'4'.repeat(64)}`,
        targetScope: 'project',
      },
    } as unknown as TestFoldedJournal['candidates'][number]);

    const result = publishFromFoldedJournal(input.folded, input.env);

    expect(result.repositories[0].paths).toEqual([input.notePath]);
  });

  it('ignores a recoverable proposed receipt while publishing kept applied receipts', () => {
    const input = fixture();
    input.folded.candidates.push({
      candidateId: 'candidate-deferred',
      status: 'deferred',
      writeReceipt: {
        ...input.folded.candidates[0].writeReceipt,
        state: 'proposed',
      },
    });

    const result = publishFromFoldedJournal(input.folded, input.env);

    expect(result.repositories[0].paths).toEqual([input.notePath]);
  });

  it('rejects a bound Source whose publishing mode is not git-pr', () => {
    const input = fixture();
    const settingsPath = path.join(input.projectDir, '.shared-adapter', 'settings.json');
    const settings = JSON.parse(readFileSync(settingsPath, 'utf8'));
    settings.wiki.publishing.mode = 'manual';
    writeJson(settingsPath, settings);

    expect(() => resolveBindings(input.env, input.projectDir, { allowStagedWikiChanges: true }))
      .toThrow(/git-pr/);
  });

  it('publishes an allowlisted created Note without exposing it on base', () => {
    const input = fixture();
    const createdPath = 'Projects/example/new-contract.md';
    const created = note('project/example/new-contract', 'New contract.', 'A reviewed new contract.');
    writeFileSync(path.join(input.worktreeRoot, input.notePath), input.original, 'utf8');
    writeFileSync(path.join(input.worktreeRoot, createdPath), created, 'utf8');
    input.folded.candidates[0].writeReceipt = {
      ...input.folded.candidates[0].writeReceipt,
      operation: 'create',
      wikiId: 'project/example/new-contract',
      path: createdPath,
      beforeHash: null,
      afterHash: contentHash(created),
    };

    const result = publishFromFoldedJournal(input.folded, input.env);

    expect(result.repositories[0].state).toBe('published');
    expect(existsSync(path.join(input.worktreeRoot, createdPath))).toBe(false);
    expect(command('git', [`--git-dir=${input.remoteRoot}`, 'show', `${result.repositories[0].branch}:${createdPath}`]))
      .toContain('A reviewed new contract.');
  });

  it('resumes after PR creation without duplicating the commit, push, or PR', () => {
    const input = fixture();
    input.env.FAKE_GH_FAIL_AFTER_CREATE = '1';

    expect(() => publishFromFoldedJournal(input.folded, input.env)).toThrow(/gh .*pr create.* failed/);
    expect(command('git', ['branch', '--show-current'], input.worktreeRoot)).toBe('main');

    const result = publishFromFoldedJournal(input.folded, input.env);

    expect(result.repositories[0]).toMatchObject({
      state: 'published',
      prUrl: 'https://github.com/acme/knowledge/pull/42',
    });
    const gh = JSON.parse(readFileSync(input.ghState, 'utf8'));
    expect(gh.calls.filter((args: string[]) => args[0] === 'pr' && args[1] === 'create')).toHaveLength(1);
    const branch = result.repositories[0].branch;
    expect(command('git', [`--git-dir=${input.remoteRoot}`, 'rev-list', '--count', `main..${branch}`])).toBe('1');
  });

  it('resumes a branch created before a failed commit', () => {
    const input = fixture();
    command('git', ['config', 'user.name', ''], input.worktreeRoot);

    expect(() => publishFromFoldedJournal(input.folded, input.env)).toThrow(/git commit .* failed/);
    expect(command('git', ['branch', '--show-current'], input.worktreeRoot)).toBe('main');
    expect(command('git', ['status', '--porcelain'], input.worktreeRoot)).toBe('');
    expect(readFileSync(path.join(input.worktreeRoot, input.notePath), 'utf8')).toBe(input.original);
    const manifestPath = path.join(input.projectDir, '.adapter', 'context', 'publish-contracts.wiki-publish.json');
    expect(JSON.parse(readFileSync(manifestPath, 'utf8')).repositories[0].stagedTree)
      .toMatch(/^[a-f0-9]{40,64}$/);

    command('git', ['config', 'user.name', 'Test User'], input.worktreeRoot);
    const result = publishFromFoldedJournal(input.folded, input.env);

    expect(result.repositories[0].state).toBe('published');
    expect(command('git', [`--git-dir=${input.remoteRoot}`, 'rev-list', '--count', `main..${result.repositories[0].branch}`])).toBe('1');
  });

  it('recovers a publish commit created before its manifest receipt was persisted', () => {
    const input = fixture();
    const runId = '123e4567-e89b-42d3-a456-426614174000';
    const branch = `grill-adapter/wiki/${input.folded.featureSlug}-wiki-${runId.slice(0, 8)}`;
    const manifestPath = path.join(
      input.projectDir,
      '.adapter',
      'context',
      `${input.folded.featureSlug}.wiki-publish.json`,
    );
    writeJson(manifestPath, {
      schemaVersion: 1,
      kind: 'grill-adapter.obsidian-wiki-publish',
      runId,
      featureSlug: input.folded.featureSlug,
      repositories: [{
        repositoryRef: 'wiki', baseBranch: 'main', branch, paths: [input.notePath],
        stagedTree: null, commit: null, prUrl: null, state: 'pending',
      }],
    });
    command('git', ['switch', '-c', branch], input.worktreeRoot);
    command('git', ['add', '--', input.notePath], input.worktreeRoot);
    command('git', ['commit', '-m', 'unrecorded publish commit'], input.worktreeRoot);

    const result = publishFromFoldedJournal(input.folded, input.env);

    expect(result.repositories[0]).toMatchObject({ branch, state: 'published' });
    expect(result.repositories[0].commit).toBeTruthy();
    expect(command('git', ['branch', '--show-current'], input.worktreeRoot)).toBe('main');
  });

  it('rejects a colliding publish branch whose Note contents do not match the applied receipt', () => {
    const input = fixture();
    command('git', ['config', 'user.name', ''], input.worktreeRoot);
    expect(() => publishFromFoldedJournal(input.folded, input.env)).toThrow(/git commit .* failed/);

    command('git', ['restore', '--staged', '--worktree', '--', input.notePath], input.worktreeRoot);
    command('git', ['config', 'user.name', 'Test User'], input.worktreeRoot);
    const manifestPath = path.join(input.projectDir, '.adapter', 'context', 'publish-contracts.wiki-publish.json');
    const publishBranch = JSON.parse(readFileSync(manifestPath, 'utf8')).repositories[0].branch;
    command('git', ['switch', publishBranch], input.worktreeRoot);
    writeFileSync(
      path.join(input.worktreeRoot, input.notePath),
      note('project/example/contract', 'Unreviewed collision.', 'Different contents on a colliding branch.'),
      'utf8',
    );
    command('git', ['add', '--', input.notePath], input.worktreeRoot);
    command('git', ['commit', '-m', 'colliding publish branch'], input.worktreeRoot);
    command('git', ['switch', 'main'], input.worktreeRoot);

    expect(() => publishFromFoldedJournal(input.folded, input.env))
      .toThrow(/write receipt afterHash drift/);
    expect(command('git', ['branch', '--show-current'], input.worktreeRoot)).toBe('main');
  });

  it('revalidates receipt contents under each repository publish lock', () => {
    const input = fixture();
    const second = addSecondRepository(input);
    const mutated = note('shared/engineering/review', 'Mutated after preflight.', 'Unreviewed concurrent contents.');
    input.env.FAKE_GH_MUTATE_PATH = path.join(second.worktreeRoot, second.notePath);
    input.env.FAKE_GH_MUTATE_CONTENT = mutated;

    expect(() => publishFromFoldedJournal(input.folded, input.env))
      .toThrow(/write receipt afterHash drift/);
    expect(command('git', ['branch', '--show-current'], second.worktreeRoot)).toBe('main');
  }, 15_000);

  it('rejects new base-worktree changes while resuming a fixed publish commit', () => {
    const input = fixture();
    input.env.FAKE_GH_FAIL_AFTER_CREATE = '1';
    expect(() => publishFromFoldedJournal(input.folded, input.env)).toThrow();
    const unrelatedPath = path.join(input.worktreeRoot, 'Projects/example/unrelated.md');
    writeFileSync(unrelatedPath, note('project/example/unrelated', 'Unrelated.', 'A later Capture change.'), 'utf8');

    expect(() => publishFromFoldedJournal(input.folded, input.env))
      .toThrow(/base worktree must be clean while resuming/);
    expect(command('git', ['branch', '--show-current'], input.worktreeRoot)).toBe('main');
  });

  it('resumes a partial multi-repository run and coordinates peer draft PRs', () => {
    const input = fixture();
    const second = addSecondRepository(input);
    input.env.FAKE_GH_FAIL_CREATE_NUMBER = '2';

    expect(() => publishFromFoldedJournal(input.folded, input.env)).toThrow(/gh .*pr create.* failed/);
    expect(command('git', ['branch', '--show-current'], input.worktreeRoot)).toBe('main');
    expect(command('git', ['branch', '--show-current'], second.worktreeRoot)).toBe('main');

    const result = publishFromFoldedJournal(input.folded, input.env);

    expect(result.repositories.map((repository) => repository.state)).toEqual(['published', 'published']);
    const gh = JSON.parse(readFileSync(input.ghState, 'utf8'));
    expect(gh.calls.filter((args: string[]) => args[1] === 'create')).toHaveLength(2);
    expect(gh.calls.filter((args: string[]) => args[1] === 'edit')).toHaveLength(2);
    const urls = result.repositories.map((repository) => repository.prUrl!);
    for (const url of urls) {
      const peer = urls.find((candidate) => candidate !== url)!;
      expect(gh.bodies[url]).toContain(peer);
    }
    for (const repository of result.repositories) {
      const remote = repository.repositoryRef === 'wiki' ? input.remoteRoot : second.remoteRoot;
      expect(command('git', [`--git-dir=${remote}`, 'rev-list', '--count', `main..${repository.branch}`])).toBe('1');
    }
  });
});
