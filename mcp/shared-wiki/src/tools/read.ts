import { readFileSync } from 'node:fs';
import type { SharedWikiConfig } from '../config.js';
import { currentHeadRevision, prepareBase } from '../git.js';
import {
  companionLeafPath,
  indexedFiles,
  isCompanionIndexForIndexedLeaf,
  isCompanionIndexPath,
  isDirectoryIndexPath,
  isLeafDocumentPath,
} from '../wiki/indexGraph.js';
import { absoluteWikiFilePath, displayPath, normalizeWikiRelativePath } from '../wiki/paths.js';

export async function readTool(config: SharedWikiConfig, input: { path: string; allowLeafDocumentRead?: boolean }) {
  await prepareBase(config);
  const revision = await currentHeadRevision(config);
  const wikiPath = normalizeWikiRelativePath(input.path);
  const indexed = indexedFiles(config);

  if (isDirectoryIndexPath(wikiPath)) {
    if (!indexed.has(wikiPath)) throw new Error(`Wiki index is not indexed: ${input.path}`);
  } else if (isCompanionIndexPath(wikiPath)) {
    if (!isCompanionIndexForIndexedLeaf(config, wikiPath)) {
      const leafPath = companionLeafPath(wikiPath);
      const suffix = leafPath ? ` Companion leaf is not indexed: ${leafPath}` : '';
      throw new Error(`Companion section index is not readable through this shared wiki graph: ${input.path}.${suffix}`);
    }
  } else if (isLeafDocumentPath(wikiPath)) {
    if (!indexed.has(wikiPath)) throw new Error(`Wiki page is not indexed: ${input.path}`);
    if (!input.allowLeafDocumentRead) {
      const companionPath = wikiPath.replace(/\.md$/, '.index.md');
      throw new Error(
        `Full leaf wiki reads are disabled by default: ${wikiPath}. Read the companion section index first (${companionPath}), then call shared_wiki_read_section with the selected section and includeDocumentContext: true.`,
      );
    }
  } else {
    throw new Error(`Unsupported shared wiki markdown path: ${input.path}`);
  }

  return {
    path: wikiPath,
    displayPath: displayPath(config, wikiPath),
    revision,
    content: readFileSync(absoluteWikiFilePath(config, wikiPath), 'utf8'),
  };
}
