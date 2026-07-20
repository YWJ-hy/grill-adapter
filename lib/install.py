#!/usr/bin/env python3
"""grill-adapter project wiring for Claude Code and Codex.

The plugin carries skills, hooks, MCP servers, and the script/contract payload. What a plugin
cannot do is edit a target project's durable instruction file, so this module writes the
marker-delimited host convention block into CLAUDE.md, AGENTS.md, or both. The block names
skills only and never hard-codes a versioned plugin install path.

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
from resolve_install_target import (  # noqa: E402
    resolve_project_target,
    user_claude_dir,
    user_codex_dir,
)

PLUGIN_NAME = "grill-adapter"
HOST_BLOCK_MARKER = "grill-adapter:host:"
RUNTIME_FILES = {"claude": "CLAUDE.md", "codex": "AGENTS.md"}
_HOST_BLOCK_RE = re.compile(
    r"\n*<!-- grill-adapter:host:[a-z]+:start -->.*?<!-- grill-adapter:host:[a-z]+:end -->\n*",
    re.DOTALL,
)


def _log(msg: str) -> None:
    print(msg)


# --- host block in the project's durable instruction file ---------------------


def _runtime_names(runtime: str) -> tuple[str, ...]:
    if runtime == "both":
        return tuple(RUNTIME_FILES)
    if runtime not in RUNTIME_FILES:
        raise SystemExit(f"Unknown runtime '{runtime}'. Choose one of: claude, codex, both")
    return (runtime,)


def _host_conventions(runtime: str) -> dict:
    return load_manifest(REPO_ROOT)["projectLevel"]["hostConventions"][runtime]


def _instruction_path(project: Path, runtime: str) -> Path:
    return project / RUNTIME_FILES[runtime]


def _strip_host_block(text: str) -> str:
    return _HOST_BLOCK_RE.sub("\n", text)


def write_host_block(project: Path, host: str, runtime: str) -> None:
    conventions = _host_conventions(runtime)
    if host not in conventions:
        raise SystemExit(f"Unknown host '{host}'. Choose one of: {', '.join(conventions)}")
    block = (REPO_ROOT / conventions[host]).read_text(encoding="utf-8")
    instructions = _instruction_path(project, runtime)
    existing = instructions.read_text(encoding="utf-8") if instructions.is_file() else ""
    stripped = _strip_host_block(existing).rstrip()
    updated = (stripped + "\n\n" + block.strip() + "\n") if stripped else (block.strip() + "\n")
    instructions.write_text(updated, encoding="utf-8")
    _log(f"project: {runtime}/{host} host convention written to {instructions}")


def remove_host_block(project: Path, runtime: str) -> bool:
    instructions = _instruction_path(project, runtime)
    if not instructions.is_file():
        return False
    text = instructions.read_text(encoding="utf-8")
    stripped = _strip_host_block(text)
    if stripped == text:
        return False
    instructions.write_text(stripped.rstrip() + "\n" if stripped.strip() else "", encoding="utf-8")
    return True


def has_host_block(project: Path, runtime: str) -> bool:
    instructions = _instruction_path(project, runtime)
    return instructions.is_file() and HOST_BLOCK_MARKER in instructions.read_text(
        encoding="utf-8", errors="replace"
    )


# --- plugin enablement (advisory only) ---------------------------------------

def claude_plugin_scopes(project: Path | None) -> list[str]:
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


def codex_plugin_enabled() -> bool:
    """Best-effort read of Codex's plugin table; advisory output only."""
    config = user_codex_dir() / "config.toml"
    if not config.is_file():
        return False
    try:
        text = config.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return False
    section = re.search(
        rf'(?ms)^\[plugins\."{re.escape(PLUGIN_NAME)}@[^"]+"\]\s*(.*?)(?=^\[|\Z)',
        text,
    )
    return bool(section and re.search(r"(?m)^enabled\s*=\s*true\s*$", section.group(1)))


def _claude_plugin_hint(project: Path | None) -> None:
    scopes = claude_plugin_scopes(project)
    if scopes:
        _log(f"plugin (claude): grill-adapter enabled at {', '.join(scopes)}")
        return
    _log("plugin (claude): grill-adapter not found; install it to activate the bundle:")
    _log(f"          claude plugin install {PLUGIN_NAME}@{PLUGIN_NAME} --scope project")


def _codex_plugin_hint() -> None:
    if codex_plugin_enabled():
        _log("plugin (codex): grill-adapter enabled")
        return
    _log("plugin (codex): grill-adapter not found; install the marketplace and plugin:")
    _log("          codex plugin marketplace add YWJ-hy/grill-adapter")
    _log(f"          codex plugin add {PLUGIN_NAME}@{PLUGIN_NAME}")


def _plugin_hint(project: Path | None, runtime: str) -> None:
    for name in _runtime_names(runtime):
        if name == "claude":
            _claude_plugin_hint(project)
        else:
            _codex_plugin_hint()


# --- commands ----------------------------------------------------------------

def cmd_install(host: str, runtime: str, project: str | None) -> int:
    target = resolve_project_target(project)
    if target is None:
        _log("Nothing to wire: pass a project root to write its host convention block.")
        _plugin_hint(None, runtime)
        return 0
    for name in _runtime_names(runtime):
        write_host_block(target, host, name)
    _plugin_hint(target, runtime)
    return 0


def cmd_uninstall(runtime: str, project: str | None) -> int:
    target = resolve_project_target(project)
    if target is None:
        _log("Nothing to unwire: pass a project root to strip its host convention block.")
        return 0
    for name in _runtime_names(runtime):
        instructions = _instruction_path(target, name)
        if remove_host_block(target, name):
            _log(f"project: stripped host block from {instructions}")
        else:
            _log(f"project: no host block in {instructions}")
    if "claude" in _runtime_names(runtime):
        _log(f"Claude plugin removal: claude plugin uninstall {PLUGIN_NAME}")
    if "codex" in _runtime_names(runtime):
        _log(f"Codex plugin removal: codex plugin remove {PLUGIN_NAME}@{PLUGIN_NAME}")
    return 0


def cmd_verify(host: str, runtime: str, project: str | None) -> int:
    target = resolve_project_target(project)
    if target is None:
        _log("grill-adapter verify: nothing to check without a project root.")
        _plugin_hint(None, runtime)
        return 0
    for name in _runtime_names(runtime):
        if not has_host_block(target, name):
            print(
                f"FAIL: no grill-adapter host block in {_instruction_path(target, name)}",
                file=sys.stderr,
            )
            return 1
    _log("grill-adapter verify OK")
    _plugin_hint(target, runtime)
    return 0


def cmd_status(runtime: str, project: str | None) -> int:
    target = resolve_project_target(project)
    _plugin_hint(target, runtime)
    if target is None:
        print("project: none passed")
        return 0
    print(f"project: {target}")
    for name in _runtime_names(runtime):
        print(f"  {RUNTIME_FILES[name]} host block present: {has_host_block(target, name)}")
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
        p.add_argument("--runtime", choices=("claude", "codex", "both"), default="claude")
    for cmd in ("uninstall", "status"):
        p = sub.add_parser(cmd)
        p.add_argument("project", nargs="?", default=None)
        p.add_argument("--runtime", choices=("claude", "codex", "both"), default="claude")
    args = parser.parse_args()

    if args.command == "install":
        return cmd_install(args.host, args.runtime, args.project)
    if args.command == "uninstall":
        return cmd_uninstall(args.runtime, args.project)
    if args.command == "verify":
        return cmd_verify(args.host, args.runtime, args.project)
    if args.command == "status":
        return cmd_status(args.runtime, args.project)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
