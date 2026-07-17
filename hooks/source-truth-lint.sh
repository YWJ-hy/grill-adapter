#!/usr/bin/env bash
# grill-adapter — Source-of-Truth Lint hook (PostToolUse / Stop).
#
# Execution-side counterpart to the planning-side /source-truth-check Verify skill.
# Lints the REAL changed files (git working tree vs HEAD, incl. untracked) against the
# project's configured sourceOfTruth policy. Surfaces `block`/`ask` findings; silent on
# `pass`. Fast-exits when sourceOfTruth is not configured. Never edits anything.
#
# `block` (a `truth/edit: never` path was touched) and `ask` (a `truth/edit: ask` path
# without authorization) are surfaced for the agent to resolve before completing the
# task; the authorization flags never bypass `truth/edit: never` (blueprint §10).
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$SELF_DIR/../scripts"

INPUT="$(cat 2>/dev/null || true)"
eval "$(HOOK_INPUT="$INPUT" python3 - <<'PY' 2>/dev/null || true
import json, os, shlex
try:
    d = json.loads(os.environ.get("HOOK_INPUT", "") or "{}")
except Exception:
    d = {}
print("HOOK_EVENT=" + shlex.quote(str(d.get("hook_event_name", ""))))
print("HOOK_CWD=" + shlex.quote(str(d.get("cwd", ""))))
PY
)"
HOOK_EVENT="${HOOK_EVENT:-}"
HOOK_CWD="${HOOK_CWD:-}"

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-}"
[ -z "$PROJECT_ROOT" ] && PROJECT_ROOT="$HOOK_CWD"
[ -z "$PROJECT_ROOT" ] && PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -z "$PROJECT_ROOT" ] && exit 0
[ -d "$PROJECT_ROOT" ] || exit 0

# Fast bail-out if sourceOfTruth is not configured in either root (avoids a python spawn per tool call).
CONFIGURED=""
for s in "$PROJECT_ROOT/.adapter/settings.json" "$PROJECT_ROOT/.shared-adapter/settings.json"; do
  [ -f "$s" ] && grep -q '"sourceOfTruth"' "$s" 2>/dev/null && CONFIGURED=1
done
[ -n "$CONFIGURED" ] || exit 0

# Real changed paths: modified + untracked vs HEAD, bounded.
CHANGED_FILE="$(mktemp 2>/dev/null || echo /tmp/grill-st-changed.$$)"
trap 'rm -f "$CHANGED_FILE"' EXIT
# --untracked-files=all so new files are listed individually, not collapsed to their dir.
git -C "$PROJECT_ROOT" status --porcelain --no-renames --untracked-files=all 2>/dev/null \
  | sed 's/^...//' \
  | grep -v '[[:space:]]->' \
  | head -200 > "$CHANGED_FILE" || true
[ -s "$CHANGED_FILE" ] || exit 0

RESULT="$(python3 "$SCRIPTS_DIR/source_truth_settings.py" "$PROJECT_ROOT" \
           --lint-changed --changed-paths-file "$CHANGED_FILE" --format json 2>/dev/null)"
[ -n "$RESULT" ] || exit 0

STATUS="$(printf '%s' "$RESULT" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("status",""))
except Exception: print("")' 2>/dev/null)"

case "$STATUS" in
  block|ask)
    REPORT="$(ST_RESULT="$RESULT" python3 - "$STATUS" <<'PY' 2>/dev/null || true
import json, os, sys
status = sys.argv[1]
try:
    d = json.loads(os.environ.get("ST_RESULT", "") or "{}")
except Exception:
    d = {}
lines = [f"grill-adapter source-of-truth lint: {status.upper()} — protected truth paths were touched."]
for f in d.get("findings", [])[:20]:
    p = f.get("path", "?"); edit = f.get("edit", "?"); rem = f.get("remediation", "")
    lines.append(f"- {p} (truth/edit: {edit}){(' — ' + rem) if rem else ''}")
if status == "block":
    lines.append("Do not complete the task until each `truth/edit: never` edit is reverted or routed through the upstream truth-source process.")
else:
    lines.append("Obtain explicit user authorization for each `truth/edit: ask` path, or revert, before completing the task.")
print("\n".join(lines))
PY
)"
    [ -n "$REPORT" ] || exit 0
    if [ "$HOOK_EVENT" = "Stop" ]; then
      python3 - "$REPORT" <<'PY' 2>/dev/null || printf '%s\n' "$REPORT" >&2
import json, sys
print(json.dumps({"systemMessage": sys.argv[1]}))
PY
    else
      python3 - "$HOOK_EVENT" "$REPORT" <<'PY' 2>/dev/null || printf '%s\n' "$REPORT" >&2
import json, sys
print(json.dumps({"hookSpecificOutput": {
    "hookEventName": sys.argv[1] or "PostToolUse",
    "additionalContext": sys.argv[2],
}}))
PY
    fi
    ;;
  *)
    ;;
esac
exit 0
