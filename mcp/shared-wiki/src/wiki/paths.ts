import path from 'node:path';
import type { SharedWikiConfig } from '../config.js';

export function repoPath(config: SharedWikiConfig, relativePath = '.'): string {
  return path.join(config.cloneDir, relativePath);
}

export function wikiRootPath(config: SharedWikiConfig): string {
  return repoPath(config, config.wikiRoot);
}

export function toPosixPath(input: string): string {
  return input.replaceAll('\\', '/');
}

export function normalizeWikiRelativePath(input: string): string {
  const normalizedInput = toPosixPath(input).replace(/^\.shared-superpowers\/wiki\//, '').replace(/^\.\//, '');
  if (!normalizedInput || normalizedInput === '.') {
    return 'index.md';
  }
  if (path.posix.isAbsolute(normalizedInput)) {
    throw new Error(`Wiki path must be relative: ${input}`);
  }
  const normalized = path.posix.normalize(normalizedInput);
  if (normalized === '..' || normalized.startsWith('../')) {
    throw new Error(`Wiki path must stay inside wiki root: ${input}`);
  }
  if (!normalized.endsWith('.md')) {
    throw new Error(`Wiki path must be a markdown file: ${input}`);
  }
  return normalized;
}

export function repoRelativeForWikiPath(config: SharedWikiConfig, wikiRelativePath: string): string {
  const normalized = normalizeWikiRelativePath(wikiRelativePath);
  return config.wikiRoot === '.' ? normalized : path.posix.join(config.wikiRoot, normalized);
}

export function wikiRelativeFromRepoPath(config: SharedWikiConfig, repoRelativePath: string): string {
  const normalized = toPosixPath(repoRelativePath).replace(/^\.\//, '');
  if (config.wikiRoot === '.') return normalizeWikiRelativePath(normalized);
  const root = config.wikiRoot.endsWith('/') ? config.wikiRoot : `${config.wikiRoot}/`;
  if (!normalized.startsWith(root)) {
    throw new Error(`Path is outside wiki root: ${repoRelativePath}`);
  }
  return normalizeWikiRelativePath(normalized.slice(root.length));
}

export function displayPath(config: SharedWikiConfig, wikiRelativePath: string): string {
  return path.posix.join(config.displayRoot, normalizeWikiRelativePath(wikiRelativePath));
}

export function absoluteWikiFilePath(config: SharedWikiConfig, wikiRelativePath: string): string {
  return path.join(wikiRootPath(config), normalizeWikiRelativePath(wikiRelativePath));
}
