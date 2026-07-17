#!/usr/bin/env python3
"""grill-adapter installer — host-agnostic, zero host-skill patching.

Two levels (blueprint §8.4):

  user level (once, cross-project):
    payload dirs (scripts/contracts/hooks/mcp) -> $GRILL_ADAPTER_HOME  (= __GRILL_ADAPTER_ROOT__)
    skills -> ~/.claude/skills/<name>/          (placeholder replaced)
    agents -> ~/.claude/agents/<name>.md        (placeholder replaced, model override)
    shared-wiki MCP: one generic registration reading CLAUDE_PROJECT_DIR

  project level (per project, when a project root is passed):
    hook entries -> <project>/.claude/settings.json   (marker-tagged, idempotent, add-only)
    host block   -> <project>/CLAUDE.md                (marker-delimited, idempotent)

Commands: install | uninstall | verify | status | mcp-registration
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "lib"))

from package_manifest import (  # noqa: E402
    generated_marker, load_manifest, payload_dirs, user_level_agents, user_level_skills,
)
from resolve_install_target import (  # noqa: E402
    payload_root, resolve_project_target, user_agents_dir, user_claude_dir, user_skills_dir,
)

try:
    from subagent_models import apply_agent_model_override  # noqa: E402
except Exception:  # pragma: no cover - model override is optional
    def apply_agent_model_override(text: str, root: Path, rel: str) -> str:  # type: ignore
        return text

PLACEHOLDER = "__GRILL_ADAPTER_ROOT__"
_EXCLUDE = {"node_modules", "dist", "__pycache__", ".git"}


def _marker() -> str:
    return generated_marker(REPO_ROOT)


def _hook_marker() -> str:
    return str(load_manifest(REPO_ROOT).get("hookMarker", "grill-adapter/hooks/"))


def _log(msg: str) -> None:
    print(msg)


# --- payload -----------------------------------------------------------------

def _copy_tree(src: Path, dst: Path) -> None:
    if dst.exists():
        shutil.rmtree(dst)
    shutil.copytree(src, dst, ignore=shutil.ignore_patterns(*_EXCLUDE))


def install_payload() -> Path:
    root = payload_root()
    root.mkdir(parents=True, exist_ok=True)
    for rel in payload_dirs(REPO_ROOT):
        src = REPO_ROOT / rel
        if not src.is_dir():
            continue
        _copy_tree(src, root / rel)
        _log(f"payload: {rel} -> {(root / rel)}")
    # scripts + hooks must be executable
    for pat in ("scripts/*.py", "hooks/*.sh"):
        for f in root.glob(pat):
            f.chmod(0o755)
    return root


def build_mcp(root: Path) -> bool:
    mcp = root / "mcp" / "shared-wiki"
    if not (mcp / "package.json").is_file():
        return False
    # Spawn the resolved path, not bare "npm": on Windows npm is npm.CMD and
    # CreateProcess does not apply PATHEXT, so ["npm", ...] raises FileNotFoundError.
    npm = shutil.which("npm")
    if npm is None:
        _log("WARN: npm not found; shared-wiki MCP not built. Skills work; shared-wiki MCP unavailable until built.")
        return False
    try:
        subprocess.run([npm, "install", "--no-audit", "--no-fund"], cwd=mcp, check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
        subprocess.run([npm, "run", "build"], cwd=mcp, check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
    except (subprocess.CalledProcessError, OSError):
        _log("WARN: shared-wiki MCP build failed; skills still work.")
        return False
    _log(f"payload: built shared-wiki MCP at {mcp / 'dist' / 'index.js'}")
    return True


# --- skills + agents ---------------------------------------------------------

def _render(text: str, root: Path, rel: str) -> str:
    text = text.replace(PLACEHOLDER, root.as_posix())
    # Optional model-override frontmatter only applies to agent files.
    if rel.startswith("agents/"):
        text = apply_agent_model_override(text, REPO_ROOT, rel)
    return text


def _safe_write(src: Path, dst: Path, root: Path, rel: str) -> None:
    """Write a rendered text file, refusing to clobber an unmanaged existing file."""
    if dst.is_file():
        existing = dst.read_text(encoding="utf-8", errors="replace")
        if _marker() not in existing:
            raise SystemExit(f"Refusing to overwrite unmanaged file: {dst}")
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_text(_render(src.read_text(encoding="utf-8"), root, rel), encoding="utf-8")


def install_skills(root: Path) -> None:
    dest_base = user_skills_dir()
    for name in user_level_skills(REPO_ROOT):
        src_dir = REPO_ROOT / "skills" / name
        if not src_dir.is_dir():
            raise SystemExit(f"Missing skill source: {src_dir}")
        for src in src_dir.rglob("*"):
            if src.is_dir() or any(part in _EXCLUDE for part in src.parts):
                continue
            rel = src.relative_to(REPO_ROOT / "skills")
            _safe_write(src, dest_base / rel, root, f"skills/{rel.as_posix()}")
        _log(f"skill: {name} -> {dest_base / name}")


def install_agents(root: Path) -> None:
    dest_base = user_agents_dir()
    dest_base.mkdir(parents=True, exist_ok=True)
    for name in user_level_agents(REPO_ROOT):
        src = REPO_ROOT / "agents" / name
        if not src.is_file():
            raise SystemExit(f"Missing agent source: {src}")
        _safe_write(src, dest_base / name, root, f"agents/{name}")
        _log(f"agent: {name} -> {dest_base / name}")


# --- project-level: hooks in settings.json -----------------------------------

def _load_json(path: Path) -> dict:
    if path.is_file():
        return json.loads(path.read_text(encoding="utf-8"))
    return {}


def _save_json(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")


def _canonical_hooks(root: Path) -> dict:
    frag = REPO_ROOT / str(load_manifest(REPO_ROOT)["projectLevel"]["hookSettings"])
    text = frag.read_text(encoding="utf-8").replace(PLACEHOLDER, root.as_posix())
    return json.loads(text).get("hooks", {})


def _group_match(target_groups: list, matcher):
    for g in target_groups:
        if g.get("matcher") == matcher:
            return g
    return None


def merge_hooks(project: Path, root: Path) -> bool:
    settings_path = project / ".claude" / "settings.json"
    data = _load_json(settings_path)
    hooks_root = data.setdefault("hooks", {})
    canonical = _canonical_hooks(root)
    changed = False
    for event, groups in canonical.items():
        target_event = hooks_root.setdefault(event, [])
        for group in groups:
            matcher = group.get("matcher")
            tgt = _group_match(target_event, matcher)
            if tgt is None:
                tgt = {"hooks": []}
                if matcher is not None:
                    tgt["matcher"] = matcher
                target_event.append(tgt)
                changed = True
            existing_cmds = {h.get("command") for h in tgt.setdefault("hooks", [])}
            for h in group.get("hooks", []):
                if h.get("command") not in existing_cmds:
                    tgt["hooks"].append(dict(h))
                    changed = True
    if changed:
        _save_json(settings_path, data)
        _log(f"project: hooks merged into {settings_path}")
    else:
        _log(f"project: hooks already present in {settings_path}")
    return changed


def unmerge_hooks(project: Path) -> bool:
    settings_path = project / ".claude" / "settings.json"
    if not settings_path.is_file():
        return False
    data = _load_json(settings_path)
    hooks_root = data.get("hooks", {})
    marker = _hook_marker()
    changed = False
    for event in list(hooks_root.keys()):
        groups = hooks_root[event]
        new_groups = []
        for g in groups:
            kept = [h for h in g.get("hooks", []) if marker not in str(h.get("command", ""))]
            if len(kept) != len(g.get("hooks", [])):
                changed = True
            if kept:
                g["hooks"] = kept
                new_groups.append(g)
            elif not g.get("hooks"):
                new_groups.append(g)
        if new_groups:
            hooks_root[event] = new_groups
        else:
            del hooks_root[event]
            changed = True
    if changed:
        _save_json(settings_path, data)
    return changed


# --- project-level: host block in CLAUDE.md ----------------------------------

def _strip_host_block(text: str) -> str:
    import re
    pattern = re.compile(
        r"\n*<!-- grill-adapter:host:[a-z]+:start -->.*?<!-- grill-adapter:host:[a-z]+:end -->\n*",
        re.DOTALL,
    )
    return pattern.sub("\n", text)


def write_host_block(project: Path, root: Path, host: str) -> None:
    conventions = load_manifest(REPO_ROOT)["projectLevel"]["hostConventions"]
    if host not in conventions:
        raise SystemExit(f"Unknown host '{host}'. Choose one of: {', '.join(conventions)}")
    block = (REPO_ROOT / conventions[host]).read_text(encoding="utf-8").replace(PLACEHOLDER, root.as_posix())
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
    if stripped != text:
        claude_md.write_text(stripped.rstrip() + "\n" if stripped.strip() else "", encoding="utf-8")
        return True
    return False


# --- MCP registration --------------------------------------------------------

def mcp_registration(root: Path) -> dict:
    entry = root / "mcp" / "shared-wiki" / "dist" / "index.js"
    return {"mcpServers": {"shared-wiki": {"command": "node", "args": [entry.as_posix()]}}}


def _register_mcp(root: Path) -> None:
    """Print (never auto-apply) the generic shared-wiki MCP registration.

    Registration is the user's explicit choice: auto-adding could clobber an existing
    `shared-wiki` server (e.g. from another adapter) and would ignore CLAUDE_CONFIG_DIR
    sandboxing. Register ONCE at user level; the server self-configures per project from
    each project's `.shared-adapter/settings.json` -> `wiki.sharedMcp`.
    """
    reg = mcp_registration(root)
    entry = Path(reg["mcpServers"]["shared-wiki"]["args"][0])
    if not entry.is_file():
        _log("shared-wiki MCP not built yet; build it, then run `manage.sh mcp-registration` for the JSON.")
        return
    _log("Register the shared-wiki MCP ONCE at user level (server reads CLAUDE_PROJECT_DIR and self-configures")
    _log("from each project's .shared-adapter/settings.json -> wiki.sharedMcp). Do NOT add SHARED_WIKI_MCP_* env.")
    _log("Register with:  claude mcp add-json -s user shared-wiki '" + json.dumps(reg["mcpServers"]["shared-wiki"]) + "'")
    _log("or paste into your user MCP config:")
    print(json.dumps(reg, indent=2))


# --- commands ----------------------------------------------------------------

def cmd_install(host: str, project: str | None) -> int:
    # regenerate self-contained lanhu analysts from neutral sources so install is idempotent
    try:
        subprocess.run([sys.executable, str(REPO_ROOT / "lib" / "sync_role_prd.py"), "sync", str(REPO_ROOT)],
                       check=True)
    except subprocess.CalledProcessError:
        _log("WARN: role-prd sync failed; installing existing agent files as-is.")
    root = install_payload()
    build_mcp(root)
    install_skills(root)
    install_agents(root)
    _register_mcp(root)
    target = resolve_project_target(project)
    if target is not None:
        merge_hooks(target, root)
        write_host_block(target, root, host)
        _log(f"grill-adapter installed (user level + project {target}, host={host}).")
    else:
        _log("grill-adapter installed (user level). Pass a project root to wire hooks + a host CLAUDE.md block.")
    return 0


def cmd_uninstall(project: str | None) -> int:
    for name in user_level_skills(REPO_ROOT):
        d = user_skills_dir() / name
        if d.is_dir():
            shutil.rmtree(d)
            _log(f"removed skill {d}")
    for name in user_level_agents(REPO_ROOT):
        f = user_agents_dir() / name
        if f.is_file() and _marker() in f.read_text(encoding="utf-8", errors="replace"):
            f.unlink()
            _log(f"removed agent {f}")
    root = payload_root()
    if root.is_dir():
        shutil.rmtree(root)
        _log(f"removed payload {root}")
    target = resolve_project_target(project)
    if target is not None:
        if unmerge_hooks(target):
            _log(f"stripped hooks from {target}/.claude/settings.json")
        if remove_host_block(target):
            _log(f"stripped host block from {target}/CLAUDE.md")
    _log("grill-adapter uninstalled.")
    return 0


def cmd_verify(host: str, project: str | None) -> int:
    problems: list[str] = []
    root = payload_root()
    for rel in payload_dirs(REPO_ROOT):
        if not (root / rel).is_dir():
            problems.append(f"missing payload dir: {root / rel}")
    for name in user_level_skills(REPO_ROOT):
        if not (user_skills_dir() / name / "SKILL.md").is_file():
            problems.append(f"missing installed skill: {name}")
        else:
            txt = (user_skills_dir() / name / "SKILL.md").read_text(encoding="utf-8", errors="replace")
            if PLACEHOLDER in txt:
                problems.append(f"unreplaced placeholder in installed skill: {name}")
    for name in user_level_agents(REPO_ROOT):
        if not (user_agents_dir() / name).is_file():
            problems.append(f"missing installed agent: {name}")
    target = resolve_project_target(project)
    if target is not None:
        settings = _load_json(target / ".claude" / "settings.json")
        cmds = [
            h.get("command", "")
            for groups in settings.get("hooks", {}).values()
            for g in groups for h in g.get("hooks", [])
        ]
        if not any(_hook_marker() in c for c in cmds):
            problems.append(f"no grill-adapter hooks in {target}/.claude/settings.json")
        claude_md = target / "CLAUDE.md"
        if not (claude_md.is_file() and "grill-adapter:host:" in claude_md.read_text(encoding="utf-8", errors="replace")):
            problems.append(f"no grill-adapter host block in {target}/CLAUDE.md")
    if problems:
        for p in problems:
            print(f"FAIL: {p}", file=sys.stderr)
        return 1
    _log("grill-adapter verify OK")
    return 0


def cmd_status(project: str | None) -> int:
    root = payload_root()
    print(f"payload root (__GRILL_ADAPTER_ROOT__): {root}  ({'present' if root.is_dir() else 'absent'})")
    print(f"user skills dir: {user_skills_dir()}")
    print(f"user agents dir: {user_agents_dir()}")
    mcp_built = (root / "mcp" / "shared-wiki" / "dist" / "index.js").is_file()
    print(f"shared-wiki MCP built: {mcp_built}")
    target = resolve_project_target(project)
    if target is not None:
        print(f"project: {target}")
        settings = _load_json(target / ".claude" / "settings.json")
        cmds = [h.get("command", "") for groups in settings.get("hooks", {}).values()
                for g in groups for h in g.get("hooks", [])]
        print(f"  grill-adapter hooks: {sum(1 for c in cmds if _hook_marker() in c)}")
        claude_md = target / "CLAUDE.md"
        has_block = claude_md.is_file() and "grill-adapter:host:" in claude_md.read_text(encoding="utf-8", errors="replace")
        print(f"  host block present: {has_block}")
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
    parser = argparse.ArgumentParser(description="grill-adapter installer (host-agnostic, zero patching).")
    sub = parser.add_subparsers(dest="command", required=True)
    default_host = str(load_manifest(REPO_ROOT).get("defaultHost", "grill"))
    for cmd in ("install", "verify"):
        p = sub.add_parser(cmd)
        p.add_argument("project", nargs="?", default=None, help="Project root for the project-level step")
        p.add_argument("--host", default=default_host, help="Host convention to wire (grill|plain)")
    for cmd in ("uninstall", "status"):
        p = sub.add_parser(cmd)
        p.add_argument("project", nargs="?", default=None)
    sub.add_parser("mcp-registration")
    args = parser.parse_args()

    if args.command == "install":
        return cmd_install(args.host, args.project)
    if args.command == "uninstall":
        return cmd_uninstall(args.project)
    if args.command == "verify":
        return cmd_verify(args.host, args.project)
    if args.command == "status":
        return cmd_status(args.project)
    if args.command == "mcp-registration":
        print(json.dumps(mcp_registration(payload_root()), indent=2))
        return 0
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
