#!/usr/bin/env python3
"""Resolve grill-adapter install targets.

grill-adapter ships as a Claude Code plugin, so there is no user-level install to resolve:
skills, agents, hooks, the shared-wiki MCP, and the script/contract payload all live inside
the plugin and are addressed from skill/agent/hook/MCP config via ``${CLAUDE_PLUGIN_ROOT}``,
which Claude Code substitutes with the plugin's versioned install dir. Never hard-code that
path anywhere that outlives a session -- it changes on every plugin update.

What remains is the one thing a plugin cannot do: edit a target project's CLAUDE.md.

  project level (per project):
    - host convention block -> <project>/CLAUDE.md
"""

from __future__ import annotations

import os
from pathlib import Path


def user_claude_dir() -> Path:
    """The user's Claude Code config dir (~/.claude), override with CLAUDE_CONFIG_DIR.

    Only used to read the plugin registry for advisory status output -- nothing is installed
    here any more.
    """
    override = os.environ.get("CLAUDE_CONFIG_DIR")
    base = Path(override).expanduser() if override else (Path.home() / ".claude")
    return base.resolve()


def resolve_project_target(explicit: str | None) -> Path | None:
    """Resolve the per-project target root, or None when no project was passed."""
    if not explicit:
        return None
    path = Path(explicit).expanduser().resolve()
    if not path.is_dir():
        raise SystemExit(f"Project root is not a directory: {path}")
    return path


def _configure_stdio() -> None:
    for stream_name in ("stdout", "stderr"):
        import sys
        stream = getattr(sys, stream_name)
        if not hasattr(stream, "reconfigure"):
            continue
        try:
            stream.reconfigure(encoding="utf-8", errors="replace", newline="\n")
        except (OSError, ValueError):
            pass


def main() -> int:
    _configure_stdio()
    import json
    import sys
    explicit = sys.argv[1] if len(sys.argv) > 1 and sys.argv[1] else None
    print(json.dumps({
        "userClaudeDir": user_claude_dir().as_posix(),
        "projectTarget": (resolve_project_target(explicit).as_posix() if explicit else None),
    }, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
