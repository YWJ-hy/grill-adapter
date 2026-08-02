#!/usr/bin/env bash
set -euo pipefail

# Exercises the three host-agnostic hooks: wiki-reread (Bind backstop), wiki-capture-suggest
# (Capture backstop), source-truth-lint (execution lint). Drives each with event JSON on stdin
# and asserts the injected output / silent paths. Hooks self-locate scripts via ../scripts.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${1:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
HOOKS="$ROOT/hooks"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
activate_project() {
  printf '%s\n' '<!-- grill-adapter:host:grill:start -->' > "$1/AGENTS.md"
}

# --- wiki-capture-suggest: fires only when journal candidates are unresolved ---
T="$(mktemp -d)"; ( cd "$T" && git init -q ); mkdir -p "$T/.grill-adapter/context/feature-a"
activate_project "$T"
JOURNAL="$T/.grill-adapter/context/feature-a/wiki-candidates.jsonl"
python3 "$ROOT/scripts/wiki_candidate_journal.py" append \
  --journal "$JOURNAL" --feature-slug feature-a --event-id evt-1 --candidate-id cand-1 \
  --stage implementation --candidate-type wiki_note --kind decision \
  --claim x --why y --source-ref z >/dev/null
OUT="$(printf '{"cwd":"%s","hook_event_name":"Stop"}' "$T" | CLAUDE_PROJECT_DIR="$T" bash "$HOOKS/wiki-capture-suggest.sh")"
printf '%s' "$OUT" | grep -q 'systemMessage' || fail "capture-suggest did not fire on pending candidates"
printf '%s' "$OUT" | grep -q 'update-wiki' || fail "capture-suggest missing update-wiki nudge"
python3 "$ROOT/scripts/wiki_candidate_journal.py" outcome \
  --journal "$JOURNAL" --feature-slug feature-a --event-id evt-2 --candidate-id cand-1 \
  --status skipped --reason 'not durable' >/dev/null
OUT="$(printf '{"cwd":"%s","hook_event_name":"Stop"}' "$T" | CLAUDE_PROJECT_DIR="$T" bash "$HOOKS/wiki-capture-suggest.sh")"
[[ -z "$OUT" ]] || fail "capture-suggest fired when every candidate was terminal"

# Pre-directory journals remain visible during recovery.
LEGACY_JOURNAL="$T/.grill-adapter/context/legacy.wiki-candidates.jsonl"
python3 "$ROOT/scripts/wiki_candidate_journal.py" append \
  --journal "$LEGACY_JOURNAL" --feature-slug legacy --event-id legacy-1 --candidate-id legacy-candidate \
  --stage implementation --candidate-type wiki_note --kind decision \
  --claim x --why y --source-ref z >/dev/null
OUT="$(printf '{"cwd":"%s","hook_event_name":"Stop"}' "$T" | CLAUDE_PROJECT_DIR="$T" bash "$HOOKS/wiki-capture-suggest.sh")"
printf '%s' "$OUT" | grep -q 'legacy.wiki-candidates.jsonl' || fail "capture-suggest did not find a legacy flat journal"
python3 "$ROOT/scripts/wiki_candidate_journal.py" outcome \
  --journal "$LEGACY_JOURNAL" --feature-slug legacy --event-id legacy-2 --candidate-id legacy-candidate \
  --status skipped --reason 'not durable' >/dev/null

printf '%s\n' '{not-json}' > "$JOURNAL"
OUT="$(printf '{"cwd":"%s","hook_event_name":"Stop"}' "$T" | CLAUDE_PROJECT_DIR="$T" bash "$HOOKS/wiki-capture-suggest.sh")"
printf '%s' "$OUT" | grep -q 'invalid candidate journal' || fail "capture-suggest hid a corrupt journal"
rm -rf "$T"

# --- source-truth-lint: block on a changed truth/edit:never path ---
T="$(mktemp -d)"; ( cd "$T" && git init -q ); mkdir -p "$T/.grill-adapter" "$T/src/generated"
cat > "$T/.grill-adapter/settings.json" <<'JSON'
{ "sourceOfTruth": { "sources": [ {"paths": ["src/generated/**"], "role": "truth", "edit": "never"} ] } }
JSON
( cd "$T" && git add -A && git -c user.email=t@t -c user.name=t commit -qm base )
printf 'hand-edited\n' > "$T/src/generated/client.ts"
OUT="$(printf '{"cwd":"%s","hook_event_name":"PostToolUse","tool_name":"Write"}' "$T" | CLAUDE_PROJECT_DIR="$T" bash "$HOOKS/source-truth-lint.sh")"
printf '%s' "$OUT" | grep -q 'BLOCK' || fail "source-truth-lint did not BLOCK a truth/edit:never change"
printf '%s' "$OUT" | grep -q 'src/generated/client.ts' || fail "source-truth-lint did not name the offending path"
printf '%s' "$OUT" | grep -q 'hookSpecificOutput' || fail "source-truth-lint PostToolUse output shape wrong"
# Stop event -> systemMessage variant
OUT="$(printf '{"cwd":"%s","hook_event_name":"Stop"}' "$T" | CLAUDE_PROJECT_DIR="$T" bash "$HOOKS/source-truth-lint.sh")"
printf '%s' "$OUT" | grep -q 'systemMessage' || fail "source-truth-lint Stop did not use systemMessage"
rm -rf "$T"

