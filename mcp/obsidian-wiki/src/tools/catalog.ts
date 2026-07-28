import { resolveBindings } from '../bindings.js';
import {
  normalizeSourceRelativePath,
  readableBindingsForScope,
  searchBoundNotes,
  sourceRelativePath,
} from '../retrieval.js';
import { presentNotes } from './search.js';

const CATALOG_QUERY = '[wiki_schema:grill-adapter.obsidian-note/v1]';
const MAX_CATALOG_LIMIT = 50;

function comparePaths(left: string, right: string): number {
  return left < right ? -1 : left > right ? 1 : 0;
}

export type CatalogInput = {
  sourceId: string;
  pathPrefix?: string;
  offset?: number;
  limit?: number;
};

type CatalogDirectory = {
  kind: 'directory';
  pathPrefix: string;
  noteCount: number;
};

type CatalogNote = {
  kind: 'note';
  relativePath: string;
} & Record<string, unknown>;

function catalogResolution(env: NodeJS.ProcessEnv) {
  const resolution = resolveBindings(env);
  if (resolution.errors.length > 0) {
    throw new Error(`Obsidian Wiki Source bindings are unhealthy: ${resolution.errors.join('; ')}`);
  }
  return resolution;
}

function boundedInteger(
  value: unknown,
  field: string,
  defaultValue: number,
  minimum: number,
  maximum: number,
): number {
  if (value === undefined) return defaultValue;
  if (!Number.isInteger(value) || (value as number) < minimum || (value as number) > maximum) {
    throw new Error(`${field} must be an integer between ${minimum} and ${maximum}`);
  }
  return value as number;
}

function catalogInput(input: CatalogInput): Required<CatalogInput> {
  if (typeof input.sourceId !== 'string' || !input.sourceId.trim()) {
    throw new Error('sourceId must be a non-empty string');
  }
  const limit = boundedInteger(input.limit, 'limit', MAX_CATALOG_LIMIT, 1, MAX_CATALOG_LIMIT);
  return {
    sourceId: input.sourceId,
    pathPrefix: normalizeSourceRelativePath(input.pathPrefix ?? ''),
    offset: boundedInteger(input.offset, 'offset', 0, 0, Number.MAX_SAFE_INTEGER),
    limit,
  };
}

function immediateEntry(relativePath: string, pathPrefix: string): { directory?: string; direct: boolean } {
  const suffix = pathPrefix
    ? relativePath.slice(`${pathPrefix}/`.length)
    : relativePath;
  const separator = suffix.indexOf('/');
  if (separator === -1) return { direct: true };
  const firstSegment = suffix.slice(0, separator);
  return { directory: pathPrefix ? `${pathPrefix}/${firstSegment}` : firstSegment, direct: false };
}

export function catalogTool(input: CatalogInput, env: NodeJS.ProcessEnv = process.env) {
  const normalized = catalogInput(input);
  const resolution = catalogResolution(env);
  const [binding] = readableBindingsForScope(resolution.bindings, { sourceId: normalized.sourceId });
  const found = searchBoundNotes(
    CATALOG_QUERY,
    resolution.bindings,
    env,
    true,
    { sourceId: normalized.sourceId },
  );
  const notes = presentNotes(found, resolution, env).notes;
  const directories = new Map<string, number>();
  const directNotes: CatalogNote[] = [];

  for (const note of notes) {
    const relativePath = sourceRelativePath(note.path, binding);
    if (
      normalized.pathPrefix
      && relativePath !== normalized.pathPrefix
      && !relativePath.startsWith(`${normalized.pathPrefix}/`)
    ) continue;
    const entry = immediateEntry(relativePath, normalized.pathPrefix);
    if (entry.directory) {
      directories.set(entry.directory, (directories.get(entry.directory) ?? 0) + 1);
    } else if (entry.direct) {
      directNotes.push({ kind: 'note', relativePath, ...note });
    }
  }

  const entries: Array<CatalogDirectory | CatalogNote> = [
    ...[...directories.entries()]
      .sort(([left], [right]) => comparePaths(left, right))
      .map(([pathPrefix, noteCount]) => ({ kind: 'directory' as const, pathPrefix, noteCount })),
    ...directNotes.sort((left, right) => comparePaths(left.relativePath, right.relativePath)),
  ];
  const page = entries.slice(normalized.offset, normalized.offset + normalized.limit);
  const nextOffset = normalized.offset + page.length;

  return {
    sourceId: binding.sourceId,
    role: binding.role,
    bindingDigest: binding.bindingDigest,
    pathPrefix: normalized.pathPrefix,
    entries: page,
    nextOffset: nextOffset < entries.length ? nextOffset : undefined,
  };
}
