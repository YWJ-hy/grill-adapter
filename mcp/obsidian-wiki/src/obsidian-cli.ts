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
    })).trim();
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
  const value = parseJson(runCli([`vault=${vaultSelector}`, 'search', query, 'format=json'], env), 'search');
  if (!Array.isArray(value)) throw new Error('Obsidian CLI search JSON must be an array');
  return value.map((entry, index) => {
    if (!entry || typeof entry !== 'object' || typeof (entry as Record<string, unknown>).path !== 'string') {
      throw new Error(`Obsidian CLI search result ${index + 1} is missing path`);
    }
    return { path: (entry as Record<string, string>).path };
  });
}

export function readNote(vaultSelector: string, notePath: string, env: NodeJS.ProcessEnv): ObsidianReadResult {
  const value = parseJson(runCli([`vault=${vaultSelector}`, 'read', notePath, 'format=json'], env), 'read');
  if (!value || typeof value !== 'object') throw new Error('Obsidian CLI read JSON must be an object');
  const record = value as Record<string, unknown>;
  if (typeof record.path !== 'string' || typeof record.content !== 'string') {
    throw new Error('Obsidian CLI read JSON must contain path and content strings');
  }
  return { path: record.path, content: record.content };
}
