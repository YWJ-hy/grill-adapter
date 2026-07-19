import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import { searchTool } from '../src/tools/search.js';
import { readNotesTool } from '../src/tools/read.js';
import { graphNeighborsTool } from '../src/tools/graph.js';

const createdDirectories: string[] = [];

function writeJson(filePath: string, value: unknown): void {
  mkdirSync(path.dirname(filePath), { recursive: true });
  writeFileSync(filePath, JSON.stringify(value, null, 2), 'utf8');
}

function sourceManifest(sourceId: string): string {
  return `---\nwiki_schema: grill-adapter.obsidian-source/v1\nwiki_source_id: ${sourceId}\nscope: project\nupdate_existing: confirm\ncreate_note: confirm\n---\n\n# ${sourceId}\n`;
}

function note(wikiId: string, summary: string, options: { status?: string; agentVisible?: boolean; dependsOn?: string[]; skillRoles?: string[] } = {}): string {
  const dependsOn = options.dependsOn?.length ? `depends_on:\n${options.dependsOn.map((value) => `  - "${value}"`).join('\n')}\n` : '';
  const skillRoles = options.skillRoles?.length ? `skill_roles:\n${options.skillRoles.map((value) => `  - ${value}`).join('\n')}\n` : '';
  return `---\nwiki_schema: grill-adapter.obsidian-note/v1\nwiki_id: ${wikiId}\ntype: constraint\nstatus: ${options.status ?? 'active'}\nagent_visible: ${options.agentVisible ?? true}\nsummary: ${summary}\nconstraint_strength: hard\n${dependsOn}${skillRoles}---\n\n# ${wikiId}\n\nRule body.\n`;
}

