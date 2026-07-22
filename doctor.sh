#!/usr/bin/env bash
# grill-adapter doctor — diagnose install and the active Wiki runtime for a project.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${1:-}"
if [[ -z "$PROJECT_ROOT" ]]; then
  printf 'Usage: %s <project-root>\n' "$0" >&2
  exit 1
fi

if [[ ! -d "$PROJECT_ROOT" ]]; then
  printf 'project root is not a directory: %s\n' "$PROJECT_ROOT" >&2
  exit 1
fi
PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd)" || exit 1
doctor_fail=0

echo "grill-adapter doctor"
echo "===================="
python3 "$SCRIPT_DIR/lib/install.py" status "$PROJECT_ROOT" || true
echo ""
echo "shared-wiki binding (per-project, .shared-adapter/settings.json -> wiki.sharedMcp):"
python3 - "$PROJECT_ROOT" <<'PY'
import json, sys
from pathlib import Path

root = Path(sys.argv[1])
settings = root / ".shared-adapter" / "settings.json"
if not settings.is_file():
    print("  no .shared-adapter/settings.json — no MCP shared wiki (fail-closed).")
    raise SystemExit(0)
try:
    data = json.loads(settings.read_text(encoding="utf-8"))
except Exception as exc:
    print(f"  settings.json is invalid JSON: {exc}")
    raise SystemExit(0)
shared = (data.get("wiki", {}) or {}).get("sharedMcp", {}) or {}
if not shared:
    print("  wiki.sharedMcp not declared — no MCP shared wiki (fail-closed).")
    raise SystemExit(0)
repo = shared.get("repoUrl")
if not repo:
    print("  wiki.sharedMcp declared WITHOUT repoUrl — server will fail closed. Add repoUrl or remove the block.")
    raise SystemExit(0)
print(f"  repoUrl:      {repo}")
print(f"  baseBranch:   {shared.get('baseBranch', '(default)')}")
print(f"  remote:       {shared.get('remote', '(default)')}")
print(f"  wikiRoot:     {shared.get('wikiRoot', '(repo root)')}")
print(f"  displayRoot:  {shared.get('displayRoot', '(default)')}")
print(f"  draftPr:      {shared.get('draftPr', False)}")
print("  binding OK.")
PY

echo ""
echo "Wiki runtime adoption:"
provider="$(python3 - "$PROJECT_ROOT" <<'PY'
import json
import sys
from pathlib import Path

settings_path = Path(sys.argv[1]) / ".shared-adapter" / "settings.json"
if not settings_path.is_file():
    print("legacy")
    raise SystemExit(0)
try:
    settings = json.loads(settings_path.read_text(encoding="utf-8"))
except Exception as exc:
    print(f"invalid .shared-adapter/settings.json: {exc}", file=sys.stderr)
    raise SystemExit(1)
if not isinstance(settings, dict):
    print("invalid .shared-adapter/settings.json: root must be an object", file=sys.stderr)
    raise SystemExit(1)
wiki = settings.get("wiki") or {}
if not isinstance(wiki, dict):
    print("invalid .shared-adapter/settings.json: wiki must be an object", file=sys.stderr)
    raise SystemExit(1)
provider = wiki.get("provider") or "legacy"
if provider not in {"legacy", "obsidian"}:
    print(f"unsupported wiki.provider: {provider}", file=sys.stderr)
    raise SystemExit(1)
print(provider)
PY
)" || {
  provider="invalid"
  doctor_fail=1
}
echo "  provider: $provider"

if [[ "$provider" == "obsidian" ]]; then
  adoption_report="$(python3 - "$PROJECT_ROOT" "$SCRIPT_DIR/scripts/wiki_migration_apply.py" <<'PY'
import json
import subprocess
import sys
from pathlib import Path

