#!/usr/bin/env bash
# grill-adapter — Capture backstop hook (Stop).
#
# Non-blocking reminder to run /update-wiki when durable knowledge was captured but not
# yet processed. The precise Capture path is the convention "after /code-review, run
# /update-wiki"; this hook is only the backstop for a skipped step (blueprint §11).
#
# Trigger = a non-empty `.wiki-candidates.jsonl` sidecar. That file is transient scratch
# that /update-wiki consumes and removes, so its presence is a self-limiting signal
# (once update-wiki runs, the reminder stops) — it cannot nag on every Stop.
set -uo pipefail

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

# Collect non-empty candidate sidecars (common plan locations + a bounded search).
FOUND=""
while IFS= read -r f; do
  [ -f "$f" ] || continue
  if [ -s "$f" ] && grep -q '[^[:space:]]' "$f" 2>/dev/null; then
    rel="${f#$PROJECT_ROOT/}"
    FOUND="${FOUND:+$FOUND, }$rel"
  fi
done < <(find "$PROJECT_ROOT" -maxdepth 4 -name '*.wiki-candidates.jsonl' -not -path '*/.git/*' -type f 2>/dev/null)

[ -n "$FOUND" ] || exit 0

MSG="grill-adapter: durable-knowledge candidates are still pending in: $FOUND. Before finishing this work, run /update-wiki to make the keep-or-skip determination (it applies the durable gate and consumes the candidates). Skipping is a valid outcome, but only as update-wiki's own conclusion."

# Non-blocking: surface as a systemMessage (shown to the user) and on stderr. Never block Stop.
python3 - "$MSG" <<'PY' 2>/dev/null || printf '%s\n' "$MSG" >&2
import json, sys
print(json.dumps({"systemMessage": sys.argv[1]}))
PY
exit 0