# --- source-truth-lint: silent when unconfigured ---
T="$(mktemp -d)"; ( cd "$T" && git init -q )
OUT="$(printf '{"cwd":"%s","hook_event_name":"PostToolUse"}' "$T" | CLAUDE_PROJECT_DIR="$T" bash "$HOOKS/source-truth-lint.sh")"
[[ -z "$OUT" ]] || fail "source-truth-lint not silent when unconfigured"
rm -rf "$T"

# --- wiki-reread: silent with no sidecar ---
T="$(mktemp -d)"; ( cd "$T" && git init -q )
OUT="$(printf '{"cwd":"%s","hook_event_name":"UserPromptSubmit"}' "$T" | CLAUDE_PROJECT_DIR="$T" bash "$HOOKS/wiki-reread.sh")"
[[ -z "$OUT" ]] || fail "wiki-reread not silent with no sidecar"
rm -rf "$T"

# --- wiki-reread: schema-v6 is silent until approved snapshots await their first Bind. ---
T="$(mktemp -d)"; ( cd "$T" && git init -q ); mkdir -p "$T/.grill-adapter/context/feature"
activate_project "$T"
printf '{"schemaVersion":6,"kind":"grill-adapter.wiki-context"}\n' > "$T/.grill-adapter/context/feature/wiki-context.json"
OUT="$(printf '{"cwd":"%s","hook_event_name":"UserPromptSubmit"}' "$T" | CLAUDE_PROJECT_DIR="$T" bash "$HOOKS/wiki-reread.sh")"
[[ -z "$OUT" ]] || fail "wiki-reread must not materialize schema-v6 notes on UserPromptSubmit"
OUT="$(printf '{"cwd":"%s","hook_event_name":"SessionStart"}' "$T" | CLAUDE_PROJECT_DIR="$T" bash "$HOOKS/wiki-reread.sh")"
[[ -z "$OUT" ]] || fail "wiki-reread must stay silent for a planning-only schema-v6 sidecar"
cat > "$T/.grill-adapter/context/feature/ticket-roster.json" <<'JSON'
{"featureSlug":"","ticketSource":"manual","tickets":[{"taskId":"01","taskTitle":"task","text":"task"}]}
JSON
python3 - "$T/.grill-adapter/context/feature/wiki-context.json" "$T/.grill-adapter/context/feature/ticket-roster.json" <<'PY'
import json
import sys

context_path, roster_path = sys.argv[1:]
context = json.load(open(context_path, encoding="utf-8"))
context["featureSlug"] = "feature"
with open(context_path, "w", encoding="utf-8") as handle:
    json.dump(context, handle)
roster = json.load(open(roster_path, encoding="utf-8"))
roster["featureSlug"] = "feature"
with open(roster_path, "w", encoding="utf-8") as handle:
    json.dump(roster, handle)
PY
touch "$T/.grill-adapter/context/feature/01.wiki-implement.md"
touch "$T/.grill-adapter/context/feature/01.wiki-review.md"
touch "$T/.grill-adapter/context/feature/01.wiki-approval.json"
OUT="$(printf '{"cwd":"%s","hook_event_name":"SessionStart"}' "$T" | CLAUDE_PROJECT_DIR="$T" bash "$HOOKS/wiki-reread.sh")"
printf '%s' "$OUT" | grep -q 'wiki-readiness' || fail "wiki-reread SessionStart did not remind about pending readiness"
printf '%s' "$OUT" | grep -q '01' || fail "wiki-reread SessionStart did not name the pending task"
if printf '%s' "$OUT" | grep -q 'wiki-materialize <ticket-id>'; then
  fail "wiki-reread still asks for a duplicate materialization"
fi
cat > "$T/.grill-adapter/context/feature/wiki-readiness.json" <<'JSON'
{"schemaVersion":1,"kind":"grill-adapter.wiki-readiness","featureSlug":"feature","ticketSource":"manual","rosterFile":"ticket-roster.json","tasks":[{"taskId":"01","status":"ready"}]}
JSON
OUT="$(printf '{"cwd":"%s","hook_event_name":"SessionStart"}' "$T" | CLAUDE_PROJECT_DIR="$T" bash "$HOOKS/wiki-reread.sh")"
[[ -z "$OUT" ]] || fail "wiki-reread reminded after task readiness was already recorded"
rm -rf "$T"

# The hook remains able to resume an existing flat sidecar without moving it.
T="$(mktemp -d)"; ( cd "$T" && git init -q ); mkdir -p "$T/.grill-adapter/context"
activate_project "$T"
printf '{"schemaVersion":6,"kind":"grill-adapter.wiki-context"}\n' > "$T/.grill-adapter/context/legacy.wiki-context.json"
OUT="$(printf '{"cwd":"%s","hook_event_name":"SessionStart"}' "$T" | CLAUDE_PROJECT_DIR="$T" bash "$HOOKS/wiki-reread.sh")"
printf '%s' "$OUT" | grep -q 'legacy.wiki-context.json' || fail "wiki-reread did not find a legacy flat sidecar"
rm -rf "$T"

printf 'hooks smoke OK\n'
