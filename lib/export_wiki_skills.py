#!/usr/bin/env python3
"""Export self-contained, repo-local wiki maintenance skills into a wiki repository.

A standalone wiki repository (wiki content at the repo root) cannot use the
grill-adapter's user-level skills directly. This stamps two self-contained
skills plus a shared vendored toolchain into the repo's `.claude/`, so anyone who
clones the repo and opens Claude Code there can maintain the wiki consistently
with zero dependency on grill-adapter at runtime:

  .claude/wiki-tools/scripts/        # vendored mechanical helpers (single copy)
  .claude/wiki-tools/.export-manifest.json
  .claude/skills/update-wiki/        # author-side incremental maintenance
  .claude/skills/migrate-wiki/       # section-ify + typed graph enrichment
  .github/workflows/rebuild-wiki-graph.yml  # rebuild .graph.json on PR merge (default on)

Re-run to refresh the vendored scripts after the adapter's logic changes. Files
are managed (they carry the adapter's generated marker); the export refuses to
overwrite any pre-existing unmanaged file.

By default the export also stamps a GitHub Action that rebuilds the root
.graph.json after a PR merges into the default branch (consumer PRs carry their
companion *.index.md but cannot include the cross-page .graph.json, so it would
otherwise go stale). Pass --no-graph-ci to skip it; on a later --no-graph-ci
re-export a previously stamped (managed) workflow is removed.
"""

from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

# The dependency closure the two skills need. wiki_common / wiki_section are the
# libraries; the other three are the CLI entry points the SKILL.md commands call.
VENDORED_SCRIPTS = [
    "wiki_common.py",
    "wiki_section.py",
    "wiki_generate_section_index.py",
    "wiki_update_check.py",
    "wiki_migrate_helper.py",
]
SKILLS = ["update-wiki", "migrate-wiki"]
TOOLS_REL = Path(".claude") / "wiki-tools"
SCRIPTS_REL = TOOLS_REL / "scripts"
SKILLS_REL = Path(".claude") / "skills"
MANIFEST_REL = TOOLS_REL / ".export-manifest.json"

# Optional CI: rebuild the root .graph.json after a PR merges into the default
# branch. The template carries a marker placeholder substituted at export time.
WORKFLOW_SRC = Path("wiki-repo-ci") / "rebuild-wiki-graph.yml"
WORKFLOW_REL = Path(".github") / "workflows" / "rebuild-wiki-graph.yml"
MARKER_PLACEHOLDER = "__ADAPTER_GENERATED_MARKER__"


def _marker(adapter_root: Path) -> str:
    sys.path.insert(0, str(adapter_root / "lib"))
    from package_manifest import generated_marker  # noqa: E402

    return generated_marker(adapter_root)


def _is_managed(path: Path, marker: str) -> bool:
    """A target is safe to write if it does not exist or carries the adapter marker."""
    if not path.exists():
        return True
    try:
        return marker in path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return False


def _skill_files(skills_src: Path, skill: str) -> list[tuple[Path, Path]]:
    """(source, relative) pairs for every file under one skill source dir."""
    base = skills_src / skill
    return [(src, src.relative_to(base)) for src in sorted(base.rglob("*")) if src.is_file()]


