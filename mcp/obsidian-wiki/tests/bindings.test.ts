import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import { environmentForMcpRequest, resolveBindings } from '../src/bindings.js';
import { sourcesTool } from '../src/tools/sources.js';
import { statusTool } from '../src/tools/status.js';

const createdDirectories: string[] = [];

function writeJson(filePath: string, value: unknown): void {
  mkdirSync(path.dirname(filePath), { recursive: true });
  writeFileSync(filePath, JSON.stringify(value, null, 2), 'utf8');
}

function manifest(sourceId: string, scope: 'project' | 'shared'): string {
  const neutrality = scope === 'shared' ? 'blocked_terms:\n  - acme-internal\nblocked_patterns:\n  - "internal"\n' : '';
  return `---\nwiki_schema: grill-adapter.obsidian-source/v1\nwiki_source_id: ${sourceId}\nscope: ${scope}\nupdate_existing: confirm\ncreate_note: direct\n${neutrality}---\n\n# ${sourceId}\n`;
}

function fixture(bindings: unknown[], manifests: Array<{ root: string; sourceId: string; scope: 'project' | 'shared' }>) {
  const root = mkdtempSync(path.join(tmpdir(), 'obsidian-bindings-'));
  createdDirectories.push(root);
  const projectDir = path.join(root, 'project');
  const vaultRoot = path.join(root, 'vault');
  const registryPath = path.join(root, 'registry.json');
  const obsidianCli = path.join(root, 'obsidian');
  mkdirSync(vaultRoot, { recursive: true });
  execFileSync('git', ['init', '--initial-branch=main', vaultRoot]);
  execFileSync('git', ['-C', vaultRoot, 'config', 'user.name', 'Test User']);
  execFileSync('git', ['-C', vaultRoot, 'config', 'user.email', 'test@example.invalid']);
  execFileSync('git', ['-C', vaultRoot, 'remote', 'add', 'origin', 'https://github.com/acme/knowledge.git']);
  for (const entry of manifests) {
    const destination = path.join(vaultRoot, entry.root, '_meta');
    mkdirSync(destination, { recursive: true });
    writeFileSync(path.join(destination, 'wiki-source.md'), manifest(entry.sourceId, entry.scope), 'utf8');
  }
  writeFileSync(path.join(vaultRoot, '.gitkeep'), '', 'utf8');
  execFileSync('git', ['-C', vaultRoot, 'add', '.']);
  execFileSync('git', ['-C', vaultRoot, 'commit', '-m', 'fixture']);
  writeFileSync(obsidianCli, '#!/usr/bin/env sh\n[ "$1" = "vault" ] && printf "Knowledge\\n"\n', 'utf8');
  chmodSync(obsidianCli, 0o755);
  writeJson(path.join(projectDir, '.shared-adapter', 'settings.json'), {
    wiki: { provider: 'obsidian', publishing: { mode: 'git-pr' }, obsidian: { bindings } },
  });
  writeJson(registryPath, {
    vaults: { knowledge: { selector: 'Knowledge' } },
    repositories: {
      wiki: {
        worktreeRoot: vaultRoot,
        remote: 'origin',
        expectedRemote: 'github.com/acme/knowledge',
        baseBranch: 'main',
        syncBeforeResearch: false,
      },
    },
  });
  return { projectDir, registryPath, vaultRoot, obsidianCli };
}

function testEnvironment(input: ReturnType<typeof fixture>): NodeJS.ProcessEnv {
  return {
    CLAUDE_PROJECT_DIR: input.projectDir,
    OBSIDIAN_WIKI_REGISTRY: input.registryPath,
    OBSIDIAN_WIKI_OBSIDIAN_CLI: input.obsidianCli,
  };
}

afterEach(() => {
  while (createdDirectories.length) rmSync(createdDirectories.pop()!, { recursive: true, force: true });
});

