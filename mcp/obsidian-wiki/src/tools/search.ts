import { resolveBindings } from '../bindings.js';
import { searchBoundNotes } from '../retrieval.js';

export function searchTool(input: { query: string }, env: NodeJS.ProcessEnv = process.env) {
  const resolution = resolveBindings(env);
  if (resolution.errors.length > 0) {
    throw new Error(`Obsidian Wiki Source bindings are unhealthy: ${resolution.errors.join('; ')}`);
  }
  return {
    notes: searchBoundNotes(input.query, resolution.bindings, env).map((note) => ({
      sourceId: note.sourceId,
      role: note.role,
      path: note.path,
      wikiId: note.wikiId,
      type: note.type,
      summary: note.summary,
      contentHash: note.contentHash,
      bindingDigest: note.bindingDigest,
    })),
  };
}
