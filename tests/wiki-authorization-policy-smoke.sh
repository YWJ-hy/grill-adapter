#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TARGET_INPUT="${1:-${ROOT}}"
TARGET_DIR="$(cd "${TARGET_INPUT}" && pwd)"
TMP_PROJECT="$(mktemp -d)"
trap 'rm -rf "${TMP_PROJECT}"' EXIT

mkdir -p "${TMP_PROJECT}/.adapter/wiki" "${TMP_PROJECT}/.shared-adapter/wiki"
cat > "${TMP_PROJECT}/.adapter/wiki/index.md" <<'MD'
# Project Wiki

<!-- grill-adapter:auto:start -->
- `existing.md`
<!-- grill-adapter:auto:end -->
MD
cat > "${TMP_PROJECT}/.adapter/wiki/existing.md" <<'MD'
# Existing

Existing detail.
MD
cat > "${TMP_PROJECT}/.shared-adapter/wiki/index.md" <<'MD'
# Shared Wiki

<!-- grill-adapter:auto:start -->
<!-- grill-adapter:auto:end -->
MD

(cd "${TMP_PROJECT}" && python3 "${TARGET_DIR}/scripts/wiki_apply_update.py" existing.md Existing "Update existing without settings." "Existing updates default to skip")

if (cd "${TMP_PROJECT}" && python3 "${TARGET_DIR}/scripts/wiki_apply_update.py" new-default.md NewDefault "Create without approval." "Should fail"); then
  printf 'Expected default create policy to require authorization\n' >&2
  exit 1
fi
(cd "${TMP_PROJECT}" && python3 "${TARGET_DIR}/scripts/wiki_apply_update.py" --authorized-create new-default.md NewDefault "Create with approval." "Authorized creates succeed")

cat > "${TMP_PROJECT}/.adapter/settings.json" <<'JSON'
{
  "wiki": {
    "updateAuthorization": {
      "updateExistingPage": "ask",
      "createNewDocument": "ask"
    }
  }
}
JSON
if (cd "${TMP_PROJECT}" && python3 "${TARGET_DIR}/scripts/wiki_apply_update.py" existing.md ExistingAsk "Update without approval." "Should fail"); then
  printf 'Expected updateExistingPage=ask to require authorization\n' >&2
  exit 1
fi
(cd "${TMP_PROJECT}" && python3 "${TARGET_DIR}/scripts/wiki_apply_update.py" --authorized-update existing.md ExistingAsk "Update with approval." "Authorized updates succeed")

cat > "${TMP_PROJECT}/.adapter/settings.json" <<'JSON'
{
  "wiki": {
    "updateAuthorization": {
      "createNewDocument": "refuse"
    }
  }
}
JSON
if (cd "${TMP_PROJECT}" && python3 "${TARGET_DIR}/scripts/wiki_apply_update.py" --authorized-create refused.md Refused "Create refused." "Should fail"); then
  printf 'Expected createNewDocument=refuse to reject even with authorization\n' >&2
  exit 1
fi

cat > "${TMP_PROJECT}/.shared-adapter/settings.json" <<'JSON'
{
  "wiki": {
    "updateAuthorization": {
      "createNewDocument": "skip"
    }
  }
}
JSON
if (cd "${TMP_PROJECT}" && python3 "${TARGET_DIR}/scripts/wiki_apply_update.py" --wiki-root project --authorized-create project-refused.md ProjectRefused "Project refused." "Should fail"); then
  printf 'Expected project create refusal to stay root-specific\n' >&2
  exit 1
fi
(cd "${TMP_PROJECT}" && python3 "${TARGET_DIR}/scripts/wiki_apply_update.py" --wiki-root shared shared-allowed.md SharedAllowed "Shared allowed." "Shared create skip policy succeeds")
if [[ -e "${TMP_PROJECT}/.adapter/wiki/shared-allowed.md" ]]; then
  printf 'Expected shared policy write not to touch project wiki\n' >&2
  exit 1
fi

mkdir -p "${TMP_PROJECT}/source"
printf '# Imported\n\nImported detail.\n' > "${TMP_PROJECT}/source/imported.md"
cat > "${TMP_PROJECT}/.adapter/settings.json" <<'JSON'
{
  "wiki": {
    "updateAuthorization": {
      "createNewDocument": "ask"
    }
  }
}
JSON
if (cd "${TMP_PROJECT}" && python3 "${TARGET_DIR}/scripts/wiki_import.py" source --target imported-policy --merge-existing); then
  printf 'Expected wiki_import.py to require create authorization\n' >&2
  exit 1
