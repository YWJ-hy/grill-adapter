import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import { contentHash } from '../src/note.js';
import { skillContractHash } from '../src/skill-card.js';
import { startWriteBridge, type WriteBridgeHandle } from '../src/write-bridge.js';

const roots: string[] = [];
const bridges: WriteBridgeHandle[] = [];

function note(wikiId: string, body: string): string {
  return `---\nwiki_schema: grill-adapter.obsidian-note/v1\nwiki_id: ${wikiId}\ntype: constraint\nstatus: active\nagent_visible: true\nsummary: Bridge contract\nconstraint_strength: hard\n---\n\n# Bridge contract\n\n${body}\n`;
}

function adrProjectionNote(wikiId: string, sourceId: string): string {
  return `---
wiki_schema: grill-adapter.obsidian-note/v1
wiki_id: ${wikiId}
type: constraint
status: active
agent_visible: true
summary: Runtime execution constraints projected from the authoritative project ADR.
constraint_strength: hard
adr_source_id: ${sourceId}
adr_source_path: src/runtime/docs/adr/0001-runtime.md
adr_source_content_hash: sha256:${'a'.repeat(64)}
---

# Derived ADR execution constraints

This Note is derived. Edit the authoritative ADR, not this projection.
`;
}

function skillCard(wikiId: string, contractHash: string): string {
  return `---\nwiki_schema: grill-adapter.obsidian-note/v1\nwiki_id: ${wikiId}\ntype: guide\nstatus: active\nagent_visible: true\nsummary: Bridge Skill Card\nskill_provider: claude-code-project\nskill_name: bridge-review\nskill_version: 1.0.0\nskill_contract_hash: ${contractHash}\nskill_roles:\n  - reviewer\nskill_triggers:\n  - bridge review\n---\n\n# Bridge review\n`;
}

function manifest(sourceId: string, scope: 'project' | 'shared'): string {
  const neutrality = scope === 'shared' ? 'blocked_terms:\n  - acme-internal\nblocked_patterns:\n  - "secret-[0-9]+"\n' : '';
  return `---\nwiki_schema: grill-adapter.obsidian-source/v1\nwiki_source_id: ${sourceId}\nscope: ${scope}\nupdate_existing: confirm\ncreate_note: confirm\n${neutrality}---\n`;
}

async function bridgeRequest(
  bridge: WriteBridgeHandle,
  route: 'validate' | 'apply',
  payload: Record<string, unknown>,
  token = 'test-token',
) {
  return fetch(`${bridge.url}/v1/notes/${route}`, {
    method: 'POST',
    redirect: 'manual',
    headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
    body: JSON.stringify(payload),
  });
}

async function fixture(
  shared = false,
  beforeAtomicExchange?: (targetPath: string) => void,
  afterAtomicExchange?: (targetPath: string) => void,
  peerProject = false,
) {
  const vaultRoot = mkdtempSync(path.join(tmpdir(), 'obsidian-write-bridge-'));
  roots.push(vaultRoot);
  const projectDir = path.join(vaultRoot, shared ? 'shared-project' : 'project');
  const sourceRoot = shared ? 'Shared/Engineering' : 'Projects/example';
  const sourceId = shared ? 'engineering-shared' : 'project';
  const wikiId = shared ? 'engineering-shared/bridge' : 'project/example/bridge';
  mkdirSync(path.join(vaultRoot, sourceRoot), { recursive: true });
  mkdirSync(path.join(vaultRoot, sourceRoot, '_meta'), { recursive: true });
  writeFileSync(path.join(vaultRoot, sourceRoot, '_meta', 'wiki-source.md'), manifest(sourceId, shared ? 'shared' : 'project'), 'utf8');
  const initial = note(wikiId, 'Initial body.');
  writeFileSync(path.join(vaultRoot, sourceRoot, 'Bridge.md'), initial, 'utf8');
  mkdirSync(path.join(projectDir, '.shared-adapter'), { recursive: true });
  writeFileSync(path.join(projectDir, '.shared-adapter', 'settings.json'), JSON.stringify({
    wiki: { provider: 'obsidian', obsidian: { bindings: [{ sourceId, role: shared ? 'shared' : 'project', vaultRef: 'knowledge', root: sourceRoot, access: { read: true, update: 'confirm' } }] } },
  }), 'utf8');
  const allowedRoots = [sourceRoot];
  const projectDirs = [projectDir];
  if (peerProject) {
    const peerSourceRoot = 'Projects/peer';
    const peerProjectDir = path.join(vaultRoot, 'peer-project');
    mkdirSync(path.join(vaultRoot, peerSourceRoot, '_meta'), { recursive: true });
    writeFileSync(
      path.join(vaultRoot, peerSourceRoot, '_meta', 'wiki-source.md'),
      manifest('peer', 'project'),
      'utf8',
    );
    writeFileSync(
      path.join(vaultRoot, peerSourceRoot, 'BridgeSkill.md'),
      skillCard('peer/bridge-review', `sha256:${'0'.repeat(64)}`),
      'utf8',
    );
    mkdirSync(path.join(peerProjectDir, '.shared-adapter'), { recursive: true });
    writeFileSync(path.join(peerProjectDir, '.shared-adapter', 'settings.json'), JSON.stringify({
      wiki: { provider: 'obsidian', obsidian: { bindings: [{ sourceId: 'peer', role: 'project', vaultRef: 'knowledge', root: peerSourceRoot, access: { read: true, update: 'confirm' } }] } },
    }), 'utf8');
    allowedRoots.push(peerSourceRoot);
    projectDirs.push(peerProjectDir);
  }
  const bridge = await startWriteBridge({
    vaultRoot,
    vaultSelector: 'Knowledge',
    allowedRoots,
    projectDirs,
    token: 'test-token',
    host: '127.0.0.1',
    port: 0,
    beforeAtomicExchange,
    afterAtomicExchange,
  });
  bridges.push(bridge);
  return { vaultRoot, projectDir, sourceRoot, sourceId, wikiId, initial, bridge };
}

