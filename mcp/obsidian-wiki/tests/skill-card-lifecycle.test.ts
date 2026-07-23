import { execFileSync } from 'node:child_process';
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import { applyNoteChangeTool, proposeNoteChangeTool } from '../src/tools/write.js';
import { publishFromFoldedJournal } from '../src/publish.js';
import { searchTool } from '../src/tools/search.js';
import { startWriteBridge, type WriteBridgeHandle } from '../src/write-bridge.js';

const roots: string[] = [];
const bridges: WriteBridgeHandle[] = [];
const scaffoldScript = path.resolve(import.meta.dirname, '..', '..', '..', 'scripts', 'scaffold_practice_skill.py');
const journalScript = path.resolve(import.meta.dirname, '..', '..', '..', 'scripts', 'wiki_candidate_journal.py');
const adapterScriptsAvailable = existsSync(scaffoldScript) && existsSync(journalScript);

function command(name: string, args: string[], cwd?: string): string {
  return String(execFileSync(name, args, { cwd, encoding: 'utf8' })).trim();
}

function writeJson(filePath: string, value: unknown): void {
  mkdirSync(path.dirname(filePath), { recursive: true });
  writeFileSync(filePath, JSON.stringify(value, null, 2), 'utf8');
}

function sourceManifest(): string {
  return '---\nwiki_schema: grill-adapter.obsidian-source/v1\nwiki_source_id: project\nscope: project\nupdate_existing: direct\ncreate_note: direct\n---\n';
}

function skillCard(registration: Record<string, unknown>): string {
  const roles = (registration.roles as string[]).map((role) => `  - ${role}`).join('\n');
  const triggers = (registration.triggers as string[]).map((trigger) => `  - ${trigger}`).join('\n');
  return `---\nwiki_schema: grill-adapter.obsidian-note/v1\nwiki_id: project/skills/${registration.name}\ntype: guide\nstatus: active\nagent_visible: true\nsummary: ${registration.summary}\nskill_provider: ${registration.provider}\nskill_name: ${registration.name}\nskill_version: ${registration.version}\nskill_contract_hash: ${registration.contractHash}\nskill_roles:\n${roles}\nskill_triggers:\n${triggers}\n---\n\n# Lifecycle Review\n\nUse the reviewed executable pack.\n`;
}

afterEach(async () => {
  while (bridges.length) await bridges.pop()!.close();
  while (roots.length) rmSync(roots.pop()!, { recursive: true, force: true });
});

