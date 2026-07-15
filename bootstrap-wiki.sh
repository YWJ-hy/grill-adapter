#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_ROOT="$SCRIPT_DIR/wiki-template"
SHARED_TEMPLATE_ROOT="$SCRIPT_DIR/shared-superpowers-template"
TEMPLATE_NAME=""
WIKI_ROOT_NAME="project"
WIKI_ROOT_REL=".superpowers/wiki"

usage() {
  printf 'Usage: %s <project-root> [--template name] [--wiki-root project|shared]\n' "$0" >&2
  exit 1
}

if [[ $# -lt 1 || -z "${1:-}" ]]; then
  printf 'Missing required project root.\n' >&2
  usage
fi

REPO_ROOT="$(cd "$1" && pwd)"
shift

while [[ $# -gt 0 ]]; do
  case "$1" in
    --template)
      TEMPLATE_NAME="${2:-}"
      shift 2
      ;;
    --wiki-root)
      WIKI_ROOT_NAME="${2:-}"
      shift 2
      ;;
    *)
      printf 'Unknown argument: %s\n' "$1" >&2
      usage
      ;;
  esac
done

case "$WIKI_ROOT_NAME" in
  project)
    WIKI_ROOT_REL=".superpowers/wiki"
    ;;
  shared)
    WIKI_ROOT_REL=".shared-superpowers/wiki"
    ;;
  *)
    printf 'Invalid --wiki-root: %s\n' "$WIKI_ROOT_NAME" >&2
    usage
    ;;
esac

WIKI_ROOT="$REPO_ROOT/$WIKI_ROOT_REL"

list_templates() {
  find "$TEMPLATE_ROOT" -mindepth 1 -maxdepth 1 -type d -print | sort | while IFS= read -r template; do
    basename "$template"
  done
}

select_template() {
  local templates=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && templates+=("$line")
  done < <(list_templates)

  if [[ ${#templates[@]} -eq 0 ]]; then
    printf 'No templates found under %s\n' "$TEMPLATE_ROOT" >&2
    exit 1
  fi

  if [[ -n "$TEMPLATE_NAME" ]]; then
    for template in "${templates[@]}"; do
      if [[ "$template" == "$TEMPLATE_NAME" ]]; then
        printf '%s\n' "$TEMPLATE_NAME"
        return
      fi
    done
    printf 'Unknown template: %s\n' "$TEMPLATE_NAME" >&2
    printf 'Available templates:\n' >&2
    for template in "${templates[@]}"; do
      printf -- '- %s\n' "$template" >&2
    done
    exit 1
  fi

  if [[ ! -t 0 ]]; then
    printf 'Missing --template in non-interactive mode. Available templates:\n' >&2
    for template in "${templates[@]}"; do
      printf -- '- %s\n' "$template" >&2
    done
    exit 1
  fi

  printf 'Available templates:\n' >&2
  local index=1
  for template in "${templates[@]}"; do
    printf '%d) %s\n' "$index" "$template" >&2
    index=$((index + 1))
  done

  local choice=""
  read -r -p 'Select template number: ' choice
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#templates[@]} )); then
    printf 'Invalid template selection: %s\n' "$choice" >&2
    exit 1
  fi
  printf '%s\n' "${templates[$((choice - 1))]}"
}

copy_files_to_root() {
  local source_root="$1"
  local target_root="$2"
  local display_prefix="$3"
  local conflicts=()
  local files=()

  if [[ ! -d "$source_root" ]]; then
    return 0
  fi

  while IFS= read -r source; do
    files+=("$source")
    local relative="${source#$source_root/}"
    local target="$target_root/$relative"
    if [[ -e "$target" ]] && ! cmp -s "$source" "$target"; then
      conflicts+=("$display_prefix/$relative")
    fi
  done < <(find "$source_root" -type f | sort)

  if [[ ${#conflicts[@]} -gt 0 ]]; then
    printf 'Refusing to overwrite existing user files:\n' >&2
    for conflict in "${conflicts[@]}"; do
      printf -- '- %s\n' "$conflict" >&2
    done
    printf 'No files were changed.\n' >&2
    exit 1
  fi

  mkdir -p "$target_root"
  for source in "${files[@]}"; do
    local relative="${source#$source_root/}"
    local target="$target_root/$relative"
    if [[ -e "$target" ]]; then
      printf 'Kept identical %s\n' "$target"
      continue
    fi
    mkdir -p "$(dirname "$target")"
    cp "$source" "$target"
    printf 'Created %s\n' "$target"
  done
}

copy_template() {
  local template_dir="$1"
  copy_files_to_root "$template_dir" "$WIKI_ROOT" "$WIKI_ROOT_REL"
}

copy_shared_support_template() {
  if [[ "$WIKI_ROOT_NAME" != "shared" ]]; then
    return 0
  fi
  local support_dir="$SHARED_TEMPLATE_ROOT/$SELECTED_TEMPLATE/.shared-superpowers"
  copy_files_to_root "$support_dir" "$REPO_ROOT/.shared-superpowers" ".shared-superpowers"
  if [[ -d "$REPO_ROOT/.shared-superpowers/scripts" ]]; then
    chmod +x "$REPO_ROOT/.shared-superpowers/scripts"/*.sh "$REPO_ROOT/.shared-superpowers/scripts"/*.py
  fi
}

SELECTED_TEMPLATE="$(select_template)"
TEMPLATE_DIR="$TEMPLATE_ROOT/$SELECTED_TEMPLATE"

if [[ ! -d "$TEMPLATE_DIR" ]]; then
  printf 'Template directory not found: wiki-template/%s\n' "$SELECTED_TEMPLATE" >&2
  exit 1
fi
if [[ ! -f "$TEMPLATE_DIR/index.md" ]]; then
  printf 'Template is missing index.md: %s\n' "$SELECTED_TEMPLATE" >&2
  exit 1
fi

copy_template "$TEMPLATE_DIR"
copy_shared_support_template
printf 'bootstrap-wiki complete: imported template %s into %s\n' "$SELECTED_TEMPLATE" "$WIKI_ROOT_REL"
