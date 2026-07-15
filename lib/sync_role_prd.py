#!/usr/bin/env python3
"""Generate self-contained Lanhu evidence analyst agents."""

from __future__ import annotations

import argparse
import sys
from dataclasses import dataclass
from pathlib import Path

from subagent_models import apply_agent_model

COMMON_SKELETON = Path('agents/lanhu-requirements-analyst.common.md')


@dataclass(frozen=True)
class RoleConfig:
    role: str
    label: str
    agent_name: str
    template_path: Path
    output_h1: str
    allowed_content: str
    output_format: str
    prd_template_name: str
    primary_artifact: str
    fallback_artifact: str

    @property
    def agent_path(self) -> Path:
        return Path('agents') / f'{self.agent_name}.md'

    @property
    def prd_template(self) -> str:
        return self.prd_template_name


ROLE_CONFIGS = (
    RoleConfig(
        role='frontend',
        label='frontend unified',
        agent_name='lanhu-frontend-requirements-analyst',
        template_path=Path('role-prd/frontend.md'),
        output_h1='# 前端 Lanhu 需求输入包',
        allowed_content='frontend source requirement facts, page/module/control/state/interaction evidence, field and data rules, permission or visibility differences when source evidence states them, system response rules, boundary conditions, source-content-specific fact sections when needed, optional design demo evidence, and open questions; never acceptance criteria, tests, implementation details, frontend/backend boundary inference, or risk/exception inference',
        output_format='frontend_unified',
        prd_template_name='frontend_unified_requirement_input_package',
        primary_artifact='index.md plus frontend-prd/prd.md plus optional frontend-prd/design/index.html and frontend-prd/design/assets/',
        fallback_artifact='not applicable; frontend always writes frontend-prd/prd.md, and the design demo is optional',
    ),
    RoleConfig(
        role='backend',
        label='backend markdown',
        agent_name='lanhu-backend-requirements-analyst',
        template_path=Path('role-prd/backend.md'),
        output_h1='# 后端相关 Lanhu 原始需求证据包',
        allowed_content='backend-related source business object facts, business flow facts, business rule facts, business state facts, permission/data visibility facts, data-related source facts, and source-content-specific business source fact sections when fixed themes do not fit, without acceptance criteria, tests, API/database design, implementation details, frontend/backend boundary inference, or risk/exception inference',
        output_format='backend_markdown',
        prd_template_name='backend_evidence_package',
        primary_artifact='index.md plus backend-prd/prd.md or backend-prd/prds/*.md',
        fallback_artifact='not applicable',
    ),
)


def fence_for(text: str) -> str:
    longest = 0
    current = 0
    for char in text:
        if char == '`':
            current += 1
            longest = max(longest, current)
        else:
            current = 0
    return '`' * max(3, longest + 1)


def render_template_block(root: Path, config: RoleConfig) -> str:
    content = (root / config.template_path).read_text(encoding='utf-8').rstrip()
    fence = fence_for(content)
    return '\n'.join(
        [
            f'### {config.label.title()} source template',
            '',
            f'Generated verbatim from `{config.template_path.as_posix()}`. Treat the template content below as the selected Lanhu package contract and the complete {config.label} source template.',
            '',
            f'{fence}markdown',
            content,
            fence,
        ]
    )


def render_format_contract(config: RoleConfig) -> str:
    if config.role == 'frontend':
        return '\n'.join(
            [
                'This agent is the only frontend Lanhu analyst. The old separate frontend Markdown and frontend HTML package variants are deprecated and must not be used.',
                '',
                'Required frontend output contract:',
                '- Create `index.md` as the `.lanhu/MM-DD-需求名称/` package entrypoint, role marker, file relationship guide, lightweight confirmation status, and reading order authority.',
                '- Always write the main frontend requirements input at `frontend-prd/prd.md` inside the package or page package.',
                '- When source evidence includes design稿、页面结构、控件关系、状态切换 or an interaction surface that is clearer by seeing/clicking, write `frontend-prd/design/index.html` as the optional interactive structure mirror.',
                '- Put only demo-supporting static files under `frontend-prd/design/assets/`, and only when the user explicitly requests/authorizes asset preservation or the demo cannot be understood without a local supporting asset.',
                '- `frontend-prd/prd.md` does not require fixed topic headings. Organize by page, flow, module, business object, state, permission difference, or another source-driven structure that is clearest.',
                '- `frontend-prd/prd.md` must focus on requirement rules, constraints, boundaries, system responses, field/data rules, state triggers, and open questions; avoid repeating layout/control/click-path details that `frontend-prd/design/index.html` already shows clearly.',
                '- `frontend-prd/design/index.html` is a 1:1 interactive structure mirror of source pages, controls, states, dialogs/drawers/tabs/dropdowns, and user operation paths. It is not production frontend implementation and not a second full PRD.',
                '- Demo placeholder/sample data must be explicitly labeled as sample data used only to show page structure.',
                '- Residual uncertainty should be handled through `待确认问题` or the confirmation gate; avoid scattering uncertainty labels throughout正文.',
                '- Backend output must never use this frontend contract.',
            ]
        )
    return '\n'.join(
        [
            'This agent handles backend Markdown-only output. Backend output is intentionally unchanged by the frontend package refactor.',
            '',
            'Required backend output contract:',
            '- Create `index.md` as the package entrypoint, role marker, reading guide, and relationship authority.',
            '- Write either `backend-prd/prd.md` or `backend-prd/prds/*.md` depending on `deliveryBoundaryCount`.',
            '- Do not write `frontend-prd/design/index.html`, package-root `index.html`, `prototype/index.html`, or any `.html` file.',
            '- If the main session routes frontend-only package fields to this backend agent, ignore those fields and keep backend Markdown-only output.',
        ]
    )


