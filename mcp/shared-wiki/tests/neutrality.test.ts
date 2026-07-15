import { describe, expect, it } from 'vitest';
import { neutralityErrors } from '../src/wiki/neutrality.js';
import { defaultPolicy } from '../src/wiki/policy.js';

describe('neutralityErrors', () => {
  it('blocks configured terms', () => {
    const errors = neutralityErrors({ ...defaultPolicy(), blockedTerms: ['internal-system'] }, [
      { label: 'page', text: 'Do not mention internal-system here.' },
    ]);
    expect(errors[0]).toMatch(/blocked shared-wiki term/);
  });

  it('blocks configured patterns', () => {
    const errors = neutralityErrors({ ...defaultPolicy(), blockedPatterns: ['prod-[a-z]+'] }, [
      { label: 'page', text: 'prod-east should not appear.' },
    ]);
    expect(errors[0]).toMatch(/blocked shared-wiki pattern/);
  });
});
