import type { SharedWikiConfig } from '../config.js';
import { ensureClone, fetchBase, remoteBaseRevision, toolAvailable } from '../git.js';
import { findSettingsPath, loadPolicy } from '../wiki/policy.js';
import { validateWiki } from '../wiki/validate.js';

export async function statusTool(config: SharedWikiConfig) {
  const gitAvailable = await toolAvailable('git');
  const ghAvailable = await toolAvailable('gh');
  if (gitAvailable) {
    await ensureClone(config);
    await fetchBase(config);
  }
  const policy = gitAvailable ? loadPolicy(config) : undefined;
  const validation = gitAvailable ? validateWiki(config) : undefined;
  const revision = gitAvailable ? await remoteBaseRevision(config) : null;
  return {
    repoUrl: config.repoUrl,
    baseBranch: config.baseBranch,
    remote: config.remote,
    wikiRoot: config.wikiRoot,
    displayRoot: config.displayRoot,
    cloneDir: config.cloneDir,
    gitAvailable,
    ghAvailable,
    revision,
    settingsPath: gitAvailable ? findSettingsPath(config) ?? null : null,
    policy,
    validation,
  };
}
