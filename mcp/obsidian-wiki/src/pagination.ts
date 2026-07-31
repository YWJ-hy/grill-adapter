import { createHash } from 'node:crypto';

export const MAX_PAGE_LIMIT = 50;

type CursorPayload = {
  version: 1;
  kind: string;
  scope: string;
  after: string;
  checksum: string;
};

export type PageMetadata = {
  limit: number;
  scannedCount: number;
  returnedCount: number;
  truncated: boolean;
  nextCursor?: string;
};

export function boundedPageLimit(value: unknown, defaultValue: number): number {
  if (value === undefined) return defaultValue;
  if (!Number.isInteger(value) || (value as number) < 1 || (value as number) > MAX_PAGE_LIMIT) {
    throw new Error(`limit must be an integer between 1 and ${MAX_PAGE_LIMIT}`);
  }
  return value as number;
}

export function cursorScope(kind: string, values: unknown[]): string {
  const canonical = JSON.stringify([kind, ...values]);
  return `sha256:${createHash('sha256').update(canonical, 'utf8').digest('hex')}`;
}

function cursorChecksum(kind: string, scope: string, after: string): string {
  return createHash('sha256')
    .update(JSON.stringify([kind, scope, after]), 'utf8')
    .digest('hex');
}

function encodeCursor(payload: Omit<CursorPayload, 'checksum'>): string {
  return Buffer.from(JSON.stringify({
    ...payload,
    checksum: cursorChecksum(payload.kind, payload.scope, payload.after),
  }), 'utf8').toString('base64url');
}

function decodeCursor(cursor: string, kind: string, scope: string): string {
  if (
    typeof cursor !== 'string'
    || cursor.length === 0
    || cursor.length > 4096
    || !/^[A-Za-z0-9_-]+$/.test(cursor)
  ) {
    throw new Error('continuation cursor is malformed');
  }
  let decoded: string;
  try {
    const bytes = Buffer.from(cursor, 'base64url');
    if (bytes.toString('base64url') !== cursor) throw new Error('non-canonical cursor');
    decoded = bytes.toString('utf8');
  } catch {
    throw new Error('continuation cursor is malformed');
  }
  let payload: unknown;
  try {
    payload = JSON.parse(decoded);
  } catch {
    throw new Error('continuation cursor is malformed');
  }
  if (
    !payload
    || typeof payload !== 'object'
    || Array.isArray(payload)
    || (payload as Partial<CursorPayload>).version !== 1
    || (payload as Partial<CursorPayload>).kind !== kind
    || typeof (payload as Partial<CursorPayload>).scope !== 'string'
    || typeof (payload as Partial<CursorPayload>).after !== 'string'
    || typeof (payload as Partial<CursorPayload>).checksum !== 'string'
  ) {
    throw new Error('continuation cursor is malformed');
  }
  const parsed = payload as CursorPayload;
  if (parsed.checksum !== cursorChecksum(parsed.kind, parsed.scope, parsed.after)) {
    throw new Error('continuation cursor is malformed');
  }
  if (parsed.scope !== scope) {
    throw new Error('continuation cursor does not match the requested scope');
  }
  return parsed.after;
}

export function pageByKey<T>(
  items: T[],
  key: (item: T) => string,
  options: {
    kind: string;
    scope: string;
    limit: number;
    cursor?: string;
    offset?: number;
  },
): { items: T[]; start: number; page: Omit<PageMetadata, 'returnedCount'> } {
  if (options.cursor !== undefined && options.offset !== undefined) {
    throw new Error('continuation cursor and offset cannot be used together');
  }
  let start = options.offset ?? 0;
  if (options.cursor !== undefined) {
    const after = decodeCursor(options.cursor, options.kind, options.scope);
    start = items.findIndex((item) => key(item) > after);
    if (start === -1) start = items.length;
  }
  const pageItems = items.slice(start, start + options.limit);
  const nextIndex = start + pageItems.length;
  const truncated = nextIndex < items.length;
  const nextCursor = truncated && pageItems.length > 0
    ? encodeCursor({
      version: 1,
      kind: options.kind,
      scope: options.scope,
      after: key(pageItems.at(-1)!),
    })
    : undefined;
  return {
    items: pageItems,
    start,
    page: {
      limit: options.limit,
      scannedCount: pageItems.length,
      truncated,
      ...(nextCursor ? { nextCursor } : {}),
    },
  };
}
