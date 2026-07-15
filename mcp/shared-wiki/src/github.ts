import type { SharedWikiConfig } from './config.js';
import { spawnFile } from './process.js';

export async function createPullRequest(config: SharedWikiConfig, input: { title: string; body: string; base: string; head: string; draft?: boolean }): Promise<string> {
  const args = [
    'pr', 'create',
    '--repo', config.repoUrl,
    '--base', input.base,
    '--head', input.head,
    '--title', input.title,
    '--body', input.body,
  ];
  if (input.draft ?? config.draftPr) {
    args.push('--draft');
  }
  const output = await spawnFile('gh', args, { cwd: config.cloneDir });
  return output.stdout.trim().split('\n').at(-1) ?? output.stdout.trim();
}

export async function ghAuthStatus(config: SharedWikiConfig): Promise<string> {
  const output = await spawnFile('gh', ['auth', 'status'], { cwd: config.cloneDir });
  return output.stderr.trim() || output.stdout.trim();
}