def export(adapter_root: Path, repo_root: Path, graph_ci: bool = True) -> dict:
    adapter_root = adapter_root.resolve()
    repo_root = repo_root.resolve()
    scripts_src = adapter_root / "scripts"
    skills_src = adapter_root / "wiki-repo-skills"
    marker = _marker(adapter_root)
    manifest = json.loads((adapter_root / "manifest.json").read_text(encoding="utf-8"))

    scripts_dst = repo_root / SCRIPTS_REL
    skills_dst = repo_root / SKILLS_REL
    workflow_dst = repo_root / WORKFLOW_REL

    # Pre-flight: never clobber a file we did not generate. We only gate the
    # workflow when we are about to WRITE it (graph_ci); under --no-graph-ci an
    # unmanaged workflow at that path is left untouched (handled in the removal
    # step below), so it must not block the rest of the export.
    targets: list[Path] = [scripts_dst / name for name in VENDORED_SCRIPTS]
    targets.append(repo_root / MANIFEST_REL)
    for skill in SKILLS:
        for _src, rel in _skill_files(skills_src, skill):
            targets.append(skills_dst / skill / rel)
    if graph_ci:
        targets.append(workflow_dst)
    blocked = [str(t) for t in targets if not _is_managed(t, marker)]
    if blocked:
        raise SystemExit(
            "Refusing to overwrite unmanaged file(s) (missing adapter marker):\n  "
            + "\n  ".join(blocked)
        )

    # Vendored scripts (verbatim — they carry no install-time placeholders).
    scripts_dst.mkdir(parents=True, exist_ok=True)
    script_hashes: dict[str, str] = {}
    for name in VENDORED_SCRIPTS:
        data = (scripts_src / name).read_bytes()
        (scripts_dst / name).write_bytes(data)
        script_hashes[name] = hashlib.sha256(data).hexdigest()

    # Skill packs.
    for skill in SKILLS:
        for src, rel in _skill_files(skills_src, skill):
            dst = skills_dst / skill / rel
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.write_text(src.read_text(encoding="utf-8"), encoding="utf-8")

    # Graph-rebuild CI: stamp the workflow (marker substituted) when enabled; when
    # disabled, remove a previously stamped managed workflow so --no-graph-ci is a
    # real off switch. Files the user authored themselves were already rejected above.
    workflow_hash: str | None = None
    if graph_ci:
        content = (adapter_root / WORKFLOW_SRC).read_text(encoding="utf-8").replace(
            MARKER_PLACEHOLDER, marker
        )
        workflow_dst.parent.mkdir(parents=True, exist_ok=True)
        workflow_dst.write_text(content, encoding="utf-8")
        workflow_hash = hashlib.sha256(content.encode("utf-8")).hexdigest()
    elif workflow_dst.exists() and _is_managed(workflow_dst, marker):
        # Real off switch, but only for a workflow we stamped — leave a
        # hand-authored file at that path untouched.
        workflow_dst.unlink()

    export_manifest = {
        "generatedMarker": marker,
        "adapterName": manifest.get("name"),
        "adapterVersion": manifest.get("version", ""),
        "toolsDir": SCRIPTS_REL.as_posix(),
        "skills": SKILLS,
        "scripts": script_hashes,
        "graphCi": graph_ci,
        "workflows": (
            {WORKFLOW_REL.as_posix(): workflow_hash} if workflow_hash else {}
        ),
    }
    manifest_path = repo_root / MANIFEST_REL
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    manifest_path.write_text(json.dumps(export_manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return export_manifest


USAGE = "Usage: export_wiki_skills.py <adapter-root> <wiki-repo-root> [--no-graph-ci]"


def main(argv: list[str]) -> int:
    graph_ci = True
    positional: list[str] = []
    for arg in argv[1:]:
        if arg in ("--no-graph-ci", "--no-ci"):
            graph_ci = False
        elif arg == "--graph-ci":
            graph_ci = True
        elif arg.startswith("--"):
            print(f"Unknown option: {arg}\n{USAGE}", file=sys.stderr)
            return 1
        else:
            positional.append(arg)
    if len(positional) != 2:
        print(USAGE, file=sys.stderr)
        return 1
    adapter_root = Path(positional[0])
    repo_root = Path(positional[1])
    if not repo_root.is_dir():
        print(f"Wiki repository root not found: {repo_root}", file=sys.stderr)
        return 1

    result = export(adapter_root, repo_root, graph_ci=graph_ci)
    print(f"Exported repo-local wiki skills to {repo_root}")
    print(f"  adapter: {result['adapterName']} {result['adapterVersion']}")
    print(f"  toolchain: {result['toolsDir']} ({len(result['scripts'])} scripts)")
    print(f"  skills: {', '.join(result['skills'])} (under .claude/skills/)")
    if result["graphCi"]:
        print(f"  graph CI: {WORKFLOW_REL.as_posix()} (rebuilds .graph.json on PR merge)")
    else:
        print("  graph CI: disabled (--no-graph-ci); root .graph.json must be rebuilt by a maintainer")

    settings = repo_root / ".shared-superpowers" / "settings.json"
    if not settings.is_file():
        print(
            "\nHint: no .shared-superpowers/settings.json found. Add one with "
            "wiki.sharedNeutrality.blockedTerms / blockedPatterns to enable mechanical "
            "neutrality guards, and wiki.updateAuthorization to govern writes.",
        )
    print("\nThese skills are edit-only: they regenerate indexes/graph and validate, but never commit.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
