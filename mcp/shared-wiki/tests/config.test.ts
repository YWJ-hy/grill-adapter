import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import { loadConfig } from '../src/config.js';

const createdDirs: string[] = [];

function projectWithSettings(content: unknown): string {
  const projectDir = mkdtempSync(path.join(tmpdir(), 'swm-proj-'));
  createdDirs.push(projectDir);
  mkdirSync(path.join(projectDir, '.shared-superpowers'), { recursive: true });
  const body = typeof content === 'string' ? content : JSON.stringify(content);
  writeFileSync(path.join(projectDir, '.shared-superpowers', 'settings.json'), body, 'utf8');
  return projectDir;
}

function emptyProject(): string {
  const projectDir = mkdtempSync(path.join(tmpdir(), 'swm-proj-'));
  createdDirs.push(projectDir);
  return projectDir;
}

afterEach(() => {
  while (createdDirs.length > 0) {
    const dir = createdDirs.pop();
    if (dir) rmSync(dir, { recursive: true, force: true });
  }
});

describe('loadConfig', () => {
  it('requires a repo URL', () => {
    expect(() => loadConfig({})).toThrow(/Missing shared wiki repo URL/);
  });

  it('loads environment config', () => {
    const config = loadConfig({
      SHARED_WIKI_MCP_REPO_URL: 'https://github.com/YWJ-hy/shared-wiki.git',
      SHARED_WIKI_MCP_BASE_BRANCH: 'main',
    });
    expect(config.repoUrl).toBe('https://github.com/YWJ-hy/shared-wiki.git');
    expect(config.baseBranch).toBe('main');
    expect(config.displayRoot).toBe('.shared-superpowers/wiki');
  });

  it('rejects absolute wiki roots', () => {
    expect(() => loadConfig({
      SHARED_WIKI_MCP_REPO_URL: 'x',
      SHARED_WIKI_MCP_WIKI_ROOT: '/tmp/wiki',
    })).toThrow(/wikiRoot must be a relative path/);
  });

  it('loads connection config from CLAUDE_PROJECT_DIR project settings', () => {
    const projectDir = projectWithSettings({
      wiki: {
        sharedMcp: {
          repoUrl: 'https://github.com/acme/platform-wiki.git',
          baseBranch: 'master',
          wikiRoot: 'docs',
          displayRoot: '.shared-superpowers/wiki',
          draftPr: false,
        },
        // sibling governance keys must be tolerated and ignored here
        updateAuthorization: { updateExistingPage: 'refuse' },
        sharedNeutrality: { blockedTerms: ['acme-internal'] },
      },
    });
    const config = loadConfig({ CLAUDE_PROJECT_DIR: projectDir });
    expect(config.repoUrl).toBe('https://github.com/acme/platform-wiki.git');
    expect(config.baseBranch).toBe('master');
    expect(config.wikiRoot).toBe('docs');
    expect(config.draftPr).toBe(false);
  });

  it('lets explicit env vars override project settings', () => {
    const projectDir = projectWithSettings({
      wiki: { sharedMcp: { repoUrl: 'https://github.com/acme/platform-wiki.git', baseBranch: 'master' } },
    });
    const config = loadConfig({
      CLAUDE_PROJECT_DIR: projectDir,
      SHARED_WIKI_MCP_REPO_URL: 'https://github.com/override/wiki.git',
    });
    expect(config.repoUrl).toBe('https://github.com/override/wiki.git');
    // baseBranch still comes from project settings since no env override is set
    expect(config.baseBranch).toBe('master');
  });

  it('fails closed when the project declares no shared wiki', () => {
    const projectDir = projectWithSettings({ wiki: { updateAuthorization: { createNewDocument: 'ask' } } });
    expect(() => loadConfig({ CLAUDE_PROJECT_DIR: projectDir })).toThrow(/Missing shared wiki repo URL/);
  });

  it('fails closed when the project has no settings file', () => {
    const projectDir = emptyProject();
    expect(() => loadConfig({ CLAUDE_PROJECT_DIR: projectDir })).toThrow(/Missing shared wiki repo URL/);
  });

  it('ignores cacheDir placed in the project block (machine-local)', () => {
    const projectDir = projectWithSettings({
      wiki: { sharedMcp: { repoUrl: 'https://github.com/acme/platform-wiki.git', cacheDir: '/etc/should-be-ignored' } },
    });
    const config = loadConfig({ CLAUDE_PROJECT_DIR: projectDir });
    expect(config.cacheDir).not.toBe('/etc/should-be-ignored');
    expect(config.cacheDir).toContain('shared-wiki-mcp');
  });

  it('reports invalid JSON in project settings', () => {
    const projectDir = projectWithSettings('{ not json');
    expect(() => loadConfig({ CLAUDE_PROJECT_DIR: projectDir })).toThrow(/Invalid JSON in .*settings\.json/);
  });

  it('reports an invalid wiki.sharedMcp block', () => {
    const projectDir = projectWithSettings({ wiki: { sharedMcp: { repoUrl: 123 } } });
    expect(() => loadConfig({ CLAUDE_PROJECT_DIR: projectDir })).toThrow(/Invalid wiki\.sharedMcp/);
  });
});
