#!/usr/bin/env bash
# grill-adapter — SessionStart Bind reminder.
#
# Per-ticket `/wiki-materialize <ticket>` is the only execution-time reread path. Hooks have no
# trustworthy ticket identity, so this SessionStart backstop only reports an active sidecar and
# reminds the session to run the explicit command. It never reads Note content or falls back to
# the filesystem. Scripts are resolved relative to this file's payload location.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$SELF_DIR/../scripts"

INPUT="$(cat 2>/dev/null || true)"

# Extract cwd + event name from the event JSON (passed via env so the heredoc can carry the
# program on stdin — piping INPUT to `python3 - <<PY` would make json.load read the program).
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
[ "$HOOK_EVENT" = "SessionStart" ] || exit 0

# Resolve project root: CLAUDE_PROJECT_DIR (Claude Code injects it) > event cwd > git toplevel.
PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-}"
[ -z "$PROJECT_ROOT" ] && PROJECT_ROOT="$HOOK_CWD"
[ -z "$PROJECT_ROOT" ] && PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -z "$PROJECT_ROOT" ] && exit 0
[ -d "$PROJECT_ROOT" ] || exit 0

# Find the active sidecar in the canonical location. A project may carry several features'
# sidecars at once, so the newest wins -- this hook is a coarse session-level guess, and the
# precise path is the per-ticket /wiki-materialize call.
SIDECAR=""
for f in "$PROJECT_ROOT"/.adapter/context/*.wiki-context.json; do
  [ -f "$f" ] || continue
  if [ -z "$SIDECAR" ] || [ "$f" -nt "$SIDECAR" ]; then SIDECAR="$f"; fi
done
if [ -z "$SIDECAR" ]; then
  # Fall back to a bounded search so a non-standard layout still binds.
  SIDECAR="$(find "$PROJECT_ROOT" -maxdepth 4 -name '*.wiki-context.json' -not -path '*/.git/*' -type f 2>/dev/null | head -1)"
fi
[ -n "$SIDECAR" ] || exit 0

SIDECAR_SCHEMA="$(python3 - "$SIDECAR" <<'PY' 2>/dev/null || true
import json, sys
try:
    print(json.load(open(sys.argv[1], encoding='utf-8')).get('schemaVersion', ''))
except Exception:
    pass
PY
)"

emit() {
  # $1 = additionalContext text. Emitted as UserPromptSubmit/SessionStart context.
  python3 - "$HOOK_EVENT" "$1" <<'PY' 2>/dev/null || true
import json, sys
event = sys.argv[1] or "UserPromptSubmit"
text = sys.argv[2]
print(json.dumps({"hookSpecificOutput": {
    "hookEventName": event,
    "additionalContext": text,
}}))
PY
}

# This hook intentionally does not discover a ticket or materialize constraints. A ticket marker
# is only a host hint and cannot establish that the current prompt is acting on that ticket.
REL_SIDECAR="${SIDECAR#$PROJECT_ROOT/}"
if [ "$SIDECAR_SCHEMA" = "6" ]; then
  emit "Active Obsidian Wiki binding detected in \`$REL_SIDECAR\`. Before implementing or reviewing each ticket, run \`/grill-adapter:wiki-materialize <ticket-id>\` to reread the authoritative routed Notes and required Skill Cards."
else
  emit "Active wiki constraints detected in \`$REL_SIDECAR\`. Before implementing or reviewing each ticket, run \`/grill-adapter:wiki-materialize <ticket-id>\` to reread the authoritative hard-constraint sections."
fi
exit 0
