#!/usr/bin/env bash
# grill-adapter — SessionStart Bind reminder.
#
# Per-ticket Bind has trustworthy task identity; this SessionStart backstop does not. For schema-v6
# it only reports approved snapshots that have not yet received a readiness result. It never reads
# task snapshot content or falls back to live Wiki materialization.
set -uo pipefail

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

# Find the active sidecar in the canonical feature-directory layout. A project may carry
# several features' sidecars at once, so the newest wins. The bounded fallback applies the
# same ordering rather than taking an arbitrary find result.
SIDECAR=""
for f in \
  "$PROJECT_ROOT"/.grill-adapter/context/*/wiki-context.json \
  "$PROJECT_ROOT"/.grill-adapter/context/*.wiki-context.json; do
  [ -f "$f" ] || continue
  if [ -z "$SIDECAR" ] || [ "$f" -nt "$SIDECAR" ]; then SIDECAR="$f"; fi
done
if [ -z "$SIDECAR" ]; then
  # Fall back to a bounded search so a non-standard layout still binds.
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    if [ -z "$SIDECAR" ] || [ "$f" -nt "$SIDECAR" ]; then SIDECAR="$f"; fi
  done < <(find "$PROJECT_ROOT" -maxdepth 4 -type f -not -path '*/.git/*' \
    \( -name 'wiki-context.json' -o -name '*.wiki-context.json' \) 2>/dev/null)
fi
[ -n "$SIDECAR" ] || exit 0

SIDECAR_SCHEMA=""
LEGACY_SIDECAR=""
PENDING_TASKS=""
eval "$(python3 - "$SIDECAR" <<'PY' 2>/dev/null || true
import json
import os
import shlex
import sys
from pathlib import Path


def emit(name, value):
    print(f"{name}=" + shlex.quote(value))


sidecar = Path(sys.argv[1])
try:
    context = json.loads(sidecar.read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError):
    raise SystemExit(0)

schema = context.get("schemaVersion")
emit("SIDECAR_SCHEMA", str(schema) if schema is not None else "")
# Existing flat sidecars remain a recovery path. They do not have feature-local roster/readiness
# state, so retain the legacy reminder rather than treating them as planning-only schema-v6 state.
if sidecar.name != "wiki-context.json":
    emit("LEGACY_SIDECAR", "1")
    raise SystemExit(0)
if schema != 6:
    raise SystemExit(0)

# A planning-only sidecar must not create a SessionStart reminder. Only a task with both
# approved role snapshots and no prior readiness result needs an explicit implementation Bind.
directory = sidecar.parent
roster_path = directory / "ticket-roster.json"
try:
    roster = json.loads(roster_path.read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError):
    raise SystemExit(0)
if roster.get("featureSlug") != context.get("featureSlug"):
    raise SystemExit(0)
tickets = roster.get("tickets")
if not isinstance(tickets, list):
    raise SystemExit(0)

handled = set()
receipt_path = directory / "wiki-readiness.json"
if receipt_path.is_file():
    try:
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        # A malformed receipt is not safe to interpret as a reason to re-inject Wiki context.
        raise SystemExit(0)
    if (
        receipt.get("schemaVersion") != 1
        or receipt.get("kind") != "grill-adapter.wiki-readiness"
        or receipt.get("featureSlug") != roster.get("featureSlug")
        or receipt.get("ticketSource") != roster.get("ticketSource")
        or receipt.get("rosterFile") != roster_path.name
        or not isinstance(receipt.get("tasks"), list)
    ):
        raise SystemExit(0)
    for task in receipt["tasks"]:
        if isinstance(task, dict) and isinstance(task.get("taskId"), str) and task.get("status") in {
            "ready", "no-relevant", "disabled", "broken"
        }:
            handled.add(task["taskId"])

pending = []
for ticket in tickets:
    if not isinstance(ticket, dict):
        continue
    task_id = ticket.get("taskId")
    if not isinstance(task_id, str) or not task_id.strip():
        continue
    task_id = task_id.strip()
    if task_id in {".", ".."} or Path(task_id).name != task_id or "/" in task_id or "\\" in task_id:
        continue
    if task_id in handled:
        continue
    required = (
        directory / f"{task_id}.wiki-implement.md",
        directory / f"{task_id}.wiki-review.md",
        directory / f"{task_id}.wiki-approval.json",
    )
    if all(path.is_file() for path in required):
        pending.append(task_id)

emit("PENDING_TASKS", ", ".join(pending))
PY
)"
SIDECAR_SCHEMA="${SIDECAR_SCHEMA:-}"
LEGACY_SIDECAR="${LEGACY_SIDECAR:-}"
PENDING_TASKS="${PENDING_TASKS:-}"

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

# This hook intentionally does not discover a current ticket or consume constraints. A ticket marker
# is only a host hint and cannot establish that the current prompt is acting on that ticket.
REL_SIDECAR="${SIDECAR#$PROJECT_ROOT/}"
if [ "$SIDECAR_SCHEMA" = "6" ] && [ "$LEGACY_SIDECAR" != "1" ]; then
  [ -n "$PENDING_TASKS" ] || exit 0
  emit "Approved Wiki task snapshot(s) await their first readiness Bind in \`$REL_SIDECAR\`: \`$PENDING_TASKS\`. When the current ticket enters implementation, use the normal \`grill-adapter:wiki-readiness\` step; it validates and consumes the frozen implementer Markdown. Do not run a separate materialization solely because of this SessionStart reminder."
else
  emit "Active wiki constraints detected in \`$REL_SIDECAR\`. Before implementing or reviewing each ticket, run \`/grill-adapter:wiki-materialize <ticket-id>\` to consume the role-specific task contract."
fi
exit 0
