import { lstatSync } from 'node:fs';
import { applyPatch, changedFiles, checkoutBase, diffNameStatus, prepareBase, resetBase } from './git.js';
import type { SharedWikiConfig } from './config.js';
import { absoluteWikiFilePath, repoRelativeForWikiPath, wikiRelativeFromRepoPath } from './wiki/paths.js';
import { enforceAuthorization, loadPolicy } from './wiki/policy.js';
import { fileNeutralityChecks, neutralityErrors } from './wiki/neutrality.js';
import { validateWiki, type ValidationSummary } from './wiki/validate.js';

export type PatchValidationResult = {
  ok: boolean;
  changedFiles: string[];
  errors: string[];
  warnings: string[];
  validation: ValidationSummary;
};

export type PatchAuthorization = {
  authorizedCreate?: boolean;
  authorizedUpdate?: boolean;
};

export function rejectUnsafePatchText(patch: string): string[] {
  const errors: string[] = [];
  if (/^GIT binary patch$/m.test(patch) || /^Binary files /m.test(patch)) {
    errors.push('Binary patches are not allowed.');
  }
  if (/^new file mode 120000$/m.test(patch)) {
    errors.push('Symlink writes are not allowed.');
  }
  if (/^deleted file mode /m.test(patch)) {
    errors.push('Deleting shared wiki files is not allowed.');
  }
  return errors;
}

export async function validatePatch(config: SharedWikiConfig, patch: string, authorization: PatchAuthorization = {}): Promise<PatchValidationResult> {
  const textErrors = rejectUnsafePatchText(patch);
  await prepareBase(config);
  const errors = [...textErrors];

  if (errors.length === 0) {
    await applyPatch(config, patch);
  }

  const changed = await changedFiles(config);
  const nameStatus = await diffNameStatus(config);
  for (const file of changed) {
    try {
      const wikiRelative = wikiRelativeFromRepoPath(config, file);
      repoRelativeForWikiPath(config, wikiRelative);
    } catch (error) {
      errors.push(error instanceof Error ? error.message : String(error));
    }
    if (!file.endsWith('.md') && !file.endsWith('settings.json')) {
      errors.push(`Only markdown wiki files and settings.json may be changed: ${file}`);
    }
    try {
      const stat = lstatSync(absoluteWikiFilePath(config, wikiRelativeFromRepoPath(config, file)));
      if (stat.isSymbolicLink()) {
        errors.push(`Symlink writes are not allowed: ${file}`);
      }
    } catch {
      // Missing files are handled by delete/name-status validation.
    }
  }

  const policy = loadPolicy(config);
  errors.push(...enforceAuthorization(policy, nameStatus, authorization));
  errors.push(...neutralityErrors(policy, [
    ...changed.map((file) => ({ label: `path ${file}`, text: file })),
    ...fileNeutralityChecks(changed.filter((file) => file.endsWith('.md')).map((file) => ({ label: file, absolutePath: absoluteWikiFilePath(config, wikiRelativeFromRepoPath(config, file)) }))),
  ]));

  const validation = validateWiki(config);
  errors.push(...validation.errors);
  await checkoutBase(config);
  await resetBase(config);

  return {
    ok: errors.length === 0,
    changedFiles: changed,
    errors,
    warnings: validation.warnings,
    validation,
  };
}
