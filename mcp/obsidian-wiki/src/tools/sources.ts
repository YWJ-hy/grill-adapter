import { resolveBindings } from '../bindings.js';

export function sourcesTool(env: NodeJS.ProcessEnv = process.env) {
  const resolution = resolveBindings(env);
  if (resolution.errors.length > 0) {
    throw new Error(`Obsidian Wiki Source bindings are unhealthy: ${resolution.errors.join('; ')}`);
  }
  return {
    sources: resolution.bindings.filter((binding) => binding.effectiveReadPolicy === 'allow').map((binding) => ({
      sourceId: binding.sourceId,
      role: binding.role,
      vaultRef: binding.vaultRef,
      repositoryRef: binding.repositoryRef,
      root: binding.root,
      publishingMode: binding.publishingMode,
      effectiveReadPolicy: binding.effectiveReadPolicy,
      effectiveUpdatePolicy: binding.effectiveUpdatePolicy,
      effectiveCreatePolicy: binding.effectiveCreatePolicy,
      writeBridgeConfigured: binding.vaultHealth.writeBridgeConfigured,
      bindingDigest: binding.bindingDigest,
      scope: binding.manifest.scope,
    })),
  };
}
