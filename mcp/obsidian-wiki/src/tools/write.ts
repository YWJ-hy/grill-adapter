import type { ResolvedBinding } from '../bindings.js';
import { resolveBindings } from '../bindings.js';
import { parseAtomicNote } from '../note.js';
import { assertPathWithinBinding, readBoundNote, searchBoundNotes } from '../retrieval.js';
import { callWriteBridge, type BridgeChangeRequest } from '../write-client.js';
import { linkPath } from './graph.js';

export type NoteChangeInput = {
  sourceId: string;
  operation: 'create' | 'update';
  path: string;
  content: string;
  expectedHash: string | null;
  authorized?: boolean;
};

function healthyBindings(env: NodeJS.ProcessEnv): ResolvedBinding[] {
  const resolution = resolveBindings(env);
  if (resolution.errors.length > 0) {
    throw new Error(`Obsidian Wiki Source bindings are unhealthy: ${resolution.errors.join('; ')}`);
  }
  return resolution.bindings;
}

function selectedBinding(input: NoteChangeInput, bindings: ResolvedBinding[]): ResolvedBinding {
  const binding = bindings.find((candidate) => candidate.sourceId === input.sourceId);
  if (!binding) throw new Error(`Obsidian Wiki Source is not bound to this project: ${input.sourceId}`);
  if (binding.effectiveReadPolicy !== 'allow') {
    throw new Error(`Obsidian Wiki Source is not readable and cannot be written safely: ${input.sourceId}`);
  }
  return binding;
}

function enforceNeutrality(binding: ResolvedBinding, notePath: string, content: string): void {
  if (binding.role !== 'shared') return;
  const candidate = `${notePath}\n${content}`;
  const violations: string[] = [];
  for (const term of binding.manifest.blockedTerms) {
    if (term && candidate.includes(term)) violations.push(`blocked term ${JSON.stringify(term)}`);
  }
  for (const source of binding.manifest.blockedPatterns) {
    try {
      if (source && new RegExp(source).test(candidate)) violations.push(`blocked pattern ${JSON.stringify(source)}`);
    } catch (error) {
      throw new Error(`Shared Source manifest has an invalid neutrality pattern ${JSON.stringify(source)}: ${error instanceof Error ? error.message : String(error)}`);
    }
  }
  if (violations.length) throw new Error(`Shared Source neutrality validation failed: ${violations.join('; ')}`);
}

function validateTypedLinks(note: ReturnType<typeof parseAtomicNote>, bindings: ResolvedBinding[], env: NodeJS.ProcessEnv): void {
  for (const links of Object.values(note.edges)) {
    for (const link of links) {
      try {
        readBoundNote(linkPath(link), bindings, env, false);
      } catch (error) {
        throw new Error(`Proposed Note typed edge ${link} is invalid: ${error instanceof Error ? error.message : String(error)}`);
      }
    }
  }
}

function validateIdentity(
  input: NoteChangeInput,
  binding: ResolvedBinding,
  bindings: ResolvedBinding[],
  env: NodeJS.ProcessEnv,
  proposed: ReturnType<typeof parseAtomicNote>,
): void {
  const matches = searchBoundNotes(`[wiki_id:${proposed.wikiId}]`, bindings, env, false)
    .filter((note) => note.wikiId === proposed.wikiId);
  if (input.operation === 'create') {
    if (input.expectedHash !== null) throw new Error('Creating an Obsidian Note requires expectedHash: null');
    if (matches.length > 0) throw new Error(`Proposed wiki_id already exists in a bound Source: ${proposed.wikiId}`);
    return;
  }
  if (!input.expectedHash) throw new Error('Updating an Obsidian Note requires expectedHash');
  const existing = readBoundNote(input.path, [binding], env, false);
  if (existing.wikiId !== proposed.wikiId) {
    throw new Error(`Proposed Note wiki_id must preserve existing identity ${existing.wikiId}`);
  }
  if (existing.contentHash !== input.expectedHash) {
    throw new Error(`Expected hash conflict for ${input.path}: the Note changed before proposal validation`);
  }
  if (matches.length !== 1 || matches[0].path !== existing.path || matches[0].sourceId !== existing.sourceId) {
    throw new Error(`Existing wiki_id does not resolve uniquely to the updated Note: ${proposed.wikiId}`);
  }
}

type PreparedChange = {
  binding: ResolvedBinding;
  policy: 'direct' | 'confirm' | 'deny';
  request: BridgeChangeRequest;
};

function prepareChange(input: NoteChangeInput, env: NodeJS.ProcessEnv): PreparedChange {
  const bindings = healthyBindings(env);
  const binding = selectedBinding(input, bindings);
  const notePath = assertPathWithinBinding(input.path, binding);
  const proposed = parseAtomicNote(input.content, notePath);
  validateIdentity(input, binding, bindings, env, proposed);
  validateTypedLinks(proposed, bindings, env);
  enforceNeutrality(binding, notePath, proposed.content);
  const policy = input.operation === 'create' ? binding.effectiveCreatePolicy : binding.effectiveUpdatePolicy;
  return {
    binding,
    policy,
    request: {
      vaultSelector: binding.vaultSelector,
      sourceId: binding.sourceId,
      sourceRoot: binding.root,
      operation: input.operation,
      path: notePath,
      content: proposed.content,
      expectedHash: input.expectedHash,
      expectedWikiId: proposed.wikiId,
      authorized: input.authorized === true,
    },
  };
}

function decorate(result: Record<string, unknown>, prepared: PreparedChange) {
  if (!result.diff || typeof result.diff !== 'object' || Array.isArray(result.diff)) {
    throw new Error('Obsidian Wiki write bridge response is missing its structured diff');
  }
  return {
    ...result,
    diff: result.diff as {
      beforeHash: string | null;
      afterHash: string;
      beforeContent: string | null;
      afterContent: string;
    },
    postWrite: result.postWrite as { wikiId: string; path: string; contentHash: string } | undefined,
    sourceId: prepared.binding.sourceId,
    repositoryRef: prepared.binding.repositoryRef,
    bindingDigest: prepared.binding.bindingDigest,
    policy: prepared.policy,
    authorizationRequired: prepared.policy === 'confirm',
  };
}

export async function proposeNoteChangeTool(input: NoteChangeInput, env: NodeJS.ProcessEnv = process.env) {
  const prepared = prepareChange(input, env);
  if (prepared.policy === 'deny') throw new Error(`Obsidian Wiki Source policy denies ${input.operation} operations`);
  return decorate(await callWriteBridge(prepared.binding, 'validate', prepared.request, env), prepared);
}

export async function applyNoteChangeTool(input: NoteChangeInput, env: NodeJS.ProcessEnv = process.env) {
  const prepared = prepareChange(input, env);
  if (prepared.policy === 'deny') throw new Error(`Obsidian Wiki Source policy denies ${input.operation} operations`);
  if (prepared.policy === 'confirm' && input.authorized !== true) {
    throw new Error(`Obsidian Wiki Source policy requires explicit authorization for ${input.operation}`);
  }
  return decorate(await callWriteBridge(prepared.binding, 'apply', prepared.request, env), prepared);
}
