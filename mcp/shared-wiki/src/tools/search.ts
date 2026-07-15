import { readFileSync } from 'node:fs';
import type { SharedWikiConfig } from '../config.js';
import { currentHeadRevision, prepareBase } from '../git.js';
import { indexedFiles } from '../wiki/indexGraph.js';
import { absoluteWikiFilePath, displayPath } from '../wiki/paths.js';

export async function searchTool(config: SharedWikiConfig, input: { query: string; maxResults?: number }) {
  await prepareBase(config);
  const revision = await currentHeadRevision(config);
  const query = input.query.trim().toLowerCase();
  if (!query) throw new Error('Search query is required.');
  const maxResults = Math.min(Math.max(input.maxResults ?? 10, 1), 50);
  const results = [];
  for (const wikiPath of [...indexedFiles(config)].sort()) {
    const content = readFileSync(absoluteWikiFilePath(config, wikiPath), 'utf8');
    const lower = content.toLowerCase();
    const index = lower.indexOf(query);
    if (index === -1) continue;
    const start = Math.max(0, index - 120);
    const end = Math.min(content.length, index + query.length + 120);
    results.push({
      path: wikiPath,
      displayPath: displayPath(config, wikiPath),
      snippet: content.slice(start, end).replace(/\s+/g, ' ').trim(),
    });
    if (results.length >= maxResults) break;
  }
  return { query: input.query, revision, results };
}
