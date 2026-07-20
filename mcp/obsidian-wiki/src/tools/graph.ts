import { resolveBindings } from '../bindings.js';
import { searchBoundNotes, type RetrievedNote } from '../retrieval.js';

const edgeTypes = [
  ['depends_on', 'dependsOn'],
  ['see_also', 'seeAlso'],
  ['supersedes', 'supersedes'],
  ['contradicts', 'contradicts'],
] as const;

type EdgeType = typeof edgeTypes[number][0];

export function linkPath(value: string): string {
  const target = /^\[\[([^#|\]]+)/.exec(value)?.[1]?.trim();
  if (!target) throw new Error(`Typed edge must use an Obsidian link: ${value}`);
  return target.endsWith('.md') ? target : `${target}.md`;
}

function exactlyOne(notes: RetrievedNote[], description: string): RetrievedNote {
  if (notes.length !== 1) throw new Error(`${description} resolved ${notes.length} readable active Notes`);
  return notes[0];
}

function resolveByWikiId(wikiId: string, env: NodeJS.ProcessEnv, bindings: ReturnType<typeof resolveBindings>['bindings']): RetrievedNote {
  return exactlyOne(searchBoundNotes(`[wiki_id:${wikiId}]`, bindings, env).filter((note) => note.wikiId === wikiId), `wiki_id ${wikiId}`);
}

function resolveByLink(link: string, env: NodeJS.ProcessEnv, bindings: ReturnType<typeof resolveBindings>['bindings']): RetrievedNote {
  const targetPath = linkPath(link);
  return exactlyOne(searchBoundNotes(`path:"${targetPath}"`, bindings, env).filter((note) => note.path === targetPath), `typed edge ${link}`);
}

export function graphNeighborsTool(input: { wikiIds: string[] }, env: NodeJS.ProcessEnv = process.env) {
  const resolution = resolveBindings(env);
  if (resolution.errors.length > 0) {
    throw new Error(`Obsidian Wiki Source bindings are unhealthy: ${resolution.errors.join('; ')}`);
  }
  const neighbors: Record<string, Array<{ type: EdgeType; wikiId: string; path: string }>> = {};
  for (const wikiId of [...new Set(input.wikiIds)]) {
    const source = resolveByWikiId(wikiId, env, resolution.bindings);
    const direct = new Map<string, { type: EdgeType; wikiId: string; path: string }>();
    for (const [type, property] of edgeTypes) {
      for (const link of source.edges[property]) {
        const target = resolveByLink(link, env, resolution.bindings);
        direct.set(`${type}\n${target.wikiId}`, { type, wikiId: target.wikiId, path: target.path });
      }
    }
    neighbors[wikiId] = [...direct.values()];
  }
  return { neighbors };
}
