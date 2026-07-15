import { mkdirSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { describe, expect, it } from 'vitest';
import type { SharedWikiConfig } from '../src/config.js';
import { spawnFile } from '../src/process.js';
import { readSectionTool } from '../src/tools/readSection.js';

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

async function createRemoteRepo(withCompanionIndex: boolean): Promise<{ repoUrl: string; commitSha: string }> {
  const repoUrl = mkdtempSync(path.join(tmpdir(), 'shared-wiki-section-remote-'));
  await spawnFile('git', ['init', '-b', 'main'], { cwd: repoUrl });
  await spawnFile('git', ['config', 'user.email', 'test@example.com'], { cwd: repoUrl });
  await spawnFile('git', ['config', 'user.name', 'Test User'], { cwd: repoUrl });
  writeFileSync(path.join(repoUrl, 'index.md'), '# Index\n\n- [API](api.md)\n');
  writeFileSync(path.join(repoUrl, 'api.md'), `# API\n\n<!-- wiki-section:auth-contract -->\n## Auth Contract\n\nUse tenant-scoped API keys.\n<!-- /wiki-section:auth-contract -->\n\n<!-- wiki-section:pagination -->\n## Pagination\n\nUse cursor pagination.\n<!-- /wiki-section:pagination -->\n`);
  if (withCompanionIndex) {
    writeFileSync(path.join(repoUrl, 'api.index.md'), `# API Contract\n\n> Shared API rules for tenant-authenticated services.\n\n| section | 描述 | 约束强度 |\n|---|---|---|\n| auth-contract | Auth Contract | hard |\n`);
  }
  await spawnFile('git', ['add', '.'], { cwd: repoUrl });
  await spawnFile('git', ['commit', '-m', 'Initial shared wiki'], { cwd: repoUrl });
  const output = await spawnFile('git', ['rev-parse', 'HEAD'], { cwd: repoUrl });
  return { repoUrl, commitSha: output.stdout.trim() };
}

describe('shared wiki read section document context', () => {
  it('keeps default section read compatible', async () => {
    const { repoUrl, commitSha } = await createRemoteRepo(true);
    const cacheDir = mkdtempSync(path.join(tmpdir(), 'shared-wiki-section-cache-'));
    mkdirSync(cacheDir, { recursive: true });

    const result = await readSectionTool(config(repoUrl, cacheDir), { path: 'api.md', section: 'auth-contract' });

    expect(result.revision.commitSha).toBe(commitSha);
    expect(result.content).toContain('Use tenant-scoped API keys');
    expect(result.content).not.toContain('Use cursor pagination');
    expect(result.documentContext).toBeUndefined();
  });

  it('returns bounded document context when requested', async () => {
    const { repoUrl, commitSha } = await createRemoteRepo(true);
    const cacheDir = mkdtempSync(path.join(tmpdir(), 'shared-wiki-section-cache-'));
    mkdirSync(cacheDir, { recursive: true });

    const result = await readSectionTool(config(repoUrl, cacheDir), {
      path: 'api.md',
      section: 'auth-contract',
      includeDocumentContext: true,
    });

    expect(result.revision.commitSha).toBe(commitSha);
    expect(result.documentContext?.title).toBe('API Contract');
    expect(result.documentContext?.overview).toContain('tenant-authenticated services');
    expect(result.documentContext?.contextSource).toBe('api.index.md');
    expect(result.content).toContain('Use tenant-scoped API keys');
    expect(result.content).not.toContain('Use cursor pagination');
  });

  it('keeps section content when companion index is missing', async () => {
    const { repoUrl } = await createRemoteRepo(false);
    const cacheDir = mkdtempSync(path.join(tmpdir(), 'shared-wiki-section-cache-'));
    mkdirSync(cacheDir, { recursive: true });

    const result = await readSectionTool(config(repoUrl, cacheDir), {
      path: 'api.md',
      section: 'auth-contract',
      includeDocumentContext: true,
    });

    expect(result.content).toContain('Use tenant-scoped API keys');
    expect(result.documentContext?.caveats).toContain('companion section index not found');
  });

  it('rejects index pages and companion indexes as section sources', async () => {
    const { repoUrl } = await createRemoteRepo(true);
    const cacheDir = mkdtempSync(path.join(tmpdir(), 'shared-wiki-section-cache-'));
    mkdirSync(cacheDir, { recursive: true });
    const sharedConfig = config(repoUrl, cacheDir);

    await expect(readSectionTool(sharedConfig, { path: 'index.md', section: 'auth-contract' })).rejects.toThrow(/index page/);
    await expect(readSectionTool(sharedConfig, { path: 'api.index.md', section: 'auth-contract' })).rejects.toThrow(/companion section index/);
  });
});
