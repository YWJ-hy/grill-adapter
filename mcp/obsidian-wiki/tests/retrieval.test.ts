import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import { searchTool } from '../src/tools/search.js';
import { readNotesByWikiIdsTool, readNotesTool } from '../src/tools/read.js';
import { graphNeighborsTool } from '../src/tools/graph.js';

const createdDirectories: string[] = [];

function writeJson(filePath: string, value: unknown): void {
  mkdirSync(path.dirname(filePath), { recursive: true });
  writeFileSync(filePath, JSON.stringify(value, null, 2), 'utf8');
}

function sourceManifest(sourceId: string): string {
  return `---\nwiki_schema: grill-adapter.obsidian-source/v1\nwiki_source_id: ${sourceId}\nscope: project\nupdate_existing: confirm\ncreate_note: confirm\n---\n\n# ${sourceId}\n`;
}

function note(wikiId: string, summary: string, options: {
  status?: string;
  agentVisible?: boolean;
  dependsOn?: string[];
  skill?: {
    provider: string;
    name: string;
    version: string;
    contractHash: string;
    roles: string[];
    triggers: string[];
  };
} = {}): string {
  const dependsOn = options.dependsOn?.length ? `depends_on:\n${options.dependsOn.map((value) => `  - "${value}"`).join('\n')}\n` : '';
  const skill = options.skill
    ? `skill_provider: ${options.skill.provider}\nskill_name: ${options.skill.name}\nskill_version: ${options.skill.version}\nskill_contract_hash: ${options.skill.contractHash}\nskill_roles:\n${options.skill.roles.map((value) => `  - ${value}`).join('\n')}\nskill_triggers:\n${options.skill.triggers.map((value) => `  - ${value}`).join('\n')}\n`
    : '';
  const type = options.skill ? 'guide' : 'constraint';
  const strength = options.skill ? '' : 'constraint_strength: hard\n';
  return `---\nwiki_schema: grill-adapter.obsidian-note/v1\nwiki_id: ${wikiId}\ntype: ${type}\nstatus: ${options.status ?? 'active'}\nagent_visible: ${options.agentVisible ?? true}\nsummary: ${summary}\n${strength}${dependsOn}${skill}---\n\n# ${wikiId}\n\nRule body.\n`;
}

