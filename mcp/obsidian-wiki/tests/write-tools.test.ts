import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import { contentHash } from '../src/note.js';
import { skillContractHash } from '../src/skill-card.js';
import { startWriteBridge, type WriteBridgeHandle } from '../src/write-bridge.js';
import { applyNoteChangeTool, proposeNoteChangeTool } from '../src/tools/write.js';

const roots: string[] = [];
const bridges: WriteBridgeHandle[] = [];

function writeJson(filePath: string, value: unknown): void {
  mkdirSync(path.dirname(filePath), { recursive: true });
  writeFileSync(filePath, JSON.stringify(value, null, 2), 'utf8');
}

function manifest(sourceId: string, scope: 'project' | 'shared', update = 'confirm'): string {
  const neutrality = scope === 'shared'
    ? 'blocked_terms:\n  - acme-internal\nblocked_patterns:\n  - "secret-[0-9]+"\n'
    : '';
  return `---\nwiki_schema: grill-adapter.obsidian-source/v1\nwiki_source_id: ${sourceId}\nscope: ${scope}\nupdate_existing: ${update}\ncreate_note: ${update}\n${neutrality}---\n\n# ${sourceId}\n`;
}

function note(wikiId: string, body: string, dependsOn?: string): string {
  const edge = dependsOn ? `depends_on:\n  - "[[${dependsOn}]]"\n` : '';
  return `---\nwiki_schema: grill-adapter.obsidian-note/v1\nwiki_id: ${wikiId}\ntype: constraint\nstatus: active\nagent_visible: true\nsummary: Write tool contract\nconstraint_strength: hard\n${edge}---\n\n# Write tool contract\n\n${body}\n`;
}

function adrProjectionNote(
  wikiId: string,
  sourceId: string,
  sourcePath = 'src/runtime/docs/adr/0001-runtime.md',
  sourceContentHash = `sha256:${'a'.repeat(64)}`,
): string {
  return `---
wiki_schema: grill-adapter.obsidian-note/v1
wiki_id: ${wikiId}
type: constraint
status: active
agent_visible: true
summary: Runtime execution constraints projected from the authoritative project ADR.
constraint_strength: hard
adr_source_id: ${sourceId}
adr_source_path: ${sourcePath}
adr_source_content_hash: ${sourceContentHash}
---

# Derived ADR execution constraints

This Note is derived. Edit the authoritative ADR, not this projection.
`;
}

function skillCard(
  wikiId: string,
  name: string,
  contractHash: string,
): string {
  return `---\nwiki_schema: grill-adapter.obsidian-note/v1\nwiki_id: ${wikiId}\ntype: guide\nstatus: active\nagent_visible: true\nsummary: Review runtime changes.\nskill_provider: claude-code-project\nskill_name: ${name}\nskill_version: 1.0.0\nskill_contract_hash: ${contractHash}\nskill_roles:\n  - reviewer\nskill_triggers:\n  - runtime review\n---\n\n# Review runtime\n\nUse the executable pack.\n`;
}

