---
name: candidate-journal
description: Append, supersede, validate, fold, or record Capture outcomes for durable Wiki Note and Skill Card candidates in one feature-scoped journal. Use whenever an opted-in grill-adapter workflow surfaces knowledge that may deserve post-review Capture. Requires explicit invocation or project opt-in; standalone grill remains inert.
---

# Candidate Journal

## Activation

Before any filesystem write or adapter workflow action, follow the canonical contract in `${CLAUDE_PLUGIN_ROOT}/contracts/project-activation-v1.json`. Resolve its preflight script relative to the installed plugin root; `--explicit` is only for a user-explicit invocation. Exit 3 is a silent standalone no-op.


Record candidates and corrections mechanically without writing Obsidian or deciding whether knowledge is durable. The journal is append-only working state at `.grill-adapter/context/<feature-slug>/wiki-candidates.jsonl`; never edit, truncate, delete, or commit it.

Use one `feature-slug` for the entire workflow. Choose the stage from `grill-with-docs`, `specification`, `tickets`, `implementation`, `review`, `debugging`, or `capture`.

## Append

Capture one atomic claim. Use `candidate-type=wiki_note` for facts, constraints, decisions, guides, conventions, and gotchas. Use `candidate-type=skill_card` only after `scaffold-practice-skill` has produced a valid executable pack identity. Include final evidence paths or issue references in `source-ref`.

```bash
python3 ${CLAUDE_PLUGIN_ROOT}/scripts/wiki_candidate_journal.py append \
  --journal .grill-adapter/context/<feature-slug>/wiki-candidates.jsonl \
  --feature-slug <feature-slug> --stage <stage> \
  --candidate-type wiki_note|skill_card \
  --kind decision|gotcha|contract|convention|domain|guide|skill_registration \
  --claim "<one atomic claim>" --why "<evidence and rationale>" \
  --source-ref "<path-or-issue>" [--source-ref "<another-ref>"] \
  [--task-id <ticket-id>] [--carve-out] [--origin <producer>]
```

`adr_execution_projection` is a reserved generated kind. Do not append it by hand. The grill ADR
bridge emits it with a strict `adrProjection` object containing the project ADR's stable source ID,
project-relative path, content hash, and project-only target scope. Ordinary non-ADR decisions
continue to use `kind=decision`.

For `skill_card`, also pass every structured registration field. Prefer the scaffold helper's `stage-card` command, which computes the contract hash and appends these fields without hand calculation:

```bash
  --skill-name <name> \
  --skill-version <SKILL.md version> --skill-contract-hash <sha256:...> \
  --skill-role implementer|reviewer [--skill-role ...] \
  --skill-trigger "<scenario>" [--skill-trigger ...] \
  --skill-summary "<theme summary>"
```

The candidate always records `discoveryState: pending`. Neither a pending candidate, an applied Note, nor an open draft PR is discoverable runtime knowledge.

Keep the returned `candidateId`. The helper locks the journal, replays every existing event, and refuses corrupt, truncated, duplicate, or illegal data before appending.

## Record a correction

Use `kind=correction` only when observed evidence says one known bound atomic Note may be wrong or
incomplete. Name the stable identity as both `sourceId` and `wikiId`; never substitute a Note path,
title, search phrase, or body excerpt. The correction claim and evidence refs are preserved in a
structured `correction` object together with the observed impact:

```bash
python3 ${CLAUDE_PLUGIN_ROOT}/scripts/wiki_candidate_journal.py append \
  --journal .grill-adapter/context/<feature-slug>/wiki-candidates.jsonl \
  --feature-slug <feature-slug> --stage <stage> \
  --candidate-type wiki_note --kind correction \
  --claim "<specific corrected claim>" \
  --why "<why the observation may invalidate the current Note>" \
  --source-ref "<verified-test-path-or-review-finding>" \
  --affected-source-id <bound-source-id> \
  --affected-wiki-id <stable-wiki-id> \
  --observed-impact "<concrete failure or user-visible effect>"
```

Missing or malformed identities/evidence fail closed. The journal does not access the Vault, so
`update-wiki` must resolve this exact identity against the current project bindings before any
target or outcome decision. Pending and deferred corrections appear in folded
`maintenanceSignals` as metadata-only `unresolved_correction` records. They are warnings for
Capture and later maintenance; they do not hide, archive, rewrite, or otherwise change the active
Note.

