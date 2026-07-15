import path from 'node:path';
import type { SharedWikiConfig } from '../config.js';
import { displayPath, normalizeWikiRelativePath } from './paths.js';

const DOCUMENT_OVERVIEW_LIMIT = 600;
const AUTO_GENERATED_INDEX_NOTICE = 'Auto-generated from section markers. Do not edit manually.';

export type DocumentContext = {
  title?: string;
  overview?: string;
  contextSource: string;
  displayPath: string;
  caveats?: string[];
};

export function companionIndexPath(wikiPath: string): string {
  const normalized = normalizeWikiRelativePath(wikiPath);
  const dir = path.posix.dirname(normalized);
  const base = path.posix.basename(normalized, '.md');
  const indexName = `${base}.index.md`;
  return dir === '.' ? indexName : path.posix.join(dir, indexName);
}

export function extractDocumentContextFromIndex(
  config: SharedWikiConfig,
  indexPath: string,
  indexContent: string,
): DocumentContext {
  let title: string | undefined;
  const overviewLines: string[] = [];
  const caveats: string[] = [];
  let inOverview = false;

  for (const line of indexContent.split('\n')) {
    const stripped = line.trim();
    if (!title && stripped.startsWith('# ')) {
      title = stripped.replace(/^#+\s*/, '').trim();
      continue;
    }
    if (stripped.startsWith('|')) break;
    if (stripped.startsWith('>')) {
      const value = stripped.replace(/^>\s?/, '').trim();
      if (!value || value === AUTO_GENERATED_INDEX_NOTICE) continue;
      overviewLines.push(value);
      inOverview = true;
      continue;
    }
    if (inOverview) break;
  }

  if (!title) caveats.push('document title missing from companion index');
  let overview = overviewLines.join(' ').trim();
  if (overview.length > DOCUMENT_OVERVIEW_LIMIT) {
    overview = `${overview.slice(0, DOCUMENT_OVERVIEW_LIMIT).trimEnd()}…`;
  }
  if (!overview) caveats.push('document overview missing from companion index');

  return {
    title,
    overview: overview || undefined,
    contextSource: indexPath,
    displayPath: displayPath(config, indexPath),
    ...(caveats.length > 0 ? { caveats } : {}),
  };
}
