/**
 * Section marker extraction for wiki documents.
 *
 * Markers use HTML comments:
 *   <!-- wiki-section:section-id -->
 *   <!-- wiki-section:section-id summary="…" -->
 *   <!-- /wiki-section:section-id -->
 *
 * Section IDs are restricted to kebab-case: [a-z0-9][a-z0-9_-]*
 *
 * Kept in lockstep with overlays/scripts/wiki_section.py (the index-generation side).
 * The open marker may carry optional HTML-comment attributes after the id (currently an
 * authored summary="…" / roles="…"); the attribute tail is captured but ignored here —
 * the MCP only needs the section id. Legacy markers without attributes keep matching.
 */

const SECTION_ID_PATTERN = '[a-z0-9][a-z0-9_-]*';
const OPEN_RE = new RegExp(`^<!-- wiki-section:(${SECTION_ID_PATTERN})(\\s[^>]*?)?\\s*-->$`);
const CLOSE_RE = new RegExp(`^<!-- /wiki-section:(${SECTION_ID_PATTERN}) -->$`);
// Catches lines that intend to be a marker but match neither OPEN_RE nor CLOSE_RE — e.g. a
// summary containing '>' truncates the comment, which would otherwise silently drop the
// whole section from parsing instead of surfacing an error.
const LOOSE_MARKER_RE = /^<!--\s*\/?wiki-section:/;
const FENCE_OPEN_RE = /^(`{3,}|~{3,})/;

interface SectionSpan {
  sectionId: string;
  startLine: number;
  endLine: number | null;
  children: SectionSpan[];
}

function findFencedLines(lines: string[]): Set<number> {
  const inside = new Set<number>();
  let fenceChar: string | null = null;
  let fenceLen = 0;

  for (let i = 0; i < lines.length; i++) {
    const stripped = lines[i].trim();
    if (fenceChar === null) {
      const m = FENCE_OPEN_RE.exec(stripped);
      if (m) {
        fenceChar = m[1][0];
        fenceLen = m[1].length;
        inside.add(i);
      }
    } else {
      inside.add(i);
      const closer = fenceChar.repeat(fenceLen);
      if (stripped.startsWith(closer) && stripped.replace(new RegExp(`[${fenceChar}]`, 'g'), '') === '') {
        fenceChar = null;
        fenceLen = 0;
      }
    }
  }
  return inside;
}

function parseSpans(text: string): { topLevel: SectionSpan[]; errors: string[] } {
  const lines = text.split('\n');
  const fenced = findFencedLines(lines);
  const errors: string[] = [];
  const stack: SectionSpan[] = [];
  const topLevel: SectionSpan[] = [];

  for (let i = 0; i < lines.length; i++) {
    if (fenced.has(i)) continue;
    const stripped = lines[i].trim();

    const openM = OPEN_RE.exec(stripped);
    if (openM) {
      const span: SectionSpan = { sectionId: openM[1], startLine: i, endLine: null, children: [] };
      if (stack.length > 0) {
        stack[stack.length - 1].children.push(span);
      } else {
        topLevel.push(span);
      }
      stack.push(span);
      continue;
    }

    const closeM = CLOSE_RE.exec(stripped);
    if (closeM) {
      const sid = closeM[1];
      if (stack.length === 0) {
        errors.push(`Line ${i + 1}: closing marker for '${sid}' without matching open`);
      } else if (stack[stack.length - 1].sectionId !== sid) {
        errors.push(`Line ${i + 1}: closing marker for '${sid}' but expected '${stack[stack.length - 1].sectionId}'`);
      } else {
        stack[stack.length - 1].endLine = i;
        stack.pop();
      }
      continue;
    }

    if (LOOSE_MARKER_RE.test(stripped)) {
      errors.push(
        `Line ${i + 1}: malformed wiki-section marker (id must be kebab-case; a ` +
          `summary="…" must avoid > and stay on one line): ${stripped.slice(0, 80)}`,
      );
    }
  }

  for (const span of stack) {
    errors.push(`Line ${span.startLine + 1}: unclosed section '${span.sectionId}'`);
  }

  return { topLevel, errors };
}

function collectAll(spans: SectionSpan[], lines: string[]): Map<string, string> {
  const result = new Map<string, string>();
  for (const span of spans) {
    if (span.endLine === null) continue;
    const contentLines = lines.slice(span.startLine + 1, span.endLine);
    result.set(span.sectionId, contentLines.join('\n'));
    for (const [k, v] of collectAll(span.children, lines)) {
      result.set(k, v);
    }
  }
  return result;
}

export function extractAllSections(content: string): Map<string, string> {
  const lines = content.split('\n');
  const { topLevel } = parseSpans(content);
  return collectAll(topLevel, lines);
}

export function extractSection(content: string, sectionId: string): string | null {
  const sections = extractAllSections(content);
  return sections.get(sectionId) ?? null;
}

export function listSectionIds(content: string): string[] {
  const lines = content.split('\n');
  const fenced = findFencedLines(lines);
  const ids: string[] = [];
  for (let i = 0; i < lines.length; i++) {
    if (fenced.has(i)) continue;
    const m = OPEN_RE.exec(lines[i].trim());
    if (m) ids.push(m[1]);
  }
  return ids;
}

export function validateSectionMarkers(content: string): string[] {
  const { errors } = parseSpans(content);
  return errors;
}
