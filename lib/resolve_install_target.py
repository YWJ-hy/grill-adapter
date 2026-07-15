#!/usr/bin/env python3
"""Resolve grill-adapter install targets.

Unlike the Superpowers-coupled ancestor, grill-adapter never discovers or writes into a
host plugin directory. It installs at two levels:

  user level (once, cross-project):
    - skills  -> ~/.claude/skills/<name>/
    - agents  -> ~/.claude/agents/<name>.md
    - payload -> $GRILL_ADAPTER_HOME (default ~/.claude/grill-adapter), holding
                 scripts/, contracts/, hooks/, mcp/ — this is __GRILL_ADAPTER_ROOT__.

  project level (per project):
    - hook entries -> <project>/.claude/settings.json
    - host block   -> <project>/CLAUDE.md
"""

from __future__ import annotations

import os
from pathlib import Path


def user_claude_dir() -> Path:
    """The user's Claude Code config dir (~/.claude), override with CLAUDE_CONFIG_DIR."""
    override = os.environ.get("CLAUDE_CONFIG_DIR")
    base = Path(override).expanduser() if override else (Path.home() / ".claude")
    return base.resolve()


def payload_root() -> Path:
    """Where the runtime payload (scripts/contracts/hooks/mcp) is installed.

    This absolute path is what every skill/agent/hook config uses as __GRILL_ADAPTER_ROOT__.
    Override with GRILL_ADAPTER_HOME.
    """
    override = os.environ.get("GRILL_ADAPTER_HOME")
    if override:
        return Path(override).expanduser().resolve()
    return user_claude_dir() / "grill-adapter"


def user_skills_dir() -> Path:
    return user_claude_dir() / "skills"


def user_agents_dir() -> Path:
    return user_claude_dir() / "agents"


def resolve_project_target(explicit: str | None) -> Path | None:
    """Resolve the per-project target root, or None for a user-level-only install."""
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
        "payloadRoot": payload_root().as_posix(),
        "userSkillsDir": user_skills_dir().as_posix(),
        "userAgentsDir": user_agents_dir().as_posix(),
        "projectTarget": (resolve_project_target(explicit).as_posix() if explicit else None),
    }, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
