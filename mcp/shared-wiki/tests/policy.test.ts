import { describe, expect, it } from 'vitest';
import { defaultPolicy, enforceAuthorization } from '../src/wiki/policy.js';

describe('enforceAuthorization', () => {
  it('requires create authorization by default', () => {
    const errors = enforceAuthorization(defaultPolicy(), [{ status: 'A', path: 'new.md' }], {});
    expect(errors).toContain('createNewDocument requires explicit authorization.');
  });

  it('allows default updates without authorization', () => {
    const errors = enforceAuthorization(defaultPolicy(), [{ status: 'M', path: 'index.md' }], {});
    expect(errors).toEqual([]);
  });

  it('does not bypass refuse', () => {
    const policy = { ...defaultPolicy(), createNewDocument: 'refuse' as const };
    const errors = enforceAuthorization(policy, [{ status: 'A', path: 'new.md' }], { authorizedCreate: true });
    expect(errors).toContain('createNewDocument is refused by shared wiki policy.');
  });
});
