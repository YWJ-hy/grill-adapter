import { createHash } from 'node:crypto';
import { existsSync, lstatSync, readFileSync, readdirSync } from 'node:fs';
import path from 'node:path';
import type { AtomicNote, AtomicNoteMetadata } from './note.js';

export type SkillAvailability = {
  available: boolean;
  reason?: string;
};

export type SkillRegistration = {
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
  if (!note.skillName) return undefined;
  return {
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
  note: AtomicNote | AtomicNoteMetadata,
  projectDir: string,
  context: SkillValidationContext,
): SkillAvailability {
  if (!note.skillName) return { available: true };
  if (context.mode === 'discovery' && !context.baseSynchronized) {
    return { available: false, reason: 'Card Source base is not synchronized with its remote' };
  }
  const packRoots = [
    path.join(projectDir, '.agents', 'skills', note.skillName),
    path.join(projectDir, '.claude', 'skills', note.skillName),
  ];
  for (const packRoot of packRoots) {
    const skillPath = path.join(packRoot, 'SKILL.md');
    if (!existsSync(skillPath)) {
      return {
        available: false,
        reason: `project skill pack is missing: ${path.relative(projectDir, skillPath)}`,
      };
    }
    try {
      const frontmatter = skillFrontmatter(skillPath);
      if (frontmatter.name !== note.skillName) {
        return {
          available: false,
          reason: `${path.relative(projectDir, packRoot)} name does not match the Card`,
        };
      }
      if (frontmatter.version !== note.skillVersion) {
        return {
          available: false,
          reason: `${path.relative(projectDir, packRoot)} version does not match the Card`,
        };
      }
      if (skillContractHash(packRoot) !== note.skillContractHash) {
        return {
          available: false,
          reason: `${path.relative(projectDir, packRoot)} contract hash does not match the Card`,
        };
      }
    } catch (error) {
      return {
        available: false,
        reason: error instanceof Error ? error.message : String(error),
      };
    }
  }
  return { available: true };
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
