import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import { catalogTool } from '../src/tools/catalog.js';
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
    name: string;
    version: string;
    contractHash: string;
    roles: string[];
    triggers: string[];
  };
} = {}): string {
  const dependsOn = options.dependsOn?.length ? `depends_on:\n${options.dependsOn.map((value) => `  - "${value}"`).join('\n')}\n` : '';
  const skill = options.skill
    ? `skill_provider: legacy-ignored\nskill_name: ${options.skill.name}\nskill_version: ${options.skill.version}\nskill_contract_hash: ${options.skill.contractHash}\nskill_roles:\n${options.skill.roles.map((value) => `  - ${value}`).join('\n')}\nskill_triggers:\n${options.skill.triggers.map((value) => `  - ${value}`).join('\n')}\n`
    : '';
  const type = options.skill ? 'guide' : 'constraint';
  const strength = options.skill ? '' : 'constraint_strength: hard\n';
  return `---\nwiki_schema: grill-adapter.obsidian-note/v1\nwiki_id: ${wikiId}\ntype: ${type}\nstatus: ${options.status ?? 'active'}\nagent_visible: ${options.agentVisible ?? true}\nsummary: ${summary}\n${strength}${dependsOn}${skill}---\n\n# ${wikiId}\n\nRule body.\n`;
}

