import { createHash } from 'node:crypto';
import { lstatSync, readFileSync, readdirSync } from 'node:fs';
import path from 'node:path';
import type { AtomicNote } from './note.js';

export type SkillAvailability = {
  available: boolean;
  reason?: string;
};

export type SkillRegistration = {
  provider: 'claude-code-project';
  name: string;
  version: string;
  contractHash: string;
  roles: ('implementer' | 'reviewer')[];
  triggers: string[];
  summary: string;
  discoveryState: 'pending';
};

export type SkillValidationContext =
  | { mode: 'write' }
  | { mode: 'discovery'; baseSynchronized: boolean };

export function pendingSkillRegistration(note: AtomicNote): SkillRegistration | undefined {
  if (!note.skillProvider) return undefined;
  return {
    provider: note.skillProvider,
    name: note.skillName!,
    version: note.skillVersion!,
    contractHash: note.skillContractHash!,
    roles: note.skillRoles,
    triggers: note.skillTriggers,
    summary: note.summary,
    discoveryState: 'pending',
  };
}

function packFiles(packRoot: string, current = packRoot): string[] {
  const files: string[] = [];
  for (const entry of readdirSync(current, { withFileTypes: true })) {
    const absolute = path.join(current, entry.name);
    const relative = path.relative(packRoot, absolute).split(path.sep).join('/');
    if (entry.isSymbolicLink() || lstatSync(absolute).isSymbolicLink()) {
      throw new Error(`skill pack contract does not allow symlinks: ${relative}`);
    }
    if (entry.isDirectory()) files.push(...packFiles(packRoot, absolute));
    else if (entry.isFile()) files.push(relative);
  }
  return files.sort((left, right) => Buffer.compare(Buffer.from(left, 'utf8'), Buffer.from(right, 'utf8')));
}

export function skillContractHash(packRoot: string): string {
  const digest = createHash('sha256');
  digest.update('grill-adapter.skill-pack-contract/v1\0', 'utf8');
  for (const relative of packFiles(packRoot)) {
    digest.update(relative, 'utf8');
    digest.update('\0', 'utf8');
    digest.update(createHash('sha256').update(readFileSync(path.join(packRoot, relative))).digest());
    digest.update('\0', 'utf8');
  }
  return `sha256:${digest.digest('hex')}`;
}

function skillFrontmatter(skillPath: string): Record<string, string> {
  const text = readFileSync(skillPath, 'utf8').replaceAll('\r\n', '\n');
  const match = /^---\n([\s\S]*?)\n---\n/.exec(text);
  if (!match) throw new Error('SKILL.md has no frontmatter');
  const fields: Record<string, string> = {};
  for (const line of match[1].split('\n')) {
    const field = /^([A-Za-z0-9_-]+):\s*(.*?)\s*$/.exec(line);
    if (field) fields[field[1]] = field[2].replace(/^['"]|['"]$/g, '');
  }
  return fields;
}

export function skillCardAvailability(
  note: AtomicNote,
  projectDir: string,
  context: SkillValidationContext,
): SkillAvailability {
  if (!note.skillProvider) return { available: true };
  if (context.mode === 'discovery' && !context.baseSynchronized) {
    return { available: false, reason: 'Card Source base is not synchronized with its remote' };
  }
  if (note.skillProvider !== 'claude-code-project') {
    return { available: false, reason: `unsupported provider ${note.skillProvider}` };
  }
  const packRoot = path.join(projectDir, '.claude', 'skills', note.skillName!);
  const skillPath = path.join(packRoot, 'SKILL.md');
  try {
    const frontmatter = skillFrontmatter(skillPath);
    if (frontmatter.name !== note.skillName) {
      return { available: false, reason: 'pack name does not match the Card' };
    }
    if (frontmatter.version !== note.skillVersion) {
      return { available: false, reason: 'pack version does not match the Card' };
    }
    if (skillContractHash(packRoot) !== note.skillContractHash) {
      return { available: false, reason: 'pack contract hash does not match the Card' };
    }
    return { available: true };
  } catch (error) {
    return {
      available: false,
      reason: error instanceof Error ? error.message : String(error),
    };
  }
}

export function assertSkillCardAvailable(
  note: AtomicNote,
  projectDir: string,
  context: SkillValidationContext,
): void {
  const availability = skillCardAvailability(note, projectDir, context);
  if (!availability.available) {
    throw new Error(
      `Skill Card is unavailable: ${note.wikiId}: ${availability.reason ?? 'unknown reason'}`,
    );
  }
}
