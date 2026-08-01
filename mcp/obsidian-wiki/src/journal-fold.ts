import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import {
  existsSync,
  lstatSync,
  readFileSync,
  readdirSync,
  realpathSync,
} from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import * as z from 'zod/v4';

const packagedScriptPath = fileURLToPath(new URL('../dist/wiki_candidate_journal.py', import.meta.url));
const sourceScriptPath = fileURLToPath(new URL('../../../scripts/wiki_candidate_journal.py', import.meta.url));
const scriptPath = existsSync(packagedScriptPath) ? packagedScriptPath : sourceScriptPath;

const FoldedCandidateSchema = z.object({
  candidateId: z.string().min(1),
  kind: z.string().min(1),
  status: z.enum(['pending', 'deferred', 'kept', 'skipped', 'superseded']),
  correction: z.object({
    affectedWikiIdentity: z.object({
      sourceId: z.string().min(1),
      wikiId: z.string().min(1),
    }).strict(),
  }).passthrough().optional(),
}).passthrough();

const FoldedJournalSchema = z.object({
  featureSlug: z.string().min(1),
  candidates: z.array(FoldedCandidateSchema),
}).passthrough();

export type FoldedCandidate = z.infer<typeof FoldedCandidateSchema>;
export type FoldedJournal = z.infer<typeof FoldedJournalSchema> & {
  journalDigest: string;
};

function lstatIfPresent(targetPath: string): ReturnType<typeof lstatSync> | undefined {
  try {
    return lstatSync(targetPath);
  } catch (error) {
    if (error && typeof error === 'object' && 'code' in error && error.code === 'ENOENT') {
      return undefined;
    }
    throw error;
  }
}

function canonicalJournalPaths(projectDir: string): Array<{ featureSlug: string; journalPath: string }> {
  const contextRoot = path.join(projectDir, '.grill-adapter', 'context');
  const rootStat = lstatIfPresent(contextRoot);
  if (!rootStat) return [];
  if (!rootStat.isDirectory() || rootStat.isSymbolicLink()) {
    throw new Error('Canonical Wiki context root must be a real directory');
  }
  const realProjectDir = realpathSync(projectDir);
  const realContextRoot = realpathSync(contextRoot);
  if (realContextRoot !== path.join(realProjectDir, '.grill-adapter', 'context')) {
    throw new Error('Canonical Wiki context root must remain inside the current project');
  }
  const journals: Array<{ featureSlug: string; journalPath: string }> = [];
  for (const entry of readdirSync(contextRoot, { withFileTypes: true })
    .sort((left, right) => left.name.localeCompare(right.name, 'en'))) {
    if (entry.isSymbolicLink()) {
      throw new Error(`Canonical Wiki feature context ${entry.name} must not be a symbolic link`);
    }
    if (!entry.isDirectory()) continue;
    const journalPath = path.join(contextRoot, entry.name, 'wiki-candidates.jsonl');
    const journalStat = lstatIfPresent(journalPath);
    if (!journalStat) continue;
    if (!journalStat.isFile() || journalStat.isSymbolicLink()) {
      throw new Error(`Canonical Wiki candidate journal for ${entry.name} must be a real file`);
    }
    journals.push({ featureSlug: entry.name, journalPath });
  }
  return journals;
}

function commandErrorDetail(error: unknown): string {
  if (error && typeof error === 'object' && 'stderr' in error) {
    const stderr = (error as { stderr?: Buffer | string }).stderr;
    const text = Buffer.isBuffer(stderr) ? stderr.toString('utf8') : stderr;
    if (typeof text === 'string' && text.trim()) return text.trim();
  }
  return error instanceof Error ? error.message : String(error);
}

export function foldCanonicalFeatureJournals(
  projectDir: string,
  env: NodeJS.ProcessEnv = process.env,
): FoldedJournal[] {
  const python = env.OBSIDIAN_WIKI_PYTHON ?? 'python3';
  return canonicalJournalPaths(projectDir).map(({ featureSlug, journalPath }) => {
    let output: string;
    try {
      output = String(execFileSync(python, [
        scriptPath,
        'fold',
        '--journal',
        journalPath,
        '--feature-slug',
        featureSlug,
      ], {
        encoding: 'utf8',
        env: { ...process.env, ...env },
        stdio: ['ignore', 'pipe', 'pipe'],
      }));
    } catch (error) {
      throw new Error(
        `Canonical Wiki candidate journal for ${featureSlug} is invalid: ${commandErrorDetail(error)}`,
      );
    }
    let parsed: unknown;
    try {
      parsed = JSON.parse(output);
    } catch (error) {
      throw new Error(
        `Canonical Wiki candidate journal for ${featureSlug} returned invalid JSON: ${
          error instanceof Error ? error.message : String(error)
        }`,
      );
    }
    const result = FoldedJournalSchema.safeParse(parsed);
    if (!result.success || result.data.featureSlug !== featureSlug) {
      const detail = result.success
        ? `feature identity ${result.data.featureSlug} does not match`
        : result.error.issues.map((issue) => `${issue.path.join('.')}: ${issue.message}`).join('; ');
      throw new Error(`Canonical Wiki candidate journal for ${featureSlug} has an invalid fold: ${detail}`);
    }
    const journalDigest = `sha256:${createHash('sha256').update(readFileSync(journalPath)).digest('hex')}`;
    return { ...result.data, journalDigest };
  });
}
