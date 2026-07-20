#!/usr/bin/env bash
# grill-adapter — Capture backstop hook (Stop).
#
# Non-blocking reminder to run /update-wiki when durable knowledge was captured but not
# yet processed. The precise Capture path is the convention "after /code-review, run
# /update-wiki"; this hook is only the backstop for a skipped step (blueprint §11).
#
# Trigger = a validated `.wiki-candidates.jsonl` journal with pending/deferred candidates,
# or an invalid journal that must fail before Capture. Terminal journals are retained as
# recovery receipts and do not keep reminding.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

INPUT="$(cat 2>/dev/null || true)"
eval "$(HOOK_INPUT="$INPUT" python3 - <<'PY' 2>/dev/null || true
import json, os, shlex
try:
    d = json.loads(os.environ.get("HOOK_INPUT", "") or "{}")
except Exception:
    d = {}
print("HOOK_CWD=" + shlex.quote(str(d.get("cwd", ""))))
print("STOP_ACTIVE=" + shlex.quote(str(d.get("stop_hook_active", ""))))
PY
)"
HOOK_CWD="${HOOK_CWD:-}"

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-}"
[ -z "$PROJECT_ROOT" ] && PROJECT_ROOT="$HOOK_CWD"
[ -z "$PROJECT_ROOT" ] && PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -z "$PROJECT_ROOT" ] && exit 0
[ -d "$PROJECT_ROOT" ] || exit 0

# Collect unresolved or invalid feature journals with a bounded search.
FOUND=""
INVALID=""
while IFS= read -r f; do
  [ -f "$f" ] || continue
  rel="${f#$PROJECT_ROOT/}"
  if ! STATE="$(python3 "$SCRIPT_DIR/../scripts/wiki_candidate_journal.py" validate --journal "$f" 2>/dev/null)"; then
    INVALID="${INVALID:+$INVALID, }$rel"
    continue
  fi
  UNRESOLVED="$(printf '%s' "$STATE" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(d["counts"]["pending"] + d["counts"]["deferred"])
' 2>/dev/null || printf '0')"
  if [ "${UNRESOLVED:-0}" -gt 0 ] 2>/dev/null; then
    FOUND="${FOUND:+$FOUND, }$rel"
  fi
done < <(find "$PROJECT_ROOT" -maxdepth 4 -name '*.wiki-candidates.jsonl' -not -path '*/.git/*' -type f 2>/dev/null)

[ -n "$FOUND$INVALID" ] || exit 0

if [ -n "$INVALID" ]; then
  MSG="grill-adapter: invalid candidate journal(s): $INVALID. Capture must fail closed; run /candidate-journal validate and repair the producing workflow without hand-editing the append-only journal."
else
  MSG="grill-adapter: durable-knowledge candidates are still pending or deferred in: $FOUND. Before finishing this work, run /update-wiki to make and journal the keep-or-skip determination."
fi

# Non-blocking: surface as a systemMessage (shown to the user) and on stderr. Never block Stop.
python3 - "$MSG" <<'PY' 2>/dev/null || printf '%s\n' "$MSG" >&2
import json, sys
print(json.dumps({"systemMessage": sys.argv[1]}))
PY
exit 0
