import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import { skillContractHash } from '../src/skill-card.js';

const roots: string[] = [];

afterEach(() => {
  while (roots.length) rmSync(roots.pop()!, { recursive: true, force: true });
});

describe('Skill Card pack contract', () => {
  it('uses the same POSIX-relative path ordering in Python staging and MCP validation', () => {
    const projectDir = mkdtempSync(path.join(tmpdir(), 'skill-card-contract-'));
    roots.push(projectDir);
    const vector = JSON.parse(readFileSync(
      path.join(import.meta.dirname, 'fixtures', 'skill-pack-hash-v1.json'),
      'utf8',
    )) as { name: string; files: Record<string, string>; expectedHash: string };
    const packRoot = path.join(projectDir, '.claude', 'skills', vector.name);
    for (const [relative, content] of Object.entries(vector.files)) {
      const destination = path.join(packRoot, relative);
      mkdirSync(path.dirname(destination), { recursive: true });
      writeFileSync(destination, content, 'utf8');
    }

    expect(skillContractHash(packRoot)).toBe(vector.expectedHash);
  });
});
