import { existsSync, readFileSync } from 'node:fs';
import type { SharedWikiConfig } from '../config.js';
import { absoluteWikiFilePath } from './paths.js';
import { indexedFiles, validateIndexGraph } from './indexGraph.js';

export type ValidationSummary = {
  errors: string[];
  warnings: string[];
  indexedFiles: number;
};

export function validateWiki(config: SharedWikiConfig): ValidationSummary {
  const errors = validateIndexGraph(config);
  const warnings: string[] = [];
  const indexed = indexedFiles(config);

  for (const wikiPath of indexed) {
    const absolute = absoluteWikiFilePath(config, wikiPath);
    if (!existsSync(absolute)) continue;
    const content = readFileSync(absolute, 'utf8');
    const lines = content.split('\n').length;
    if (lines >= 800 || content.length >= 40000) {
      warnings.push(`${wikiPath} is very large; avoid appending unrelated content.`);
    } else if (lines >= 500 || content.length >= 24000) {
      warnings.push(`${wikiPath} is large; consider whether it should be split by ownership.`);
    } else if (lines >= 250 || content.length >= 12000) {
      warnings.push(`${wikiPath} is approaching large-page thresholds.`);
    }
    const fenceCount = (content.match(/```/g) ?? []).length;
    if (fenceCount % 2 !== 0) {
      errors.push(`${wikiPath} has an unclosed markdown code fence.`);
    }
    if (/TODO|TBD|FIXME/.test(content)) {
      warnings.push(`${wikiPath} contains placeholder text.`);
    }
  }

  return { errors, warnings, indexedFiles: indexed.size };
}
