import { resolveBindings } from '../bindings.js';
import { assertUniqueBoundSkillCard, searchBoundNotes } from '../retrieval.js';
import { skillCardAvailability } from '../skill-card.js';
import { publishBranchOptions } from '../publish.js';

export function searchTool(input: { query: string; publishFeatureSlug?: string }, env: NodeJS.ProcessEnv = process.env) {
  const resolution = resolveBindings(env, process.cwd(), {
    allowStagedWikiChanges: input.publishFeatureSlug !== undefined,
    allowedRepositoryBranches: input.publishFeatureSlug
      ? publishBranchOptions(input.publishFeatureSlug, env)
      : undefined,
  });
  if (resolution.errors.length > 0) {
    throw new Error(`Obsidian Wiki Source bindings are unhealthy: ${resolution.errors.join('; ')}`);
  }
  const found = searchBoundNotes(input.query, resolution.bindings, env);
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
            mode: input.publishFeatureSlug ? 'write' : 'discovery',
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
      discoveryState: note.skillProvider ? 'discoverable' : undefined,
      summary: note.summary,
      contentHash: note.contentHash,
      bindingDigest: note.bindingDigest,
      })),
  };
}
