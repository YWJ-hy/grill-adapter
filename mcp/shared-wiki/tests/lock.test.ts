import { existsSync, mkdtempSync } from 'node:fs';
import { mkdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import type { SharedWikiConfig } from '../src/config.js';
import { withCloneLock } from '../src/lock.js';

const createdDirs: string[] = [];

function makeConfig(): SharedWikiConfig {
  const cacheDir = mkdtempSync(path.join(tmpdir(), 'swm-lock-'));
  createdDirs.push(cacheDir);
  // withCloneLock only consults cloneDir + cacheDir; the rest is irrelevant here.
  return { cacheDir, cloneDir: path.join(cacheDir, 'repo-test') } as unknown as SharedWikiConfig;
}

const delay = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

afterEach(async () => {
  while (createdDirs.length > 0) {
    const dir = createdDirs.pop();
    if (dir) await rm(dir, { recursive: true, force: true });
  }
});

describe('withCloneLock', () => {
  it('serializes concurrent critical sections on the same clone', async () => {
    const config = makeConfig();
    const order: string[] = [];
    const section = (tag: string) =>
      withCloneLock(config, async () => {
        order.push(`${tag}:start`);
        await delay(40);
        order.push(`${tag}:end`);
      }, { retryMs: 5 });

    await Promise.all([section('A'), section('B')]);

    // No interleaving: whoever starts first fully finishes before the other starts.
    expect(order).toHaveLength(4);
    const first = order[0].split(':')[0];
    expect(order[0]).toBe(`${first}:start`);
    expect(order[1]).toBe(`${first}:end`);
    const second = order[2].split(':')[0];
    expect(second).not.toBe(first);
    expect(order[2]).toBe(`${second}:start`);
    expect(order[3]).toBe(`${second}:end`);
  });

  it('releases the lock file after the section completes', async () => {
    const config = makeConfig();
    const lockPath = `${config.cloneDir}.lock`;
    await withCloneLock(config, async () => {
      expect(existsSync(lockPath)).toBe(true);
    });
    expect(existsSync(lockPath)).toBe(false);
  });

  it('breaks a stale lock left by a dead holder', async () => {
    const config = makeConfig();
    const lockPath = `${config.cloneDir}.lock`;
    await mkdir(config.cacheDir, { recursive: true });
    await writeFile(lockPath, '999999', 'utf8'); // PID that is essentially never alive

    let ran = false;
    await withCloneLock(config, async () => { ran = true; }, { timeoutMs: 1000, retryMs: 5 });
    expect(ran).toBe(true);
    expect(existsSync(lockPath)).toBe(false);
  });

  it('times out when a live holder keeps the lock', async () => {
    const config = makeConfig();
    const lockPath = `${config.cloneDir}.lock`;
    await mkdir(config.cacheDir, { recursive: true });
    await writeFile(lockPath, String(process.pid), 'utf8'); // current process is alive

    await expect(
      withCloneLock(config, async () => { /* never reached */ }, { timeoutMs: 150, retryMs: 20 }),
    ).rejects.toThrow(/busy/i);

    await rm(lockPath, { force: true });
  });
});
