import { execFileSync } from 'node:child_process';

export type ObsidianSearchResult = {
  path: string;
};

export type ObsidianReadResult = {
  path: string;
  content: string;
};

function runCli(args: string[], env: NodeJS.ProcessEnv): string {
  const executable = env.OBSIDIAN_WIKI_OBSIDIAN_CLI || 'obsidian';
  try {
    return String(execFileSync(executable, args, {
      encoding: 'utf8',
      env: { ...process.env, ...env },
      stdio: ['ignore', 'pipe', 'pipe'],
    }));
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    throw new Error(`Obsidian CLI ${args.join(' ')} failed: ${message}`);
  }
}

function parseJson(value: string, operation: string): unknown {
  try {
    return JSON.parse(value);
  } catch (error) {
    throw new Error(`Obsidian CLI ${operation} did not return JSON: ${error instanceof Error ? error.message : String(error)}`);
  }
}

export function searchNotes(vaultSelector: string, query: string, env: NodeJS.ProcessEnv): ObsidianSearchResult[] {
  const value = parseJson(runCli([`vault=${vaultSelector}`, 'search', `query=${query}`, 'format=json'], env), 'search');
  if (!Array.isArray(value)) throw new Error('Obsidian CLI search JSON must be an array');
  return value.map((entry, index) => {
    if (typeof entry !== 'string' || !entry) {
      throw new Error(`Obsidian CLI search result ${index + 1} must be a non-empty path string`);
    }
    return { path: entry };
  });
}

export function readNote(vaultSelector: string, notePath: string, env: NodeJS.ProcessEnv): ObsidianReadResult {
  return {
    path: notePath,
    content: runCli([`vault=${vaultSelector}`, 'read', `path=${notePath}`], env),
  };
}