def render_agent(root: Path, config: RoleConfig) -> str:
    skeleton = (root / COMMON_SKELETON).read_text(encoding='utf-8')
    replacements = {
        '{{AGENT_NAME}}': config.agent_name,
        '{{ROLE}}': config.role,
        '{{ROLE_LABEL}}': config.label,
        '{{OUTPUT_FORMAT}}': config.output_format,
        '{{PRD_TEMPLATE}}': config.prd_template,
        '{{ROLE_PRD_TEMPLATE_PATH}}': config.template_path.as_posix(),
        '{{ROLE_PRD_SOURCE_PATHS}}': f'`{config.template_path.as_posix()}`',
        '{{ROLE_OUTPUT_H1}}': config.output_h1,
        '{{ROLE_ALLOWED_CONTENT}}': config.allowed_content,
        '{{PRIMARY_ARTIFACT}}': config.primary_artifact,
        '{{FALLBACK_ARTIFACT}}': config.fallback_artifact,
        '{{FORMAT_CONTRACT}}': render_format_contract(config),
        '{{ROLE_PRD_TEMPLATE_BLOCK}}': render_template_block(root, config),
    }
    rendered = skeleton
    for key, value in replacements.items():
        rendered = rendered.replace(key, value)
    unresolved = [token for token in replacements if token in rendered]
    if unresolved:
        raise SystemExit(f'Unresolved placeholders in generated {config.agent_name}: {unresolved}')
    return rendered.rstrip() + '\n'


def installed_relative(relative: Path) -> Path:
    parts = relative.parts
    if parts and parts[0] == 'overlays':
        return Path(*parts[1:])
    return relative


def sync(root: Path) -> bool:
    changed = False
    for config in ROLE_CONFIGS:
        path = root / config.agent_path
        rendered = render_agent(root, config)
        original = path.read_text(encoding='utf-8') if path.exists() else None
        if original != rendered:
            path.write_text(rendered, encoding='utf-8', newline='\n')
            changed = True
            print(f'Updated {config.agent_path.as_posix()}')
    return changed


def check(root: Path, target_root: Path | None = None) -> bool:
    ok = True
    check_root = target_root or root
    for config in ROLE_CONFIGS:
        rendered = render_agent(root, config)
        if target_root:
            from subagent_models import model_for_agent

            model = model_for_agent(root, config.agent_name)
            if model:
                rendered = apply_agent_model(rendered, config.agent_name, model)
        relative = installed_relative(config.agent_path) if target_root else config.agent_path
        path = check_root / relative
        if not path.is_file():
            location = 'installed file' if target_root else 'overlay file'
            print(f'Missing generated Lanhu role analyst {location}: {relative.as_posix()}', file=sys.stderr)
            ok = False
            continue
        original = path.read_text(encoding='utf-8')
        if original != rendered:
            location = 'installed file' if target_root else 'overlay file'
            print(f'Lanhu role analyst is out of sync in {location}: {relative.as_posix()}', file=sys.stderr)
            ok = False
    return ok


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description='Generate self-contained Lanhu evidence analyst agents.')
    parser.add_argument('mode', choices=('sync', 'check'))
    parser.add_argument('root', nargs='?', default=str(Path(__file__).resolve().parents[1]))
    parser.add_argument('--target-root')
    return parser.parse_args()



def _configure_stdio() -> None:
    for stream in (sys.stdout, sys.stderr):
        if not hasattr(stream, "reconfigure"):
            continue
        try:
            stream.reconfigure(encoding="utf-8", errors="replace", newline="\n")
        except (OSError, ValueError):
            pass

def main() -> None:
    _configure_stdio()
    args = parse_args()
    root = Path(args.root).resolve()
    target_root = Path(args.target_root).resolve() if args.target_root else None
    if args.mode == 'sync':
        sync(root)
    else:
        if not check(root, target_root):
            raise SystemExit(1)


if __name__ == '__main__':
    main()
