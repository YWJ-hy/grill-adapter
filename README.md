# grill-adapter

A **host-agnostic Claude Code adapter** that adds three things to your coding workflow — a sectioned, cross-repo **project wiki**; **Lanhu (蓝湖) requirements intake**; and **source-of-truth** verification — as standalone skills, agents, and hooks. It **never patches a host skill**: it wires into your workflow purely through a project `CLAUDE.md` convention block and Claude Code hooks, so host upgrades can't break it.

It defaults to [**grill** (mattpocock/skills)](https://github.com/mattpocock/skills) as the front-end (`/grill-with-docs → /to-spec → /to-tickets → /implement → /code-review`), and also runs on **plain Claude Code**.

> grill-adapter is the host-agnostic successor to a Superpowers-coupled adapter. It keeps all of that adapter's functionality and drops exactly one thing: the mechanism that patched anchors into the host's own skills. See [`docs/DECISIONS_CN.md`](docs/DECISIONS_CN.md).

## What it solves

A code assistant forgets your project's durable rules between sessions and across repos. grill-adapter gives your project a **wiki as tier-2 knowledge**: sectioned pages with typed `[[page#section]]` edges, a derived `.graph.json`, cross-repo sharing over an MCP server, and — crucially — **execution-time binding**, so the rules that constrain a task are re-read as authoritative section text while that task is implemented. grill's own `CONTEXT.md` glossary + `docs/adr/` are tier-1; grill-adapter bridges their increments up into the wiki.

## The four wiki touchpoints (stable contract)

| Touchpoint | Mechanism | grill stage |
|---|---|---|
| **Disclose** | `/wiki-research` skill → `wiki-researcher` agent selects relevant sections | `/grill-with-docs` |
| **Carry** | `.wiki-context.json` sidecar records the selection (source-aware refs + `sharedWiki` identity) | `/to-tickets` |
| **Bind** | `/wiki-materialize <ticket>` re-reads hard-constraint sections (+ bounded 1-hop `depends-on` closure); a session-level hook is the coarse backstop | `/implement` |
| **Capture** | `/update-wiki` writes durable knowledge back (fed by the `grill_context_to_candidates.py` bridge) | after `/code-review` |

Plus **Lanhu intake** (`/lanhu-requirements`), **source-of-truth** verify (`/source-truth-check`) + lint hook, and **break-loop** debugging retrospective (`/break-loop`).

## Install (30 seconds, if you already have grill)

```bash
git clone https://github.com/YWJ-hy/grill-adapter.git
cd grill-adapter
./manage.sh install /path/to/your/project --host grill   # user-level skills/agents + wire this project
./manage.sh bootstrap-wiki /path/to/your/project           # seed .superpowers/wiki/
./manage.sh doctor /path/to/your/project                   # sanity-check
```

- **User level (once, cross-project):** skills → `~/.claude/skills/`, agents → `~/.claude/agents/`, a runtime payload (`scripts/`, `contracts/`, `hooks/`, the built shared-wiki MCP) → `~/.claude/grill-adapter/`.
- **Project level (per project):** hook entries merged into `.claude/settings.json`, a host convention block appended to `CLAUDE.md`.
- **Zero host-skill patching.** Uninstall with `./manage.sh uninstall /path/to/your/project`.

New to grill? Follow [`docs/SETUP_AND_USAGE_CN.md`](docs/SETUP_AND_USAGE_CN.md), which installs grill first.

## Commands

```
./manage.sh install|uninstall|verify|status [project] [--host grill|plain]
./manage.sh mcp-registration
./manage.sh bootstrap-wiki <project> [--template name] [--wiki-root project|shared]
./manage.sh init-wiki <project> [hint]
./manage.sh export-wiki-skills <wiki-repo> [--no-graph-ci]
./manage.sh doctor <project>
./manage.sh self-test [project]
./manage.sh release-check <project>
```

## Relationship to grill / Claude Code

grill (mattpocock/skills) is a read-only, versioned plugin bundle you subscribe to; grill-adapter never forks or edits it. grill-adapter is the layer that adds the wiki/Lanhu/source-truth touchpoints *around* grill by convention. On plain Claude Code you invoke the same skills yourself at the matching moments (see the `plain` host block).

## Documentation

| Doc | For |
|---|---|
| [`docs/SETUP_AND_USAGE_CN.md`](docs/SETUP_AND_USAGE_CN.md) | 从未装过 grill 的用户：装 grill + 装 grill-adapter + 端到端走一遍 |
| [`QUICKSTART_CN.md`](QUICKSTART_CN.md) | 已装过 grill：5 分钟跑通 |
| [`docs/ARCHITECTURE_CN.md`](docs/ARCHITECTURE_CN.md) | 三层架构、4 触点、引擎、section 图、shared MCP、执行期闭包 |
| [`docs/HOST_INTEGRATION_CN.md`](docs/HOST_INTEGRATION_CN.md) | host 适配器模型、grill/plain 约定块全文、install 模型 |
| [`docs/USER_FLOW_CN.md`](docs/USER_FLOW_CN.md) | 最终用户端到端流程 |
| [`docs/LANHU_CN.md`](docs/LANHU_CN.md) | Lanhu 需求录入专章 |
| [`docs/DEVELOPMENT_CN.md`](docs/DEVELOPMENT_CN.md) | 开发与验收原则、测试分层 |
| [`docs/DECISIONS_CN.md`](docs/DECISIONS_CN.md) | 为什么这么设计 |
| [`docs/BUILD_PLAN_CN.md`](docs/BUILD_PLAN_CN.md) | 本项目的构建蓝图（存档） |

## Requirements

- Claude Code (CLI, desktop, or IDE extension)
- Python 3.9+
- Node.js ≥ 20 (only for the shared-wiki MCP server; built during install)

## License

[MIT](LICENSE)
