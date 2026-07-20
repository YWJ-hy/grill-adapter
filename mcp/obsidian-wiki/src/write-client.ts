import type { ResolvedBinding } from './bindings.js';

type BridgeRoute = 'validate' | 'apply';

export type BridgeChangeRequest = {
  vaultSelector: string;
  sourceId: string;
  sourceRoot: string;
  operation: 'create' | 'update';
  path: string;
  content: string;
  expectedHash: string | null;
  expectedWikiId: string;
  authorized: boolean;
};

function responseError(status: number, value: unknown): Error {
  const record = value && typeof value === 'object' ? value as Record<string, unknown> : {};
  const detail = typeof record.error === 'string' ? record.error : `HTTP ${status}`;
  if (status === 401) return new Error(`Obsidian Wiki write bridge authentication failed: ${detail}`);
  if (status === 409) return new Error(`Obsidian Wiki write conflict: ${detail}`);
  return new Error(`Obsidian Wiki write bridge rejected the request: ${detail}`);
}

export async function callWriteBridge(
  binding: ResolvedBinding,
  route: BridgeRoute,
  request: BridgeChangeRequest,
  env: NodeJS.ProcessEnv,
): Promise<Record<string, unknown>> {
  if (!binding.bridgeUrl || !binding.bridgeTokenEnv) {
    throw new Error(`Obsidian Wiki Source ${binding.sourceId} has no configured write bridge`);
  }
  const token = env[binding.bridgeTokenEnv];
  if (!token) throw new Error(`Obsidian Wiki write bridge token environment variable is unavailable: ${binding.bridgeTokenEnv}`);
  const response = await fetch(new URL(`/v1/notes/${route}`, binding.bridgeUrl), {
    method: 'POST',
    redirect: 'manual',
    headers: {
      authorization: `Bearer ${token}`,
      'content-type': 'application/json',
      accept: 'application/json',
    },
    body: JSON.stringify(request),
  });
  let value: unknown;
  try {
    value = await response.json();
  } catch (error) {
    throw new Error(`Obsidian Wiki write bridge returned invalid JSON: ${error instanceof Error ? error.message : String(error)}`);
  }
  if (!response.ok) throw responseError(response.status, value);
  if (!value || typeof value !== 'object' || Array.isArray(value) || (value as Record<string, unknown>).ok !== true) {
    throw new Error('Obsidian Wiki write bridge returned an invalid success response');
  }
  return value as Record<string, unknown>;
}