afterEach(async () => {
  while (bridges.length) await bridges.pop()!.close();
  while (roots.length) rmSync(roots.pop()!, { recursive: true, force: true });
});

describe('Obsidian Wiki loopback write bridge', () => {
  it('validates without writing, then atomically applies an expected-hash update', async () => {
    const { vaultRoot, projectDir, sourceRoot, initial, bridge } = await fixture();
    const proposed = note('project/example/bridge', 'Updated body.');
    const request = {
      vaultSelector: 'Knowledge',
      projectDir,
      sourceId: 'project',
      vaultRef: 'knowledge',
      sourceRoot,
      operation: 'update',
      path: `${sourceRoot}/Bridge.md`,
      content: proposed,
      expectedHash: contentHash(initial),
      expectedWikiId: 'project/example/bridge',
      authorized: true,
    };

    const preview = await bridgeRequest(bridge, 'validate', request);
    expect(preview.status).toBe(200);
    expect(await preview.json()).toMatchObject({
      ok: true,
      operation: 'update',
      diff: {
        beforeHash: contentHash(initial),
        afterHash: contentHash(proposed),
        beforeContent: initial,
        afterContent: proposed,
      },
    });
    expect(readFileSync(path.join(vaultRoot, sourceRoot, 'Bridge.md'), 'utf8')).toBe(initial);

    const applied = await bridgeRequest(bridge, 'apply', request);
    expect(applied.status).toBe(200);
    expect(await applied.json()).toMatchObject({
      ok: true,
      postWrite: {
        wikiId: 'project/example/bridge',
        path: `${sourceRoot}/Bridge.md`,
        contentHash: contentHash(proposed),
      },
    });
    expect(readFileSync(path.join(vaultRoot, sourceRoot, 'Bridge.md'), 'utf8')).toBe(proposed);
  });

  it('rejects invalid tokens, stale hashes, metadata paths, unbound roots, and non-loopback binding', async () => {
    const { projectDir, sourceRoot, initial, bridge } = await fixture();
    const base = {
      vaultSelector: 'Knowledge',
      projectDir,
      sourceId: 'project',
      vaultRef: 'knowledge',
      sourceRoot,
      operation: 'update',
      path: `${sourceRoot}/Bridge.md`,
      content: note('project/example/bridge', 'Updated body.'),
      expectedHash: contentHash(initial),
      expectedWikiId: 'project/example/bridge',
      authorized: true,
    };

    expect((await bridgeRequest(bridge, 'apply', base, 'wrong-token')).status).toBe(401);
    expect((await bridgeRequest(bridge, 'apply', { ...base, authorized: false })).status).toBe(403);
    expect((await bridgeRequest(bridge, 'apply', { ...base, expectedHash: `sha256:${'0'.repeat(64)}` })).status).toBe(409);
    expect((await bridgeRequest(bridge, 'apply', { ...base, path: `${sourceRoot}/_meta/wiki-source.md` })).status).toBe(403);
    expect((await bridgeRequest(bridge, 'apply', { ...base, sourceRoot: 'Projects/other', path: 'Projects/other/Note.md' })).status).toBe(403);

    await expect(startWriteBridge({
      vaultRoot: path.dirname(sourceRoot),
      vaultSelector: 'Knowledge',
      allowedRoots: [sourceRoot],
      projectDirs: [projectDir],
      token: 'test-token',
      host: '0.0.0.0',
      port: 0,
    })).rejects.toThrow(/loopback/);
  });

  it('enforces Shared neutrality inside the bridge so direct callers cannot bypass it', async () => {
    const { projectDir, sourceRoot, sourceId, wikiId, initial, bridge } = await fixture(true);
    const request = {
      vaultSelector: 'Knowledge',
      projectDir,
      sourceId,
      vaultRef: 'knowledge',
      sourceRoot,
      operation: 'update',
      path: `${sourceRoot}/Bridge.md`,
      content: note(wikiId, 'Contains acme-internal and secret-42.'),
      expectedHash: contentHash(initial),
      expectedWikiId: wikiId,
      authorized: true,
    };

    expect((await bridgeRequest(bridge, 'validate', request)).status).toBe(403);
    expect((await bridgeRequest(bridge, 'apply', request)).status).toBe(403);
  });

  it('enforces project-only ADR projection ownership and source identity uniqueness', async () => {
    const project = await fixture();
    const authorityId = `project-adr:${'1'.repeat(64)}`;
    const create = {
      vaultSelector: 'Knowledge',
      projectDir: project.projectDir,
      sourceId: project.sourceId,
      vaultRef: 'knowledge',
      sourceRoot: project.sourceRoot,
      operation: 'create',
      path: `${project.sourceRoot}/RuntimeProjection.md`,
      content: adrProjectionNote(`${project.sourceId}/adr/runtime`, authorityId),
      expectedHash: null,
      expectedWikiId: `${project.sourceId}/adr/runtime`,
      authorized: true,
    };
    expect((await bridgeRequest(project.bridge, 'apply', create)).status).toBe(200);
    const duplicate = {
      ...create,
      path: `${project.sourceRoot}/RuntimeProjectionDuplicate.md`,
      content: adrProjectionNote(`${project.sourceId}/adr/runtime-duplicate`, authorityId),
      expectedWikiId: `${project.sourceId}/adr/runtime-duplicate`,
    };
    expect((await bridgeRequest(project.bridge, 'validate', duplicate)).status).toBe(409);

    const shared = await fixture(true);
    const sharedCreate = {
      vaultSelector: 'Knowledge',
      projectDir: shared.projectDir,
      sourceId: shared.sourceId,
      vaultRef: 'knowledge',
      sourceRoot: shared.sourceRoot,
      operation: 'create',
      path: `${shared.sourceRoot}/RuntimeProjection.md`,
      content: adrProjectionNote(`${shared.sourceId}/adr/runtime`, authorityId),
      expectedHash: null,
      expectedWikiId: `${shared.sourceId}/adr/runtime`,
      authorized: true,
    };
    expect((await bridgeRequest(shared.bridge, 'validate', sharedCreate)).status).toBe(403);
    expect((await bridgeRequest(shared.bridge, 'apply', sharedCreate)).status).toBe(403);
  });

  it('rejects an unavailable Skill Card through the direct authenticated bridge boundary', async () => {
    const { vaultRoot, projectDir, sourceRoot, sourceId, bridge } = await fixture();
    const packRoot = path.join(projectDir, '.claude', 'skills', 'bridge-review');
    mkdirSync(packRoot, { recursive: true });
    writeFileSync(
      path.join(packRoot, 'SKILL.md'),
      '---\nname: bridge-review\ndescription: Review bridge changes.\nversion: 1.0.0\n---\n',
      'utf8',
    );
    const target = path.join(vaultRoot, sourceRoot, 'BridgeSkill.md');
    const request = {
      vaultSelector: 'Knowledge',
      projectDir,
      sourceId,
      vaultRef: 'knowledge',
      sourceRoot,
      operation: 'create',
      path: `${sourceRoot}/BridgeSkill.md`,
      content: skillCard(`${sourceId}/bridge-review`, `sha256:${'0'.repeat(64)}`),
      expectedHash: null,
      expectedWikiId: `${sourceId}/bridge-review`,
      authorized: true,
    };

    expect((await bridgeRequest(bridge, 'validate', request)).status).toBe(403);
    expect((await bridgeRequest(bridge, 'apply', request)).status).toBe(403);
    expect(() => readFileSync(target, 'utf8')).toThrow();
  });

  it('scopes Card uniqueness to one project even when the bridge serves peer projects', async () => {
    const { projectDir, sourceRoot, sourceId, bridge } = await fixture(
      false,
      undefined,
      undefined,
      true,
    );
    const packRoot = path.join(projectDir, '.claude', 'skills', 'bridge-review');
    mkdirSync(packRoot, { recursive: true });
    writeFileSync(
      path.join(packRoot, 'SKILL.md'),
      '---\nname: bridge-review\ndescription: Review bridge changes.\nversion: 1.0.0\n---\n',
      'utf8',
    );
    const contractHash = skillContractHash(packRoot);
    const first = {
      vaultSelector: 'Knowledge',
      projectDir,
      sourceId,
      vaultRef: 'knowledge',
      sourceRoot,
      operation: 'create',
      path: `${sourceRoot}/BridgeSkill.md`,
      content: skillCard(`${sourceId}/bridge-review`, contractHash),
      expectedHash: null,
      expectedWikiId: `${sourceId}/bridge-review`,
      authorized: true,
    };
    expect((await bridgeRequest(bridge, 'apply', first)).status).toBe(200);

    const duplicate = {
      ...first,
      path: `${sourceRoot}/DuplicateBridgeSkill.md`,
      content: skillCard(`${sourceId}/bridge-review-duplicate`, contractHash),
      expectedWikiId: `${sourceId}/bridge-review-duplicate`,
    };
    const response = await bridgeRequest(bridge, 'validate', duplicate);
    expect(response.status).toBe(409);
    expect(await response.json()).toMatchObject({ error: expect.stringMatching(/already exists/) });
  });

  it('rereads Source and project governance for every request', async () => {
    const { vaultRoot, projectDir, sourceRoot, initial, bridge } = await fixture();
    const request = {
      vaultSelector: 'Knowledge',
      projectDir,
      sourceId: 'project',
      vaultRef: 'knowledge',
      sourceRoot,
      operation: 'update',
      path: `${sourceRoot}/Bridge.md`,
      content: note('project/example/bridge', 'Updated body.'),
      expectedHash: contentHash(initial),
      expectedWikiId: 'project/example/bridge',
      authorized: true,
    };
    writeFileSync(path.join(vaultRoot, sourceRoot, '_meta', 'wiki-source.md'), manifest('project', 'project').replace('update_existing: confirm', 'update_existing: deny'), 'utf8');
    expect((await bridgeRequest(bridge, 'validate', request)).status).toBe(403);

    writeFileSync(path.join(vaultRoot, sourceRoot, '_meta', 'wiki-source.md'), manifest('project', 'project'), 'utf8');
    const settingsPath = path.join(projectDir, '.shared-adapter', 'settings.json');
    const settings = JSON.parse(readFileSync(settingsPath, 'utf8'));
    settings.wiki.obsidian.bindings[0].access.update = 'deny';
    writeFileSync(settingsPath, JSON.stringify(settings), 'utf8');
    expect((await bridgeRequest(bridge, 'apply', request)).status).toBe(403);
  });

  it('serializes concurrent bridge updates and lets only one expected hash win', async () => {
    const { projectDir, sourceRoot, initial, bridge } = await fixture();
    const request = {
      vaultSelector: 'Knowledge',
      projectDir,
      sourceId: 'project',
      vaultRef: 'knowledge',
      sourceRoot,
      operation: 'update',
      path: `${sourceRoot}/Bridge.md`,
      content: note('project/example/bridge', 'One winner.'),
      expectedHash: contentHash(initial),
      expectedWikiId: 'project/example/bridge',
      authorized: true,
    };

    const responses = await Promise.all([
      bridgeRequest(bridge, 'apply', request),
      bridgeRequest(bridge, 'apply', request),
    ]);
    expect(responses.map((response) => response.status).sort()).toEqual([200, 409]);
  });

  it('atomically rolls back when an external editor wins the final update race', async () => {
    const firstExternal = note('project/example/bridge', 'First external editor body.');
    const latestExternal = note('project/example/bridge', 'Latest external editor body.');
    const result = await fixture(
      false,
      (targetPath) => writeFileSync(targetPath, firstExternal, 'utf8'),
      (targetPath) => writeFileSync(targetPath, latestExternal, 'utf8'),
    );
    const request = {
      vaultSelector: 'Knowledge',
      projectDir: result.projectDir,
      sourceId: 'project',
      vaultRef: 'knowledge',
      sourceRoot: result.sourceRoot,
      operation: 'update',
      path: `${result.sourceRoot}/Bridge.md`,
      content: note('project/example/bridge', 'Bridge body.'),
      expectedHash: contentHash(result.initial),
      expectedWikiId: 'project/example/bridge',
      authorized: true,
    };

    expect((await bridgeRequest(result.bridge, 'apply', request)).status).toBe(409);
    expect(readFileSync(path.join(result.vaultRoot, result.sourceRoot, 'Bridge.md'), 'utf8')).toBe(latestExternal);
  });
});