describe('reviewed Skill Card lifecycle', () => {
  it.runIf(adapterScriptsAvailable)(
    'stays pending through apply and draft PR, then becomes discoverable after merge and base sync',
    async () => {
    const root = mkdtempSync(path.join(tmpdir(), 'skill-card-lifecycle-'));
    roots.push(root);
    const projectDir = path.join(root, 'project');
    const worktreeRoot = path.join(root, 'knowledge');
    const remoteRoot = path.join(root, 'knowledge.git');
    const sourceRoot = 'Projects/example';
    const registryPath = path.join(root, 'registry.json');
    const obsidianCli = path.join(root, 'obsidian');
    const ghCli = path.join(root, 'gh');
    const journal = path.join(projectDir, '.adapter', 'context', 'card-lifecycle.wiki-candidates.jsonl');

    command('git', ['init', '--bare', '--initial-branch=main', remoteRoot]);
    command('git', ['init', '--initial-branch=main', worktreeRoot]);
    command('git', ['config', 'user.name', 'Test User'], worktreeRoot);
    command('git', ['config', 'user.email', 'test@example.invalid'], worktreeRoot);
    command('git', ['remote', 'add', 'origin', remoteRoot], worktreeRoot);
    mkdirSync(path.join(worktreeRoot, sourceRoot, '_meta'), { recursive: true });
    writeFileSync(path.join(worktreeRoot, sourceRoot, '_meta', 'wiki-source.md'), sourceManifest(), 'utf8');
    command('git', ['add', '.'], worktreeRoot);
    command('git', ['commit', '-m', 'base'], worktreeRoot);
    command('git', ['push', '--set-upstream', 'origin', 'main'], worktreeRoot);

    const packRoot = path.join(projectDir, '.claude', 'skills', 'lifecycle-review');
    mkdirSync(packRoot, { recursive: true });
    writeFileSync(
      path.join(packRoot, 'SKILL.md'),
      '---\nname: lifecycle-review\ndescription: Review Skill Card lifecycle changes.\nversion: 1.0.0\n---\n\n# Lifecycle Review\n',
      'utf8',
    );
    const staged = JSON.parse(command('python3', [
      scaffoldScript,
      '--project-root', projectDir,
      '--json',
      'stage-card',
      '--name', 'lifecycle-review',
      '--feature-slug', 'card-lifecycle',
      '--provider', 'claude-code-project',
      '--version', '1.0.0',
      '--roles', 'review',
      '--triggers', 'Skill Card lifecycle review',
      '--summary', 'Review the Skill Card publishing lifecycle.',
    ]));
    expect(staged.discoveryState).toBe('pending');

    writeFileSync(obsidianCli, `#!/usr/bin/env node
const fs = require('node:fs');
const path = require('node:path');
const args = process.argv.slice(2);
const root = process.env.FAKE_OBSIDIAN_VAULT_ROOT;
if (args[0] === 'vaults') process.stdout.write('Knowledge\\n');
else if (args.includes('search')) {
  const files = [];
  function walk(dir) { for (const name of fs.readdirSync(dir)) { const item = path.join(dir, name); if (fs.statSync(item).isDirectory() && name !== '.git') walk(item); else if (name.endsWith('.md')) files.push(path.relative(root, item).split(path.sep).join('/')); } }
  walk(root);
  process.stdout.write(JSON.stringify(files));
} else if (args.includes('read')) {
  const notePath = args.find((arg) => arg.startsWith('path='))?.slice('path='.length);
  if (!notePath) process.exit(2);
  process.stdout.write(fs.readFileSync(path.join(root, notePath), 'utf8'));
} else process.exit(2);
`, 'utf8');
    chmodSync(obsidianCli, 0o755);
    writeFileSync(ghCli, `#!/usr/bin/env node
const args = process.argv.slice(2);
if (args[0] !== 'pr') process.exit(2);
if (args[1] === 'list') process.stdout.write('');
else if (args[1] === 'create') process.stdout.write('https://github.com/acme/knowledge/pull/42\\n');
else if (args[1] === 'edit') process.stdout.write(args[2] + '\\n');
else process.exit(2);
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
    const bridge = await startWriteBridge({
      vaultRoot: worktreeRoot,
      vaultSelector: 'Knowledge',
      allowedRoots: [sourceRoot],
      projectDirs: [projectDir],
      token: 'bridge-token',
      port: 0,
    });
    bridges.push(bridge);
    writeJson(registryPath, {
      vaults: { knowledge: { selector: 'Knowledge', bridgeUrl: bridge.url, bridgeTokenEnv: 'BRIDGE_TOKEN' } },
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
      FAKE_OBSIDIAN_VAULT_ROOT: worktreeRoot,
      BRIDGE_TOKEN: 'bridge-token',
    };

    const cardPath = `${sourceRoot}/Skills/lifecycle-review.md`;
    const content = skillCard(staged.skillRegistration);
    const change = { sourceId: 'project', operation: 'create' as const, path: cardPath, content, expectedHash: null };
    const proposal = await proposeNoteChangeTool(change, env);
    const applied = await applyNoteChangeTool(change, env);
    expect(proposal.diff.afterHash).toBe(applied.postWrite!.contentHash);
    expect(applied.skillRegistration).toEqual(staged.skillRegistration);
    const appliedRegistration = applied.skillRegistration!;

    command('python3', [
      journalScript,
      'outcome',
      '--journal', journal,
      '--feature-slug', 'card-lifecycle',
      '--candidate-id', staged.candidateId,
      '--status', 'kept',
      '--reason', 'Reviewed Card applied through the bridge.',
      '--write-state', 'applied',
      '--operation', 'create',
      '--source-id', applied.sourceId,
      '--repository-ref', applied.repositoryRef,
      '--binding-digest', applied.bindingDigest,
      '--wiki-id', applied.postWrite!.wikiId,
      '--path', applied.postWrite!.path,
      '--after-hash', applied.postWrite!.contentHash,
      '--skill-provider', appliedRegistration.provider,
      '--skill-name', appliedRegistration.name,
      '--skill-version', appliedRegistration.version,
      '--skill-contract-hash', appliedRegistration.contractHash,
      ...appliedRegistration.roles.flatMap((role) => ['--skill-role', role]),
      ...appliedRegistration.triggers.flatMap((trigger) => ['--skill-trigger', trigger]),
      '--skill-summary', appliedRegistration.summary,
    ]);
    const folded = JSON.parse(command('python3', [
      journalScript,
      'fold',
      '--journal', journal,
      '--feature-slug', 'card-lifecycle',
    ]));
    expect(folded.candidates[0].skillRegistration.discoveryState).toBe('pending');

    const published = publishFromFoldedJournal(folded, env);
    expect(published.repositories[0]).toMatchObject({ state: 'published', prUrl: expect.stringContaining('/pull/') });
    expect(searchTool({ query: 'lifecycle' }, env).notes.map((note) => note.wikiId))
      .not.toContain('project/skills/lifecycle-review');

    const publishBranch = published.repositories[0].branch;
    command('git', ['push', 'origin', `${publishBranch}:main`], worktreeRoot);
    const discovered = searchTool({ query: 'lifecycle' }, env).notes.find(
      (note) => note.wikiId === 'project/skills/lifecycle-review',
    );
    expect(discovered).toMatchObject({
      skillName: 'lifecycle-review',
      skillVersion: '1.0.0',
      skillRoles: ['reviewer'],
      discoveryState: 'discoverable',
    });
    expect(readFileSync(path.join(worktreeRoot, cardPath), 'utf8')).toBe(content);
    },
  );
});