async function fixture(options: { shared?: boolean; update?: string } = {}) {
  const root = mkdtempSync(path.join(tmpdir(), 'obsidian-write-tools-'));
  roots.push(root);
  const projectDir = path.join(root, 'project');
  const vaultRoot = path.join(root, 'vault');
  const sourceRoot = options.shared ? 'Shared/Engineering' : 'Projects/example';
  const sourceId = options.shared ? 'engineering-shared' : 'project';
  const sourcePath = path.join(vaultRoot, sourceRoot);
  const registryPath = path.join(root, 'registry.json');
  const obsidianCli = path.join(root, 'obsidian');
  mkdirSync(path.join(sourcePath, '_meta'), { recursive: true });
  writeFileSync(path.join(sourcePath, '_meta', 'wiki-source.md'), manifest(sourceId, options.shared ? 'shared' : 'project', options.update), 'utf8');
  const initial = note(`${sourceId}/existing`, 'Initial body.', `${sourceRoot}/Dependency`);
  writeFileSync(path.join(sourcePath, 'Existing.md'), initial, 'utf8');
  const dependency = note(`${sourceId}/dependency`, 'Dependency body.');
  writeFileSync(path.join(sourcePath, 'Dependency.md'), dependency, 'utf8');
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
if (args[0] === 'vaults') process.stdout.write('Knowledge\\n');
else if (args.includes('search')) {
  const files = [];
  function walk(dir) { for (const name of fs.readdirSync(dir)) { const item = path.join(dir, name); if (fs.statSync(item).isDirectory()) walk(item); else if (name.endsWith('.md')) files.push(path.relative(vaultRoot, item).split(path.sep).join('/')); } }
  walk(vaultRoot);
  process.stdout.write(JSON.stringify(files));
} else if (args.includes('read')) {
  const notePath = args.find((arg) => arg.startsWith('path='))?.slice('path='.length);
  if (!notePath) process.exit(2);
  process.stdout.write(fs.readFileSync(path.join(vaultRoot, notePath), 'utf8'));
} else process.exit(2);
`, 'utf8');
  chmodSync(obsidianCli, 0o755);
  writeJson(path.join(projectDir, '.shared-adapter', 'settings.json'), {
    wiki: { provider: 'obsidian', publishing: { mode: 'git-pr' }, obsidian: { bindings: [{ sourceId, role: options.shared ? 'shared' : 'project', vaultRef: 'knowledge', repositoryRef: 'wiki', root: sourceRoot, access: { read: true, update: options.update ?? 'confirm' } }] } },
  });
  const bridge = await startWriteBridge({ vaultRoot, vaultSelector: 'Knowledge', allowedRoots: [sourceRoot], projectDirs: [projectDir], token: 'bridge-token', port: 0 });
  bridges.push(bridge);
  writeJson(registryPath, {
    vaults: { knowledge: { selector: 'Knowledge', bridgeUrl: bridge.url, bridgeTokenEnv: 'TEST_BRIDGE_TOKEN' } },
    repositories: { wiki: { worktreeRoot: vaultRoot, remote: 'origin', expectedRemote: 'github.com/acme/knowledge', baseBranch: 'main', syncBeforeResearch: false } },
  });
  const env = { CLAUDE_PROJECT_DIR: projectDir, OBSIDIAN_WIKI_REGISTRY: registryPath, OBSIDIAN_WIKI_OBSIDIAN_CLI: obsidianCli, FAKE_OBSIDIAN_VAULT_ROOT: vaultRoot, TEST_BRIDGE_TOKEN: 'bridge-token' };
  return { env, vaultRoot, projectDir, sourceRoot, sourceId, initial, dependency };
}

afterEach(async () => {
  while (bridges.length) await bridges.pop()!.close();
  while (roots.length) rmSync(roots.pop()!, { recursive: true, force: true });
});

describe('bound Obsidian Note writes', () => {
  it('returns a validated proposal before an explicitly authorized update', async () => {
    const { env, vaultRoot, sourceRoot, sourceId, initial } = await fixture();
    const proposed = note(`${sourceId}/existing`, 'Updated body.', `${sourceRoot}/Dependency`);
    const input = { sourceId, operation: 'update' as const, path: `${sourceRoot}/Existing.md`, content: proposed, expectedHash: contentHash(initial) };

    const preview = await proposeNoteChangeTool(input, env);
    expect(preview).toMatchObject({ policy: 'confirm', authorizationRequired: true, diff: { beforeHash: contentHash(initial), afterHash: contentHash(proposed) } });
    expect(readFileSync(path.join(vaultRoot, sourceRoot, 'Existing.md'), 'utf8')).toBe(initial);
    await expect(applyNoteChangeTool(input, env)).rejects.toThrow(/explicit authorization/);

    const applied = await applyNoteChangeTool({ ...input, authorized: true }, env);
    expect(applied.postWrite).toMatchObject({ wikiId: `${sourceId}/existing`, contentHash: contentHash(proposed) });
  });

  it('creates a new bound Note with expectedHash null and returns post-write identity', async () => {
    const { env, vaultRoot, sourceRoot, sourceId } = await fixture({ update: 'direct' });
    const content = note(`${sourceId}/new`, 'New body.');
    const input = { sourceId, operation: 'create' as const, path: `${sourceRoot}/Guides/New.md`, content, expectedHash: null };

    const preview = await proposeNoteChangeTool(input, env);
    expect(preview.diff).toMatchObject({ beforeHash: null, beforeContent: null, afterHash: contentHash(content) });
    const applied = await applyNoteChangeTool(input, env);
    expect(applied.postWrite).toMatchObject({ wikiId: `${sourceId}/new`, path: `${sourceRoot}/Guides/New.md`, contentHash: contentHash(content) });
    expect(readFileSync(path.join(vaultRoot, sourceRoot, 'Guides', 'New.md'), 'utf8')).toBe(content);
  });

  it('creates a reviewed Skill Card only when its project pack identity is available', async () => {
    const { env, projectDir, sourceRoot, sourceId } = await fixture({ update: 'direct' });
    const packRoot = path.join(projectDir, '.claude', 'skills', 'review-runtime');
    mkdirSync(packRoot, { recursive: true });
    writeFileSync(
      path.join(packRoot, 'SKILL.md'),
      '---\nname: review-runtime\ndescription: Review runtime changes.\nversion: 1.0.0\n---\n\n# Review Runtime\n',
      'utf8',
    );
    const wikiId = `${sourceId}/skills/review-runtime`;
    const notePath = `${sourceRoot}/Skills/review-runtime.md`;
    const content = skillCard(wikiId, 'review-runtime', skillContractHash(packRoot));
    const input = {
      sourceId,
      operation: 'create' as const,
      path: notePath,
      content,
      expectedHash: null,
    };

    await expect(proposeNoteChangeTool(input, env)).resolves.toMatchObject({
      diff: { afterHash: contentHash(content) },
    });
    await expect(applyNoteChangeTool(input, env)).resolves.toMatchObject({
      postWrite: { wikiId, path: notePath },
      skillRegistration: {
        provider: 'claude-code-project',
        name: 'review-runtime',
        version: '1.0.0',
        discoveryState: 'pending',
      },
    });

    const duplicateWikiId = `${sourceId}/skills/review-runtime-duplicate`;
    await expect(proposeNoteChangeTool({
      ...input,
      path: `${sourceRoot}/Skills/review-runtime-duplicate.md`,
      content: skillCard(duplicateWikiId, 'review-runtime', skillContractHash(packRoot)),
    }, env)).rejects.toThrow(/Skill Card identity.*already exists/);

    const stale = skillCard(wikiId.replace('review-runtime', 'stale-runtime'), 'review-runtime', `sha256:${'0'.repeat(64)}`);
    await expect(proposeNoteChangeTool({
      ...input,
      path: `${sourceRoot}/Skills/stale-runtime.md`,
      content: stale,
    }, env)).rejects.toThrow(/Skill Card is unavailable/);
  });

  it('rejects malformed Skill Card identity and routing metadata', async () => {
    const { env, sourceRoot, sourceId } = await fixture({ update: 'direct' });
    const wikiId = `${sourceId}/skills/review-runtime`;
    const notePath = `${sourceRoot}/Skills/review-runtime.md`;
    const validHash = `sha256:${'a'.repeat(64)}`;
    const base = skillCard(wikiId, 'review-runtime', validHash);

    for (const [label, content] of [
      ['path-like name', base.replace('skill_name: review-runtime', 'skill_name: ../../outside')],
      ['invalid version', base.replace('skill_version: 1.0.0', 'skill_version: latest')],
      ['incomplete semantic version', base.replace('skill_version: 1.0.0', 'skill_version: 1.2')],
      ['duplicate role', base.replace('  - reviewer\nskill_triggers:', '  - reviewer\n  - reviewer\nskill_triggers:')],
      ['duplicate trigger', base.replace('  - runtime review\n---', '  - runtime review\n  - runtime review\n---')],
    ] as const) {
      await expect(proposeNoteChangeTool({
        sourceId,
        operation: 'create',
        path: notePath,
        content,
        expectedHash: null,
      }, env), label).rejects.toThrow(/invalid atomic Note properties|must be unique/);
    }
  });

  it('continues proposing and applying bound Notes after earlier bridge writes stage the worktree', async () => {
    const { env, sourceRoot, sourceId, initial, dependency } = await fixture({ update: 'direct' });
    const first = note(`${sourceId}/existing`, 'First staged update.', `${sourceRoot}/Dependency`);
    await applyNoteChangeTool({ sourceId, operation: 'update', path: `${sourceRoot}/Existing.md`, content: first, expectedHash: contentHash(initial) }, env);

    const second = note(`${sourceId}/dependency`, 'Second staged update.');
    const input = { sourceId, operation: 'update' as const, path: `${sourceRoot}/Dependency.md`, content: second, expectedHash: contentHash(dependency) };
    await expect(proposeNoteChangeTool(input, env)).resolves.toMatchObject({ diff: { afterHash: contentHash(second) } });
    await expect(applyNoteChangeTool(input, env)).resolves.toMatchObject({ postWrite: { wikiId: `${sourceId}/dependency` } });
  });

  it('fails closed on identity drift, broken typed links, denied policy, and a stale bridge token', async () => {
    const first = await fixture();
    const base = { sourceId: first.sourceId, operation: 'update' as const, path: `${first.sourceRoot}/Existing.md`, expectedHash: contentHash(first.initial) };
    await expect(proposeNoteChangeTool({ ...base, content: note(`${first.sourceId}/renamed`, 'Changed identity.') }, first.env)).rejects.toThrow(/wiki_id/);
    await expect(proposeNoteChangeTool({ ...base, content: note(`${first.sourceId}/existing`, 'Broken edge.', `${first.sourceRoot}/Missing`) }, first.env)).rejects.toThrow(/typed edge/);
    await expect(proposeNoteChangeTool({ ...base, content: note(`${first.sourceId}/existing`, 'Bad token.') }, { ...first.env, TEST_BRIDGE_TOKEN: 'wrong' })).rejects.toThrow(/authentication/);

    const denied = await fixture({ update: 'deny' });
    await expect(applyNoteChangeTool({ sourceId: denied.sourceId, operation: 'update', path: `${denied.sourceRoot}/Existing.md`, content: note(`${denied.sourceId}/existing`, 'Denied.'), expectedHash: contentHash(denied.initial), authorized: true }, denied.env)).rejects.toThrow(/policy denies/);
  });

  it('rejects metadata, unbound paths, duplicate IDs, and Shared neutrality violations', async () => {
    const project = await fixture({ update: 'direct' });
    const create = { sourceId: project.sourceId, operation: 'create' as const, content: note(`${project.sourceId}/new`, 'New body.'), expectedHash: null };
    await expect(proposeNoteChangeTool({ ...create, path: `${project.sourceRoot}/_meta/New.md` }, project.env)).rejects.toThrow(/metadata/);
    await expect(proposeNoteChangeTool({ ...create, path: 'Projects/other/New.md' }, project.env)).rejects.toThrow(/bound Source/);
    await expect(proposeNoteChangeTool({ ...create, path: `${project.sourceRoot}/Duplicate.md`, content: note(`${project.sourceId}/existing`, 'Duplicate identity.') }, project.env)).rejects.toThrow(/already exists/);

    const shared = await fixture({ shared: true, update: 'direct' });
    await expect(proposeNoteChangeTool({ sourceId: shared.sourceId, operation: 'create', path: `${shared.sourceRoot}/New.md`, content: note(`${shared.sourceId}/new`, 'Contains acme-internal and secret-42.'), expectedHash: null }, shared.env)).rejects.toThrow(/neutrality/);
  });

  it('keeps ADR execution projections project-only and unique by authority identity', async () => {
    const project = await fixture({ update: 'direct' });
    const authorityId = `project-adr:${'1'.repeat(64)}`;
    const firstPath = `${project.sourceRoot}/Decisions/runtime-projection.md`;
    const first = adrProjectionNote(`${project.sourceId}/adr/runtime`, authorityId);
    await expect(applyNoteChangeTool({
      sourceId: project.sourceId,
      operation: 'create',
      path: firstPath,
      content: first,
      expectedHash: null,
    }, project.env)).resolves.toMatchObject({
      postWrite: { wikiId: `${project.sourceId}/adr/runtime` },
      adrProjection: {
        sourceId: authorityId,
        sourcePath: 'src/runtime/docs/adr/0001-runtime.md',
        targetScope: 'project',
      },
    });

    const updated = adrProjectionNote(
      `${project.sourceId}/adr/runtime`,
      authorityId,
      'src/runtime/docs/adr/0001-runtime.md',
      `sha256:${'b'.repeat(64)}`,
    );
    await expect(applyNoteChangeTool({
      sourceId: project.sourceId,
      operation: 'update',
      path: firstPath,
      content: updated,
      expectedHash: contentHash(first),
    }, project.env)).resolves.toMatchObject({
      postWrite: { wikiId: `${project.sourceId}/adr/runtime` },
      adrProjection: {
        sourceId: authorityId,
        sourceContentHash: `sha256:${'b'.repeat(64)}`,
      },
    });

    await expect(proposeNoteChangeTool({
      sourceId: project.sourceId,
      operation: 'create',
      path: `${project.sourceRoot}/Decisions/runtime-duplicate.md`,
      content: adrProjectionNote(`${project.sourceId}/adr/runtime-duplicate`, authorityId),
      expectedHash: null,
    }, project.env)).rejects.toThrow(/ADR source identity.*already exists/);

    await expect(proposeNoteChangeTool({
      sourceId: project.sourceId,
      operation: 'update',
      path: firstPath,
      content: adrProjectionNote(`${project.sourceId}/adr/runtime`, `project-adr:${'2'.repeat(64)}`),
      expectedHash: contentHash(updated),
    }, project.env)).rejects.toThrow(/ADR source identity must be preserved/);

    const shared = await fixture({ shared: true, update: 'direct' });
    await expect(proposeNoteChangeTool({
      sourceId: shared.sourceId,
      operation: 'create',
      path: `${shared.sourceRoot}/runtime-projection.md`,
      content: adrProjectionNote(`${shared.sourceId}/adr/runtime`, authorityId),
      expectedHash: null,
    }, shared.env)).rejects.toThrow(/ADR execution projections.*project Source/);
  });
});
