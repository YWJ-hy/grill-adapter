import { mkdirSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { describe, expect, it } from 'vitest';
import type { SharedWikiConfig } from '../src/config.js';
import { spawnFile } from '../src/process.js';
import { readTool } from '../src/tools/read.js';
import { searchTool } from '../src/tools/search.js';
import { statusTool } from '../src/tools/status.js';
import { treeTool } from '../src/tools/tree.js';

function config(repoUrl: string, cacheDir: string): SharedWikiConfig {
  return {
    repoUrl,
    baseBranch: 'main',
    remote: 'origin',
    wikiRoot: '.',
    displayRoot: '.shared-superpowers/wiki',
    cacheDir,
    cloneDir: path.join(cacheDir, 'clone'),
    draftPr: true,
  };
}

async function createRemoteRepo(withCompanionIndex = true): Promise<{ repoUrl: string; commitSha: string }> {
  const repoUrl = mkdtempSync(path.join(tmpdir(), 'shared-wiki-remote-'));
  await spawnFile('git', ['init', '-b', 'main'], { cwd: repoUrl });
  await spawnFile('git', ['config', 'user.email', 'test@example.com'], { cwd: repoUrl });
  await spawnFile('git', ['config', 'user.name', 'Test User'], { cwd: repoUrl });
  writeFileSync(path.join(repoUrl, 'index.md'), '# Index\n\n- [API](api.md)\n');
  writeFileSync(path.join(repoUrl, 'api.md'), '# API\n\nReusable API contract.\n');
  if (withCompanionIndex) {
    writeFileSync(path.join(repoUrl, 'api.index.md'), '# API Sections\n\n> Shared API contract sections.\n\n| section | 描述 | 约束强度 |\n|---|---|---|\n| auth-contract | Auth Contract | hard |\n');
  }
  await spawnFile('git', ['add', '.'], { cwd: repoUrl });
  await spawnFile('git', ['commit', '-m', 'Initial shared wiki'], { cwd: repoUrl });
  const output = await spawnFile('git', ['rev-parse', 'HEAD'], { cwd: repoUrl });
  return { repoUrl, commitSha: output.stdout.trim() };
}

describe('shared wiki tool revisions', () => {
  it('returns revision from status, tree, read, and search tools', async () => {
    const { repoUrl, commitSha } = await createRemoteRepo();
    const cacheDir = mkdtempSync(path.join(tmpdir(), 'shared-wiki-cache-'));
    mkdirSync(cacheDir, { recursive: true });
    const sharedConfig = config(repoUrl, cacheDir);

    const status = await statusTool(sharedConfig);
    expect(status.revision?.ref).toBe('origin/main');
    expect(status.revision?.commitSha).toBe(commitSha);
    expect(status.revision?.shortSha).toBe(commitSha.slice(0, 12));
    expect(status.validation.errors).toEqual([]);

    const tree = await treeTool(sharedConfig);
    expect(tree.revision.commitSha).toBe(commitSha);
    const apiNode = tree.files.find((file) => file.path === 'api.md');
    expect(apiNode?.kind).toBe('leaf');
    expect(apiNode?.readStrategy).toBe('companion_index_then_section');
    expect(apiNode?.companionIndex?.path).toBe('api.index.md');

    const indexRead = await readTool(sharedConfig, { path: 'index.md' });
    expect(indexRead.revision.commitSha).toBe(commitSha);
    expect(indexRead.content).toContain('[API](api.md)');

    const companionRead = await readTool(sharedConfig, { path: 'api.index.md' });
    expect(companionRead.revision.commitSha).toBe(commitSha);
    expect(companionRead.content).toContain('API Sections');

    await expect(readTool(sharedConfig, { path: 'api.md' })).rejects.toThrow(/shared_wiki_read_section/);

    const leafRead = await readTool(sharedConfig, { path: 'api.md', allowLeafDocumentRead: true });
    expect(leafRead.revision.commitSha).toBe(commitSha);
    expect(leafRead.content).toContain('Reusable API contract');

    const search = await searchTool(sharedConfig, { query: 'contract' });
    expect(search.revision.commitSha).toBe(commitSha);
    expect(search.results[0]?.path).toBe('api.md');
  });

  it('reports indexed leaf pages missing companion section indexes in status validation', async () => {
    const { repoUrl } = await createRemoteRepo(false);
    const cacheDir = mkdtempSync(path.join(tmpdir(), 'shared-wiki-cache-'));
    mkdirSync(cacheDir, { recursive: true });

    const status = await statusTool(config(repoUrl, cacheDir));

    expect(status.validation.errors).toContain('api.md is missing companion section index: api.index.md');
  });
});
