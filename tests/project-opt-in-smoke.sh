#!/usr/bin/env bash
set -euo pipefail

# A globally installed plugin must remain inert in projects that use grill without
# grill-adapter. Project workflow activation comes from the installed host marker or
# settings; an explicit user invocation remains the one-off escape hatch.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${1:-$(cd "${SCRIPT_DIR}/.." && pwd)}"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

WORKFLOW_SKILLS=(
  break-loop
  candidate-journal
  import-wiki
  init-wiki
  migrate-wiki
  scaffold-practice-skill
  setup-init-obsidian
  source-truth-check
  update-wiki
  wiki-materialize
  wiki-maintenance
  wiki-readiness
  wiki-research
)

for skill in "${WORKFLOW_SKILLS[@]}"; do
  file="$ROOT/skills/$skill/SKILL.md"
  [[ -f "$file" ]] || fail "missing workflow skill: $skill"

  frontmatter="$(awk 'NR == 1 { next } /^---$/ { exit } { print }' "$file")"
  printf '%s' "$frontmatter" | grep -Fqi 'standalone grill' \
    || fail "$skill description can auto-activate in a standalone grill project"

  grep -Fq '## Activation gate' "$file" \
    || fail "$skill has no activation gate"
  grep -Fq '<!-- grill-adapter:host:' "$file" \
    || fail "$skill activation gate does not recognize installed host wiring"
  grep -Fq '.grill-adapter/settings.json' "$file" \
    || fail "$skill activation gate does not recognize explicit project settings"
  grep -Fqi 'before any filesystem write' "$file" \
    || fail "$skill activation gate does not protect the filesystem"
  grep -Fq 'scripts/project_activation.py' "$file" \
    || fail "$skill activation gate does not run the mechanical preflight"
done

python3 - "$ROOT/.codex-plugin/plugin.json" <<'PY'
import json
import sys

manifest = json.load(open(sys.argv[1], encoding="utf-8"))
prompts = manifest.get("interface", {}).get("defaultPrompt", [])
assert prompts, "Codex plugin defaultPrompt is missing"
for prompt in prompts:
    assert "wired for grill-adapter" in prompt.lower(), (
        "Codex default prompts must not imply activation in standalone grill projects"
    )
PY

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
( cd "$TMP" && git init -q )

if python3 "$ROOT/scripts/project_activation.py" "$TMP"; then
  fail "unwired standalone grill project was reported active"
elif [[ "$?" != "3" ]]; then
  fail "unwired activation check did not return the documented exit 3"
fi
[[ ! -e "$TMP/.grill-adapter" ]] \
  || fail "activation check created .grill-adapter in an unwired project"

python3 "$ROOT/scripts/project_activation.py" "$TMP" --explicit

printf '%s\n' '<!-- grill-adapter:host:grill:start -->' > "$TMP/AGENTS.md"
python3 "$ROOT/scripts/project_activation.py" "$TMP"
rm -f "$TMP/AGENTS.md"

mkdir -p "$TMP/.grill-adapter"
printf '%s\n' '{}' > "$TMP/.grill-adapter/settings.json"
python3 "$ROOT/scripts/project_activation.py" "$TMP"
rm -rf "$TMP/.grill-adapter"

run_hook() {
  local hook="$1"
  local event="$2"
  printf '{"cwd":"%s","hook_event_name":"%s"}' "$TMP" "$event" \
    | CLAUDE_PROJECT_DIR="$TMP" bash "$ROOT/hooks/$hook" >/dev/null
}

run_hook wiki-reread.sh SessionStart
run_hook wiki-capture-suggest.sh Stop
run_hook source-truth-lint.sh PostToolUse
run_hook source-truth-lint.sh Stop

[[ ! -e "$TMP/.grill-adapter" ]] \
  || fail "global hooks created .grill-adapter in an unwired project"

mkdir -p "$TMP/.grill-adapter/context/stale"
printf '%s\n' '{}' > "$TMP/.grill-adapter/context/stale/stale.wiki-context.json"
printf '%s\n' '{}' > "$TMP/.grill-adapter/context/stale/stale.wiki-candidates.jsonl"

if python3 "$ROOT/scripts/project_activation.py" "$TMP"; then
  fail "leftover adapter context was treated as project opt-in"
elif [[ "$?" != "3" ]]; then
  fail "leftover context activation check did not return the documented exit 3"
fi

for hook_event in \
  "wiki-reread.sh SessionStart" \
  "wiki-capture-suggest.sh Stop" \
  "source-truth-lint.sh PostToolUse" \
  "source-truth-lint.sh Stop"; do
  read -r hook event <<< "$hook_event"
  output="$(run_hook "$hook" "$event")"
  [[ -z "$output" ]] \
    || fail "$hook emitted adapter noise for leftover context in a standalone grill project"
done

printf 'project opt-in smoke OK\n'
