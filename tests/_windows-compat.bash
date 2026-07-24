# Shared helpers for smoke scripts running under Git Bash on Windows.
portable_tmpdir() {
  local path
  path="$(mktemp -d)"
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -m "$path"
  else
    printf '%s\n' "$path"
  fi
}

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    python3 - "$1" <<'PY'
import hashlib
import sys
with open(sys.argv[1], "rb") as handle:
    print(hashlib.sha256(handle.read()).hexdigest())
PY
  fi
}

sha256_tree() {
  python3 - "$1" <<'PY'
import hashlib
import sys
from pathlib import Path

root = Path(sys.argv[1])
for path in sorted(item for item in root.rglob("*") if item.is_file()):
    print(f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path}")
PY
}
