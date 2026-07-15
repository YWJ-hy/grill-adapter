import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import * as z from 'zod/v4';
import type { SharedWikiConfig } from '../config.js';

export type AuthorizationMode = 'skip' | 'ask' | 'refuse';

export type WikiPolicy = {
  updateExistingPage: AuthorizationMode;
  createNewDocument: AuthorizationMode;
  blockedTerms: string[];
  blockedPatterns: string[];
};

const ModeSchema = z.enum(['skip', 'ask', 'refuse']);
const SettingsSchema = z.object({
  wiki: z.object({
    updateAuthorization: z.object({
      updateExistingPage: ModeSchema.optional(),
      createNewDocument: ModeSchema.optional(),
    }).optional(),
    sharedNeutrality: z.object({
      blockedTerms: z.array(z.string()).optional(),
      blockedPatterns: z.array(z.string()).optional(),
    }).optional(),
  }).optional(),
});

export function defaultPolicy(): WikiPolicy {
  return {
    updateExistingPage: 'skip',
    createNewDocument: 'ask',
    blockedTerms: [],
    blockedPatterns: [],
  };
}

export function loadPolicy(config: SharedWikiConfig): WikiPolicy {
  const settingsPath = findSettingsPath(config);
  if (!settingsPath) return defaultPolicy();
  const parsed = SettingsSchema.parse(JSON.parse(readFileSync(settingsPath, 'utf8')) as unknown);
  return {
    updateExistingPage: parsed.wiki?.updateAuthorization?.updateExistingPage ?? 'skip',
    createNewDocument: parsed.wiki?.updateAuthorization?.createNewDocument ?? 'ask',
    blockedTerms: parsed.wiki?.sharedNeutrality?.blockedTerms ?? [],
    blockedPatterns: parsed.wiki?.sharedNeutrality?.blockedPatterns ?? [],
  };
}

export function findSettingsPath(config: SharedWikiConfig): string | undefined {
  const candidates = [
    path.join(config.cloneDir, config.wikiRoot, '.shared-superpowers/settings.json'),
    path.join(config.cloneDir, '.shared-superpowers/settings.json'),
    path.join(config.cloneDir, 'settings.json'),
  ];
  return candidates.find((candidate) => existsSync(candidate));
}

export function enforceAuthorization(policy: WikiPolicy, changes: Array<{ status: string; path: string }>, options: { authorizedCreate?: boolean; authorizedUpdate?: boolean }): string[] {
  const errors: string[] = [];
  const hasCreate = changes.some((change) => change.status.startsWith('A'));
  const hasUpdate = changes.some((change) => change.status.startsWith('M'));
  const hasDelete = changes.some((change) => change.status.startsWith('D'));

  if (hasDelete) {
    errors.push('Deleting shared wiki files is not allowed by the MCP write path.');
  }
  if (hasCreate) {
    enforceMode('createNewDocument', policy.createNewDocument, Boolean(options.authorizedCreate), errors);
  }
  if (hasUpdate) {
    enforceMode('updateExistingPage', policy.updateExistingPage, Boolean(options.authorizedUpdate), errors);
  }
  return errors;
}

function enforceMode(name: string, mode: AuthorizationMode, authorized: boolean, errors: string[]): void {
  if (mode === 'refuse') {
    errors.push(`${name} is refused by shared wiki policy.`);
  }
  if (mode === 'ask' && !authorized) {
    errors.push(`${name} requires explicit authorization.`);
  }
}
