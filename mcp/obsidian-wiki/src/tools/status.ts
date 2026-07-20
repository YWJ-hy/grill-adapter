import path from 'node:path';
import { resolveBindings } from '../bindings.js';

export function statusTool(env: NodeJS.ProcessEnv = process.env) {
  const projectDir = path.resolve(env.CLAUDE_PROJECT_DIR ?? process.cwd());
  try {
    const resolution = resolveBindings(env);
    return {
      healthy: resolution.errors.length === 0,
      provider: 'obsidian',
      projectDir: resolution.projectDir,
      registryPath: resolution.registryPath,
      bindings: resolution.bindings.map((binding) => ({
        sourceId: binding.sourceId,
        role: binding.role,
        vaultRef: binding.vaultRef,
        vaultSelector: binding.vaultSelector,
        repositoryRef: binding.repositoryRef,
        vaultHealth: binding.vaultHealth,
        repositoryHealth: binding.repositoryHealth,
        root: binding.root,
        publishingMode: binding.publishingMode,
        effectiveReadPolicy: binding.effectiveReadPolicy,
        effectiveUpdatePolicy: binding.effectiveUpdatePolicy,
        effectiveCreatePolicy: binding.effectiveCreatePolicy,
        bindingDigest: binding.bindingDigest,
        manifest: binding.manifest,
      })),
      errors: resolution.errors,
      warnings: resolution.warnings,
    };
  } catch (error) {
    return {
      healthy: false,
      provider: 'obsidian',
      projectDir,
      bindings: [],
      errors: [error instanceof Error ? error.message : String(error)],
      warnings: [],
    };
  }
}
