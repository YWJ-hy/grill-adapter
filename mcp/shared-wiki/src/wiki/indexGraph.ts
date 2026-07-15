import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs';
import path from 'node:path';
import type { SharedWikiConfig } from '../config.js';
import { companionIndexPath } from './documentContext.js';
import { absoluteWikiFilePath, displayPath, normalizeWikiRelativePath, wikiRootPath } from './paths.js';

export type WikiNode = {
  path: string;
  displayPath: string;
  title: string;
  kind: 'index' | 'leaf';
  readStrategy: 'index' | 'companion_index_then_section' | 'missing_companion_index';
  companionIndex?: {
    path: string;
    displayPath: string;
    exists: boolean;
    readable: boolean;
  };
};

type ResolvedReference =
  | { kind: 'page'; path: string }
  | { kind: 'skip' }
  | { kind: 'error'; message: string };

const MARKDOWN_LINK_RE = /\[[^\]]+\]\(([^)]+?)(?:\s+"[^"]*")?\)/g;
const BACKTICK_RE = /`([^`\n]+)`/g;
const DEFAULT_IGNORED_DIRECTORIES = new Set(['draft', 'archive', 'examples']);

export function indexedFiles(config: SharedWikiConfig): Set<string> {
  const visited = new Set<string>();
  const queue = ['index.md'];
  const ignoredDirectories = loadIgnoredDirectories(config);
  while (queue.length > 0) {
    const current = normalizeWikiRelativePath(queue.shift() ?? 'index.md');
    if (visited.has(current)) continue;
    const absolute = absoluteWikiFilePath(config, current);
    if (!existsSync(absolute)) continue;
    visited.add(current);
    if (!isDirectoryIndexPath(current)) continue;
    const content = readFileSync(absolute, 'utf8');
    for (const target of extractWikiReferences(content)) {
      const resolved = resolveReference(config, current, target, ignoredDirectories);
      if (resolved.kind === 'page') queue.push(resolved.path);
    }
  }
  return visited;
}

export function indexedWikiNodes(config: SharedWikiConfig): WikiNode[] {
  const indexed = indexedFiles(config);
  return [...indexed]
    .filter((wikiPath) => !isCompanionIndexPath(wikiPath))
    .sort()
    .map((wikiPath) => wikiNode(config, wikiPath));
}

export function tree(config: SharedWikiConfig): WikiNode[] {
  return indexedWikiNodes(config);
}

export function validateIndexGraph(config: SharedWikiConfig): string[] {
  const errors: string[] = [];
  const rootIndex = absoluteWikiFilePath(config, 'index.md');
  if (!existsSync(rootIndex)) {
    return ['Shared wiki is missing index.md.'];
  }

  const ignoredDirectories = loadIgnoredDirectories(config);
  for (const wikiPath of indexedFiles(config)) {
    if (!isDirectoryIndexPath(wikiPath)) continue;
    const absolute = absoluteWikiFilePath(config, wikiPath);
    const content = readFileSync(absolute, 'utf8');
    for (const target of extractWikiReferences(content)) {
      const resolved = resolveReference(config, wikiPath, target, ignoredDirectories);
      if (resolved.kind === 'skip') continue;
      if (resolved.kind === 'error') {
        errors.push(`${wikiPath} has unsafe markdown reference: ${target} (${resolved.message})`);
        continue;
      }
      if (!existsSync(absoluteWikiFilePath(config, resolved.path))) {
        errors.push(`${wikiPath} links to missing wiki page: ${resolved.path}`);
      }
    }
  }

  for (const wikiPath of indexedFiles(config)) {
    if (!isLeafDocumentPath(wikiPath)) continue;
    const indexPath = companionIndexPath(wikiPath);
    if (!existsSync(absoluteWikiFilePath(config, indexPath))) {
      errors.push(`${wikiPath} is missing companion section index: ${indexPath}`);
    }
  }

  return errors;
}

export function allMarkdownFiles(config: SharedWikiConfig): string[] {
  const root = path.join(config.cloneDir, config.wikiRoot);
  if (!existsSync(root)) return [];
  const results: string[] = [];
  walk(root, root, results);
  return results.sort();
}

export function isDirectoryIndexPath(wikiPath: string): boolean {
  return path.posix.basename(wikiPath) === 'index.md';
}

export function isCompanionIndexPath(wikiPath: string): boolean {
  const base = path.posix.basename(wikiPath);
  return base.endsWith('.index.md') && base !== 'index.md';
}

export function isLeafDocumentPath(wikiPath: string): boolean {
  return wikiPath.endsWith('.md') && !isDirectoryIndexPath(wikiPath) && !isCompanionIndexPath(wikiPath);
}

export function companionLeafPath(indexPath: string): string | null {
  if (!isCompanionIndexPath(indexPath)) return null;
  const normalized = normalizeWikiRelativePath(indexPath);
  return normalized.replace(/\.index\.md$/, '.md');
}

export function isCompanionIndexForIndexedLeaf(config: SharedWikiConfig, wikiPath: string): boolean {
  const leafPath = companionLeafPath(wikiPath);
  return leafPath !== null && indexedFiles(config).has(leafPath);
}

function wikiNode(config: SharedWikiConfig, wikiPath: string): WikiNode {
  if (isDirectoryIndexPath(wikiPath)) {
    return {
      path: wikiPath,
      displayPath: displayPath(config, wikiPath),
      title: firstHeading(absoluteWikiFilePath(config, wikiPath)) ?? wikiPath,
      kind: 'index',
      readStrategy: 'index',
    };
  }

  const indexPath = companionIndexPath(wikiPath);
  const exists = existsSync(absoluteWikiFilePath(config, indexPath));
  return {
    path: wikiPath,
    displayPath: displayPath(config, wikiPath),
    title: firstHeading(absoluteWikiFilePath(config, wikiPath)) ?? wikiPath,
    kind: 'leaf',
    readStrategy: exists ? 'companion_index_then_section' : 'missing_companion_index',
    companionIndex: {
      path: indexPath,
      displayPath: displayPath(config, indexPath),
      exists,
      readable: exists,
    },
  };
}

function walk(root: string, current: string, results: string[]): void {
  for (const entry of readdirSync(current)) {
    const absolute = path.join(current, entry);
    const stat = statSync(absolute);
    if (stat.isDirectory()) {
      if (entry === '.git' || entry === 'node_modules') continue;
      walk(root, absolute, results);
    } else if (stat.isFile() && entry.endsWith('.md')) {
      results.push(path.relative(root, absolute).replaceAll('\\', '/'));
    }
  }
}

function extractWikiReferences(content: string): string[] {
  const references: string[] = [];
  const searchable = stripFencedCodeBlocks(content);

  for (const match of searchable.matchAll(MARKDOWN_LINK_RE)) {
    references.push(cleanReference(match[1] ?? ''));
  }
  for (const match of searchable.matchAll(BACKTICK_RE)) {
    const candidate = cleanReference(match[1] ?? '');
    if (looksLikeWikiReference(candidate)) references.push(candidate);
  }
  for (const line of searchable.split('\n')) {
    const match = line.match(/^\s*[-*+]\s+(.+)$/);
    if (!match) continue;
    const body = match[1] ?? '';
    if (body.includes('](')) continue;
    const candidate = cleanReference(body.trim().split(/\s+/)[0] ?? '');
    if (looksLikeWikiReference(candidate)) references.push(candidate);
  }

  return references.filter(Boolean);
}

function stripFencedCodeBlocks(content: string): string {
  const lines = content.split('\n');
  let inFence = false;
  return lines.map((line) => {
    if (/^\s*```/.test(line) || /^\s*~~~/.test(line)) {
      inFence = !inFence;
      return '';
    }
    return inFence ? '' : line;
  }).join('\n');
}