function fixture(options: { duplicateSkillActive?: boolean; extraNoteCount?: number } = {}) {
  const root = mkdtempSync(path.join(tmpdir(), 'obsidian-retrieval-'));
  createdDirectories.push(root);
  const projectDir = path.join(root, 'project');
  const vaultRoot = path.join(root, 'vault');
  const remoteRoot = path.join(root, 'knowledge.git');
  const registryPath = path.join(root, 'registry.json');
  const obsidianCli = path.join(root, process.platform === 'win32' ? 'obsidian.cmd' : 'obsidian');
  const obsidianScript = process.platform === 'win32' ? path.join(root, 'obsidian.js') : obsidianCli;
  const sourceRoot = path.join(vaultRoot, 'Projects', 'example');
  for (const [name, description] of [
    ['review-runtime', 'Review runtime changes.'],
    ['stale-runtime', 'Review stale runtime changes.'],
  ]) {
    for (const runtimeDir of ['.agents', '.claude']) {
      const skillPack = path.join(projectDir, runtimeDir, 'skills', name);
      mkdirSync(skillPack, { recursive: true });
      writeFileSync(
        path.join(skillPack, 'SKILL.md'),
        `---\nname: ${name}\ndescription: ${description}\nversion: 1.0.0\n---\n\n# ${name}\n`,
        'utf8',
      );
    }
  }
  mkdirSync(path.join(sourceRoot, '_meta'), { recursive: true });
  writeFileSync(path.join(sourceRoot, '_meta', 'wiki-source.md'), sourceManifest('project'), 'utf8');
  writeFileSync(path.join(sourceRoot, 'Visible.md'), note('project/example/visible', 'Visible note', { dependsOn: ['[[Projects/example/Dependency]]'] }), 'utf8');
  writeFileSync(path.join(sourceRoot, 'Dependency.md'), note('project/example/dependency', 'Dependency note', { dependsOn: ['[[Projects/example/Transitive]]'] }), 'utf8');
  writeFileSync(path.join(sourceRoot, 'Transitive.md'), note('project/example/transitive', 'Transitive note'), 'utf8');
  writeFileSync(path.join(sourceRoot, 'Archived.md'), note('project/example/archived', 'Archived note', { status: 'archived' }), 'utf8');
  writeFileSync(path.join(sourceRoot, 'Private.md'), note('project/example/private', 'Private note', { agentVisible: false }), 'utf8');
  mkdirSync(path.join(sourceRoot, 'guides', 'runtime'), { recursive: true });
  writeFileSync(path.join(sourceRoot, 'guides', 'Overview.md'), note('project/example/guides/overview', 'Guide overview'), 'utf8');
  writeFileSync(path.join(sourceRoot, 'guides', 'runtime', 'Boundary.md'), note('project/example/guides/runtime-boundary', 'Runtime guide boundary'), 'utf8');
  const matchingSkill = {
    name: 'review-runtime',
    version: '1.0.0',
    contractHash: 'sha256:021891d0e3ddf819b18ba677a4bb740c814b363d02b0b2f1131aee9b1c155c02',
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
    status: options.duplicateSkillActive ? 'active' : 'archived',
    skill: matchingSkill,
  }), 'utf8');
  const bulkPaths: string[] = [];
  for (let index = 0; index < (options.extraNoteCount ?? 0); index += 1) {
    const name = `Note-${String(index).padStart(3, '0')}.md`;
    const vaultPath = `Projects/example/bulk/${name}`;
    bulkPaths.push(vaultPath);
    mkdirSync(path.join(sourceRoot, 'bulk'), { recursive: true });
    writeFileSync(
      path.join(sourceRoot, 'bulk', name),
      note(`project/example/bulk-${String(index).padStart(3, '0')}`, `Bulk note ${index}`),
      'utf8',
    );
  }
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
  const searchPaths = [
    'Projects/example/Visible.md',
    'Projects/example/Dependency.md',
    'Projects/example/Transitive.md',
    'Projects/example/Archived.md',
    'Projects/example/Private.md',
    'Projects/example/guides/Overview.md',
    'Projects/example/guides/runtime/Boundary.md',
    'Projects/example/ReviewSkill.md',
    'Projects/example/StaleSkill.md',
    'Projects/example/MissingSkill.md',
    'Projects/example/DuplicateSkill.md',
    'Projects/other/Other.md',
    ...bulkPaths,
  ];
  writeFileSync(obsidianScript, `#!/usr/bin/env node
const fs = require('node:fs');
const path = require('node:path');
const args = process.argv.slice(2);
const vaultRoot = process.env.FAKE_OBSIDIAN_VAULT_ROOT;
if (process.env.FAKE_OBSIDIAN_CALLS) fs.appendFileSync(process.env.FAKE_OBSIDIAN_CALLS, args.join(' ') + '\\n');
if (args[0] === 'vaults') process.stdout.write('Knowledge\\n');
else if (args.includes('search')) {
  if (process.env.FAKE_OBSIDIAN_NO_MATCHES === 'true') process.stdout.write('No matches found.\\n');
  else process.stdout.write(JSON.stringify(${JSON.stringify(searchPaths)}));
}
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
  writeJson(path.join(projectDir, '.grill-adapter', 'settings.json'), {
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
  it('treats the real CLI zero-match sentinel as an empty search result', () => {
    const { env } = fixture();

    expect(searchTool({ query: 'missing' }, { ...env, FAKE_OBSIDIAN_NO_MATCHES: 'true' }))
      .toEqual({
        notes: [],
        page: {
          limit: 20,
          scannedCount: 0,
          returnedCount: 0,
          truncated: false,
        },
      });
  });

  it('bounds search body reads and continues in deterministic path order', () => {
    const { env } = fixture({ extraNoteCount: 120 });
    const callsPath = path.join(tmpdir(), `obsidian-search-calls-${process.pid}-${createdDirectories.length}`);
    const measuredEnv = { ...env, FAKE_OBSIDIAN_CALLS: callsPath };

    const first = searchTool({
      query: 'bulk',
      sourceId: 'project',
      pathPrefix: 'bulk',
      limit: 7,
    }, measuredEnv);
    expect(first.notes.map((entry) => entry.path)).toEqual(
      Array.from({ length: 7 }, (_, index) => `Projects/example/bulk/Note-${String(index).padStart(3, '0')}.md`),
    );
    expect(first.page).toMatchObject({
      limit: 7,
      scannedCount: 7,
      returnedCount: 7,
      truncated: true,
      nextCursor: expect.any(String),
    });

    const second = searchTool({
      query: 'bulk',
      sourceId: 'project',
      pathPrefix: 'bulk',
      limit: 7,
      cursor: first.page.nextCursor,
    }, measuredEnv);
    expect(second.notes.map((entry) => entry.path)).toEqual(
      Array.from({ length: 7 }, (_, index) => `Projects/example/bulk/Note-${String(index + 7).padStart(3, '0')}.md`),
    );
    expect(second.page).toMatchObject({
      limit: 7,
      scannedCount: 7,
      returnedCount: 7,
      truncated: true,
      nextCursor: expect.any(String),
    });

    const calls = readFileSync(callsPath, 'utf8').split(/\r?\n/).filter(Boolean);
    expect(calls.filter((line) => line.includes(' read '))).toHaveLength(14);
    expect(() => searchTool({ query: 'bulk', limit: 0 }, env)).toThrow(/between 1 and 50/);
    expect(() => searchTool({ query: 'bulk', limit: 51 }, env)).toThrow(/between 1 and 50/);
    expect(() => searchTool({ query: 'bulk', cursor: 'not-a-cursor' }, env)).toThrow(/cursor/i);
    const tamperedCursor = `${first.page.nextCursor!.slice(0, -1)}${first.page.nextCursor!.endsWith('a') ? 'b' : 'a'}`;
    expect(() => searchTool({
      query: 'bulk',
      sourceId: 'project',
      pathPrefix: 'bulk',
      cursor: tamperedCursor,
    }, env)).toThrow(/cursor/i);
    expect(() => searchTool({
      query: 'different',
      sourceId: 'project',
      pathPrefix: 'bulk',
      cursor: first.page.nextCursor,
    }, env)).toThrow(/cursor.*scope/i);
    rmSync(callsPath, { force: true });
  });

  it('rejects duplicate active wiki IDs even when they would land on different pages', () => {
    const { env, vaultRoot } = fixture({ extraNoteCount: 60 });
    const duplicatePath = path.join(
      vaultRoot,
      'Projects',
      'example',
      'bulk',
      'Note-055.md',
    );
    writeFileSync(
      duplicatePath,
      note('project/example/bulk-000', 'Duplicate bulk note'),
      'utf8',
    );
    execFileSync('git', ['-C', vaultRoot, 'add', duplicatePath]);
    execFileSync('git', ['-C', vaultRoot, 'commit', '-m', 'duplicate wiki id']);
    execFileSync('git', ['-C', vaultRoot, 'push', 'origin', 'main']);

    expect(() => searchTool({
      query: 'bulk',
      sourceId: 'project',
      pathPrefix: 'bulk',
      limit: 10,
    }, env)).toThrow(/Duplicate wiki_id/);
  });

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

  it('lists a paginated metadata-only catalog and expands selected directories', () => {
    const { env } = fixture();
    const root = catalogTool({ sourceId: 'project' }, env);

    expect(root).toMatchObject({
      sourceId: 'project',
      role: 'project',
      pathPrefix: '',
    });
    expect(root.entries).toContainEqual({ kind: 'directory', pathPrefix: 'guides', noteCount: 2 });
    expect(root.entries.every((entry) => !('content' in entry))).toBe(true);
    expect(root.entries.map((entry) => (
      entry.kind === 'directory' ? `directory:${entry.pathPrefix}` : `note:${entry.relativePath}`
    ))).toEqual([
      'directory:guides',
      'note:Dependency.md',
      'note:ReviewSkill.md',
      'note:Transitive.md',
      'note:Visible.md',
    ]);
    const catalogJson = JSON.stringify(root);
    expect(catalogJson).not.toContain('project/example/archived');
    expect(catalogJson).not.toContain('project/example/private');
    expect(catalogJson).not.toContain('_meta');

    const firstPage = catalogTool({ sourceId: 'project', limit: 1 }, env);
    expect(firstPage.entries).toEqual([root.entries[0]]);
    expect(firstPage.nextOffset).toBe(1);
    expect(catalogTool({ sourceId: 'project', offset: 1, limit: 1 }, env).entries)
      .toEqual([root.entries[1]]);

    const guides = catalogTool({ sourceId: 'project', pathPrefix: 'guides' }, env);
    expect(guides.entries).toContainEqual({ kind: 'directory', pathPrefix: 'guides/runtime', noteCount: 1 });
    expect(guides.entries).toContainEqual(expect.objectContaining({
      kind: 'note',
      relativePath: 'guides/Overview.md',
      wikiId: 'project/example/guides/overview',
      summary: 'Guide overview',
    }));
  });

  it('scopes searches to catalog directories and rejects unbound scope expansion', () => {
    const { env } = fixture();
    const scoped = searchTool({ query: 'guide', sourceId: 'project', pathPrefix: 'guides' }, env);

    expect(scoped.notes.map((note) => note.wikiId).sort()).toEqual([
      'project/example/guides/overview',
      'project/example/guides/runtime-boundary',
    ]);
    expect(() => searchTool({ query: 'guide', pathPrefix: 'guides' }, env))
      .toThrow(/pathPrefix requires sourceId/);
    expect(() => catalogTool({ sourceId: 'missing' }, env))
      .toThrow(/Unknown readable Obsidian Wiki Source/);
    expect(() => catalogTool({ sourceId: 'project', pathPrefix: '../other' }, env))
      .toThrow(/escapes its Source/);
    expect(() => catalogTool({ sourceId: 'project', pathPrefix: 'guides/../other' }, env))
      .toThrow(/escapes its Source/);
    expect(() => catalogTool({ sourceId: 'project', pathPrefix: '/other' }, env))
      .toThrow(/must be Source-relative/);
    expect(() => catalogTool({ sourceId: 'project', pathPrefix: 'C:\\other' }, env))
      .toThrow(/must be Source-relative/);
    expect(() => catalogTool({ sourceId: 'project', limit: 51 }, env))
      .toThrow(/between 1 and 50/);
  });

  it('paginates a large catalog from metadata without Obsidian body reads', () => {
    const { env } = fixture({ extraNoteCount: 120 });
    const callsPath = path.join(tmpdir(), `obsidian-catalog-calls-${process.pid}-${createdDirectories.length}`);
    writeFileSync(callsPath, '', 'utf8');
    const measuredEnv = { ...env, FAKE_OBSIDIAN_CALLS: callsPath };

    const first = catalogTool({ sourceId: 'project', pathPrefix: 'bulk', limit: 11 }, measuredEnv);
    expect(first.entries).toHaveLength(11);
    expect(first.page).toMatchObject({
      limit: 11,
      returnedCount: 11,
      truncated: true,
      nextCursor: expect.any(String),
    });
    expect(first.entries.every((entry) => !('content' in entry) && !('contentHash' in entry))).toBe(true);

    const second = catalogTool({
      sourceId: 'project',
      pathPrefix: 'bulk',
      limit: 11,
      cursor: first.page.nextCursor,
    }, measuredEnv);
    expect(second.entries).toHaveLength(11);
    expect(second.entries[0]).not.toEqual(first.entries[0]);
    expect(second.page).toMatchObject({ limit: 11, returnedCount: 11, truncated: true });

    expect(readFileSync(callsPath, 'utf8')).not.toContain(' read ');
    expect(() => catalogTool({
      sourceId: 'project',
      pathPrefix: 'guides',
      cursor: first.page.nextCursor,
    }, env)).toThrow(/cursor.*scope/i);
    rmSync(callsPath, { force: true });
  });

  it('rebuilds catalog metadata when the bound Git revision changes', () => {
    const { env, vaultRoot } = fixture();
    const firstPage = catalogTool({
      sourceId: 'project',
      pathPrefix: 'guides',
      limit: 1,
    }, env);
    expect(catalogTool({ sourceId: 'project', pathPrefix: 'guides' }, env).entries)
      .not.toContainEqual(expect.objectContaining({ relativePath: 'guides/New.md' }));

    writeFileSync(
      path.join(vaultRoot, 'Projects', 'example', 'guides', 'New.md'),
      note('project/example/guides/new', 'New guide'),
      'utf8',
    );
    execFileSync('git', ['-C', vaultRoot, 'add', 'Projects/example/guides/New.md']);
    execFileSync('git', ['-C', vaultRoot, 'commit', '-m', 'add guide']);
    execFileSync('git', ['-C', vaultRoot, 'push', 'origin', 'main']);

    expect(catalogTool({ sourceId: 'project', pathPrefix: 'guides' }, env).entries)
      .toContainEqual(expect.objectContaining({
        kind: 'note',
        relativePath: 'guides/New.md',
        wikiId: 'project/example/guides/new',
      }));
    expect(() => catalogTool({
      sourceId: 'project',
      pathPrefix: 'guides',
      cursor: firstPage.page.nextCursor,
    }, env)).toThrow(/cursor.*scope/i);
  });

  it('discovers only base-synchronized Skill Cards whose local name/version/hash are available', () => {
    const { env } = fixture();
    const result = searchTool({ query: 'skill' }, env);

    const skill = result.notes.find((note) => note.wikiId === 'project/example/review-skill');
    expect(skill).toMatchObject({
      wikiId: 'project/example/review-skill',
      skillRoles: ['reviewer'],
      skillName: 'review-runtime',
      skillVersion: '1.0.0',
      skillContractHash: 'sha256:021891d0e3ddf819b18ba677a4bb740c814b363d02b0b2f1131aee9b1c155c02',
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
    const { env } = fixture({ duplicateSkillActive: true });

    expect(() => searchTool({ query: 'skill' }, env))
      .toThrow(/resolved 2 active Cards/);
    expect(() => catalogTool({ sourceId: 'project' }, env))
      .toThrow(/resolved 2 active Cards/);
    expect(() => readNotesByWikiIdsTool({ wikiIds: ['project/example/review-skill'] }, env))
      .toThrow(/resolved 2 active Cards/);
    expect(() => graphNeighborsTool({ wikiIds: ['project/example/review-skill'] }, env))
      .toThrow(/resolved 2 active Cards/);
  });

  it('fails closed for duplicate active Skill Cards before availability filtering', () => {
    const { env, vaultRoot } = fixture();
    const duplicatePath = path.join(
      vaultRoot,
      'Projects',
      'example',
      'DuplicateMissingSkill.md',
    );
    writeFileSync(duplicatePath, note(
      'project/example/duplicate-missing-skill',
      'Duplicate missing Skill Card',
      {
        skill: {
          name: 'missing-runtime',
          version: '1.0.0',
          contractHash: 'sha256:021891d0e3ddf819b18ba677a4bb740c814b363d02b0b2f1131aee9b1c155c02',
          roles: ['reviewer'],
          triggers: ['runtime review'],
        },
      },
    ), 'utf8');
    execFileSync('git', ['-C', vaultRoot, 'add', duplicatePath]);
    execFileSync('git', ['-C', vaultRoot, 'commit', '-m', 'duplicate unavailable skill']);
    execFileSync('git', ['-C', vaultRoot, 'push', 'origin', 'main']);

    expect(() => catalogTool({ sourceId: 'project' }, env))
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

  it('serves metadata-only catalogs through the built JSON CLI seam', () => {
    const { env } = fixture();
    const bundle = path.resolve(import.meta.dirname, '..', 'dist', 'index.js');

    const output = execFileSync('node', [bundle, 'catalog'], {
      encoding: 'utf8',
      input: JSON.stringify({ sourceId: 'project', pathPrefix: 'guides' }),
      env: { ...process.env, ...env },
    });

    const result = JSON.parse(output);
    expect(result.entries).toContainEqual(expect.objectContaining({
      kind: 'note',
      relativePath: 'guides/Overview.md',
    }));
    expect(JSON.stringify(result)).not.toContain('Rule body.');
  });

  it('rejects non-numeric search limits through the built JSON CLI seam', () => {
    const { env } = fixture();
    const bundle = path.resolve(import.meta.dirname, '..', 'dist', 'index.js');

    expect(() => execFileSync('node', [bundle, 'search'], {
      encoding: 'utf8',
      input: JSON.stringify({ query: 'note', limit: '7' }),
      env: { ...process.env, ...env },
    })).toThrow(/limit must be a number/);
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
