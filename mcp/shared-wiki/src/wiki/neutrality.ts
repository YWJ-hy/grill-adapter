import { readFileSync } from 'node:fs';
import type { WikiPolicy } from './policy.js';

export function neutralityErrors(policy: WikiPolicy, checks: Array<{ label: string; text: string }>): string[] {
  const errors: string[] = [];
  for (const check of checks) {
    for (const term of policy.blockedTerms) {
      if (term && check.text.includes(term)) {
        errors.push(`${check.label} contains blocked shared-wiki term: ${term}`);
      }
    }
    for (const pattern of policy.blockedPatterns) {
      if (!pattern) continue;
      const regex = new RegExp(pattern);
      if (regex.test(check.text)) {
        errors.push(`${check.label} matches blocked shared-wiki pattern: ${pattern}`);
      }
    }
  }
  return errors;
}

export function fileNeutralityChecks(files: Array<{ label: string; absolutePath: string }>): Array<{ label: string; text: string }> {
  return files.map((file) => ({ label: file.label, text: readFileSync(file.absolutePath, 'utf8') }));
}
