import { createHash } from 'node:crypto';
import * as z from 'zod/v4';

const SkillNameSchema = z.string().regex(/^[a-z0-9][a-z0-9-]*$/);
const SkillVersionSchema = z.string().regex(
  /^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-(?:0|[1-9][0-9]*|[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9][0-9]*|[A-Za-z-][0-9A-Za-z-]*))*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$/,
);
const uniqueList = <T>(values: T[]) => new Set(values).size === values.length;

const NoteSchema = z.object({
  wiki_schema: z.literal('grill-adapter.obsidian-note/v1'),
  wiki_id: z.string().min(1),
  type: z.enum(['constraint', 'domain', 'decision', 'guide']),
  status: z.enum(['active', 'draft', 'archived']),
  agent_visible: z.boolean().optional(),
  summary: z.string().min(1),
  constraint_strength: z.enum(['hard', 'soft']).optional(),
  depends_on: z.array(z.string()).optional(),
  see_also: z.array(z.string()).optional(),
  supersedes: z.array(z.string()).optional(),
  contradicts: z.array(z.string()).optional(),
  skill_roles: z.array(z.enum(['implementer', 'reviewer']))
    .min(1)
    .refine(uniqueList, 'Skill Card roles must be unique')
    .optional(),
  skill_provider: z.literal('claude-code-project').optional(),
  skill_name: SkillNameSchema.optional(),
  skill_version: SkillVersionSchema.optional(),
  skill_contract_hash: z.string().regex(/^sha256:[a-f0-9]{64}$/).optional(),
  skill_triggers: z.array(z.string().min(1))
    .min(1)
    .refine(uniqueList, 'Skill Card triggers must be unique')
    .optional(),
});

export type AtomicNote = {
  wikiId: string;
  type: 'constraint' | 'domain' | 'decision' | 'guide';
  status: 'active' | 'draft' | 'archived';
  agentVisible: boolean;
  summary: string;
  constraintStrength: 'hard' | 'soft' | undefined;
  skillRoles: ('implementer' | 'reviewer')[];
  skillProvider: 'claude-code-project' | undefined;
  skillName: string | undefined;
  skillVersion: string | undefined;
  skillContractHash: string | undefined;
  skillTriggers: string[];
  edges: Record<'dependsOn' | 'seeAlso' | 'supersedes' | 'contradicts', string[]>;
  content: string;
  contentHash: string;
};

function parseScalar(raw: string): string | boolean {
  const value = raw.trim();
  if (value === 'true') return true;
  if (value === 'false') return false;
  return value.replace(/^['"]|['"]$/g, '');
}

function parseStringList(lines: string[], start: number): { values: string[]; end: number } {
  const values: string[] = [];
  let index = start;
  while (index < lines.length && /^\s+-\s+/.test(lines[index])) {
    values.push(String(parseScalar(lines[index].replace(/^\s+-\s+/, ''))));
    index += 1;
  }
  return { values, end: index };
}

function parseFrontmatter(contents: string): Record<string, string | boolean | string[]> {
  const normalized = canonicalContent(contents);
  if (!normalized.startsWith('---\n')) throw new Error('Note must start with YAML frontmatter');
  const closing = normalized.indexOf('\n---\n', 4);
  if (closing === -1) throw new Error('Note frontmatter is not terminated');
  const values: Record<string, string | boolean | string[]> = {};
  const lines = normalized.slice(4, closing).split('\n');
  for (let index = 0; index < lines.length; index += 1) {
    const match = /^([a-z_]+):\s*(.*)$/.exec(lines[index]);
    if (!match) throw new Error(`Note has unsupported frontmatter syntax on line ${index + 2}`);
    const [, key, raw] = match;
    if (raw === '') {
      const list = parseStringList(lines, index + 1);
      values[key] = list.values;
      index = list.end - 1;
    } else {
      values[key] = parseScalar(raw);
    }
  }
  return values;
}

export function canonicalContent(contents: string): string {
  return contents.replaceAll('\r\n', '\n');
}

export function contentHash(contents: string): string {
  return `sha256:${createHash('sha256').update(canonicalContent(contents), 'utf8').digest('hex')}`;
}

export function parseAtomicNote(contents: string, description = 'Note'): AtomicNote {
  const raw = parseFrontmatter(contents);
  const parsed = NoteSchema.safeParse(raw);
  if (!parsed.success) {
    throw new Error(`${description} has invalid atomic Note properties: ${parsed.error.issues.map((issue) => issue.message).join('; ')}`);
  }
  const note = parsed.data;
  const skillFields = [
    note.skill_provider,
    note.skill_name,
    note.skill_version,
    note.skill_contract_hash,
    note.skill_roles,
    note.skill_triggers,
  ];
  const isSkillCard = skillFields.some((value) => value !== undefined);
  if (isSkillCard && skillFields.some((value) => value === undefined)) {
    throw new Error(`${description} has incomplete Skill Card properties`);
  }
  if (isSkillCard && note.type !== 'guide') {
    throw new Error(`${description} Skill Card type must be guide`);
  }
  return {
    wikiId: note.wiki_id,
    type: note.type,
    status: note.status,
    agentVisible: note.agent_visible ?? true,
    summary: note.summary,
    constraintStrength: note.constraint_strength,
    skillRoles: note.skill_roles ?? [],
    skillProvider: note.skill_provider,
    skillName: note.skill_name,
    skillVersion: note.skill_version,
    skillContractHash: note.skill_contract_hash,
    skillTriggers: note.skill_triggers ?? [],
    edges: {
      dependsOn: note.depends_on ?? [],
      seeAlso: note.see_also ?? [],
      supersedes: note.supersedes ?? [],
      contradicts: note.contradicts ?? [],
    },
    content: canonicalContent(contents),
    contentHash: contentHash(contents),
  };
}
