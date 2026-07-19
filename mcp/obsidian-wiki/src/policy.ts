export type WritePolicy = 'direct' | 'confirm' | 'deny';

const POLICY_RANK: Record<WritePolicy, number> = {
  direct: 0,
  confirm: 1,
  deny: 2,
};

export function normalizeWritePolicy(value: string | undefined, field: string): WritePolicy {
  switch (value) {
    case undefined:
    case 'direct':
    case 'allow':
      return 'direct';
    case 'confirm':
    case 'ask':
      return 'confirm';
    case 'deny':
    case 'refuse':
      return 'deny';
    default:
      throw new Error(`${field} must be direct, confirm, or deny`);
  }
}

export function stricterPolicy(...policies: WritePolicy[]): WritePolicy {
  return policies.reduce((strictest, candidate) => (
    POLICY_RANK[candidate] > POLICY_RANK[strictest] ? candidate : strictest
  ));
}
