import { mkdir, open, readFile, rm, stat } from 'node:fs/promises';
import type { SharedWikiConfig } from './config.js';

// Cross-process advisory lock that serializes git operations against a single shared
// clone. Claude Code spawns one stdio MCP server per session; concurrent sessions that
// target the SAME shared wiki resolve to the same cloneDir (hashed from repoUrl) and would
// otherwise race on prepareBase (checkout -B + reset --hard), validatePatch (apply + reset),
// and createPatchPr (branch/apply/commit/push) — producing index.lock errors, ensureClean
// false-trips, or a read's reset --hard clobbering another session's in-flight PR build.
//
// The lock is per-clone (sibling file next to cloneDir, NOT inside it, so it never disturbs
// `git clone` into an empty dir), so different repos never block each other. Acquire it at the
// TOOL-HANDLER layer and hold it across the whole call (prepareBase + the file reads that
// follow), never inside the shared git helpers — createPatchPr calls validatePatch internally,
// so a function-level lock would self-deadlock.

const ACQUIRE_TIMEOUT_MS = 30_000;
const RETRY_MS = 100;
// Only used to break a lock whose holder PID is unreadable; a live holder is never broken.
const STALE_MS = 10 * 60_000;

export type CloneLockOptions = {
  timeoutMs?: number;
  retryMs?: number;
  staleMs?: number;
};

function lockPathFor(config: SharedWikiConfig): string {
  return `${config.cloneDir}.lock`;
}

function isProcessAlive(pid: number): boolean {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    // Signal 0 probes existence without affecting the process.
    process.kill(pid, 0);
    return true;
  } catch (error) {
    // ESRCH => no such process (dead). EPERM => exists but not ours (alive).
    return (error as NodeJS.ErrnoException).code === 'EPERM';
  }
}

async function lockIsStale(lockPath: string, staleMs: number): Promise<boolean> {
  let pidText: string;
  try {
    pidText = (await readFile(lockPath, 'utf8')).trim();
  } catch {
    // Lock vanished between the failed acquire and this read; let the caller retry.
    return false;
  }
  const pid = Number.parseInt(pidText, 10);
  if (Number.isInteger(pid) && pid > 0) {
    // A dead holder means the lock leaked from a crashed process; break it.
    return !isProcessAlive(pid);
  }
  // PID unreadable: fall back to age so a corrupt lock cannot wedge the cache forever.
  try {
    const info = await stat(lockPath);
    return Date.now() - info.mtimeMs > staleMs;
  } catch {
    return false;
  }
}

export async function withCloneLock<T>(
  config: SharedWikiConfig,
  fn: () => Promise<T>,
  opts: CloneLockOptions = {},
): Promise<T> {
  const timeoutMs = opts.timeoutMs ?? ACQUIRE_TIMEOUT_MS;
  const retryMs = opts.retryMs ?? RETRY_MS;
  const staleMs = opts.staleMs ?? STALE_MS;
  const lockPath = lockPathFor(config);
  // The lock lives in cacheDir; make sure it exists before the first clone ever happens.
  await mkdir(config.cacheDir, { recursive: true });

  const deadline = Date.now() + timeoutMs;
  for (;;) {
    try {
      const handle = await open(lockPath, 'wx'); // atomic create-exclusive
      try {
        await handle.write(String(process.pid));
      } finally {
        await handle.close();
      }
      break;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== 'EEXIST') throw error;
      if (Date.now() > deadline) {
        throw new Error('Shared wiki cache is busy: another session holds the clone lock. Retry shortly.');
      }
      if (await lockIsStale(lockPath, staleMs)) {
        await rm(lockPath, { force: true });
      } else {
        await new Promise((resolve) => setTimeout(resolve, retryMs));
      }
    }
  }

  try {
    return await fn();
  } finally {
    await rm(lockPath, { force: true });
  }
}
