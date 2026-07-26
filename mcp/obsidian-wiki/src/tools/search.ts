import { resolveBindings } from '../bindings.js';
import { assertUniqueBoundSkillCard, searchBoundNotes } from '../retrieval.js';
import { skillCardAvailability } from '../skill-card.js';
import { publishBranchOptions } from '../publish.js';

type SearchOptions = { publishFeatureSlug?: string };
type SearchInput = SearchOptions & { query: string };

function searchResolution(input: SearchOptions, env: NodeJS.ProcessEnv) {
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

function presentNotes(
  found: ReturnType<typeof searchBoundNotes>,
  resolution: ReturnType<typeof searchResolution>,
  env: NodeJS.ProcessEnv,
  publishFeatureSlug?: string,
) {
  for (const note of found) assertUniqueBoundSkillCard(note, resolution.bindings, env);
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
      skillProvider: note.skillProvider,
      skillName: note.skillName,
      skillVersion: note.skillVersion,
      skillContractHash: note.skillContractHash,
      skillTriggers: note.skillTriggers,
      adrSourceId: note.adrSourceId,
      adrSourcePath: note.adrSourcePath,
      adrSourceContentHash: note.adrSourceContentHash,
      discoveryState: note.skillProvider ? 'discoverable' : undefined,
      summary: note.summary,
      contentHash: note.contentHash,
      bindingDigest: note.bindingDigest,
      })),
  };
}

export function searchTool(input: SearchInput, env: NodeJS.ProcessEnv = process.env) {
  const resolution = searchResolution(input, env);
  return presentNotes(
    searchBoundNotes(input.query, resolution.bindings, env),
    resolution,
    env,
    input.publishFeatureSlug,
  );
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
