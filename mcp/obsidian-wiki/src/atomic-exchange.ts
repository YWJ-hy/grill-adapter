import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const scriptPath = fileURLToPath(new URL('../scripts/atomic_swap.py', import.meta.url));

export function atomicExchange(firstPath: string, secondPath: string, env: NodeJS.ProcessEnv = process.env): void {
  const python = env.OBSIDIAN_WIKI_PYTHON ?? 'python3';
  try {
    execFileSync(python, [scriptPath, firstPath, secondPath], {
      encoding: 'utf8',
      env: { ...process.env, ...env },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
  } catch (error) {
    throw new Error(`Atomic Note exchange failed: ${error instanceof Error ? error.message : String(error)}`);
  }
}
