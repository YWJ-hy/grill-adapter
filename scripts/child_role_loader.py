#!/usr/bin/env python3
"""Resolve and load digest-bound role prompts for isolated Codex children."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path, PurePosixPath
from typing import Any


MANIFEST_RELATIVE_PATH = Path("contracts/child-role-loader-v1.json")
MANIFEST_KIND = "grill-adapter.child-role-loader"
DESCRIPTOR_KIND = "grill-adapter.child-role-descriptor"
ROLE_IDENTITY = re.compile(r"^grill-adapter:[a-z][a-z0-9-]{0,63}$")
DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")


class RoleLoaderError(ValueError):
    pass


def fail(message: str) -> None:
    raise RoleLoaderError(message)


def is_within(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
    except ValueError:
        return False
    return True


def canonical_directory(value: str) -> Path:
    try:
        path = Path(value).resolve(strict=True)
    except OSError:
        fail("plugin root is unavailable")
    if not path.is_dir():
        fail("plugin root is not a directory")
    return path


def canonical_file(path: Path, root: Path, field: str) -> Path:
    if path.is_symlink():
        fail(f"{field} may not be a symlink")
    try:
        resolved = path.resolve(strict=True)
    except OSError:
        fail(f"{field} is unavailable")
    if not resolved.is_file() or not is_within(resolved, root):
        fail(f"{field} is outside the plugin root")
    return resolved


def manifest_source(root: Path) -> Path:
    return canonical_file(root / MANIFEST_RELATIVE_PATH, root, "role manifest")


def load_manifest(root: Path) -> dict[str, Any]:
    try:
        value = json.loads(manifest_source(root).read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        fail("role manifest is unreadable")
    if not isinstance(value, dict) or set(value) != {"schemaVersion", "kind", "roles"}:
        fail("role manifest shape is invalid")
    if value["schemaVersion"] != 1 or value["kind"] != MANIFEST_KIND:
        fail("role manifest identity is invalid")
    if not isinstance(value["roles"], dict) or not value["roles"]:
        fail("role manifest roles are invalid")
    return value


def configured_source(root: Path, raw_source: Any) -> Path:
    if not isinstance(raw_source, str) or not raw_source:
        fail("role source is invalid")
    relative = PurePosixPath(raw_source)
    if relative.is_absolute() or ".." in relative.parts or relative.as_posix() != raw_source:
        fail("role source is invalid")
    return canonical_file(root.joinpath(*relative.parts), root, "role source")


def role_entry(root: Path, role: str) -> tuple[Path, str]:
    if not ROLE_IDENTITY.fullmatch(role):
        fail("role identity is invalid")
    roles = load_manifest(root)["roles"]
    entry = roles.get(role)
    if not isinstance(entry, dict) or set(entry) != {"source", "digest"}:
        fail("role manifest entry is invalid")
    digest = entry["digest"]
    if not isinstance(digest, str) or not DIGEST.fullmatch(digest):
        fail("role digest is invalid")
    return configured_source(root, entry["source"]), digest


def resolve_descriptor(plugin_root: str, role: str) -> dict[str, Any]:
    root = canonical_directory(plugin_root)
    source, digest = role_entry(root, role)
    return {
        "schemaVersion": 1,
        "kind": DESCRIPTOR_KIND,
        "role": role,
        "source": str(source),
        "expectedDigest": digest,
    }


def root_for_source(source: str) -> Path:
    candidate = Path(source)
    if not candidate.is_absolute() or candidate.suffix != ".md" or candidate.parent.name != "agents":
        fail("role source does not identify a supported role")
    try:
        return candidate.parent.parent.resolve(strict=True)
    except OSError:
        fail("role source is unavailable")


def load_role(role: str, source: str, expected_digest: str) -> str:
    root = root_for_source(source)
    descriptor = resolve_descriptor(str(root), role)
    if source != descriptor["source"]:
        fail("role source does not match its descriptor")
    if expected_digest != descriptor["expectedDigest"]:
        fail("expected role digest does not match its descriptor")
    try:
        content = Path(source).read_bytes()
    except OSError:
        fail("role source is unreadable")
    actual_digest = "sha256:" + hashlib.sha256(content).hexdigest()
    if actual_digest != expected_digest:
        fail("role content digest drifted")
    try:
        return content.decode("utf-8")
    except UnicodeDecodeError:
        fail("role source is not UTF-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    resolve = subparsers.add_parser("resolve")
    resolve.add_argument("--plugin-root", required=True)
    resolve.add_argument("--role", required=True)

    load = subparsers.add_parser("load")
    load.add_argument("--role", required=True)
    load.add_argument("--source", required=True)
    load.add_argument("--expected-digest", required=True)

    args = parser.parse_args()
    try:
        if args.command == "resolve":
            print(json.dumps(resolve_descriptor(args.plugin_root, args.role), separators=(",", ":")))
        else:
            sys.stdout.write(load_role(args.role, args.source, args.expected_digest))
    except RoleLoaderError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
