#!/usr/bin/env python3
"""grill-adapter project wiring — writes the host convention block into a project.

grill-adapter ships as a Claude Code plugin. Skills, agents, hooks (`hooks/hooks.json`), the
shared-wiki MCP (`.mcp.json`), and the whole script/contract payload all travel inside the
plugin and activate together via:

    claude plugin install grill-adapter --scope project|user

Nothing is copied into ~/.claude, no hook entries are merged into a project's
.claude/settings.json, and no MCP is registered by hand. Scope is the plugin's scope — a
plugin-bundled MCP cannot be scoped separately from its plugin.

What a plugin *cannot* do is edit a target project's CLAUDE.md, so exactly one project-level
step remains here: writing the marker-delimited host convention block that tells the host
workflow (grill or plain) when to invoke each touchpoint. The block names skills only — it
hard-codes no install path, because the plugin's install path is version-scoped and would go
stale on the next plugin update.

Commands: install | uninstall | verify | status
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "lib"))

from package_manifest import load_manifest  # noqa: E402
from resolve_install_target import resolve_project_target, user_claude_dir  # noqa: E402

PLUGIN_NAME = "grill-adapter"
HOST_BLOCK_MARKER = "grill-adapter:host:"
_HOST_BLOCK_RE = re.compile(
    r"\n*<!-- grill-adapter:host:[a-z]+:start -->.*?<!-- grill-adapter:host:[a-z]+:end -->\n*",
    re.DOTALL,
)


def _log(msg: str) -> None:
    print(msg)


# --- host block in the project's CLAUDE.md ------------------------------------

def _host_conventions() -> dict:
    return load_manifest(REPO_ROOT)["projectLevel"]["hostConventions"]


def _strip_host_block(text: str) -> str:
    return _HOST_BLOCK_RE.sub("\n", text)


def write_host_block(project: Path, host: str) -> None:
    conventions = _host_conventions()
    if host not in conventions:
        raise SystemExit(f"Unknown host '{host}'. Choose one of: {', '.join(conventions)}")
    block = (REPO_ROOT / conventions[host]).read_text(encoding="utf-8")
    claude_md = project / "CLAUDE.md"
    existing = claude_md.read_text(encoding="utf-8") if claude_md.is_file() else ""
    stripped = _strip_host_block(existing).rstrip()
    updated = (stripped + "\n\n" + block.strip() + "\n") if stripped else (block.strip() + "\n")
    claude_md.write_text(updated, encoding="utf-8")
    _log(f"project: {host} host convention written to {claude_md}")


def remove_host_block(project: Path) -> bool:
    claude_md = project / "CLAUDE.md"
    if not claude_md.is_file():
        return False
    text = claude_md.read_text(encoding="utf-8")
    stripped = _strip_host_block(text)
    if stripped == text:
        return False
    claude_md.write_text(stripped.rstrip() + "\n" if stripped.strip() else "", encoding="utf-8")
    return True


def has_host_block(project: Path) -> bool:
    claude_md = project / "CLAUDE.md"
    return claude_md.is_file() and HOST_BLOCK_MARKER in claude_md.read_text(
        encoding="utf-8", errors="replace"
    )


# --- plugin enablement (advisory only) ---------------------------------------

def plugin_scopes(project: Path | None) -> list[str]:
    """Scopes grill-adapter appears installed at, read from Claude Code's plugin registry.

    Advisory only: `--plugin-dir` dev runs and any future registry layout change are both
    invisible here, so a negative result never fails a command -- it only shapes a hint.
    """
    registry = user_claude_dir() / "plugins" / "installed_plugins.json"
    if not registry.is_file():
        return []
    try:
        data = json.loads(registry.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return []
    scopes: list[str] = []
    for key, entries in (data.get("plugins") or {}).items():
        if key.split("@", 1)[0] != PLUGIN_NAME or not isinstance(entries, list):
            continue
        for entry in entries:
            if not isinstance(entry, dict):
                continue
            scope = str(entry.get("scope", "?"))
            if scope == "project":
                bound = entry.get("projectPath")
                if project is not None and bound and Path(str(bound)) != project:
                    continue
                scopes.append(f"project ({bound})")
            else:
                scopes.append(scope)
    return scopes


def _plugin_hint(project: Path | None) -> None:
    scopes = plugin_scopes(project)
    if scopes:
        _log(f"plugin: grill-adapter enabled at {', '.join(scopes)}")
        return
    _log("plugin: grill-adapter not found in the plugin registry. The skills, agents, hooks and")
    _log("        shared-wiki MCP all live in the plugin, so install it to activate them:")
    _log(f"          claude plugin install {PLUGIN_NAME}@{PLUGIN_NAME} --scope project")
    _log("        (project scope also scopes the bundled MCP to that project; use --scope user")
    _log("        for every project. Dev runs via `claude --plugin-dir` are not listed here.)")


# --- commands ----------------------------------------------------------------

def cmd_install(host: str, project: str | None) -> int:
    target = resolve_project_target(project)
    if target is None:
        _log("Nothing to wire: pass a project root to write its host convention block.")
        _plugin_hint(None)
        return 0
    write_host_block(target, host)
    _plugin_hint(target)
    return 0


def cmd_uninstall(project: str | None) -> int:
    target = resolve_project_target(project)
    if target is None:
        _log("Nothing to unwire: pass a project root to strip its host convention block.")
        return 0
    if remove_host_block(target):
        _log(f"project: stripped host block from {target / 'CLAUDE.md'}")
    else:
        _log(f"project: no host block in {target / 'CLAUDE.md'}")
    _log(f"To remove the skills/agents/hooks/MCP, uninstall the plugin: claude plugin uninstall {PLUGIN_NAME}")
    return 0


def cmd_verify(host: str, project: str | None) -> int:
    target = resolve_project_target(project)
    if target is None:
        _log("grill-adapter verify: nothing to check without a project root.")
        _plugin_hint(None)
        return 0
    if not has_host_block(target):
        print(f"FAIL: no grill-adapter host block in {target / 'CLAUDE.md'}", file=sys.stderr)
        return 1
    _log("grill-adapter verify OK")
    _plugin_hint(target)
    return 0


def cmd_status(project: str | None) -> int:
    target = resolve_project_target(project)
    _plugin_hint(target)
    if target is None:
        print("project: none passed")
        return 0
    print(f"project: {target}")
    print(f"  host block present: {has_host_block(target)}")
    return 0


def _configure_stdio() -> None:
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            try:
                stream.reconfigure(encoding="utf-8", errors="replace", newline="\n")
            except (OSError, ValueError):
                pass


def main() -> int:
    _configure_stdio()
    parser = argparse.ArgumentParser(
        description="grill-adapter project wiring (the plugin carries everything else)."
    )
    sub = parser.add_subparsers(dest="command", required=True)
    default_host = str(load_manifest(REPO_ROOT).get("defaultHost", "grill"))
    for cmd in ("install", "verify"):
        p = sub.add_parser(cmd)
        p.add_argument("project", nargs="?", default=None, help="Project root to wire")
        p.add_argument("--host", default=default_host, help="Host convention to wire (grill|plain)")
    for cmd in ("uninstall", "status"):
        p = sub.add_parser(cmd)
        p.add_argument("project", nargs="?", default=None)
    args = parser.parse_args()

    if args.command == "install":
        return cmd_install(args.host, args.project)
    if args.command == "uninstall":
        return cmd_uninstall(args.project)
    if args.command == "verify":
        return cmd_verify(args.host, args.project)
    if args.command == "status":
        return cmd_status(args.project)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
