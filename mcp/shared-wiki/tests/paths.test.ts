import { describe, expect, it } from 'vitest';
import { normalizeWikiRelativePath } from '../src/wiki/paths.js';

describe('normalizeWikiRelativePath', () => {
  it('normalizes display paths', () => {
    expect(normalizeWikiRelativePath('.shared-superpowers/wiki/contracts/api.md')).toBe('contracts/api.md');
  });

  it('defaults empty path to index', () => {
    expect(normalizeWikiRelativePath('.')).toBe('index.md');
  });

  it('rejects traversal', () => {
    expect(() => normalizeWikiRelativePath('../secret.md')).toThrow(/inside wiki root/);
  });

  it('rejects non-markdown files', () => {
    expect(() => normalizeWikiRelativePath('settings.json')).toThrow(/markdown/);
  });
});
