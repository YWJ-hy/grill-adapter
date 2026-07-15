import type { SharedWikiConfig } from '../config.js';
import { currentHeadRevision, prepareBase } from '../git.js';
import { tree } from '../wiki/indexGraph.js';

export async function treeTool(config: SharedWikiConfig) {
  await prepareBase(config);
  return { revision: await currentHeadRevision(config), files: tree(config) };
}
