#!/usr/bin/env python3
"""Check the generated documentation inventory and routing contract."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


START = "<!-- generated:documentation-inventory:start -->"
END = "<!-- generated:documentation-inventory:end -->"


def load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def rel(root: Path, path: Path) -> str:
    return path.relative_to(root).as_posix()


def inventory(root: Path) -> str:
    claude = load_json(root / ".claude-plugin/plugin.json")
    codex = load_json(root / ".codex-plugin/plugin.json")
    hooks = load_json(root / "hooks/hooks.json").get("hooks", {})
    skills = sorted(rel(root, path) for path in (root / "skills").glob("*/SKILL.md"))
    agents = sorted(rel(root, path) for path in (root / "agents").glob("*.md"))
    tests = sorted(rel(root, path) for path in (root / "tests").glob("*.sh"))
    mcp_tests = sorted(
        rel(root, path)
        for path in (root / "mcp").glob("*/tests/**/*")
        if path.is_file() and path.suffix in {".ts", ".tsx", ".js", ".mjs"}
    )
    acceptance = sorted(rel(root, path) for path in (root / "acceptance").glob("*.sh"))
    mcp_servers = sorted(codex.get("mcpServers", {}))
    rows = [
        "### Plugin components (generated)",
        "",
        f"- Skills ({len(skills)}): " + ", ".join(f"`{path}`" for path in skills),
        f"- Agents ({len(agents)}): " + ", ".join(f"`{path}`" for path in agents),
        f"- Hook events ({len(hooks)}): " + ", ".join(f"`{name}`" for name in sorted(hooks)),
        f"- MCP servers ({len(mcp_servers)}): " + ", ".join(f"`{name}`" for name in mcp_servers),
        "",
        "### Smoke tests (generated)",
        "",
        f"- Bash smoke files ({len(tests)}): " + ", ".join(f"`{path}`" for path in tests),
        f"- MCP test files ({len(mcp_tests)}): " + ", ".join(f"`{path}`" for path in mcp_tests),
        f"- Installed acceptance gates ({len(acceptance)}): " + ", ".join(f"`{path}`" for path in acceptance),
        "",
        "The generated lists come from the plugin manifests and repository layout. Run "
        "`python3 scripts/check_documentation_index.py --check` after adding a component or smoke test.",
    ]
    # Touch both manifests deliberately: a malformed Claude manifest should fail the index check too.
    if claude.get("name") != codex.get("name"):
        raise ValueError("Claude and Codex manifests disagree on plugin name")
    return "\n".join(rows)


def replace_generated(document: str, generated: str) -> str:
    if START not in document or END not in document:
        raise ValueError("documentation inventory markers are missing")
    before, rest = document.split(START, 1)
    _, after = rest.split(END, 1)
    return before + START + "\n" + generated.rstrip() + "\n" + END + after


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", nargs="?", default=".")
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()
    root = Path(args.root).resolve()
    index_path = root / "docs/DOCUMENTATION_INDEX_CN.md"
    contract = load_json(root / "contracts/developer-doc-routing-v1.json")
    for key, path in contract["authority"].items():
        if "<" in path:
            continue
        if not (root / path).exists():
            raise SystemExit(f"missing authority path ({key}): {path}")
    for route in contract["routes"]:
        for path in route["docs"]:
            if "<" in path:
                continue
            if not (root / path).exists():
                raise SystemExit(f"missing route path ({route['id']}): {path}")
    generated = inventory(root)
    current = index_path.read_text(encoding="utf-8")
    development = (root / "docs/DEVELOPMENT_CN.md").read_text(encoding="utf-8")
    for route in contract["routes"]:
        if route["changeType"] not in development:
            raise SystemExit(f"developer route is missing from DEVELOPMENT_CN.md: {route['id']}")
        for check in route["checks"]:
            if check not in development:
                raise SystemExit(f"developer route check is missing from DEVELOPMENT_CN.md: {route['id']} -> {check}")
        for path in route["docs"]:
            if "<" in path or path == "docs/DEVELOPMENT_CN.md":
                continue
            display_path = path.removeprefix("docs/")
            if display_path not in development:
                raise SystemExit(f"developer route doc is missing from DEVELOPMENT_CN.md: {route['id']} -> {path}")
    expected = replace_generated(current, generated)
    if args.write:
        index_path.write_text(expected, encoding="utf-8")
    if args.check and current != expected:
        raise SystemExit("documentation inventory is stale; run scripts/check_documentation_index.py --write")
    if not args.check and not args.write:
        print(generated)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
