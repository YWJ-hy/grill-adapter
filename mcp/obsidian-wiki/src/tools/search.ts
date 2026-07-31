import { resolveBindings } from '../bindings.js';
import {
  assertUniqueActiveBoundSearchCandidateIds,
  assertUniqueBoundSkillCard,
  assertUniqueBoundSkillCardMetadata,
  boundNoteMetadataRevision,
  normalizeSourceRelativePath,
  readBoundNote,
  readableBindingsForScope,
  searchBoundNoteCandidates,
  searchBoundNotes,
} from '../retrieval.js';
import { skillCardAvailability } from '../skill-card.js';
import { publishBranchOptions } from '../publish.js';
import type { BoundNoteScope } from '../retrieval.js';
import {
  boundedPageLimit,
  cursorScope,
  pageByKey,
} from '../pagination.js';

export type SearchOptions = BoundNoteScope & { publishFeatureSlug?: string };
type SearchInput = SearchOptions & {
  query: string;
  limit?: number;
  cursor?: string;
};

export function searchResolution(input: SearchOptions, env: NodeJS.ProcessEnv) {
  const resolution = resolveBindings(env, process.cwd(), {
    allowStagedWikiChanges: input.publishFeatureSlug !== undefined,
    allowedRepositoryBranches: input.publishFeatureSlug
      ? publishBranchOptions(input.publishFeatureSlug, env)
      : undefined,
  });
  if (resolution.errors.length > 0) {
    throw new Error(`Obsidian Wiki Source bindings are unhealthy: ${resolution.errors.join('; ')}`);
  }
  return resolution;
}

export function presentNotes(
  found: ReturnType<typeof searchBoundNotes>,
  resolution: ReturnType<typeof searchResolution>,
  env: NodeJS.ProcessEnv,
  publishFeatureSlug?: string,
) {
  for (const note of found) {
    if (publishFeatureSlug) assertUniqueBoundSkillCard(note, resolution.bindings, env);
    else assertUniqueBoundSkillCardMetadata(note, resolution.bindings);
  }
  return {
    notes: found
      .filter((note) => {
        const binding = resolution.bindings.find(
          (candidate) => candidate.bindingDigest === note.bindingDigest,
        );
        return skillCardAvailability(
          note,
          resolution.projectDir,
          {
            mode: publishFeatureSlug ? 'write' : 'discovery',
            baseSynchronized: binding?.repositoryHealth.baseSynchronized === true,
          },
        ).available;
      })
      .map((note) => ({
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
      contentHash: note.contentHash,
      bindingDigest: note.bindingDigest,
      })),
  };
}

export function searchTool(input: SearchInput, env: NodeJS.ProcessEnv = process.env) {
  if (typeof input.query !== 'string' || !input.query.trim()) {
    throw new Error('query must be a non-empty string');
  }
  const resolution = searchResolution(input, env);
  const limit = boundedPageLimit(input.limit, 20);
  const normalizedPathPrefix = input.pathPrefix === undefined
    ? undefined
    : normalizeSourceRelativePath(input.pathPrefix);
  const scope = cursorScope('obsidian-wiki-search', [
    input.query,
    input.sourceId ?? null,
    normalizedPathPrefix ?? null,
    input.publishFeatureSlug ?? null,
    readableBindingsForScope(resolution.bindings, {
      sourceId: input.sourceId,
      pathPrefix: normalizedPathPrefix,
    }).map((binding) => [
      binding.bindingDigest,
      boundNoteMetadataRevision(binding),
    ]).sort(([left], [right]) => left.localeCompare(right)),
  ]);
  const candidates = searchBoundNoteCandidates(
    input.query,
    resolution.bindings,
    env,
    { sourceId: input.sourceId, pathPrefix: normalizedPathPrefix },
  );
  assertUniqueActiveBoundSearchCandidateIds(candidates);
  const bounded = pageByKey(candidates, (candidate) => candidate.sortKey, {
    kind: 'obsidian-wiki-search',
    scope,
    limit,
    cursor: input.cursor,
  });
  const seenIds = new Set<string>();
  const found = bounded.items.flatMap(({ binding, notePath }) => {
    const note = readBoundNote(notePath, [binding], env, false);
    if (note.status !== 'active' || !note.agentVisible) return [];
    if (seenIds.has(note.wikiId)) {
      throw new Error(`Duplicate wiki_id in readable bound Sources: ${note.wikiId}`);
    }
    seenIds.add(note.wikiId);
    return [note];
  });
  const presented = presentNotes(
    found,
    resolution,
    env,
    input.publishFeatureSlug,
  );
  return {
    ...presented,
    page: {
      ...bounded.page,
      returnedCount: presented.notes.length,
    },
  };
}

export function searchWikiIdsTool(
  input: { wikiIds: string[]; publishFeatureSlug?: string },
  env: NodeJS.ProcessEnv = process.env,
) {
  const resolution = searchResolution(input, env);
  const found = input.wikiIds.flatMap((wikiId) => (
    searchBoundNotes(`[wiki_id:${wikiId}]`, resolution.bindings, env)
      .filter((note) => note.wikiId === wikiId)
  ));
  return presentNotes(found, resolution, env, input.publishFeatureSlug);
}
