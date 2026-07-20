---
name: candidate-journal
description: Append, supersede, validate, fold, or record Capture outcomes for durable Wiki Note and Skill Card candidates in one feature-scoped journal. Use whenever discovery, specification, tickets, implementation, review, or debugging surfaces knowledge that may deserve post-review Capture.
---

# Candidate Journal

Record candidates mechanically without writing Obsidian or deciding whether knowledge is durable. The journal is append-only working state at `.adapter/context/<feature-slug>.wiki-candidates.jsonl`; never edit, truncate, delete, or commit it.

Use one `feature-slug` for the entire workflow. Choose the stage from `grill-with-docs`, `specification`, `tickets`, `implementation`, `review`, `debugging`, or `capture`.

## Append

Capture one atomic claim. Use `candidate-type=wiki_note` for facts, constraints, decisions, guides, conventions, and gotchas. Use `candidate-type=skill_card` only for an executable pack registration candidate. Include final evidence paths or issue references in `source-ref`; never use a Lanhu evidence package as a source.

```bash
python3 ${CLAUDE_PLUGIN_ROOT}/scripts/wiki_candidate_journal.py append \
  --journal .adapter/context/<feature-slug>.wiki-candidates.jsonl \
  --feature-slug <feature-slug> --stage <stage> \
  --candidate-type wiki_note|skill_card \
  --kind decision|gotcha|contract|convention|domain|guide|skill_registration \
  --claim "<one atomic claim>" --why "<evidence and rationale>" \
  --source-ref "<path-or-issue>" [--source-ref "<another-ref>"] \
  [--task-id <ticket-id>] [--carve-out] [--origin <producer>]
```

Keep the returned `candidateId`. The helper locks the journal, replays every existing event, and refuses corrupt, truncated, duplicate, or illegal data before appending.

## Supersede

Append the replacement candidate first. Then link the old active candidate to it:

```bash
python3 ${CLAUDE_PLUGIN_ROOT}/scripts/wiki_candidate_journal.py supersede \
  --journal .adapter/context/<feature-slug>.wiki-candidates.jsonl \
  --feature-slug <feature-slug> --candidate-id <old-id> \
  --by-candidate-id <replacement-id> --reason "<why the old claim is obsolete>"
```

Do not supersede kept, skipped, or already superseded candidates.

## Capture

Before Capture, validate and fold. Stop on any error; do not recover by hand-editing the JSONL.

```bash
python3 ${CLAUDE_PLUGIN_ROOT}/scripts/wiki_candidate_journal.py validate \
  --journal .adapter/context/<feature-slug>.wiki-candidates.jsonl \
  --feature-slug <feature-slug>
python3 ${CLAUDE_PLUGIN_ROOT}/scripts/wiki_candidate_journal.py fold \
  --journal .adapter/context/<feature-slug>.wiki-candidates.jsonl \
  --feature-slug <feature-slug>
```

Only `update-wiki` records outcomes. Append `kept` only after the proposed knowledge change succeeds, `skipped` with the durable-gate reason, or `deferred` when recoverable work remains. A deferred candidate can later become kept or skipped; kept and skipped are terminal.

```bash
python3 ${CLAUDE_PLUGIN_ROOT}/scripts/wiki_candidate_journal.py outcome \
  --journal .adapter/context/<feature-slug>.wiki-candidates.jsonl \
  --feature-slug <feature-slug> --candidate-id <id> \
  --status kept|skipped|deferred --reason "<Capture result>"
```

Retain the journal as the interruption/recovery receipt. The Stop hook is silent once every candidate is terminal; it continues to remind on pending/deferred work and reports invalid journals.
