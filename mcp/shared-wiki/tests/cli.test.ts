import { mkdirSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { describe, expect, it } from 'vitest';
import { spawnFile } from '../src/process.js';
import {
  parseGraphNeighborsInput,
  parseReadSectionsInput,
  runGraphNeighborsCli,
  runReadSectionsCli,
} from '../src/cli.js';

async function createRemoteRepo(): Promise<{ repoUrl: string; commitSha: string }> {
  const repoUrl = mkdtempSync(path.join(tmpdir(), 'shared-wiki-cli-remote-'));
  await spawnFile('git', ['init', '-b', 'main'], { cwd: repoUrl });
  await spawnFile('git', ['config', 'user.email', 'test@example.com'], { cwd: repoUrl });
  await spawnFile('git', ['config', 'user.name', 'Test User'], { cwd: repoUrl });
  mkdirSync(path.join(repoUrl, 'frontend'), { recursive: true });
  writeFileSync(path.join(repoUrl, 'index.md'), '# Index\n\n- [Quality](frontend/quality.md)\n');
  writeFileSync(
    path.join(repoUrl, 'frontend', 'quality.md'),
    '# Quality\n\n<!-- wiki-section:required-quality-patterns -->\n## Required\n\nNew code must pass type checks.\n<!-- /wiki-section:required-quality-patterns -->\n\n<!-- wiki-section:forbidden -->\n## Forbidden\n\nNo side-effect leaks.\n<!-- /wiki-section:forbidden -->\n',
  );
  writeFileSync(
    path.join(repoUrl, 'frontend', 'quality.index.md'),
    '# Quality Guidelines\n\n> Frontend quality gates and forbidden patterns.\n\n| section | 描述 | 约束强度 |\n|---|---|---|\n| required-quality-patterns | Required | hard |\n| forbidden | Forbidden | hard |\n',
  );
  await spawnFile('git', ['add', '.'], { cwd: repoUrl });
  await spawnFile('git', ['commit', '-m', 'Initial shared wiki'], { cwd: repoUrl });
  const output = await spawnFile('git', ['rev-parse', 'HEAD'], { cwd: repoUrl });
  return { repoUrl, commitSha: output.stdout.trim() };
}

// Remote repo whose committed .graph.json carries a depends-on edge between two indexed leaves,
// so graphNeighborsTool can resolve a 1-hop neighbor with indexed=true after clone.
async function createRemoteRepoWithGraph(): Promise<{ repoUrl: string; commitSha: string }> {
  const repoUrl = mkdtempSync(path.join(tmpdir(), 'shared-wiki-cli-graph-remote-'));
  await spawnFile('git', ['init', '-b', 'main'], { cwd: repoUrl });
  await spawnFile('git', ['config', 'user.email', 'test@example.com'], { cwd: repoUrl });
  await spawnFile('git', ['config', 'user.name', 'Test User'], { cwd: repoUrl });
  mkdirSync(path.join(repoUrl, 'frontend'), { recursive: true });
  writeFileSync(
    path.join(repoUrl, 'index.md'),
    '# Index\n\n- [Quality](frontend/quality.md)\n- [Type Safety](frontend/type-safety.md)\n',
  );
  writeFileSync(
    path.join(repoUrl, 'frontend', 'quality.md'),
    '# Quality\n\n<!-- wiki-section:required-quality-patterns -->\n## Required\n\nMust pass type checks. 见 [[depends-on: frontend/type-safety#type-organization]]\n<!-- /wiki-section:required-quality-patterns -->\n',
  );
  writeFileSync(
    path.join(repoUrl, 'frontend', 'quality.index.md'),
    '# Quality Guidelines\n\n> Frontend quality gates.\n\n| section | 描述 | 约束强度 |\n|---|---|---|\n| required-quality-patterns | Required | hard |\n',
  );
  writeFileSync(
    path.join(repoUrl, 'frontend', 'type-safety.md'),
    '# Type Safety\n\n<!-- wiki-section:type-organization -->\n## Organization\n\nWhere enums live.\n<!-- /wiki-section:type-organization -->\n',
  );
  writeFileSync(
    path.join(repoUrl, 'frontend', 'type-safety.index.md'),
    '# Type Safety\n\n> Type organization.\n\n| section | 描述 | 约束强度 |\n|---|---|---|\n| type-organization | Organization | hard |\n',
  );
  writeFileSync(
    path.join(repoUrl, '.graph.json'),
    `${JSON.stringify(
      {
        schema: 'section-graph/3',
        nodes: ['frontend/quality.md#required-quality-patterns', 'frontend/type-safety.md#type-organization'],
        edges: [
          {
            from: 'frontend/quality.md#required-quality-patterns',
            to: 'frontend/type-safety.md#type-organization',
            type: 'depends-on',
            raw: '[[depends-on: frontend/type-safety#type-organization]]',
          },
        ],
        backlinks: {
          'frontend/type-safety.md#type-organization': [
            { from: 'frontend/quality.md#required-quality-patterns', type: 'depends-on' },
          ],
        },
      },
      null,
      2,
    )}\n`,
  );
  await spawnFile('git', ['add', '.'], { cwd: repoUrl });
  await spawnFile('git', ['commit', '-m', 'Shared wiki with graph'], { cwd: repoUrl });
  const output = await spawnFile('git', ['rev-parse', 'HEAD'], { cwd: repoUrl });
  return { repoUrl, commitSha: output.stdout.trim() };
}

async function withEnv<T>(overrides: Record<string, string>, fn: () => Promise<T>): Promise<T> {
  const saved = new Map<string, string | undefined>();
  for (const [key, value] of Object.entries(overrides)) {
    saved.set(key, process.env[key]);
    process.env[key] = value;
  }
  try {
    return await fn();
  } finally {
    for (const [key, value] of saved) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
  }
}

describe('read-sections CLI', () => {
  it('reads sections via loadConfig + readSectionsTool and rides repoUrl back', async () => {
    const { repoUrl, commitSha } = await createRemoteRepo();
    const cacheDir = mkdtempSync(path.join(tmpdir(), 'shared-wiki-cli-cache-'));

    const result = await withEnv(
      {
        SHARED_WIKI_MCP_REPO_URL: repoUrl,
        SHARED_WIKI_MCP_BASE_BRANCH: 'main',
        SHARED_WIKI_MCP_CACHE_DIR: cacheDir,
      },
      () =>
        runReadSectionsCli({
          includeDocumentContext: true,
          sections: [{ path: 'frontend/quality.md', section: 'required-quality-patterns' }],
        }),
    );

    expect(result.status).toBe('ok');
    expect(result.repoUrl).toBe(repoUrl);
    expect(result.revision.commitSha).toBe(commitSha);
    expect(result.results[0]).toMatchObject({ status: 'ok', path: 'frontend/quality.md', section: 'required-quality-patterns' });
    expect(result.results[0]?.content).toContain('New code must pass type checks');
    expect(result.results[0]?.content).not.toContain('No side-effect leaks');
    expect(result.results[0]?.documentContext?.title).toBe('Quality Guidelines');
  });

  it('propagates strict section errors so the caller fails closed', async () => {
    const { repoUrl } = await createRemoteRepo();
    const cacheDir = mkdtempSync(path.join(tmpdir(), 'shared-wiki-cli-cache-'));

    await expect(
      withEnv(
        {
          SHARED_WIKI_MCP_REPO_URL: repoUrl,
          SHARED_WIKI_MCP_BASE_BRANCH: 'main',
          SHARED_WIKI_MCP_CACHE_DIR: cacheDir,
        },
        () => runReadSectionsCli({ sections: [{ path: 'frontend/quality.md', section: 'missing-section' }] }),
      ),
    ).rejects.toThrow(/missing-section/);
  });

  it('parses a stdin JSON request and rejects malformed input', () => {
    expect(parseReadSectionsInput('{"sections":[{"path":"a.md","section":"s"}],"includeDocumentContext":true}')).toEqual({
      sections: [{ path: 'a.md', section: 's' }],
      includeDocumentContext: true,
      errorMode: undefined,
    });
    expect(() => parseReadSectionsInput('')).toThrow(/No input on stdin/);
    expect(() => parseReadSectionsInput('[]')).toThrow(/must be a JSON object/);
    expect(() => parseReadSectionsInput('{"sections":"nope"}')).toThrow(/"sections" array/);
  });
});

describe('graph-neighbors CLI', () => {
  it('returns 1-hop depends-on edges with an indexed flag and rides repoUrl back', async () => {
    const { repoUrl, commitSha } = await createRemoteRepoWithGraph();
    const cacheDir = mkdtempSync(path.join(tmpdir(), 'shared-wiki-cli-cache-'));

    const result = await withEnv(
      {
        SHARED_WIKI_MCP_REPO_URL: repoUrl,
        SHARED_WIKI_MCP_BASE_BRANCH: 'main',
        SHARED_WIKI_MCP_CACHE_DIR: cacheDir,
      },
      () => runGraphNeighborsCli({ nodes: ['frontend/quality.md#required-quality-patterns'] }),
    );

    expect(result.repoUrl).toBe(repoUrl);
    expect(result.revision.commitSha).toBe(commitSha);
    const slice = result.neighbors['frontend/quality.md#required-quality-patterns'];
    expect(slice?.out).toEqual([
      { to: 'frontend/type-safety.md#type-organization', type: 'depends-on', indexed: true },
    ]);
  });

  it('parses a stdin JSON request and rejects malformed input', () => {
    expect(parseGraphNeighborsInput('{"nodes":["a.md#s"]}')).toEqual({ nodes: ['a.md#s'] });
    expect(() => parseGraphNeighborsInput('')).toThrow(/No input on stdin/);
    expect(() => parseGraphNeighborsInput('[]')).toThrow(/must be a JSON object/);
    expect(() => parseGraphNeighborsInput('{"nodes":"nope"}')).toThrow(/"nodes" string array/);
    expect(() => parseGraphNeighborsInput('{"nodes":[1]}')).toThrow(/"nodes" string array/);
  });
});
