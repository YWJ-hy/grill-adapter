import { resolveBindings } from '../bindings.js';
import {
  assertUniqueBoundSkillCardMetadata,
  boundNoteMetadata,
  boundNoteMetadataRevision,
  normalizeSourceRelativePath,
  readableBindingsForScope,
  sourceRelativePath,
} from '../retrieval.js';
import { skillCardAvailability } from '../skill-card.js';
import { evaluateKnowledgeFreshness } from '../note.js';
import {
  boundedPageLimit,
  cursorScope,
  pageByKey,
} from '../pagination.js';

function comparePaths(left: string, right: string): number {
  return left < right ? -1 : left > right ? 1 : 0;
}

export type CatalogInput = {
  sourceId: string;
  pathPrefix?: string;
  offset?: number;
  limit?: number;
  cursor?: string;
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

function boundedOffset(
  value: unknown,
  defaultValue: number,
): number {
  if (value === undefined) return defaultValue;
  if (!Number.isInteger(value) || (value as number) < 0 || (value as number) > Number.MAX_SAFE_INTEGER) {
    throw new Error(`offset must be an integer between 0 and ${Number.MAX_SAFE_INTEGER}`);
  }
  return value as number;
}

function catalogInput(input: CatalogInput) {
  if (typeof input.sourceId !== 'string' || !input.sourceId.trim()) {
    throw new Error('sourceId must be a non-empty string');
  }
  return {
    sourceId: input.sourceId,
    pathPrefix: normalizeSourceRelativePath(input.pathPrefix ?? ''),
    offset: input.offset === undefined ? undefined : boundedOffset(input.offset, 0),
    limit: boundedPageLimit(input.limit, 50),
    cursor: input.cursor,
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

export function catalogTool(
  input: CatalogInput,
  env: NodeJS.ProcessEnv = process.env,
  now: Date = new Date(),
) {
  const normalized = catalogInput(input);
  const resolution = catalogResolution(env);
  const [binding] = readableBindingsForScope(resolution.bindings, { sourceId: normalized.sourceId });
  const activeNotes = boundNoteMetadata(binding)
    .filter((note) => note.status === 'active' && note.agentVisible)
    .map((note) => ({ note, freshness: evaluateKnowledgeFreshness(note, now) }))
    .filter(({ freshness }) => freshness.state !== 'expired');
  for (const { note } of activeNotes) {
    assertUniqueBoundSkillCardMetadata(note, resolution.bindings);
  }
  const notes = activeNotes.filter(({ note }) => (
    skillCardAvailability(note, resolution.projectDir, {
      mode: 'discovery',
      baseSynchronized: binding.repositoryHealth.baseSynchronized,
    }).available
  ));
  const directories = new Map<string, number>();
  const directNotes: CatalogNote[] = [];

  for (const { note, freshness } of notes) {
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
      directNotes.push({
        kind: 'note',
        relativePath,
        sourceId: note.sourceId,
        role: note.role,
        path: note.path,
        wikiId: note.wikiId,
        type: note.type,
        constraintStrength: note.constraintStrength,
        skillRoles: note.skillRoles,
        skillName: note.skillName,
        skillVersion: note.skillVersion,
        skillContractHash: note.skillContractHash,
        skillTriggers: note.skillTriggers,
        adrSourceId: note.adrSourceId,
        adrSourcePath: note.adrSourcePath,
        adrSourceContentHash: note.adrSourceContentHash,
        discoveryState: note.skillName ? 'discoverable' : undefined,
        summary: note.summary,
        bindingDigest: note.bindingDigest,
        verifiedAt: note.verifiedAt,
        reviewAfter: note.reviewAfter,
        expiresAt: note.expiresAt,
        freshnessState: freshness.state,
        maintenanceWarning: freshness.warning,
      });
    }
  }

  const entries: Array<CatalogDirectory | CatalogNote> = [
    ...[...directories.entries()]
      .sort(([left], [right]) => comparePaths(left, right))
      .map(([pathPrefix, noteCount]) => ({ kind: 'directory' as const, pathPrefix, noteCount })),
    ...directNotes.sort((left, right) => comparePaths(left.relativePath, right.relativePath)),
  ];
  const scope = cursorScope('obsidian-wiki-catalog', [
    binding.bindingDigest,
    boundNoteMetadataRevision(binding),
    normalized.pathPrefix,
  ]);
  const bounded = pageByKey(
    entries,
    (entry) => entry.kind === 'directory'
      ? `0:${entry.pathPrefix}`
      : `1:${entry.relativePath}`,
    {
      kind: 'obsidian-wiki-catalog',
      scope,
      limit: normalized.limit,
      cursor: normalized.cursor,
      offset: normalized.offset,
    },
  );
  const nextOffset = bounded.start + bounded.items.length;

  return {
    sourceId: binding.sourceId,
    role: binding.role,
    bindingDigest: binding.bindingDigest,
    pathPrefix: normalized.pathPrefix,
    entries: bounded.items,
    nextOffset: nextOffset < entries.length ? nextOffset : undefined,
    page: {
      ...bounded.page,
      returnedCount: bounded.items.length,
    },
  };
}
