import { describe, expect, it } from 'vitest';
import { rejectUnsafePatchText } from '../src/patch.js';

describe('rejectUnsafePatchText', () => {
  it('rejects binary patches', () => {
    expect(rejectUnsafePatchText('GIT binary patch\n')).toContain('Binary patches are not allowed.');
  });

  it('rejects symlink patches', () => {
    expect(rejectUnsafePatchText('new file mode 120000\n')).toContain('Symlink writes are not allowed.');
  });

  it('rejects deleted files', () => {
    expect(rejectUnsafePatchText('deleted file mode 100644\n')).toContain('Deleting shared wiki files is not allowed.');
  });
});
