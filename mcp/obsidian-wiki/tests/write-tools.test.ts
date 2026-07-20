import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import { contentHash } from '../src/note.js';
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
if (args[0] === 'vault') process.stdout.write('Knowledge\\n');
else if (args.includes('search')) {
  const files = [];
  function walk(dir) { for (const name of fs.readdirSync(dir)) { const item = path.join(dir, name); if (fs.statSync(item).isDirectory()) walk(item); else if (name.endsWith('.md')) files.push(path.relative(vaultRoot, item).split(path.sep).join('/')); } }
  walk(vaultRoot);
  process.stdout.write(JSON.stringify(files.map((entry) => ({ path: entry }))));
} else if (args.includes('read')) {
  const notePath = args[args.indexOf('read') + 1];
  process.stdout.write(JSON.stringify({ path: notePath, content: fs.readFileSync(path.join(vaultRoot, notePath), 'utf8') }));
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
});