function fixture() {
  const root = mkdtempSync(path.join(tmpdir(), 'obsidian-retrieval-'));
  createdDirectories.push(root);
  const projectDir = path.join(root, 'project');
  const vaultRoot = path.join(root, 'vault');
  const registryPath = path.join(root, 'registry.json');
  const obsidianCli = path.join(root, 'obsidian');
  const sourceRoot = path.join(vaultRoot, 'Projects', 'example');
  mkdirSync(path.join(sourceRoot, '_meta'), { recursive: true });
  writeFileSync(path.join(sourceRoot, '_meta', 'wiki-source.md'), sourceManifest('project'), 'utf8');
  writeFileSync(path.join(sourceRoot, 'Visible.md'), note('project/example/visible', 'Visible note', { dependsOn: ['[[Projects/example/Dependency]]'] }), 'utf8');
  writeFileSync(path.join(sourceRoot, 'Dependency.md'), note('project/example/dependency', 'Dependency note', { dependsOn: ['[[Projects/example/Transitive]]'] }), 'utf8');
  writeFileSync(path.join(sourceRoot, 'Transitive.md'), note('project/example/transitive', 'Transitive note'), 'utf8');
  writeFileSync(path.join(sourceRoot, 'Archived.md'), note('project/example/archived', 'Archived note', { status: 'archived' }), 'utf8');
  writeFileSync(path.join(sourceRoot, 'Private.md'), note('project/example/private', 'Private note', { agentVisible: false }), 'utf8');
  writeFileSync(path.join(sourceRoot, 'ReviewSkill.md'), note('project/example/review-skill', 'Review Skill Card', { skillRoles: ['reviewer'] }), 'utf8');
  mkdirSync(path.join(vaultRoot, 'Projects', 'other'), { recursive: true });
  writeFileSync(path.join(vaultRoot, 'Projects', 'other', 'Other.md'), note('project/other/private', 'Other project note'), 'utf8');
  execFileSync('git', ['init', '--initial-branch=main', vaultRoot]);
  execFileSync('git', ['-C', vaultRoot, 'config', 'user.name', 'Test User']);
  execFileSync('git', ['-C', vaultRoot, 'config', 'user.email', 'test@example.invalid']);
  execFileSync('git', ['-C', vaultRoot, 'remote', 'add', 'origin', 'https://github.com/acme/knowledge.git']);
  execFileSync('git', ['-C', vaultRoot, 'add', '.']);
  execFileSync('git', ['-C', vaultRoot, 'commit', '-m', 'fixture']);
  writeFileSync(obsidianCli, `#!/usr/bin/env node
const fs = require('node:fs');
const path = require('node:path');
const args = process.argv.slice(2);
const vaultRoot = process.env.FAKE_OBSIDIAN_VAULT_ROOT;
if (process.env.FAKE_OBSIDIAN_CALLS) fs.appendFileSync(process.env.FAKE_OBSIDIAN_CALLS, args.join(' ') + '\\n');
if (args[0] === 'vault') process.stdout.write('Knowledge\\n');
else if (args.includes('search')) process.stdout.write(JSON.stringify([
  { path: 'Projects/example/Visible.md' },
  { path: 'Projects/example/Dependency.md' },
  { path: 'Projects/example/Transitive.md' },
  { path: 'Projects/example/Archived.md' },
  { path: 'Projects/example/Private.md' },
  { path: 'Projects/example/ReviewSkill.md' },
  { path: 'Projects/other/Other.md' },
]));
else if (args.includes('read')) {
  const notePath = args[args.indexOf('read') + 1];
  const statePath = process.env.FAKE_OBSIDIAN_READ_STATE;
  const readCount = statePath && fs.existsSync(statePath) ? Number(fs.readFileSync(statePath, 'utf8')) : 0;
  if (statePath) fs.writeFileSync(statePath, String(readCount + 1));
  const content = fs.readFileSync(path.join(vaultRoot, notePath), 'utf8');
  process.stdout.write(JSON.stringify({ path: notePath, content: process.env.FAKE_OBSIDIAN_MUTATE_SECOND_READ === 'true' && readCount === 1 ? content.replace('Rule body.', 'Changed body.') : content }));
} else process.exit(2);
`, 'utf8');
  chmodSync(obsidianCli, 0o755);
  writeJson(path.join(projectDir, '.shared-adapter', 'settings.json'), {
    wiki: {
      provider: 'obsidian',
      publishing: { mode: 'git-pr' },
      obsidian: {
        bindings: [{ sourceId: 'project', role: 'project', vaultRef: 'knowledge', repositoryRef: 'wiki', root: 'Projects/example', access: { read: true } }],
      },
    },
  });
  writeJson(registryPath, {
    vaults: { knowledge: { selector: 'Knowledge' } },
    repositories: { wiki: { worktreeRoot: vaultRoot, remote: 'origin', expectedRemote: 'github.com/acme/knowledge', baseBranch: 'main', syncBeforeResearch: false } },
  });
  return {
    vaultRoot,
    env: {
      CLAUDE_PROJECT_DIR: projectDir,
      OBSIDIAN_WIKI_REGISTRY: registryPath,
      OBSIDIAN_WIKI_OBSIDIAN_CLI: obsidianCli,
      FAKE_OBSIDIAN_VAULT_ROOT: vaultRoot,
    },
  };
}

afterEach(() => {
  while (createdDirectories.length) rmSync(createdDirectories.pop()!, { recursive: true, force: true });
});

