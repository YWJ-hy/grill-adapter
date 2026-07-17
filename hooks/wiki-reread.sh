#!/usr/bin/env bash
# grill-adapter — Bind backstop hook (UserPromptSubmit / SessionStart).
#
# Coarse, session-level companion to the precise per-ticket `/wiki-materialize <ticket>`
# path. Claude Code hooks have no native "current ticket" field, so this hook:
#   1. detects an active `.wiki-context.json` sidecar in the project,
#   2. resolves a ticket if one is discoverable (GRILL_CURRENT_TICKET env, or a
#      `.adapter/current-ticket` marker file), and
#   3. injects hard wiki constraints via hookSpecificOutput.additionalContext:
#        - ticket known  -> full materialized rereads for that task (the fixed fetcher),
#        - ticket unknown -> the reread-list summary + a nudge to run /wiki-materialize.
#
# It never fails the session: on any error it degrades to a short caveat. Scripts are
# resolved relative to this file's payload location, so no install-time path surgery.
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

# Resolve a ticket if discoverable (marker/env — blueprint §14 option 2).
TICKET="${GRILL_CURRENT_TICKET:-}"
if [ -z "$TICKET" ] && [ -f "$PROJECT_ROOT/.adapter/current-ticket" ]; then
  TICKET="$(tr -d ' \t\r\n' < "$PROJECT_ROOT/.adapter/current-ticket" 2>/dev/null || true)"
fi

REL_SIDECAR="${SIDECAR#$PROJECT_ROOT/}"

if [ -n "$TICKET" ]; then
  OUT="$(python3 "$SCRIPTS_DIR/wiki_materialize_task.py" "$SIDECAR" --task-id "$TICKET" \
          --role implementer --project-root "$PROJECT_ROOT" --strict --execution-ready 2>/dev/null)"
  if [ $? -eq 0 ] && [ -n "$OUT" ]; then
    emit "## Hard Wiki Constraint Rereads (auto-materialized for ticket $TICKET)

$OUT"
    exit 0
  fi
  emit "Active wiki constraints detected in \`$REL_SIDECAR\` for ticket $TICKET, but auto-materialize could not complete (possible shared-wiki drift or not execution-ready). Run \`/wiki-materialize $TICKET\` explicitly and resolve any reported drift before implementing."
  exit 0
fi

# No ticket resolvable: surface that constraints exist + the reread summary, and nudge the precise path.
SUMMARY="$(python3 "$SCRIPTS_DIR/wiki_context_render.py" "$SIDECAR" --reread-list --strict 2>/dev/null)"
if [ -n "$SUMMARY" ]; then
  emit "Active wiki constraints detected in \`$REL_SIDECAR\`. Before implementing each ticket, run \`/wiki-materialize <ticket-id>\` to reread the authoritative hard-constraint sections (this session-level hook cannot resolve the current ticket by itself). Selected hard-constraint sections:

$SUMMARY"
fi
exit 0