function cleanReference(input: string): string {
  return input.trim().replace(/^<|>$/g, '').replace(/[),.;:]+$/g, '');
}

function looksLikeWikiReference(input: string): boolean {
  const withoutAnchor = input.split('#')[0] ?? input;
  return withoutAnchor.endsWith('.md') || withoutAnchor.endsWith('/');
}

function resolveReference(config: SharedWikiConfig, current: string, rawTarget: string, ignoredDirectories: Set<string>): ResolvedReference {
  const target = cleanReference(rawTarget);
  if (!target || isExternalReference(target) || target.startsWith('#')) return { kind: 'skip' };

  const withoutAnchor = target.split('#')[0] ?? target;
  if (!looksLikeWikiReference(withoutAnchor)) return { kind: 'skip' };

  let candidate = withoutAnchor.replaceAll('\\', '/');
  if (candidate.endsWith('/')) candidate = `${candidate}index.md`;
  if (path.posix.isAbsolute(candidate)) return { kind: 'error', message: 'absolute paths are not allowed' };

  const currentDir = path.posix.dirname(current) === '.' ? '' : path.posix.dirname(current);
  const joined = isRootPrefixedDisplayPath(candidate)
    ? candidate
    : path.posix.normalize(path.posix.join(currentDir, candidate));

  let normalized: string;
  try {
    normalized = normalizeWikiRelativePath(joined);
  } catch (error) {
    return { kind: 'error', message: error instanceof Error ? error.message : String(error) };
  }

  const segments = normalized.split('/');
  if (segments.some((segment) => segment.startsWith('.'))) {
    return { kind: 'error', message: 'hidden path segments are not allowed' };
  }
  const ignoredSegment = segments.find((segment) => ignoredDirectories.has(segment));
  if (ignoredSegment) {
    return { kind: 'error', message: `ignored directory is referenced: ${ignoredSegment}` };
  }

  return { kind: 'page', path: normalized };
}

function isExternalReference(target: string): boolean {
  return /^[a-z][a-z0-9+.-]*:/i.test(target);
}

function isRootPrefixedDisplayPath(target: string): boolean {
  return target === '.shared-superpowers/wiki' || target.startsWith('.shared-superpowers/wiki/');
}

function loadIgnoredDirectories(config: SharedWikiConfig): Set<string> {
  const ignored = new Set(DEFAULT_IGNORED_DIRECTORIES);
  const ignorePath = path.join(wikiRootPath(config), '.adapter-ignore');
  if (!existsSync(ignorePath)) return ignored;
  for (const line of readFileSync(ignorePath, 'utf8').split('\n')) {
    const entry = line.trim();
    if (!entry || entry.startsWith('#')) continue;
    ignored.add(entry.replaceAll('\\', '/').replace(/^\/+|\/+$/g, ''));
  }
  return ignored;
}

function firstHeading(absolutePath: string): string | undefined {
  const content = readFileSync(absolutePath, 'utf8');
  const line = content.split('\n').find((candidate) => candidate.startsWith('# '));
  return line?.replace(/^#\s+/, '').trim();
}