describe('Obsidian Wiki Source bindings', () => {
  it('resolves bound Sources and derives stable effective policies and digest', () => {
    const input = fixture([
      { sourceId: 'project', role: 'project', vaultRef: 'knowledge', repositoryRef: 'wiki', root: 'Projects/example', access: { read: true, update: 'direct' } },
      { sourceId: 'shared', role: 'shared', vaultRef: 'knowledge', repositoryRef: 'wiki', root: 'Shared/Engineering', access: { read: true, update: 'deny' } },
    ], [
      { root: 'Projects/example', sourceId: 'project', scope: 'project' },
      { root: 'Shared/Engineering', sourceId: 'shared', scope: 'shared' },
    ]);
    const result = resolveBindings(testEnvironment(input));
    expect(result.errors).toEqual([]);
    expect(result.bindings).toHaveLength(2);
    expect(result.bindings[0]).toMatchObject({ effectiveReadPolicy: 'allow', effectiveUpdatePolicy: 'confirm', effectiveCreatePolicy: 'direct' });
    expect(result.bindings[1]).toMatchObject({ effectiveUpdatePolicy: 'deny', effectiveCreatePolicy: 'deny' });
    expect(result.bindings[0].bindingDigest).toMatch(/^[a-f0-9]{64}$/);
  });

  it('fails closed for absent project configuration and registry entries', () => {
    expect(() => resolveBindings({}, path.join(tmpdir(), 'missing-codex-project'))).toThrow(/Project settings/);
    const input = fixture([
      { sourceId: 'project', role: 'project', vaultRef: 'missing', repositoryRef: 'wiki', root: 'Projects/example', access: { read: true } },
    ], [{ root: 'Projects/example', sourceId: 'project', scope: 'project' }]);
    const status = statusTool(testEnvironment(input));
    expect(status.healthy).toBe(false);
    expect(status.projectDir).toBe(input.projectDir);
    expect(status.errors.join(' ')).toMatch(/unresolved vaultRef/);
  });

  it('resolves Codex bindings from the MCP working directory', () => {
    const input = fixture([
      { sourceId: 'project', role: 'project', vaultRef: 'knowledge', repositoryRef: 'wiki', root: 'Projects/example', access: { read: true } },
    ], [{ root: 'Projects/example', sourceId: 'project', scope: 'project' }]);
    const env = testEnvironment(input);
    delete env.CLAUDE_PROJECT_DIR;
    expect(resolveBindings(env, input.projectDir).bindings).toHaveLength(1);
  });

  it('resolves Codex bindings from MCP request workspace metadata when cwd is the plugin root', () => {
    const input = fixture([
      { sourceId: 'project', role: 'project', vaultRef: 'knowledge', repositoryRef: 'wiki', root: 'Projects/example', access: { read: true } },
    ], [{ root: 'Projects/example', sourceId: 'project', scope: 'project' }]);
    const env = testEnvironment(input);
    delete env.CLAUDE_PROJECT_DIR;
    const pluginLikeProject = fixture([], []);
    const requestEnv = environmentForMcpRequest(env, {
      'x-codex-turn-metadata': { workspaces: { [input.projectDir]: { has_changes: false } } },
    }, pluginLikeProject.projectDir);
    expect(requestEnv.CLAUDE_PROJECT_DIR).toBe(input.projectDir);
    expect(resolveBindings(requestEnv).bindings).toHaveLength(1);
  });

  it('fails closed when Codex workspace binding is absent or ambiguous', () => {
    const first = fixture([], []);
    const second = fixture([], []);
    expect(() => environmentForMcpRequest({}, {}, path.join(tmpdir(), 'plugin-root')))
      .toThrow(/No Codex workspace metadata/);
    expect(() => environmentForMcpRequest({}, {
      'x-codex-turn-metadata': {
        workspaces: { [first.projectDir]: {}, [second.projectDir]: {} },
      },
    }, path.join(tmpdir(), 'plugin-root'))).toThrow(/binding is ambiguous/);
  });

  it('rejects duplicate IDs, duplicate roots, overlapping roots, extra project roles, and root escapes', () => {
    const input = fixture([
      { sourceId: 'project', role: 'project', vaultRef: 'knowledge', repositoryRef: 'wiki', root: 'Projects/example', access: { read: true } },
      { sourceId: 'project', role: 'shared', vaultRef: 'knowledge', repositoryRef: 'wiki', root: 'Projects/other', access: { read: true } },
      { sourceId: 'second-project', role: 'project', vaultRef: 'knowledge', repositoryRef: 'wiki', root: 'Projects/example', access: { read: true } },
      { sourceId: 'nested', role: 'shared', vaultRef: 'knowledge', repositoryRef: 'wiki', root: 'Projects/example/restricted', access: { read: false } },
      { sourceId: 'escape', role: 'shared', vaultRef: 'knowledge', repositoryRef: 'wiki', root: '../outside', access: { read: true } },
    ], [
      { root: 'Projects/example', sourceId: 'project', scope: 'project' },
      { root: 'Projects/other', sourceId: 'project', scope: 'shared' },
    ]);
    const result = resolveBindings(testEnvironment(input));
    expect(result.errors.join(' ')).toMatch(/duplicate sourceId/);
    expect(result.errors.join(' ')).toMatch(/at most one binding may have role/);
    expect(result.errors.join(' ')).toMatch(/overlapping root for vault/);
    expect(result.errors.join(' ')).toMatch(/binding root must name a directory/);
  });

  it('rejects Source identity and scope mismatch plus missing manifests', () => {
    const input = fixture([
      { sourceId: 'project', role: 'project', vaultRef: 'knowledge', repositoryRef: 'wiki', root: 'Projects/missing', access: { read: true } },
      { sourceId: 'wrong', role: 'shared', vaultRef: 'knowledge', repositoryRef: 'wiki', root: 'Shared/Engineering', access: { read: true } },
    ], [{ root: 'Shared/Engineering', sourceId: 'other', scope: 'shared' }]);
    const result = resolveBindings(testEnvironment(input));
    expect(result.errors.join(' ')).toMatch(/Source manifest missing/);
    expect(result.errors.join(' ')).toMatch(/Source manifest ID mismatch/);
  });

  it('rejects a Source root that escapes through a symbolic link', () => {
    const input = fixture([
      { sourceId: 'escape', role: 'shared', vaultRef: 'knowledge', repositoryRef: 'wiki', root: 'Shared/Escape', access: { read: true } },
    ], []);
    const projectRoot = path.dirname(input.projectDir);
    const outside = path.join(projectRoot, 'outside');
    mkdirSync(path.join(outside, '_meta'), { recursive: true });
    writeFileSync(path.join(outside, '_meta', 'wiki-source.md'), manifest('escape', 'shared'), 'utf8');
    mkdirSync(path.join(projectRoot, 'vault', 'Shared'), { recursive: true });
    symlinkSync(outside, path.join(projectRoot, 'vault', 'Shared', 'Escape'));
    execFileSync('git', ['-C', input.vaultRoot, 'add', 'Shared/Escape']);
    execFileSync('git', ['-C', input.vaultRoot, 'commit', '-m', 'add escape fixture']);
    const result = resolveBindings(testEnvironment(input));
    expect(result.errors.join(' ')).toMatch(/binding root escapes repository worktree/);
  });

  it('rejects a manifest that escapes through a nested symbolic link', () => {
    const input = fixture([
      { sourceId: 'project', role: 'project', vaultRef: 'knowledge', repositoryRef: 'wiki', root: 'Projects/example', access: { read: true } },
    ], [{ root: 'Projects/example', sourceId: 'project', scope: 'project' }]);
    const outside = path.join(path.dirname(input.projectDir), 'outside-meta');
    mkdirSync(outside, { recursive: true });
    writeFileSync(path.join(outside, 'wiki-source.md'), manifest('project', 'project'), 'utf8');
    rmSync(path.join(input.vaultRoot, 'Projects', 'example', '_meta'), { recursive: true });
    symlinkSync(outside, path.join(input.vaultRoot, 'Projects', 'example', '_meta'));
    execFileSync('git', ['-C', input.vaultRoot, 'add', '-A']);
    execFileSync('git', ['-C', input.vaultRoot, 'commit', '-m', 'add nested manifest escape']);
    expect(resolveBindings(testEnvironment(input)).errors.join(' ')).toMatch(/Source manifest escapes binding root/);
  });

  it('fails closed for credential-bearing remotes, mismatched remotes, non-base branches, dirty worktrees, and unavailable Vault selectors', () => {
    const validBinding = { sourceId: 'project', role: 'project', vaultRef: 'knowledge', repositoryRef: 'wiki', root: 'Projects/example', access: { read: true } };
    const credentialed = fixture([validBinding], [{ root: 'Projects/example', sourceId: 'project', scope: 'project' }]);
    const credentialedRegistry = JSON.parse(readFileSync(credentialed.registryPath, 'utf8'));
    credentialedRegistry.repositories.wiki.expectedRemote = 'https://token@github.com/acme/knowledge.git';
    writeJson(credentialed.registryPath, credentialedRegistry);
    expect(resolveBindings(testEnvironment(credentialed)).errors.join(' ')).toMatch(/must not contain credentials/);

    const scpCredentialed = fixture([validBinding], [{ root: 'Projects/example', sourceId: 'project', scope: 'project' }]);
    execFileSync('git', ['-C', scpCredentialed.vaultRoot, 'remote', 'set-url', 'origin', 'token@github.com:acme/knowledge.git']);
    expect(resolveBindings(testEnvironment(scpCredentialed)).errors.join(' ')).toMatch(/must not contain credentials/);

    const mismatched = fixture([validBinding], [{ root: 'Projects/example', sourceId: 'project', scope: 'project' }]);
    execFileSync('git', ['-C', mismatched.vaultRoot, 'remote', 'set-url', 'origin', 'https://github.com/acme/other.git']);
    expect(resolveBindings(testEnvironment(mismatched)).errors.join(' ')).toMatch(/does not match expectedRemote/);

    const nonBase = fixture([validBinding], [{ root: 'Projects/example', sourceId: 'project', scope: 'project' }]);
    execFileSync('git', ['-C', nonBase.vaultRoot, 'checkout', '-b', 'feature']);
    expect(resolveBindings(testEnvironment(nonBase)).errors.join(' ')).toMatch(/must be on baseBranch/);

    const dirty = fixture([validBinding], [{ root: 'Projects/example', sourceId: 'project', scope: 'project' }]);
    writeFileSync(path.join(dirty.vaultRoot, 'dirty.md'), '# dirty\n', 'utf8');
    expect(resolveBindings(testEnvironment(dirty)).errors.join(' ')).toMatch(/worktree must be clean/);

    const missingVault = fixture([validBinding], [{ root: 'Projects/example', sourceId: 'project', scope: 'project' }]);
    writeFileSync(missingVault.obsidianCli, '#!/usr/bin/env sh\nprintf "Different Vault\\n"\n', 'utf8');
    chmodSync(missingVault.obsidianCli, 0o755);
    expect(resolveBindings(testEnvironment(missingVault)).errors.join(' ')).toMatch(/Vault selector is not available/);

    const locked = fixture([validBinding], [{ root: 'Projects/example', sourceId: 'project', scope: 'project' }]);
    writeFileSync(path.join(locked.vaultRoot, '.grill-adapter-wiki.publish.lock'), 'active\n', 'utf8');
    expect(resolveBindings(testEnvironment(locked)).errors.join(' ')).toMatch(/active Obsidian Wiki publish lock/);
  });

  it('lists only readable bound Sources and never accepts a caller supplied Vault path', () => {
    const input = fixture([
      { sourceId: 'project', role: 'project', vaultRef: 'knowledge', repositoryRef: 'wiki', root: 'Projects/example', access: { read: true } },
      { sourceId: 'private', role: 'shared', vaultRef: 'knowledge', repositoryRef: 'wiki', root: 'Shared/private', access: { read: false } },
    ], [
      { root: 'Projects/example', sourceId: 'project', scope: 'project' },
      { root: 'Shared/private', sourceId: 'private', scope: 'shared' },
    ]);
    expect(sourcesTool(testEnvironment(input))).toEqual(expect.objectContaining({
      sources: [expect.objectContaining({ sourceId: 'project', root: 'Projects/example' })],
    }));
  });
});
