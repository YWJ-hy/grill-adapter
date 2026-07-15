import { existsSync, readFileSync } from 'node:fs';
import type { SharedWikiConfig } from '../config.js';
import { currentHeadRevision, prepareBase, type GitRevision } from '../git.js';
import { companionIndexPath, extractDocumentContextFromIndex, type DocumentContext } from '../wiki/documentContext.js';
import { indexedFiles, isCompanionIndexPath, isDirectoryIndexPath, isLeafDocumentPath } from '../wiki/indexGraph.js';
import { absoluteWikiFilePath, displayPath, normalizeWikiRelativePath } from '../wiki/paths.js';
import { extractSection, listSectionIds } from '../wiki/sections.js';

export type SectionReadRequest = {
  path: string;
  section: string;
  includeDocumentContext?: boolean;
};

export type SectionReadResult = {
  path: string;
  section: string;
  displayPath: string;
  revision: GitRevision;
  content: string;
  documentContext?: DocumentContext;
};

export type PreparedSectionReadContext = {
  config: SharedWikiConfig;
  revision: GitRevision;
  indexed: Set<string>;
  fileContentCache?: Map<string, string>;
  documentContextCache?: Map<string, DocumentContext>;
};

export function validateSectionSource(inputPath: string, wikiPath: string, indexed: Set<string>): void {
  if (isDirectoryIndexPath(wikiPath)) {
    throw new Error(`Cannot read a wiki section from an index page: ${wikiPath}`);
  }
  if (isCompanionIndexPath(wikiPath)) {
    throw new Error(`Cannot read a wiki section from a companion section index: ${wikiPath}`);
  }
  if (!isLeafDocumentPath(wikiPath)) {
    throw new Error(`Unsupported shared wiki section source: ${wikiPath}`);
  }
  if (!indexed.has(wikiPath)) {
    throw new Error(`Wiki page is not indexed: ${inputPath}`);
  }
}

export function readWikiFileContent(ctx: PreparedSectionReadContext, wikiPath: string): string {
  const cached = ctx.fileContentCache?.get(wikiPath);
  if (cached !== undefined) return cached;
  const content = readFileSync(absoluteWikiFilePath(ctx.config, wikiPath), 'utf8');
  ctx.fileContentCache?.set(wikiPath, content);
  return content;
}

export function readDocumentContext(ctx: PreparedSectionReadContext, wikiPath: string): DocumentContext {
  const indexPath = companionIndexPath(wikiPath);
  const cached = ctx.documentContextCache?.get(indexPath);
  if (cached !== undefined) return cached;
  const absoluteIndexPath = absoluteWikiFilePath(ctx.config, indexPath);
  const documentContext = existsSync(absoluteIndexPath)
    ? extractDocumentContextFromIndex(ctx.config, indexPath, readFileSync(absoluteIndexPath, 'utf8'))
    : {
        contextSource: indexPath,
        displayPath: displayPath(ctx.config, indexPath),
        caveats: ['companion section index not found'],
      };
  ctx.documentContextCache?.set(indexPath, documentContext);
  return documentContext;
}

export function readSectionFromPreparedBase(ctx: PreparedSectionReadContext, input: SectionReadRequest): SectionReadResult {
  const wikiPath = normalizeWikiRelativePath(input.path);
  validateSectionSource(input.path, wikiPath, ctx.indexed);
  const content = readWikiFileContent(ctx, wikiPath);
  const sectionContent = extractSection(content, input.section);
  if (sectionContent === null) {
    const available = listSectionIds(content);
    const hint = available.length > 0
      ? `Available sections: ${available.join(', ')}`
      : 'No section markers found in this file.';
    throw new Error(`Section '${input.section}' not found in ${wikiPath}. ${hint}`);
  }
  const result: SectionReadResult = {
    path: wikiPath,
    section: input.section,
    displayPath: displayPath(ctx.config, wikiPath),
    revision: ctx.revision,
    content: sectionContent,
  };

  if (input.includeDocumentContext) {
    result.documentContext = readDocumentContext(ctx, wikiPath);
  }

  return result;
}

export async function readSectionTool(config: SharedWikiConfig, input: SectionReadRequest): Promise<SectionReadResult> {
  await prepareBase(config);
  const revision = await currentHeadRevision(config);
  return readSectionFromPreparedBase({
    config,
    revision,
    indexed: indexedFiles(config),
    fileContentCache: new Map(),
    documentContextCache: new Map(),
  }, input);
}
