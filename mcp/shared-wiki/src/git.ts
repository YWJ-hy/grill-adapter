import { mkdir } from 'node:fs/promises';
import { spawnFile } from './process.js';
import type { SharedWikiConfig } from './config.js';

export type GitRevision = {
  ref: string;
  commitSha: string;
  shortSha: string;
};

export async function ensureClone(config: SharedWikiConfig): Promise<void> {
  await mkdir(config.cacheDir, { recursive: true });
  const exists = await gitDirExists(config.cloneDir);
  if (!exists) {
    await spawnFile('git', ['clone', config.repoUrl, config.cloneDir]);
  }
  await spawnFile('git', ['remote', 'set-url', config.remote, config.repoUrl], { cwd: config.cloneDir });
}

async function gitDirExists(cwd: string): Promise<boolean> {
  try {
    await spawnFile('git', ['rev-parse', '--git-dir'], { cwd });
    return true;
  } catch {
    return false;
  }
}

export async function fetchBase(config: SharedWikiConfig): Promise<void> {
  await spawnFile('git', ['fetch', config.remote, config.baseBranch], { cwd: config.cloneDir });
}

export async function ensureClean(config: SharedWikiConfig): Promise<void> {
  const status = await spawnFile('git', ['status', '--porcelain'], { cwd: config.cloneDir });
  if (status.stdout.trim()) {
    throw new Error(`Shared wiki cache has uncommitted changes:\n${status.stdout}`);
  }
}

export async function checkoutBase(config: SharedWikiConfig): Promise<void> {
  await spawnFile('git', ['checkout', '-B', config.baseBranch, `${config.remote}/${config.baseBranch}`], { cwd: config.cloneDir });
}

export async function resetBase(config: SharedWikiConfig): Promise<void> {
  await spawnFile('git', ['reset', '--hard', `${config.remote}/${config.baseBranch}`], { cwd: config.cloneDir });
}

export async function prepareBase(config: SharedWikiConfig): Promise<void> {
  await ensureClone(config);
  await ensureClean(config);
  await fetchBase(config);
  await checkoutBase(config);
  await resetBase(config);
  await ensureClean(config);
}

export async function remoteBaseRevision(config: SharedWikiConfig): Promise<GitRevision> {
  const ref = `${config.remote}/${config.baseBranch}`;
  const output = await spawnFile('git', ['rev-parse', ref], { cwd: config.cloneDir });
  const commitSha = output.stdout.trim();
  return { ref, commitSha, shortSha: commitSha.slice(0, 12) };
}

export async function currentHeadRevision(config: SharedWikiConfig): Promise<GitRevision> {
  const ref = 'HEAD';
  const output = await spawnFile('git', ['rev-parse', ref], { cwd: config.cloneDir });
  const commitSha = output.stdout.trim();
  return { ref, commitSha, shortSha: commitSha.slice(0, 12) };
}

export async function createBranch(config: SharedWikiConfig, branchName: string): Promise<void> {
  await spawnFile('git', ['checkout', '-B', branchName, `${config.remote}/${config.baseBranch}`], { cwd: config.cloneDir });
}

export async function applyPatch(config: SharedWikiConfig, patch: string): Promise<void> {
  await spawnFile('git', ['apply', '--whitespace=nowarn', '-'], { cwd: config.cloneDir, input: patch });
}

export async function changedFiles(config: SharedWikiConfig): Promise<string[]> {
  const output = await spawnFile('git', ['diff', '--name-only'], { cwd: config.cloneDir });
  return output.stdout.split('\n').map((line) => line.trim()).filter(Boolean);
}

export async function diffNameStatus(config: SharedWikiConfig): Promise<Array<{ status: string; path: string }>> {
  const output = await spawnFile('git', ['diff', '--name-status'], { cwd: config.cloneDir });
  return output.stdout.split('\n').filter(Boolean).map((line) => {
    const [status, ...rest] = line.split('\t');
    return { status, path: rest[rest.length - 1] ?? '' };
  });
}

export async function commitAll(config: SharedWikiConfig, message: string): Promise<string> {
  await spawnFile('git', ['add', '--all'], { cwd: config.cloneDir });
  await spawnFile('git', ['commit', '-m', message], { cwd: config.cloneDir });
  const output = await spawnFile('git', ['rev-parse', 'HEAD'], { cwd: config.cloneDir });
  return output.stdout.trim();
}

export async function pushBranch(config: SharedWikiConfig, branchName: string): Promise<void> {
  await spawnFile('git', ['push', '-u', config.remote, branchName], { cwd: config.cloneDir });
}

export async function toolAvailable(name: string): Promise<boolean> {
  try {
    await spawnFile(name, ['--version']);
    return true;
  } catch {
    return false;
  }
}
