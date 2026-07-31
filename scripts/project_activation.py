#!/usr/bin/env python3
"""Read-only project activation check for workflow-facing grill-adapter skills."""

from __future__ import annotations

import argparse
import re
from pathlib import Path


HOST_MARKER = re.compile(
    r"<!--\s*grill-adapter:host:(?:grill|plain):start\s*-->"
)


def activation_reason(project_root: Path, explicit: bool) -> str | None:
    if explicit:
        return "explicit"

    if (project_root / ".grill-adapter" / "settings.json").is_file():
        return "settings"

    for name in ("AGENTS.md", "CLAUDE.md"):
        instructions = project_root / name
        try:
            text = instructions.read_text(encoding="utf-8")
        except (FileNotFoundError, OSError, UnicodeError):
            continue
        if HOST_MARKER.search(text):
            return "host-marker"

    return None


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Check whether grill-adapter is active for a project."
    )
    parser.add_argument("project_root")
    parser.add_argument(
        "--explicit",
        action="store_true",
        help="Allow a user-explicit grill-adapter skill invocation.",
    )
    parser.add_argument(
        "--print-reason",
        action="store_true",
        help="Print explicit, settings, or host-marker when active.",
    )
    args = parser.parse_args()

    project_root = Path(args.project_root).resolve()
    if not project_root.is_dir():
        parser.error(f"project root is not a directory: {project_root}")

    reason = activation_reason(project_root, args.explicit)
    if reason is None:
        return 3
    if args.print_reason:
        print(reason)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