fi
(cd "${TMP_PROJECT}" && python3 "${TARGET_DIR}/scripts/wiki_import.py" source --target imported-policy --merge-existing --authorized-create)
printf '# Imported\n\nDifferent detail.\n' > "${TMP_PROJECT}/source/imported.md"
if (cd "${TMP_PROJECT}" && python3 "${TARGET_DIR}/scripts/wiki_import.py" source --target imported-policy --merge-existing --authorized-create); then
  printf 'Expected wiki_import.py to keep refusing conflicting content\n' >&2
  exit 1
fi

cat > "${TMP_PROJECT}/.adapter/settings.json" <<'JSON'
{
  "wiki": {
    "updateAuthorization": {
      "updateExistingPage": "ask",
      "createNewDocument": "skip"
    }
  }
}
JSON
cat > "${TMP_PROJECT}/.adapter/wiki/summary-target.md" <<'MD'
# Summary Target

New summary text.
MD
cat > "${TMP_PROJECT}/.adapter/wiki/index.md" <<'MD'
# Project Wiki

<!-- grill-adapter:auto:start -->
- `summary-target.md` — Old summary text.
<!-- grill-adapter:auto:end -->
MD
if (cd "${TMP_PROJECT}" && python3 "${TARGET_DIR}/scripts/update-wiki.py" --wiki-root project); then
  printf 'Expected update-wiki.py to require update authorization for changed indexes\n' >&2
  exit 1
fi
(cd "${TMP_PROJECT}" && python3 "${TARGET_DIR}/scripts/update-wiki.py" --wiki-root project --authorized-update)
if ! grep -Fq 'New summary text.' "${TMP_PROJECT}/.adapter/wiki/index.md"; then
  printf 'Expected authorized index refresh to update summary\n' >&2
  exit 1
fi

# Regression: a section-ized page whose title is immediately followed by a wiki-section
# marker (no prose paragraph) must NOT degrade its auto-block summary to the first
# '## subheading'. The extractor should skip the heading and reach the real prose.
cat > "${TMP_PROJECT}/.adapter/wiki/section-page.md" <<'MD'
# Section Page

<!-- wiki-section:demo -->
## 子标题
真实说明段落。
<!-- /wiki-section:demo -->
MD
cat > "${TMP_PROJECT}/.adapter/wiki/index.md" <<'MD'
# Project Wiki

<!-- grill-adapter:auto:start -->
- `section-page.md` — stale
<!-- grill-adapter:auto:end -->
MD
(cd "${TMP_PROJECT}" && python3 "${TARGET_DIR}/scripts/update-wiki.py" --wiki-root project --authorized-update)
if grep -Fq '## 子标题' "${TMP_PROJECT}/.adapter/wiki/index.md"; then
  printf 'Regression: section-ized page summary degraded to a raw ## subheading\n' >&2
  cat "${TMP_PROJECT}/.adapter/wiki/index.md" >&2
  exit 1
fi
if ! grep -Fq '真实说明段落。' "${TMP_PROJECT}/.adapter/wiki/index.md"; then
  printf 'Expected section-ized page summary to reach the real prose paragraph\n' >&2
  cat "${TMP_PROJECT}/.adapter/wiki/index.md" >&2
  exit 1
fi

cat > "${TMP_PROJECT}/.shared-adapter/settings.json" <<'JSON'
{
  "wiki": {
    "legacyRuntime": {
      "mode": "read-only-archive",
      "roots": [".adapter/wiki", ".shared-adapter/wiki"],
      "migrationManifest": ".adapter/context/example.obsidian-migration.json"
    }
  }
}
JSON
if (cd "${TMP_PROJECT}" && python3 "${TARGET_DIR}/scripts/wiki_apply_update.py" --authorized-update existing.md Archived "Archived update." "Must fail"); then
  printf 'Expected wiki_apply_update.py to reject an archived legacy root\n' >&2
  exit 1
fi
if (cd "${TMP_PROJECT}" && python3 "${TARGET_DIR}/scripts/wiki_import.py" source --target archived-import --authorized-create); then
  printf 'Expected wiki_import.py to reject an archived legacy root\n' >&2
  exit 1
fi
if python3 "${TARGET_DIR}/scripts/wiki_migrate_helper.py" --generate-indexes "${TMP_PROJECT}" --wiki-root project; then
  printf 'Expected migrate-wiki write modes to reject an archived legacy root\n' >&2
  exit 1
fi

printf 'wiki authorization policy smoke test complete\n'