try:
    root = Path(sys.argv[1]).resolve()
    migrator = Path(sys.argv[2]).resolve()
    settings = json.loads((root / ".shared-adapter" / "settings.json").read_text(encoding="utf-8"))
    legacy = ((settings.get("wiki") or {}).get("legacyRuntime") or {})
    if not isinstance(legacy, dict):
        raise ValueError("wiki.legacyRuntime must be an object")
    archive_roots = []
    if legacy:
        if legacy.get("mode") != "read-only-archive":
            raise ValueError("wiki.legacyRuntime.mode must be read-only-archive")
        archive_roots = legacy.get("roots")
        allowed_roots = {".adapter/wiki", ".shared-adapter/wiki"}
        if not isinstance(archive_roots, list) or any(item not in allowed_roots for item in archive_roots):
            raise ValueError("wiki.legacyRuntime.roots contains an unsupported legacy archive root")
        manifest_ref = legacy.get("migrationManifest")
        if not isinstance(manifest_ref, str) or not manifest_ref:
            raise ValueError("wiki.legacyRuntime.migrationManifest must be a project-relative path")
        manifest_path = (root / manifest_ref).resolve()
        try:
            manifest_path.relative_to(root)
        except ValueError as exc:
            raise ValueError("wiki.legacyRuntime.migrationManifest escapes the project") from exc
        if not manifest_path.is_file():
            raise ValueError(f"migrationManifest does not exist: {manifest_ref}")
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        cutover = manifest.get("cutover")
        if manifest.get("state") != "cutover" or not isinstance(cutover, dict):
            raise ValueError("migrationManifest is not a completed Obsidian migration cutover receipt")
        if cutover.get("settingsPath") != ".shared-adapter/settings.json" or cutover.get("legacyRuntime") != legacy:
            raise ValueError("migrationManifest cutover receipt does not match wiki.legacyRuntime")
        verification = subprocess.run(
            [sys.executable, str(migrator), "verify", "--project-root", str(root), "--manifest", str(manifest_path)],
            capture_output=True,
            text=True,
        )
        if verification.returncode != 0:
            detail = verification.stderr.strip() or verification.stdout.strip() or "unknown verification error"
            raise ValueError(f"migration verify failed: {detail}")
        print("  adoptionState: cutover-complete")
        if archive_roots:
            print(f"  read-only legacy archives: {', '.join(archive_roots)}")
    elif (root / ".adapter" / "wiki").exists() or (root / ".shared-adapter" / "wiki").exists():
        print("  adoptionState: shadow-validation")
        print("  legacy roots remain unchanged until migration verify and explicit cutover")
    else:
        print("  adoptionState: obsidian-native")
    print("  legacy runtime fallback: disabled")
except Exception as exc:
    print(f"  adoption error: {exc}", file=sys.stderr)
    raise SystemExit(1)
PY
)" || {
    adoption_report="  adoptionState: invalid"
    doctor_fail=1
  }
  printf '%s\n' "$adoption_report"

  echo ""
  echo "Obsidian Wiki Source runtime (binding/read/write-bridge diagnostic):"
  if [[ -f "$SCRIPT_DIR/mcp/obsidian-wiki/dist/index.js" ]] && command -v node >/dev/null 2>&1; then
    status_output="$(CLAUDE_PROJECT_DIR="$PROJECT_ROOT" node "$SCRIPT_DIR/mcp/obsidian-wiki/dist/index.js" status 2>&1)"
    status_exit=$?
    if [[ $status_exit -ne 0 ]]; then
      printf '  Obsidian runtime healthy: no\n'
      printf '  bundle error: %s\n' "$status_output"
      doctor_fail=1
    elif ! printf '%s\n' "$status_output" | python3 -c '
import json, sys
try:
    status = json.load(sys.stdin)
except Exception as exc:
    print(f"  Obsidian runtime healthy: no\n  invalid status response: {exc}")
    raise SystemExit(1)
healthy = status.get("healthy") is True
health_text = "yes" if healthy else "no"
print(f"  Obsidian runtime healthy: {health_text}")
print("  resolved bindings: {}".format(len(status.get("bindings") or [])))
for warning in status.get("warnings") or []:
    print(f"  warning: {warning}")
for error in status.get("errors") or []:
    print(f"  error: {error}")
raise SystemExit(0 if healthy else 1)
'; then
      doctor_fail=1
    fi
  else
    echo "  Obsidian runtime healthy: no"
    echo "  unavailable: obsidian-wiki bundle or node is missing."
    doctor_fail=1
  fi
else
  echo "  adoptionState: legacy"
  echo "  Obsidian validation: inactive (set wiki.provider to obsidian to adopt it)"
fi

exit "$doctor_fail"
