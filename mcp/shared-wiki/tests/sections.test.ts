import { describe, expect, it } from 'vitest';
import { extractAllSections, extractSection, listSectionIds, validateSectionMarkers } from '../src/wiki/sections.js';

const SAMPLE_DOC = `# Hook Guidelines

Introduction paragraph.

<!-- wiki-section:path-based-update -->
## Path-Based Update

All field updates MUST use updateByPath(path, value).
Direct props.model mutation is forbidden.
<!-- /wiki-section:path-based-update -->

<!-- wiki-section:deep-path -->
## Deep Path Handling

For nested objects, use dot-notation paths.
<!-- /wiki-section:deep-path -->
`;

const NESTED_DOC = `# Nested

<!-- wiki-section:parent -->
## Parent

Parent intro.

<!-- wiki-section:child -->
### Child

Child content.
<!-- /wiki-section:child -->

Parent outro.
<!-- /wiki-section:parent -->
`;

const CODE_BLOCK_DOC = `# Code Block Test

\`\`\`markdown
<!-- wiki-section:fake -->
Fake content.
<!-- /wiki-section:fake -->
\`\`\`

<!-- wiki-section:real -->
## Real

Real content.
<!-- /wiki-section:real -->
`;

const BROKEN_DOC = `# Broken

<!-- wiki-section:unclosed -->
## Unclosed

No closing marker.
`;

// Markers now carry an authored summary="…" (and optionally roles="…") attribute tail.
// The MCP parser must tolerate it and still resolve the section by id.
const SUMMARY_DOC = `# Hook Guidelines

<!-- wiki-section:hook-scope-placement summary="Hook 按作用域分层放置: ..." -->
## Hook Scope Placement

Hooks must be layered by scope.
<!-- /wiki-section:hook-scope-placement -->

<!-- wiki-section:card-x summary="A card" roles="review" -->
## Card X

Card body.
<!-- /wiki-section:card-x -->
`;

describe('extractAllSections', () => {
  it('extracts all top-level sections', () => {
    const sections = extractAllSections(SAMPLE_DOC);
    expect(sections.size).toBe(2);
    expect(sections.get('path-based-update')).toContain('updateByPath(path, value)');
    expect(sections.get('deep-path')).toContain('dot-notation');
  });

  it('extracts nested sections', () => {
    const sections = extractAllSections(NESTED_DOC);
    expect(sections.size).toBe(2);
    expect(sections.get('parent')).toContain('Parent intro');
    expect(sections.get('parent')).toContain('wiki-section:child');
    expect(sections.get('child')).toContain('Child content');
    expect(sections.get('child')).not.toContain('Parent intro');
  });

  it('ignores markers inside code blocks', () => {
    const sections = extractAllSections(CODE_BLOCK_DOC);
    expect(sections.has('fake')).toBe(false);
    expect(sections.has('real')).toBe(true);
    expect(sections.get('real')).toContain('Real content');
  });

  it('resolves sections whose open marker carries a summary/roles attribute', () => {
    const sections = extractAllSections(SUMMARY_DOC);
    expect(sections.size).toBe(2);
    expect(sections.get('hook-scope-placement')).toContain('layered by scope');
    expect(sections.get('card-x')).toContain('Card body');
  });
});

describe('extractSection', () => {
  it('returns content for existing section', () => {
    const content = extractSection(SAMPLE_DOC, 'path-based-update');
    expect(content).toContain('updateByPath');
  });

  it('returns null for missing section', () => {
    expect(extractSection(SAMPLE_DOC, 'nonexistent')).toBeNull();
  });

  it('returns content for a section whose marker carries a summary attribute', () => {
    const content = extractSection(SUMMARY_DOC, 'hook-scope-placement');
    expect(content).toContain('layered by scope');
  });
});

describe('listSectionIds', () => {
  it('lists all section IDs in order', () => {
    const ids = listSectionIds(SAMPLE_DOC);
    expect(ids).toEqual(['path-based-update', 'deep-path']);
  });

  it('lists ids whose markers carry attributes', () => {
    expect(listSectionIds(SUMMARY_DOC)).toEqual(['hook-scope-placement', 'card-x']);
  });

  it('includes nested IDs', () => {
    const ids = listSectionIds(NESTED_DOC);
    expect(ids).toEqual(['parent', 'child']);
  });

  it('excludes IDs inside code blocks', () => {
    const ids = listSectionIds(CODE_BLOCK_DOC);
    expect(ids).toEqual(['real']);
  });
});

describe('validateSectionMarkers', () => {
  it('returns empty for valid document', () => {
    expect(validateSectionMarkers(SAMPLE_DOC)).toEqual([]);
  });

  it('reports unclosed markers', () => {
    const errors = validateSectionMarkers(BROKEN_DOC);
    expect(errors.length).toBe(1);
    expect(errors[0]).toContain('unclosed');
  });

  it('reports mismatched close', () => {
    const doc = `<!-- wiki-section:aaa -->\nContent\n<!-- /wiki-section:bbb -->`;
    const errors = validateSectionMarkers(doc);
    expect(errors.length).toBeGreaterThanOrEqual(1);
    expect(errors[0]).toContain("expected 'aaa'");
  });

  it('accepts valid summary/roles attributes', () => {
    expect(validateSectionMarkers(SUMMARY_DOC)).toEqual([]);
  });

  it('flags a marker whose summary contains > (truncated comment)', () => {
    const doc = `<!-- wiki-section:bad summary="a > b" -->\nContent\n<!-- /wiki-section:bad -->`;
    const errors = validateSectionMarkers(doc);
    expect(errors.some((e) => e.includes('malformed wiki-section marker'))).toBe(true);
  });
});
