import type { SharedWikiConfig } from '../config.js';
import { validatePatch } from '../patch.js';

export async function validatePatchTool(config: SharedWikiConfig, input: { patch: string; authorizedCreate?: boolean; authorizedUpdate?: boolean }) {
  return validatePatch(config, input.patch, {
    authorizedCreate: input.authorizedCreate,
    authorizedUpdate: input.authorizedUpdate,
  });
}
