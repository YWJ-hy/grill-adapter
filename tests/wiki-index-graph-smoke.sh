#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TARGET_INPUT="${1:-${ROOT}}"
PROJECT_ROOT="${2:-${ROOT}/..}"
WIKI_ROOT="${PROJECT_ROOT}/.superpowers/wiki"
SHARED_WIKI_ROOT="${PROJECT_ROOT}/.shared-superpowers/wiki"

mkdir -p "${WIKI_ROOT}/platform/api" "${WIKI_ROOT}/guides" "${WIKI_ROOT}/shared/deep" "${WIKI_ROOT}/unindexed"
mkdir -p "${SHARED_WIKI_ROOT}/platform/shared" "${SHARED_WIKI_ROOT}/unindexed"
cat > "${WIKI_ROOT}/index.md" <<'EOF'
# Project Wiki

<!-- grill-adapter:auto:start -->
- `platform/api/contract.md`
- `guides/`
- `shared/deep/rule.md`
<!-- grill-adapter:auto:end -->
EOF
cat > "${WIKI_ROOT}/guides/index.md" <<'EOF'
# Guides

<!-- grill-adapter:auto:start -->
- `debugging.md`
<!-- grill-adapter:auto:end -->
EOF
printf '# API Contract\n\nContract behavior.\n' > "${WIKI_ROOT}/platform/api/contract.md"
printf '# Debugging\n\nDebugging behavior.\n' > "${WIKI_ROOT}/guides/debugging.md"
printf '# Deep Rule\n\nDeep indexed behavior.\n' > "${WIKI_ROOT}/shared/deep/rule.md"
printf '# Secret\n\nUnindexed behavior.\n' > "${WIKI_ROOT}/unindexed/secret.md"
cat > "${SHARED_WIKI_ROOT}/index.md" <<'EOF'
# Shared Wiki

<!-- grill-adapter:auto:start -->
- `platform/shared/conventions.md`
<!-- grill-adapter:auto:end -->
EOF
printf '# Shared Conventions\n\nShared behavior.\n' > "${SHARED_WIKI_ROOT}/platform/shared/conventions.md"
printf '# Shared Secret\n\nUnindexed shared behavior.\n' > "${SHARED_WIKI_ROOT}/unindexed/secret.md"

tree_output="$(cd "${PROJECT_ROOT}" && python3 "${TARGET_INPUT}/scripts/wiki-context.py" --tree --depth 5)"
for expected in "Wiki root: \`.superpowers/wiki/\`" "Wiki root: \`.shared-superpowers/wiki/\`" ".superpowers/wiki/platform/api/contract.md" ".superpowers/wiki/guides/index.md" ".superpowers/wiki/guides/debugging.md" ".superpowers/wiki/shared/deep/rule.md" ".shared-superpowers/wiki/platform/shared/conventions.md"; do
  case "${tree_output}" in
    *"${expected}"*) : ;;
    *) printf 'Expected index-driven tree to include %s\n%s\n' "${expected}" "${tree_output}" >&2; exit 1 ;;
  esac
done
case "${tree_output}" in
  *"unindexed/secret.md"*) printf 'Expected tree to exclude unindexed file\n' >&2; exit 1 ;;
  *) : ;;
esac

shared_file_output="$(cd "${PROJECT_ROOT}" && python3 "${TARGET_INPUT}/scripts/wiki-context.py" --file .shared-superpowers/wiki/platform/shared/conventions.md)"
case "${shared_file_output}" in
  *"Shared behavior."*) : ;;
  *) printf 'Expected root-prefixed shared file read to work\n%s\n' "${shared_file_output}" >&2; exit 1 ;;
esac

cat > "${WIKI_ROOT}/index.md" <<'EOF'
# Project Wiki

<!-- grill-adapter:auto:start -->
- `frontend/`
<!-- grill-adapter:auto:end -->
EOF
mkdir -p "${WIKI_ROOT}/frontend/examples"
cat > "${WIKI_ROOT}/frontend/index.md" <<'EOF'
# Frontend Wiki

<!-- grill-adapter:auto:start -->
- `component-guidelines.md`
- `hook-guidelines.md`
- `type-safety.md`
- `examples/`
<!-- grill-adapter:auto:end -->
EOF
cat > "${WIKI_ROOT}/frontend/examples/index.md" <<'EOF'
# Examples

Use this index to navigate the wiki pages in this section.
EOF
printf '# Component Guidelines\n\nReusable Vue component props, emits, upload UI, and directory composition.\n' > "${WIKI_ROOT}/frontend/component-guidelines.md"
printf '# Hook Guidelines\n\nReusable useUpload composables and hook extraction patterns.\n' > "${WIKI_ROOT}/frontend/hook-guidelines.md"
printf '# Type Safety\n\nTypeScript contracts and Naive UI component declarations.\n' > "${WIKI_ROOT}/frontend/type-safety.md"
printf '# Example\n\nIgnored example content.\n' > "${WIKI_ROOT}/frontend/examples/example.md"
component_tree_output="$(cd "${PROJECT_ROOT}" && python3 "${TARGET_INPUT}/scripts/wiki-context.py" --tree --depth 4)"
for expected in ".superpowers/wiki/frontend/component-guidelines.md" ".superpowers/wiki/frontend/hook-guidelines.md" ".superpowers/wiki/frontend/type-safety.md"; do
  case "${component_tree_output}" in
    *"${expected}"*) : ;;
    *) printf 'Expected component tree to include %s\n%s\n' "${expected}" "${component_tree_output}" >&2; exit 1 ;;
  esac
done
case "${component_tree_output}" in
  *"frontend/examples/example.md"*) printf 'Expected tree to exclude ignored examples leaf\n' >&2; exit 1 ;;
  *) : ;;
esac

printf 'wiki-index-graph smoke test complete\n'
