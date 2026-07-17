import { mkdirSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { describe, expect, it } from 'vitest';
import type { SharedWikiConfig } from '../src/config.js';
import { spawnFile } from '../src/process.js';
import { readSectionsTool } from '../src/tools/readSections.js';

function config(repoUrl: string, cacheDir: string): SharedWikiConfig {
  return {
    repoUrl,
    baseBranch: 'main',
    remote: 'origin',
    wikiRoot: '.',
    displayRoot: '.shared-adapter/wiki',
    cacheDir,
    cloneDir: path.join(cacheDir, 'clone'),
    draftPr: true,
  };
}

async function createRemoteRepo(): Promise<{ repoUrl: string; commitSha: string }> {
  const repoUrl = mkdtempSync(path.join(tmpdir(), 'shared-wiki-sections-remote-'));
  await spawnFile('git', ['init', '-b', 'main'], { cwd: repoUrl });
  await spawnFile('git', ['config', 'user.email', 'test@example.com'], { cwd: repoUrl });
  await spawnFile('git', ['config', 'user.name', 'Test User'], { cwd: repoUrl });
  mkdirSync(path.join(repoUrl, 'frontend'), { recursive: true });
  mkdirSync(path.join(repoUrl, 'draft'), { recursive: true });
  writeFileSync(path.join(repoUrl, 'index.md'), '# Index\n\n- [API](api.md)\n- [Contracts](frontend/contracts.md)\n');
  writeFileSync(path.join(repoUrl, 'api.md'), `# API\n\n<!-- wiki-section:auth-contract -->\n## Auth Contract\n\nUse tenant-scoped API keys.\n<!-- /wiki-section:auth-contract -->\n\n<!-- wiki-section:pagination -->\n## Pagination\n\nUse cursor pagination.\n<!-- /wiki-section:pagination -->\n`);
  writeFileSync(path.join(repoUrl, 'api.index.md'), `# API Contract\n\n> Shared API rules for tenant-authenticated services.\n\n| section | 描述 | 约束强度 |\n|---|---|---|\n| auth-contract | Auth Contract | hard |\n| pagination | Pagination | hard |\n`);
  writeFileSync(path.join(repoUrl, 'frontend', 'contracts.md'), `# Contracts\n\n<!-- wiki-section:contract-review -->\n## Contract Review\n\nShared payload names must stay portable.\n<!-- /wiki-section:contract-review -->\n\n<!-- wiki-section:naming -->\n## Naming\n\nAvoid project-specific deployment names.\n<!-- /wiki-section:naming -->\n`);
  writeFileSync(path.join(repoUrl, 'frontend', 'contracts.index.md'), `# Frontend Contracts\n\n> Portable shared contract rules.\n\n| section | 描述 | 约束强度 |\n|---|---|---|\n| contract-review | Contract Review | hard |\n| naming | Naming | hard |\n`);
  writeFileSync(path.join(repoUrl, 'draft', 'unindexed.md'), `# Unindexed\n\n<!-- wiki-section:hidden -->\nHidden section.\n<!-- /wiki-section:hidden -->\n`);
  await spawnFile('git', ['add', '.'], { cwd: repoUrl });
  await spawnFile('git', ['commit', '-m', 'Initial shared wiki'], { cwd: repoUrl });
  const output = await spawnFile('git', ['rev-parse', 'HEAD'], { cwd: repoUrl });
  return { repoUrl, commitSha: output.stdout.trim() };
}

describe('shared wiki batch section reads', () => {
  it('reads selected sections across files in order with document context', async () => {
    const { repoUrl, commitSha } = await createRemoteRepo();
    const cacheDir = mkdtempSync(path.join(tmpdir(), 'shared-wiki-sections-cache-'));
    mkdirSync(cacheDir, { recursive: true });

    const result = await readSectionsTool(config(repoUrl, cacheDir), {
      includeDocumentContext: true,
      sections: [
        { path: 'api.md', section: 'auth-contract' },
        { path: 'frontend/contracts.md', section: 'contract-review' },
      ],
    });

    expect(result.status).toBe('ok');
    expect(result.revision.commitSha).toBe(commitSha);
    expect(result.requestedCount).toBe(2);
    expect(result.errors).toEqual([]);
    expect(result.results.map((item) => item.index)).toEqual([0, 1]);
    expect(result.results[0]).toMatchObject({ status: 'ok', path: 'api.md', section: 'auth-contract' });
    expect(result.results[0]?.revision.commitSha).toBe(commitSha);
    expect(result.results[0]?.content).toContain('Use tenant-scoped API keys');
    expect(result.results[0]?.content).not.toContain('Use cursor pagination');
    expect(result.results[0]?.documentContext?.title).toBe('API Contract');
    expect(result.results[1]).toMatchObject({ status: 'ok', path: 'frontend/contracts.md', section: 'contract-review' });
    expect(result.results[1]?.content).toContain('Shared payload names must stay portable');
    expect(result.results[1]?.documentContext?.title).toBe('Frontend Contracts');
  });

  it('reads multiple sections from one file without sibling leakage', async () => {
    const { repoUrl } = await createRemoteRepo();
    const cacheDir = mkdtempSync(path.join(tmpdir(), 'shared-wiki-sections-cache-'));
    mkdirSync(cacheDir, { recursive: true });

    const result = await readSectionsTool(config(repoUrl, cacheDir), {
      sections: [
        { path: 'api.md', section: 'pagination' },
        { path: 'api.md', section: 'auth-contract' },
      ],
    });

    expect(result.results.map((item) => item.section)).toEqual(['pagination', 'auth-contract']);
    expect(result.results[0]?.content).toContain('Use cursor pagination');
    expect(result.results[0]?.content).not.toContain('Use tenant-scoped API keys');
    expect(result.results[1]?.content).toContain('Use tenant-scoped API keys');
    expect(result.results[1]?.content).not.toContain('Use cursor pagination');
  });

  it('rejects the full batch in strict mode when any section is missing', async () => {
    const { repoUrl } = await createRemoteRepo();
    const cacheDir = mkdtempSync(path.join(tmpdir(), 'shared-wiki-sections-cache-'));
    mkdirSync(cacheDir, { recursive: true });

    await expect(readSectionsTool(config(repoUrl, cacheDir), {
      sections: [
        { path: 'api.md', section: 'auth-contract' },
        { path: 'api.md', section: 'missing-section' },
      ],
    })).rejects.toThrow(/\[1\] api\.md#missing-section:.*Available sections: auth-contract, pagination/);
  });

  it('returns ordered ok and error items in partial diagnostic mode', async () => {
    const { repoUrl } = await createRemoteRepo();
    const cacheDir = mkdtempSync(path.join(tmpdir(), 'shared-wiki-sections-cache-'));
    mkdirSync(cacheDir, { recursive: true });

    const result = await readSectionsTool(config(repoUrl, cacheDir), {
      errorMode: 'partial',
      sections: [
        { path: 'api.md', section: 'auth-contract' },
        { path: 'api.md', section: 'missing-section' },
      ],
    });

    expect(result.status).toBe('partial');
    expect(result.errors).toHaveLength(1);
    expect(result.errors[0]).toMatchObject({ index: 1, path: 'api.md', section: 'missing-section' });
    expect(result.errors[0]?.availableSections).toEqual(['auth-contract', 'pagination']);
    expect(result.results.map((item) => item.status)).toEqual(['ok', 'error']);
    expect(result.results[0]?.content).toContain('Use tenant-scoped API keys');
    expect(result.results[1]).toMatchObject({ status: 'error', path: 'api.md', section: 'missing-section' });
  });

  it('rejects index pages, companion indexes, and unindexed leaf pages', async () => {
    const { repoUrl } = await createRemoteRepo();
    const cacheDir = mkdtempSync(path.join(tmpdir(), 'shared-wiki-sections-cache-'));
    mkdirSync(cacheDir, { recursive: true });
    const sharedConfig = config(repoUrl, cacheDir);

    await expect(readSectionsTool(sharedConfig, { sections: [{ path: 'index.md', section: 'auth-contract' }] })).rejects.toThrow(/index page/);
    await expect(readSectionsTool(sharedConfig, { sections: [{ path: 'api.index.md', section: 'auth-contract' }] })).rejects.toThrow(/companion section index/);
    await expect(readSectionsTool(sharedConfig, { sections: [{ path: 'draft/unindexed.md', section: 'hidden' }] })).rejects.toThrow(/Wiki page is not indexed/);
  });
});
