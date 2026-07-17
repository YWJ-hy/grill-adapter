import { mkdirSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { describe, expect, it } from 'vitest';
import type { SharedWikiConfig } from '../src/config.js';
import { spawnFile } from '../src/process.js';
import { graphNeighborsTool } from '../src/tools/graphNeighbors.js';

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

function companion(wikiPath: string): string {
  return `# Sections: ${wikiPath}\n\n> Test companion index.\n\n| section | 描述 | 约束强度 |\n|---|---|---|\n| example | Example | hard |\n`;
}

// a.md and b.md are indexed (linked from index.md); c.md is NOT linked, so a neighbor
// pointing at it must come back indexed:false.
const GRAPH = {
  schema: 'section-graph/3',
  nodes: ['a.md#s1', 'b.md#s2', 'c.md#s3'],
  pageTypes: {},
  edges: [
    { from: 'a.md#s1', to: 'b.md#s2', type: 'depends-on', raw: '[[depends-on: b.md#s2]]' },
    { from: 'a.md#s1', to: 'c.md#s3', type: 'see-also', raw: '[[c.md#s3]]' },
  ],
  backlinks: {
    'b.md#s2': [{ from: 'a.md#s1', type: 'depends-on' }],
    'c.md#s3': [{ from: 'a.md#s1', type: 'see-also' }],
  },
  dangling: [],
};

async function createRemoteRepo(withGraph: boolean): Promise<{ repoUrl: string; commitSha: string }> {
  const repoUrl = mkdtempSync(path.join(tmpdir(), 'shared-wiki-graph-remote-'));
  await spawnFile('git', ['init', '-b', 'main'], { cwd: repoUrl });
  await spawnFile('git', ['config', 'user.email', 'test@example.com'], { cwd: repoUrl });
  await spawnFile('git', ['config', 'user.name', 'Test User'], { cwd: repoUrl });
  writeFileSync(path.join(repoUrl, 'index.md'), '# Index\n\n- [A](a.md)\n- [B](b.md)\n');
  writeFileSync(path.join(repoUrl, 'a.md'), '# A\n\n<!-- wiki-section:s1 -->\n## S1\nbody\n<!-- /wiki-section:s1 -->\n');
  writeFileSync(path.join(repoUrl, 'b.md'), '# B\n\n<!-- wiki-section:s2 -->\n## S2\nbody\n<!-- /wiki-section:s2 -->\n');
  writeFileSync(path.join(repoUrl, 'c.md'), '# C\n');
  writeFileSync(path.join(repoUrl, 'a.index.md'), companion('a.md'));
  writeFileSync(path.join(repoUrl, 'b.index.md'), companion('b.md'));
  writeFileSync(path.join(repoUrl, 'c.index.md'), companion('c.md'));
  if (withGraph) {
    writeFileSync(path.join(repoUrl, '.graph.json'), `${JSON.stringify(GRAPH, null, 2)}\n`);
  }
  await spawnFile('git', ['add', '-A'], { cwd: repoUrl });
  await spawnFile('git', ['commit', '-m', 'graph fixture'], { cwd: repoUrl });
  const out = await spawnFile('git', ['rev-parse', 'HEAD'], { cwd: repoUrl });
  return { repoUrl, commitSha: out.stdout.trim() };
}

function cache(): string {
  const dir = mkdtempSync(path.join(tmpdir(), 'shared-wiki-graph-cache-'));
  mkdirSync(dir, { recursive: true });
  return dir;
}

describe('shared wiki graph neighbors', () => {
  it('returns only the requested nodes 1-hop slice with type and indexed flag', async () => {
    const { repoUrl, commitSha } = await createRemoteRepo(true);
    const result = await graphNeighborsTool(config(repoUrl, cache()), { nodes: ['a.md#s1', 'b.md#s2'] });

    expect(result.revision.commitSha).toBe(commitSha);
    expect(Object.keys(result.neighbors).sort()).toEqual(['a.md#s1', 'b.md#s2']);

    expect(result.neighbors['a.md#s1'].out).toEqual([
      { to: 'b.md#s2', type: 'depends-on', indexed: true },
      { to: 'c.md#s3', type: 'see-also', indexed: false }, // c.md not linked from index → not indexed
    ]);
    expect(result.neighbors['a.md#s1'].in).toEqual([]);

    expect(result.neighbors['b.md#s2'].in).toEqual([{ from: 'a.md#s1', type: 'depends-on', indexed: true }]);
    expect(result.neighbors['b.md#s2'].out).toEqual([]);
  });

  it('resolves display-prefixed and .md-less node ids to the same canonical slice', async () => {
    const { repoUrl } = await createRemoteRepo(true);
    // The read path (read-sections) accepts a page as a display-root-prefixed path, a
    // ./-prefixed path, or the .md-less form shown in [[page#section]] link text. graph-neighbors
    // must resolve them the same way instead of silently returning empty edges; results stay
    // keyed by the caller's original (un-normalized) node string.
    const canonical = await graphNeighborsTool(config(repoUrl, cache()), { nodes: ['a.md#s1'] });
    const variants = ['.shared-adapter/wiki/a.md#s1', './a.md#s1', 'a#s1'];
    for (const node of variants) {
      const result = await graphNeighborsTool(config(repoUrl, cache()), { nodes: [node] });
      expect(Object.keys(result.neighbors)).toEqual([node]); // keyed by what the caller asked
      expect(result.neighbors[node].out).toEqual(canonical.neighbors['a.md#s1'].out);
      expect(result.neighbors[node].in).toEqual(canonical.neighbors['a.md#s1'].in);
    }
    // Backlink direction resolves through the same normalization.
    const prefixedTarget = await graphNeighborsTool(config(repoUrl, cache()), {
      nodes: ['.shared-adapter/wiki/b.md#s2'],
    });
    expect(prefixedTarget.neighbors['.shared-adapter/wiki/b.md#s2'].in).toEqual([
      { from: 'a.md#s1', type: 'depends-on', indexed: true },
    ]);
  });

  it('returns empty slice for unknown nodes', async () => {
    const { repoUrl } = await createRemoteRepo(true);
    const result = await graphNeighborsTool(config(repoUrl, cache()), { nodes: ['missing.md#nope'] });
    expect(result.neighbors).toEqual({ 'missing.md#nope': { out: [], in: [] } });
  });

  it('degrades to empty neighbors and a caveat when the graph file is absent', async () => {
    const { repoUrl } = await createRemoteRepo(false);
    const result = await graphNeighborsTool(config(repoUrl, cache()), { nodes: ['a.md#s1'] });
    expect(result.neighbors).toEqual({ 'a.md#s1': { out: [], in: [] } });
    expect(result.caveats?.[0]).toMatch(/\.graph\.json not found/);
  });
});