## Supersede

Append the replacement candidate first. Then link the old active candidate to it:

```bash
python3 ${CLAUDE_PLUGIN_ROOT}/scripts/wiki_candidate_journal.py supersede \
  --journal .grill-adapter/context/<feature-slug>/wiki-candidates.jsonl \
  --feature-slug <feature-slug> --candidate-id <old-id> \
  --by-candidate-id <replacement-id> --reason "<why the old claim is obsolete>"
```

Do not supersede kept, skipped, or already superseded candidates.

## Capture

Before Capture, validate and fold. Stop on any error; do not recover by hand-editing the JSONL.

```bash
python3 ${CLAUDE_PLUGIN_ROOT}/scripts/wiki_candidate_journal.py validate \
  --journal .grill-adapter/context/<feature-slug>/wiki-candidates.jsonl \
  --feature-slug <feature-slug>
python3 ${CLAUDE_PLUGIN_ROOT}/scripts/wiki_candidate_journal.py fold \
  --journal .grill-adapter/context/<feature-slug>/wiki-candidates.jsonl \
  --feature-slug <feature-slug>
```

Only `update-wiki` records outcomes. Normal Capture appends `kept` only after the deterministic staging boundary has accepted an immutable Outbox entry, using `writeReceipt.state: queued`; append `skipped` with the durable-gate reason or `deferred` when a user decision or recoverable prerequisite remains. Kept and skipped are terminal for Capture reminders. `queued` is not authoritative Wiki knowledge: it becomes `pr-open` only after an explicitly confirmed batch publish, and `active` only after merge plus synchronized-base identity verification. Legacy `proposed`/`applied` receipts remain valid only for exact recovery of pre-Outbox transactions.

When several active candidates express the same final claim, do not write the claim more than once. Append one atomic `capture`-stage candidate with the reconciled final wording, then supersede each related active candidate by that replacement before proposing a change. This keeps the semantic merge explicit and reviewable; the helper does not infer duplicates.

```bash
python3 ${CLAUDE_PLUGIN_ROOT}/scripts/wiki_candidate_journal.py outcome \
  --journal .grill-adapter/context/<feature-slug>/wiki-candidates.jsonl \
  --feature-slug <feature-slug> --candidate-id <id> \
  --status kept|skipped|deferred --reason "<Capture result>"
```

The staging boundary records `kept --write-state queued` with the exact `sourceId`, `repositoryRef`, `bindingDigest`, `wikiId`, path, operation, and before/after hashes of the protected Git object; omit `--before-hash` only for create. For a Skill Card, it also copies every validated `skillRegistration` field using the same `--skill-*` flags as the candidate append example above. The helper requires a queued or legacy-applied receipt for a kept Skill Card and rejects missing or mismatched registration.

For an `adr_execution_projection`, also copy the write result's complete `adrProjection` identity
with `--adr-authority-type`, `--adr-projection-type`, `--adr-source-id`, `--adr-source-path`,
`--adr-source-content-hash`, and `--adr-target-scope`. A proposed/applied receipt that omits or
changes this identity cannot complete the ADR candidate.

```bash
python3 ${CLAUDE_PLUGIN_ROOT}/scripts/wiki_candidate_journal.py outcome \
  --journal .grill-adapter/context/<feature-slug>/wiki-candidates.jsonl \
  --feature-slug <feature-slug> --candidate-id <id> \
  --status kept --reason "Capture Plan staged in the machine-local Outbox." \
  --write-state queued --operation update \
  --source-id <source-id> --repository-ref <repository-ref> \
  --binding-digest <binding-digest> --wiki-id <wiki-id> --path <vault-relative.md> \
  --before-hash <sha256:...> --after-hash <sha256:...>
```

The folded candidate exposes this as `writeReceipt`. For a Card, its nested `skillRegistration` must exactly equal the staged candidate registration. It contains no Note body, token, or authorization secret; it is a lifecycle receipt, while complete draft content remains in Git objects protected by the current project's hidden Outbox ref.

Retain the journal as the interruption/recovery receipt. The Stop hook is silent once every candidate is terminal; it continues to remind on pending/deferred work and reports invalid journals.
