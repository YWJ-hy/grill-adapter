import type { SharedWikiConfig } from '../config.js';
import { commitAll, createBranch, fetchBase, pushBranch, ensureClean, applyPatch, changedFiles } from '../git.js';
import { createPullRequest } from '../github.js';
import { validatePatch } from '../patch.js';

export async function createPatchPrTool(config: SharedWikiConfig, input: {
  patch: string;
  branchName?: string;
  commitMessage: string;
  prTitle: string;
  prBody: string;
  authorizedCreate?: boolean;
  authorizedUpdate?: boolean;
  draft?: boolean;
}) {
  const validation = await validatePatch(config, input.patch, {
    authorizedCreate: input.authorizedCreate,
    authorizedUpdate: input.authorizedUpdate,
  });
  if (!validation.ok) {
    return { ok: false, validation };
  }

  await ensureClean(config);
  await fetchBase(config);
  const branchName = sanitizeBranchName(input.branchName ?? `shared-wiki/update-${new Date().toISOString().replace(/[:.]/g, '-')}`);
  await createBranch(config, branchName);
  await applyPatch(config, input.patch);
  const files = await changedFiles(config);
  const commitSha = await commitAll(config, input.commitMessage);
  await pushBranch(config, branchName);
  const prUrl = await createPullRequest(config, {
    title: input.prTitle,
    body: input.prBody,
    base: config.baseBranch,
    head: branchName,
    draft: input.draft,
  });

  return {
    ok: true,
    branchName,
    commitSha,
    prUrl,
    changedFiles: files,
    validation,
  };
}

function sanitizeBranchName(input: string): string {
  const branch = input.replace(/[^A-Za-z0-9._/-]+/g, '-').replace(/^-+|-+$/g, '');
  if (!branch || branch === '.' || branch.includes('..') || branch.endsWith('.lock')) {
    throw new Error(`Invalid branch name: ${input}`);
  }
  return branch;
}
