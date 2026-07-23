---
name: candidate-journal
description: Append, supersede, validate, fold, or record Capture outcomes for durable Wiki Note and Skill Card candidates in one feature-scoped journal. Use whenever discovery, specification, tickets, implementation, review, or debugging surfaces knowledge that may deserve post-review Capture.
---

# Candidate Journal

Record candidates mechanically without writing Obsidian or deciding whether knowledge is durable. The journal is append-only working state at `.adapter/context/<feature-slug>.wiki-candidates.jsonl`; never edit, truncate, delete, or commit it.

Use one `feature-slug` for the entire workflow. Choose the stage from `grill-with-docs`, `specification`, `tickets`, `implementation`, `review`, `debugging`, or `capture`.

## Append

Capture one atomic claim. Use `candidate-type=wiki_note` for facts, constraints, decisions, guides, conventions, and gotchas. Use `candidate-type=skill_card` only after `scaffold-practice-skill` has produced a valid executable pack identity. Include final evidence paths or issue references in `source-ref`.

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

For `skill_card`, also pass every structured registration field. Prefer the scaffold helper's `stage-card` command, which computes the contract hash and appends these fields without hand calculation:

```bash
  --skill-provider claude-code-project --skill-name <name> \
  --skill-version <SKILL.md version> --skill-contract-hash <sha256:...> \
  --skill-role implementer|reviewer [--skill-role ...] \
  --skill-trigger "<scenario>" [--skill-trigger ...] \
  --skill-summary "<theme summary>"
```

The candidate always records `discoveryState: pending`. Neither a pending candidate, an applied Note, nor an open draft PR is discoverable runtime knowledge.

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

Only `update-wiki` records outcomes. Append `kept` only after the proposed knowledge change succeeds, `skipped` with the durable-gate reason, or `deferred` when recoverable work remains. A resumed Capture may append another `deferred` outcome to replace stale recoverable state with a newly validated proposal; it can later become kept or skipped. Kept and skipped are terminal.

When several active candidates express the same final claim, do not write the claim more than once. Append one atomic `capture`-stage candidate with the reconciled final wording, then supersede each related active candidate by that replacement before proposing a change. This keeps the semantic merge explicit and reviewable; the helper does not infer duplicates.

```bash
python3 ${CLAUDE_PLUGIN_ROOT}/scripts/wiki_candidate_journal.py outcome \
  --journal .adapter/context/<feature-slug>.wiki-candidates.jsonl \
  --feature-slug <feature-slug> --candidate-id <id> \
  --status kept|skipped|deferred --reason "<Capture result>"
```

For an Obsidian proposal that must pause, append `deferred` with `--write-state proposed`. If resumed Capture must re-propose after drift, append another deferred proposed receipt; the latest valid proposal replaces the folded recovery view without erasing history. A receipt-less re-deferral updates the reason but retains that latest proposal, so it cannot bypass the eventual identity check. After a successful apply, append `kept` with the same identity as that latest proposal and `--write-state applied`. Supply the exact `sourceId`, `repositoryRef`, `bindingDigest`, `wikiId`, path, operation, and diff hashes returned by the write tools; omit `--before-hash` only for create. For a Skill Card, also copy every field from the write result's `skillRegistration` using the same `--skill-*` flags as the candidate append example above. The helper requires an applied receipt for a kept Skill Card and rejects a missing or mismatched registration.

```bash
python3 ${CLAUDE_PLUGIN_ROOT}/scripts/wiki_candidate_journal.py outcome \
  --journal .adapter/context/<feature-slug>.wiki-candidates.jsonl \
  --feature-slug <feature-slug> --candidate-id <id> \
  --status kept --reason "Write bridge returned matching post-write identity." \
  --write-state applied --operation update \
  --source-id <source-id> --repository-ref <repository-ref> \
  --binding-digest <binding-digest> --wiki-id <wiki-id> --path <vault-relative.md> \
  --before-hash <sha256:...> --after-hash <sha256:...>
```

The folded candidate exposes this as `writeReceipt`. For a Card, its nested `skillRegistration` must exactly equal the staged candidate registration. It contains no Note body, token, or authorization secret; it is the allowlisted candidate-to-write identity needed by later publishing and recovery.

Retain the journal as the interruption/recovery receipt. The Stop hook is silent once every candidate is terminal; it continues to remind on pending/deferred work and reports invalid journals.