function fixture() {
  const root = mkdtempSync(path.join(tmpdir(), 'obsidian-retrieval-'));
  createdDirectories.push(root);
  const projectDir = path.join(root, 'project');
  const vaultRoot = path.join(root, 'vault');
  const remoteRoot = path.join(root, 'knowledge.git');
  const registryPath = path.join(root, 'registry.json');
  const obsidianCli = path.join(root, process.platform === 'win32' ? 'obsidian.cmd' : 'obsidian');
  const obsidianScript = process.platform === 'win32' ? path.join(root, 'obsidian.js') : obsidianCli;
  const sourceRoot = path.join(vaultRoot, 'Projects', 'example');
  const skillPack = path.join(projectDir, '.claude', 'skills', 'review-runtime');
  mkdirSync(skillPack, { recursive: true });
  writeFileSync(
    path.join(skillPack, 'SKILL.md'),
    '---\nname: review-runtime\ndescription: Review runtime changes.\nversion: 1.0.0\n---\n\n# Review Runtime\n',
    'utf8',
  );
  const staleSkillPack = path.join(projectDir, '.claude', 'skills', 'stale-runtime');
  mkdirSync(staleSkillPack, { recursive: true });
  writeFileSync(
    path.join(staleSkillPack, 'SKILL.md'),
    '---\nname: stale-runtime\ndescription: Review stale runtime changes.\nversion: 1.0.0\n---\n\n# Stale Runtime\n',
    'utf8',
  );
  mkdirSync(path.join(sourceRoot, '_meta'), { recursive: true });
  writeFileSync(path.join(sourceRoot, '_meta', 'wiki-source.md'), sourceManifest('project'), 'utf8');
  writeFileSync(path.join(sourceRoot, 'Visible.md'), note('project/example/visible', 'Visible note', { dependsOn: ['[[Projects/example/Dependency]]'] }), 'utf8');
  writeFileSync(path.join(sourceRoot, 'Dependency.md'), note('project/example/dependency', 'Dependency note', { dependsOn: ['[[Projects/example/Transitive]]'] }), 'utf8');
  writeFileSync(path.join(sourceRoot, 'Transitive.md'), note('project/example/transitive', 'Transitive note'), 'utf8');
  writeFileSync(path.join(sourceRoot, 'Archived.md'), note('project/example/archived', 'Archived note', { status: 'archived' }), 'utf8');
  writeFileSync(path.join(sourceRoot, 'Private.md'), note('project/example/private', 'Private note', { agentVisible: false }), 'utf8');
  const matchingSkill = {
    provider: 'claude-code-project',
    name: 'review-runtime',
    version: '1.0.0',
    contractHash: 'sha256:5cea9f04d62aa80841dedb5c02af7f85b3bb074a0e12a18f293954e4ea3bbc3c',
    roles: ['reviewer'],
    triggers: ['runtime review'],
  };
  writeFileSync(path.join(sourceRoot, 'ReviewSkill.md'), note('project/example/review-skill', 'Review Skill Card', { skill: matchingSkill }), 'utf8');
  writeFileSync(path.join(sourceRoot, 'StaleSkill.md'), note('project/example/stale-skill', 'Stale Skill Card', {
    skill: { ...matchingSkill, name: 'stale-runtime', contractHash: `sha256:${'0'.repeat(64)}` },
  }), 'utf8');
  writeFileSync(path.join(sourceRoot, 'MissingSkill.md'), note('project/example/missing-skill', 'Missing Skill Card', {
    skill: { ...matchingSkill, name: 'missing-runtime' },
  }), 'utf8');
  writeFileSync(path.join(sourceRoot, 'DuplicateSkill.md'), note('project/example/duplicate-skill', 'Archived duplicate Skill Card', {
    status: 'archived',
    skill: matchingSkill,
  }), 'utf8');
  mkdirSync(path.join(vaultRoot, 'Projects', 'other'), { recursive: true });
  writeFileSync(path.join(vaultRoot, 'Projects', 'other', 'Other.md'), note('project/other/private', 'Other project note'), 'utf8');
  execFileSync('git', ['init', '--initial-branch=main', vaultRoot]);
  execFileSync('git', ['init', '--bare', '--initial-branch=main', remoteRoot]);
  execFileSync('git', ['-C', vaultRoot, 'config', 'user.name', 'Test User']);
  execFileSync('git', ['-C', vaultRoot, 'config', 'user.email', 'test@example.invalid']);
  execFileSync('git', ['-C', vaultRoot, 'remote', 'add', 'origin', remoteRoot]);
  execFileSync('git', ['-C', vaultRoot, 'add', '.']);
  execFileSync('git', ['-C', vaultRoot, 'commit', '-m', 'fixture']);
  execFileSync('git', ['-C', vaultRoot, 'push', '--set-upstream', 'origin', 'main']);
  writeFileSync(obsidianScript, `#!/usr/bin/env node
const fs = require('node:fs');
const path = require('node:path');
const args = process.argv.slice(2);
const vaultRoot = process.env.FAKE_OBSIDIAN_VAULT_ROOT;
if (process.env.FAKE_OBSIDIAN_CALLS) fs.appendFileSync(process.env.FAKE_OBSIDIAN_CALLS, args.join(' ') + '\\n');
if (args[0] === 'vaults') process.stdout.write('Knowledge\\n');
else if (args.includes('search')) process.stdout.write(JSON.stringify([
  'Projects/example/Visible.md',
  'Projects/example/Dependency.md',
  'Projects/example/Transitive.md',
  'Projects/example/Archived.md',
  'Projects/example/Private.md',
  'Projects/example/ReviewSkill.md',
  'Projects/example/StaleSkill.md',
  'Projects/example/MissingSkill.md',
  'Projects/example/DuplicateSkill.md',
  'Projects/other/Other.md',
]));
else if (args.includes('read')) {
  const notePath = args.find((arg) => arg.startsWith('path='))?.slice('path='.length);
  if (!notePath) process.exit(2);
  const statePath = process.env.FAKE_OBSIDIAN_READ_STATE;
  const readCount = statePath && fs.existsSync(statePath) ? Number(fs.readFileSync(statePath, 'utf8')) : 0;
  if (statePath) fs.writeFileSync(statePath, String(readCount + 1));
  let content = fs.readFileSync(path.join(vaultRoot, notePath), 'utf8');
  if (process.env.FAKE_OBSIDIAN_DUPLICATE_ACTIVE === 'true' && notePath.endsWith('/DuplicateSkill.md')) content = content.replace('status: archived', 'status: active');
  process.stdout.write(process.env.FAKE_OBSIDIAN_MUTATE_SECOND_READ === 'true' && readCount === 1 ? content.replace('Rule body.', 'Changed body.') : content);
} else process.exit(2);
`, 'utf8');
  if (process.platform === 'win32') {
    writeFileSync(obsidianCli, `@echo off\r\n"${process.execPath}" "%~dp0obsidian.js" %*\r\n`, 'utf8');
  } else {
    chmodSync(obsidianCli, 0o755);
  }
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
    repositories: { wiki: { worktreeRoot: vaultRoot, remote: 'origin', expectedRemote: remoteRoot, baseBranch: 'main', syncBeforeResearch: true } },
  });
  return {
    vaultRoot,
    registryPath,
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

  it('discovers only base-synchronized Skill Cards whose local provider/version/hash are available', () => {
    const { env } = fixture();
    const result = searchTool({ query: 'skill' }, env);

    const skill = result.notes.find((note) => note.wikiId === 'project/example/review-skill');
    expect(skill).toMatchObject({
      wikiId: 'project/example/review-skill',
      skillRoles: ['reviewer'],
      skillProvider: 'claude-code-project',
      skillName: 'review-runtime',
      skillVersion: '1.0.0',
      skillContractHash: 'sha256:5cea9f04d62aa80841dedb5c02af7f85b3bb074a0e12a18f293954e4ea3bbc3c',
      skillTriggers: ['runtime review'],
      discoveryState: 'discoverable',
    });
    expect(skill).not.toHaveProperty('content');
    expect(result.notes.map((note) => note.wikiId)).not.toContain('project/example/stale-skill');
    expect(result.notes.map((note) => note.wikiId)).not.toContain('project/example/missing-skill');
    expect(() => readNotesByWikiIdsTool({ wikiIds: ['project/example/stale-skill'] }, env))
      .toThrow(/Skill Card is unavailable/);
  });

  it('does not discover or directly read a Skill Card without affirmative base synchronization', () => {
    const { env, registryPath } = fixture();
    const registry = JSON.parse(readFileSync(registryPath, 'utf8'));
    registry.repositories.wiki.syncBeforeResearch = false;
    writeJson(registryPath, registry);

    expect(searchTool({ query: 'skill' }, env).notes.map((note) => note.wikiId))
      .not.toContain('project/example/review-skill');
    expect(() => readNotesByWikiIdsTool({ wikiIds: ['project/example/review-skill'] }, env))
      .toThrow(/base.*synchron/i);
    expect(() => graphNeighborsTool({ wikiIds: ['project/example/review-skill'] }, env))
      .toThrow(/base.*synchron/i);
  });

  it('fails closed when one executable pack has multiple active Skill Cards', () => {
    const { env } = fixture();
    const duplicateEnv = { ...env, FAKE_OBSIDIAN_DUPLICATE_ACTIVE: 'true' };

    expect(() => searchTool({ query: 'skill' }, duplicateEnv))
      .toThrow(/resolved 2 active Cards/);
    expect(() => readNotesByWikiIdsTool({ wikiIds: ['project/example/review-skill'] }, duplicateEnv))
      .toThrow(/resolved 2 active Cards/);
    expect(() => graphNeighborsTool({ wikiIds: ['project/example/review-skill'] }, duplicateEnv))
      .toThrow(/resolved 2 active Cards/);
  });

  it('targets the binding Vault explicitly for Obsidian search and reads', () => {
    const { env } = fixture();
    const callsPath = path.join(tmpdir(), `obsidian-cli-calls-${process.pid}-${createdDirectories.length}`);

    searchTool({ query: 'note' }, { ...env, FAKE_OBSIDIAN_CALLS: callsPath });

    const calls = readFileSync(callsPath, 'utf8');
    expect(calls).toMatch(/vault=Knowledge search query=note path:"?Projects\/example"? format=json/);
    expect(calls).toContain('vault=Knowledge read path=Projects/example/Visible.md');
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

  it('resolves batch reads by stable wiki ID through the built JSON CLI seam', () => {
    const { env } = fixture();
    const bundle = path.resolve(import.meta.dirname, '..', 'dist', 'index.js');

    const output = execFileSync('node', [bundle, 'read-notes-by-wiki-ids'], {
      encoding: 'utf8',
      input: JSON.stringify({ wikiIds: ['project/example/visible'] }),
      env: { ...process.env, ...env },
    });

    expect(JSON.parse(output)).toMatchObject({
      notes: [expect.objectContaining({ wikiId: 'project/example/visible', path: 'Projects/example/Visible.md' })],
      snapshotHash: expect.stringMatching(/^sha256:[a-f0-9]{64}$/),
    });
  });

  it('fails closed when a stable wiki ID is missing or duplicated', () => {
    const { env } = fixture();

    expect(() => readNotesByWikiIdsTool({ wikiIds: ['project/example/missing'] }, env)).toThrow(/resolved 0 readable active Notes/);
    expect(() => readNotesByWikiIdsTool({ wikiIds: ['project/example/visible', 'project/example/visible'] }, env)).toThrow(/Duplicate wiki_id requested/);
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
