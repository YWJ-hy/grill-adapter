import type { ResolvedBinding } from './bindings.js';
import { resolveSecretEnvironment } from './config.js';

type BridgeRoute = 'validate' | 'apply';

export type BridgeChangeRequest = {
  requestId: string;
  vaultSelector: string;
  projectDir: string;
  sourceId: string;
  vaultRef: string;
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

function bridgeTimeoutMs(env: NodeJS.ProcessEnv): number {
  const raw = env.OBSIDIAN_WIKI_BRIDGE_TIMEOUT_MS ?? '30000';
  const value = Number(raw);
  if (!Number.isFinite(value) || value <= 0) throw new Error('OBSIDIAN_WIKI_BRIDGE_TIMEOUT_MS must be a positive number');
  return value;
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
  const token = resolveSecretEnvironment(binding.bridgeTokenEnv, env);
  if (!token) {
    throw new Error(
      `Obsidian Wiki write bridge token is unavailable: ${binding.bridgeTokenEnv}. ` +
      `Set it in this process or recover it on macOS with ` +
      `export ${binding.bridgeTokenEnv}="$(launchctl getenv ${binding.bridgeTokenEnv})"`,
    );
  }
  const attempts = route === 'validate' ? 2 : 1;
  let response: Response | undefined;
  let lastError: unknown;
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), bridgeTimeoutMs(env));
    try {
      response = await fetch(new URL(`/v1/notes/${route}`, binding.bridgeUrl), {
        method: 'POST',
        redirect: 'manual',
        signal: controller.signal,
        headers: {
          authorization: `Bearer ${token}`,
          'content-type': 'application/json',
          accept: 'application/json',
          'x-grill-adapter-request-id': request.requestId,
        },
        body: JSON.stringify(request),
      });
      clearTimeout(timer);
      break;
    } catch (error) {
      clearTimeout(timer);
      lastError = error;
      if (attempt + 1 === attempts) {
        const detail = error instanceof DOMException && error.name === 'AbortError'
          ? `timed out after ${bridgeTimeoutMs(env)}ms`
          : error instanceof Error ? error.message : String(error);
        throw new Error(`Obsidian Wiki write bridge request ${request.requestId} failed: ${detail}`);
      }
    }
  }
  if (!response) throw new Error(`Obsidian Wiki write bridge request ${request.requestId} failed: ${String(lastError)}`);
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
