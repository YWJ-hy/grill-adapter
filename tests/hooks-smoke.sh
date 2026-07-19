#!/usr/bin/env bash
set -euo pipefail

# Exercises the three host-agnostic hooks: wiki-reread (Bind backstop), wiki-capture-suggest
# (Capture backstop), source-truth-lint (execution lint). Drives each with event JSON on stdin
# and asserts the injected output / silent paths. Hooks self-locate scripts via ../scripts.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${1:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
HOOKS="$ROOT/hooks"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# --- wiki-capture-suggest: fires only when candidates pending ---
T="$(mktemp -d)"; ( cd "$T" && git init -q )
printf '{"kind":"decision","claim":"x"}\n' > "$T/.wiki-candidates.jsonl"
OUT="$(printf '{"cwd":"%s","hook_event_name":"Stop"}' "$T" | CLAUDE_PROJECT_DIR="$T" bash "$HOOKS/wiki-capture-suggest.sh")"
printf '%s' "$OUT" | grep -q 'systemMessage' || fail "capture-suggest did not fire on pending candidates"
printf '%s' "$OUT" | grep -q 'update-wiki' || fail "capture-suggest missing update-wiki nudge"
rm -f "$T/.wiki-candidates.jsonl"
OUT="$(printf '{"cwd":"%s","hook_event_name":"Stop"}' "$T" | CLAUDE_PROJECT_DIR="$T" bash "$HOOKS/wiki-capture-suggest.sh")"
[[ -z "$OUT" ]] || fail "capture-suggest fired with no candidates"
rm -rf "$T"

# --- source-truth-lint: block on a changed truth/edit:never path ---
T="$(mktemp -d)"; ( cd "$T" && git init -q ); mkdir -p "$T/.adapter" "$T/src/generated"
cat > "$T/.adapter/settings.json" <<'JSON'
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

# --- wiki-reread: UserPromptSubmit must not reread schema-v6 notes; explicit Bind owns it. ---
T="$(mktemp -d)"; ( cd "$T" && git init -q ); mkdir -p "$T/.adapter/context"
printf '{"schemaVersion":6,"kind":"grill-adapter.wiki-context"}\n' > "$T/.adapter/context/feature.wiki-context.json"
OUT="$(printf '{"cwd":"%s","hook_event_name":"UserPromptSubmit"}' "$T" | CLAUDE_PROJECT_DIR="$T" bash "$HOOKS/wiki-reread.sh")"
[[ -z "$OUT" ]] || fail "wiki-reread must not materialize schema-v6 notes on UserPromptSubmit"
OUT="$(printf '{"cwd":"%s","hook_event_name":"SessionStart"}' "$T" | CLAUDE_PROJECT_DIR="$T" bash "$HOOKS/wiki-reread.sh")"
printf '%s' "$OUT" | grep -q 'wiki-materialize' || fail "wiki-reread SessionStart did not remind about explicit schema-v6 Bind"
rm -rf "$T"

printf 'hooks smoke OK\n'
