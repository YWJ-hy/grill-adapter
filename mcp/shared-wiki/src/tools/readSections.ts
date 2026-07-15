import type { SharedWikiConfig } from '../config.js';
import { currentHeadRevision, prepareBase, type GitRevision } from '../git.js';
import { displayPath, normalizeWikiRelativePath } from '../wiki/paths.js';
import { indexedFiles } from '../wiki/indexGraph.js';
import { extractAllSections, listSectionIds } from '../wiki/sections.js';
import {
  readDocumentContext,
  readWikiFileContent,
  validateSectionSource,
  type PreparedSectionReadContext,
  type SectionReadRequest,
  type SectionReadResult,
} from './readSection.js';

type ErrorMode = 'strict' | 'partial';

type BatchSectionReadInput = {
  sections: SectionReadRequest[];
  includeDocumentContext?: boolean;
  errorMode?: ErrorMode;
};

type BatchSectionReadError = {
  index: number;
  path: string;
  section: string;
  message: string;
  availableSections?: string[];
};

type BatchSectionReadOkItem = SectionReadResult & {
  index: number;
  status: 'ok';
  request: SectionReadRequest;
};

type BatchSectionReadErrorItem = {
  index: number;
  status: 'error';
  request: SectionReadRequest;
  path: string;
  section: string;
  error: {
    message: string;
    availableSections?: string[];
  };
};

type BatchSectionReadItem = BatchSectionReadOkItem | BatchSectionReadErrorItem;

export type BatchSectionReadResult = {
  status: 'ok' | 'partial';
  revision: GitRevision;
  requestedCount: number;
  results: BatchSectionReadItem[];
  errors: BatchSectionReadError[];
};

const MAX_BATCH_SECTIONS = 100;

export async function readSectionsTool(config: SharedWikiConfig, input: BatchSectionReadInput): Promise<BatchSectionReadResult> {
  const sections = input.sections;
  if (!Array.isArray(sections) || sections.length === 0) {
    throw new Error('sections must contain at least one section request');
  }
  if (sections.length > MAX_BATCH_SECTIONS) {
    throw new Error(`sections must contain at most ${MAX_BATCH_SECTIONS} section requests`);
  }
  const errorMode = input.errorMode ?? 'strict';
  if (errorMode !== 'strict' && errorMode !== 'partial') {
    throw new Error(`Unsupported errorMode: ${String(input.errorMode)}`);
  }

  await prepareBase(config);
  const revision = await currentHeadRevision(config);
  const ctx: PreparedSectionReadContext = {
    config,
    revision,
    indexed: indexedFiles(config),
    fileContentCache: new Map(),
    documentContextCache: new Map(),
  };
  const parsedSectionsByPath = new Map<string, Map<string, string>>();
  const availableSectionsByPath = new Map<string, string[]>();
  const results: BatchSectionReadItem[] = [];
  const errors: BatchSectionReadError[] = [];

  sections.forEach((rawRequest, index) => {
    const request: SectionReadRequest = {
      path: rawRequest.path,
      section: rawRequest.section,
      includeDocumentContext: rawRequest.includeDocumentContext ?? input.includeDocumentContext,
    };
    try {
      const item = readBatchItem(ctx, parsedSectionsByPath, availableSectionsByPath, request, index);
      results.push(item);
    } catch (error) {
      const batchError = error instanceof BatchItemError
        ? error.toResult(index, request)
        : {
            index,
            path: request.path,
            section: request.section,
            message: error instanceof Error ? error.message : String(error),
          };
      errors.push(batchError);
      results.push({
        index,
        status: 'error',
        request,
        path: batchError.path,
        section: batchError.section,
        error: {
          message: batchError.message,
          ...(batchError.availableSections ? { availableSections: batchError.availableSections } : {}),
        },
      });
    }
  });

  if (errors.length > 0 && errorMode === 'strict') {
    throw new Error(formatAggregateError(errors));
  }

  return {
    status: errors.length > 0 ? 'partial' : 'ok',
    revision,
    requestedCount: sections.length,
    results,
    errors,
  };
}

function readBatchItem(
  ctx: PreparedSectionReadContext,
  parsedSectionsByPath: Map<string, Map<string, string>>,
  availableSectionsByPath: Map<string, string[]>,
  request: SectionReadRequest,
  index: number,
): BatchSectionReadOkItem {
  let wikiPath: string;
  try {
    wikiPath = normalizeWikiRelativePath(request.path);
    validateSectionSource(request.path, wikiPath, ctx.indexed);
  } catch (error) {
    throw new BatchItemError(
      request.path,
      request.section,
      error instanceof Error ? error.message : String(error),
    );
  }

  let sections = parsedSectionsByPath.get(wikiPath);
  if (!sections) {
    const content = readWikiFileContent(ctx, wikiPath);
    sections = extractAllSections(content);
    parsedSectionsByPath.set(wikiPath, sections);
    availableSectionsByPath.set(wikiPath, listSectionIds(content));
  }

  const sectionContent = sections.get(request.section);
  if (sectionContent === undefined) {
    const availableSections = availableSectionsByPath.get(wikiPath) ?? [];
    const hint = availableSections.length > 0
      ? `Available sections: ${availableSections.join(', ')}`
      : 'No section markers found in this file.';
    throw new BatchItemError(
      wikiPath,
      request.section,
      `Section '${request.section}' not found in ${wikiPath}. ${hint}`,
      availableSections,
    );
  }

  const result: BatchSectionReadOkItem = {
    index,
    status: 'ok',
    request,
    path: wikiPath,
    section: request.section,
    displayPath: displayPath(ctx.config, wikiPath),
    revision: ctx.revision,
    content: sectionContent,
  };

  if (request.includeDocumentContext) {
    result.documentContext = readDocumentContext(ctx, wikiPath);
  }

  return result;
}

class BatchItemError extends Error {
  constructor(
    readonly path: string,
    readonly section: string,
    message: string,
    readonly availableSections?: string[],
  ) {
    super(message);
  }

  toResult(index: number, request: SectionReadRequest): BatchSectionReadError {
    return {
      index,
      path: this.path || request.path,
      section: this.section || request.section,
      message: this.message,
      ...(this.availableSections ? { availableSections: this.availableSections } : {}),
    };
  }
}

function formatAggregateError(errors: BatchSectionReadError[]): string {
  const details = errors.map((error) => {
    const available = error.availableSections?.length
      ? ` Available sections: ${error.availableSections.join(', ')}`
      : '';
    return `[${error.index}] ${error.path}#${error.section}: ${error.message}${available}`;
  });
  return `shared_wiki_read_sections failed for ${errors.length} section request(s):\n${details.join('\n')}`;
}
