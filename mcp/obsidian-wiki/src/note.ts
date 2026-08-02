import { createHash } from 'node:crypto';
import * as z from 'zod/v4';

const SkillNameSchema = z.string().regex(/^[a-z0-9][a-z0-9-]*$/);
const SkillVersionSchema = z.string().regex(
  /^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-(?:0|[1-9][0-9]*|[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9][0-9]*|[A-Za-z-][0-9A-Za-z-]*))*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$/,
);
const ContentHashSchema = z.string().regex(/^sha256:[a-f0-9]{64}$/);
const NormalizedTimestampSchema = z.string().refine((value) => {
  if (!/^[0-9]{4}-(?:0[1-9]|1[0-2])-(?:0[1-9]|[12][0-9]|3[01])T(?:[01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]Z$/.test(value)) {
    return false;
  }
  if (value.startsWith('0000-')) return false;
  const parsed = new Date(value);
  return !Number.isNaN(parsed.getTime())
    && parsed.toISOString().replace('.000Z', 'Z') === value;
}, 'must be a normalized UTC timestamp (YYYY-MM-DDTHH:mm:ssZ)');
const AdrSourceIdSchema = z.string().regex(/^project-adr:[a-f0-9]{64}$/);
const AdrSourcePathSchema = z.string().refine((value) => {
  if (value.includes('\\') || value.startsWith('/')) return false;
  const parts = value.split('/');
  const hasAdrRoot = parts.some((part, index) => part === 'docs' && parts[index + 1] === 'adr');
  return parts.length >= 3
    && hasAdrRoot
    && parts.at(-1)?.endsWith('.md') === true
    && parts.every((part) => part !== '' && part !== '.' && part !== '..');
}, 'ADR source path must be a normalized project-relative path under docs/adr');
const uniqueList = <T>(values: T[]) => new Set(values).size === values.length;

const NoteSchema = z.object({
  wiki_schema: z.literal('grill-adapter.obsidian-note/v1'),
  wiki_id: z.string().min(1),
  type: z.enum(['constraint', 'domain', 'decision', 'guide']),
  status: z.enum(['active', 'draft', 'archived']),
  agent_visible: z.boolean().optional(),
  summary: z.string().min(1),
  verified_at: NormalizedTimestampSchema.optional(),
  review_after: NormalizedTimestampSchema.optional(),
  expires_at: NormalizedTimestampSchema.optional(),
  constraint_strength: z.enum(['hard', 'soft']).optional(),
  depends_on: z.array(z.string()).optional(),
  see_also: z.array(z.string()).optional(),
  supersedes: z.array(z.string()).optional(),
  contradicts: z.array(z.string()).optional(),
  adr_source_id: AdrSourceIdSchema.optional(),
  adr_source_path: AdrSourcePathSchema.optional(),
  adr_source_content_hash: ContentHashSchema.optional(),
  skill_roles: z.array(z.enum(['implementer', 'reviewer']))
    .min(1)
    .refine(uniqueList, 'Skill Card roles must be unique')
    .optional(),
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
  verifiedAt: string | undefined;
  reviewAfter: string | undefined;
  expiresAt: string | undefined;
  constraintStrength: 'hard' | 'soft' | undefined;
  skillRoles: ('implementer' | 'reviewer')[];
  skillName: string | undefined;
  skillVersion: string | undefined;
  skillContractHash: string | undefined;
  skillTriggers: string[];
  adrSourceId: string | undefined;
  adrSourcePath: string | undefined;
  adrSourceContentHash: string | undefined;
  edges: Record<'dependsOn' | 'seeAlso' | 'supersedes' | 'contradicts', string[]>;
  content: string;
  contentHash: string;
};

export type AtomicNoteMetadata = Omit<AtomicNote, 'content' | 'contentHash'>;
export type KnowledgeFreshnessState = 'fresh' | 'review-due' | 'expired';

export type KnowledgeFreshness = {
  state: KnowledgeFreshnessState;
  warning?: string;
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

export function parseAtomicNoteMetadata(contents: string, description = 'Note'): AtomicNoteMetadata {
  const raw = parseFrontmatter(contents);
  const parsed = NoteSchema.safeParse(raw);
  if (!parsed.success) {
    throw new Error(
      `${description} has invalid atomic Note properties: ${
        parsed.error.issues
          .map((issue) => `${issue.path.join('.') || 'frontmatter'} ${issue.message}`)
          .join('; ')
      }`,
    );
  }
  const note = parsed.data;
  const skillFields = [
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
  const adrFields = [
    note.adr_source_id,
    note.adr_source_path,
    note.adr_source_content_hash,
  ];
  const isAdrProjection = adrFields.some((value) => value !== undefined);
  if (isAdrProjection && adrFields.some((value) => value === undefined)) {
    throw new Error(`${description} has incomplete ADR execution projection properties`);
  }
  if (
    isAdrProjection
    && (note.type !== 'constraint' || note.constraint_strength !== 'hard')
  ) {
    throw new Error(`${description} ADR execution projection must be a hard constraint`);
  }
  const verifiedAt = note.verified_at === undefined ? undefined : new Date(note.verified_at);
  const reviewAfter = note.review_after === undefined ? undefined : new Date(note.review_after);
  const expiresAt = note.expires_at === undefined ? undefined : new Date(note.expires_at);
  if (verifiedAt && reviewAfter && reviewAfter < verifiedAt) {
    throw new Error(`${description} review_after must not be earlier than verified_at`);
  }
  if (verifiedAt && expiresAt && expiresAt < verifiedAt) {
    throw new Error(`${description} expires_at must not be earlier than verified_at`);
  }
  if (reviewAfter && expiresAt && expiresAt < reviewAfter) {
    throw new Error(`${description} expires_at must not be earlier than review_after`);
  }
  return {
    wikiId: note.wiki_id,
    type: note.type,
    status: note.status,
    agentVisible: note.agent_visible ?? true,
    summary: note.summary,
    verifiedAt: note.verified_at,
    reviewAfter: note.review_after,
    expiresAt: note.expires_at,
    constraintStrength: note.constraint_strength,
    skillRoles: note.skill_roles ?? [],
    skillName: note.skill_name,
    skillVersion: note.skill_version,
    skillContractHash: note.skill_contract_hash,
    skillTriggers: note.skill_triggers ?? [],
    adrSourceId: note.adr_source_id,
    adrSourcePath: note.adr_source_path,
    adrSourceContentHash: note.adr_source_content_hash,
    edges: {
      dependsOn: note.depends_on ?? [],
      seeAlso: note.see_also ?? [],
      supersedes: note.supersedes ?? [],
      contradicts: note.contradicts ?? [],
    },
  };
}

export function evaluateKnowledgeFreshness(
  note: Pick<AtomicNoteMetadata, 'wikiId' | 'verifiedAt' | 'reviewAfter' | 'expiresAt'>,
  now: Date = new Date(),
  description = `Wiki Note ${note.wikiId}`,
): KnowledgeFreshness {
  if (Number.isNaN(now.getTime())) throw new Error('Knowledge freshness clock is invalid');
  const verifiedAt = note.verifiedAt === undefined ? undefined : new Date(note.verifiedAt);
  if (verifiedAt && verifiedAt > now) {
    throw new Error(`${description} verified_at cannot be in the future: ${note.verifiedAt}`);
  }
  const expiresAt = note.expiresAt === undefined ? undefined : new Date(note.expiresAt);
  if (expiresAt && expiresAt <= now) return { state: 'expired' };
  const reviewAfter = note.reviewAfter === undefined ? undefined : new Date(note.reviewAfter);
  if (reviewAfter && reviewAfter <= now) {
    return {
      state: 'review-due',
      warning: `Wiki Note ${note.wikiId} is review-due since ${note.reviewAfter}.`,
    };
  }
  return { state: 'fresh' };
}

export function parseAtomicNote(contents: string, description = 'Note'): AtomicNote {
  return {
    ...parseAtomicNoteMetadata(contents, description),
    content: canonicalContent(contents),
    contentHash: contentHash(contents),
  };
}