describe('Obsidian Wiki retrieval', () => {
  it('searches only active agent-visible Notes under readable bound Sources', () => {
    const { env } = fixture();

    const result = searchTool({ query: 'note' }, env);

    expect(result.notes).toContainEqual(expect.objectContaining({
      sourceId: 'project',
      wikiId: 'project/example/visible',
      path: 'Projects/example/Visible.md',
      summary: 'Visible note',
    }));
    expect(result.notes.map((note) => note.wikiId)).not.toContain('project/example/archived');
    expect(result.notes.map((note) => note.wikiId)).not.toContain('project/example/private');
    expect(result.notes.map((note) => note.wikiId)).not.toContain('project/other/private');
  });

  it('exposes declared Skill Card roles without returning Note content from search', () => {
    const { env } = fixture();
    const result = searchTool({ query: 'skill' }, env);

    const skill = result.notes.find((note) => note.wikiId === 'project/example/review-skill');
    expect(skill).toMatchObject({
      wikiId: 'project/example/review-skill',
      skillRoles: ['reviewer'],
      constraintStrength: 'hard',
    });
    expect(skill).not.toHaveProperty('content');
  });

  it('targets the binding Vault explicitly for Obsidian search and reads', () => {
    const { env } = fixture();
    const callsPath = path.join(tmpdir(), `obsidian-cli-calls-${process.pid}-${createdDirectories.length}`);

    searchTool({ query: 'note' }, { ...env, FAKE_OBSIDIAN_CALLS: callsPath });

    expect(readFileSync(callsPath, 'utf8')).toContain('vault=Knowledge');
    rmSync(callsPath, { force: true });
  });

  it('serves batch reads through the built JSON CLI seam', () => {
    const { env } = fixture();
    const bundle = path.resolve(import.meta.dirname, '..', 'dist', 'index.js');

    const output = execFileSync('node', [bundle, 'read-notes'], {
      encoding: 'utf8',
      input: JSON.stringify({ paths: ['Projects/example/Visible.md'] }),
      env: { ...process.env, ...env },
    });

    expect(JSON.parse(output)).toMatchObject({
      notes: [expect.objectContaining({ wikiId: 'project/example/visible' })],
      snapshotHash: expect.stringMatching(/^sha256:[a-f0-9]{64}$/),
    });
  });

  it('batch reads bound Notes with stable content and snapshot hashes', () => {
    const { env } = fixture();

    const result = readNotesTool({ paths: ['Projects/example/Visible.md'] }, env);

    expect(result).toEqual({
      notes: [expect.objectContaining({
        sourceId: 'project',
        wikiId: 'project/example/visible',
        content: expect.stringContaining('Rule body.'),
        contentHash: expect.stringMatching(/^sha256:[a-f0-9]{64}$/),
      })],
      snapshotHash: expect.stringMatching(/^sha256:[a-f0-9]{64}$/),
    });
    expect(readNotesTool({ paths: ['Projects/example/Visible.md'] }, env).snapshotHash).toBe(result.snapshotHash);
  });

  it('fails closed for requests outside bound Sources', () => {
    const { env } = fixture();

    expect(() => readNotesTool({ paths: ['Projects/other/Other.md'] }, env)).toThrow(/not within a readable bound Source/);
  });

  it('refuses inactive and non-agent-visible Notes on direct reads', () => {
    const { env } = fixture();

    expect(() => readNotesTool({ paths: ['Projects/example/Archived.md'] }, env)).toThrow(/not active and agent-visible/);
    expect(() => readNotesTool({ paths: ['Projects/example/Private.md'] }, env)).toThrow(/not active and agent-visible/);
  });

  it('fails closed when a Note changes during a batch read', () => {
    const { env } = fixture();
    const statePath = path.join(tmpdir(), `obsidian-read-state-${process.pid}-${createdDirectories.length}`);

    expect(() => readNotesTool({ paths: ['Projects/example/Visible.md'] }, {
      ...env,
      FAKE_OBSIDIAN_READ_STATE: statePath,
      FAKE_OBSIDIAN_MUTATE_SECOND_READ: 'true',
    })).toThrow(/changed during stable batch read/);
    rmSync(statePath, { force: true });
  });

  it('returns direct typed neighbors once without recursively traversing their edges', () => {
    const { env } = fixture();

    expect(graphNeighborsTool({ wikiIds: ['project/example/visible'] }, env)).toEqual({
      neighbors: {
        'project/example/visible': [{
          type: 'depends_on',
          wikiId: 'project/example/dependency',
          path: 'Projects/example/Dependency.md',
        }],
      },
    });
  });
});
