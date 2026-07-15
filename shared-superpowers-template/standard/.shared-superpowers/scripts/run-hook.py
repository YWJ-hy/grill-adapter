#!/usr/bin/env python3
"""Run project-local shared-superpowers hooks from settings.json."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description='Run a hook from .shared-superpowers/settings.json')
    parser.add_argument('hook_name')
    parser.add_argument('--settings', default='.shared-superpowers/settings.json')
    return parser.parse_args()


def load_settings(path: Path) -> dict:
    try:
        data = json.loads(path.read_text(encoding='utf-8'))
    except FileNotFoundError:
        raise SystemExit(f'Settings file not found: {path}')
    except json.JSONDecodeError as exc:
        raise SystemExit(f'Invalid JSON in {path}: {exc}') from exc
    if not isinstance(data, dict):
        raise SystemExit(f'Settings root must be an object: {path}')
    hooks = data.get('hooks')
    if not isinstance(hooks, dict):
        raise SystemExit(f'Settings must contain a hooks object: {path}')
    return data


def normalize_hook_item(item: object, hook_name: str, index: int) -> list[str]:
    if not isinstance(item, dict):
        raise SystemExit(f'Hook {hook_name}[{index}] must be an object')
    command = item.get('command')
    args = item.get('args', [])
    if not isinstance(command, str) or not command:
        raise SystemExit(f'Hook {hook_name}[{index}].command must be a non-empty string')
    if not isinstance(args, list) or not all(isinstance(arg, str) for arg in args):
        raise SystemExit(f'Hook {hook_name}[{index}].args must be an array of strings')
    return [command, *args]


def shell_command(command: list[str]) -> list[str]:
    if os.name != 'nt' or not command[0].endswith('.sh'):
        return command
    bash = shutil.which('bash.exe') or shutil.which('bash') or 'bash'
    return [bash, *command]


def main() -> int:
    args = parse_args()
    settings_path = Path(args.settings)
    settings = load_settings(settings_path)
    hooks = settings['hooks']
    hook_items = hooks.get(args.hook_name)
    if hook_items is None:
        raise SystemExit(f'Hook not found: {args.hook_name}')
    if not isinstance(hook_items, list):
        raise SystemExit(f'Hook {args.hook_name} must be an array')
    if not hook_items:
        return 0

    for index, item in enumerate(hook_items):
        command = shell_command(normalize_hook_item(item, args.hook_name, index))
        result = subprocess.run(command, check=False)
        if result.returncode != 0:
            return result.returncode
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
