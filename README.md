# grill-adapter

A **host-agnostic Claude Code and Codex plugin** that adds three things to your coding workflow — a sectioned, cross-repo **project wiki**; **Lanhu (蓝湖) requirements intake**; and **source-of-truth** verification — as standalone skills, agent roles, and hooks. It **never patches a host skill**: it wires into your workflow through a project convention block (`CLAUDE.md` or `AGENTS.md`) and the plugin's own hooks, so host upgrades can't break it.

It defaults to [**grill** (mattpocock/skills)](https://github.com/mattpocock/skills) as the front-end (`grill-with-docs → to-spec → to-tickets → implement → code-review`), and also runs on **plain Claude Code or Codex**.

> grill-adapter is the host-agnostic successor to a Superpowers-coupled adapter. It keeps all of that adapter's functionality and drops exactly one thing: the mechanism that patched anchors into the host's own skills. See [`docs/DECISIONS_CN.md`](docs/DECISIONS_CN.md).

## What it solves

A code assistant forgets your project's durable rules between sessions and across repos. grill-adapter gives your project a **wiki as tier-2 knowledge**: sectioned pages with typed `[[page#section]]` edges, a derived `.graph.json`, cross-repo sharing over an MCP server, and — crucially — **execution-time binding**, so the rules that constrain a task are re-read as authoritative section text while that task is implemented. grill's own `CONTEXT.md` glossary + `docs/adr/` are tier-1; grill-adapter bridges their increments up into the wiki.

## The four wiki touchpoints (stable contract)

| Touchpoint | Mechanism | grill stage |
|---|---|---|
| **Disclose** | `/grill-adapter:wiki-research` skill → `wiki-researcher` selects relevant bound Obsidian atomic Notes and Skill Cards | `/grill-with-docs` |
| **Carry** | schema-v6 `.wiki-context.json` records bound Source digests and metadata-only Note/Card identity, routing, and ticket fingerprints | `/to-tickets` |
| **Bind** | `/grill-adapter:wiki-materialize <ticket>` rereads schema-v5 hard sections or schema-v6 routed hard Obsidian Notes, required Skill Cards, and a bounded 1-hop `depends_on` closure; all drift gates fail closed | `/implement` |
| **Capture** | every stage appends to one feature journal through `/grill-adapter:candidate-journal`; `/grill-adapter:update-wiki` validates/folds it and records keep/skip/defer outcomes before durable knowledge is written | after `/code-review` |

Plus **Lanhu intake** (`/grill-adapter:lanhu-requirements`), **source-of-truth** verify (`/grill-adapter:source-truth-check`) + lint hook, and **break-loop** debugging retrospective (`/grill-adapter:break-loop`).

## Install (30 seconds, if you already have grill)

**1. Install the plugin**.

Claude Code (from your project directory):

```bash
claude plugin marketplace add YWJ-hy/grill-adapter
claude plugin install grill-adapter@grill-adapter --scope project
```

Codex:

```bash
codex plugin marketplace add YWJ-hy/grill-adapter
codex plugin add grill-adapter@grill-adapter
```

Both runtimes discover **13 skills, 3 hook events, and 2 MCP servers**. Claude Code also registers the 3 files under `agents/` directly; Codex keeps those prompts as plugin payload and the two entry skills dispatch general sub-agents with the same role instructions. The legacy `shared-wiki` and Source-binding `obsidian-wiki` servers are registered together and start automatically.

> **Claude Code scope is shared.** Skills, agents, hooks, and bundled MCP servers all take the plugin's scope. Codex's current `plugin add` command has no project/user scope flag; project isolation comes from explicit Wiki bindings and fail-closed policy.

**2. Wire the project** — the one thing a plugin cannot touch is your project's durable instruction file:

```bash
git clone https://github.com/YWJ-hy/grill-adapter.git
cd grill-adapter
./manage.sh install /path/to/your/project --host grill --runtime claude
# Codex: --runtime codex; teams using both: --runtime both
./manage.sh bootstrap-wiki /path/to/your/project           # seed .adapter/wiki/
./manage.sh doctor /path/to/your/project                   # sanity-check
```

- The convention block is marker-delimited and **names skills only — it carries no install path**, so plugin upgrades can't rot it. Claude Code uses `CLAUDE.md`; Codex uses `AGENTS.md`.
- **Zero host-skill patching.** To remove: drop `grill-adapter@grill-adapter` from the project's `.claude/settings.json` `enabledPlugins` (a project-scope plugin is a committed, team-shared setting, so `claude plugin uninstall` deliberately refuses to remove it for you — use `claude plugin disable grill-adapter@grill-adapter --scope local` to switch it off for yourself only), then `./manage.sh uninstall /path/to/your/project` to strip the convention block.
- On Codex, remove the bundle with `codex plugin remove grill-adapter@grill-adapter`, then run `./manage.sh uninstall /path/to/your/project --runtime codex`.

New to grill? Follow [`docs/SETUP_AND_USAGE_CN.md`](docs/SETUP_AND_USAGE_CN.md), which installs grill first.

## Commands

`manage.sh` only covers project wiring and the wiki utilities; the plugin itself is managed by `claude plugin` / `/plugin` or `codex plugin`.

```
./manage.sh install|uninstall|verify|status <project> [--host grill|plain] [--runtime claude|codex|both]
./manage.sh bootstrap-wiki <project> [--template name] [--wiki-root project|shared]
./manage.sh init-wiki <project> [hint]
./manage.sh export-wiki-skills <wiki-repo> [--no-graph-ci]
./manage.sh doctor <project>
./manage.sh self-test [project]
./manage.sh release-check <project>
```

## Relationship to grill / Claude Code / Codex

grill (mattpocock/skills) is a read-only, versioned plugin bundle you subscribe to; grill-adapter never forks or edits it. grill-adapter adds wiki/Lanhu/source-truth touchpoints *around* grill by convention. On plain Claude Code or Codex you invoke the same skills yourself at the matching moments (see the runtime-specific `plain` host block).

## Documentation

| Doc | For |
|---|---|
| [`docs/SETUP_AND_USAGE_CN.md`](docs/SETUP_AND_USAGE_CN.md) | 从未装过 grill 的用户：装 grill + 装 grill-adapter + 端到端走一遍 |
| [`QUICKSTART_CN.md`](QUICKSTART_CN.md) | 已装过 grill：5 分钟跑通 |
| [`docs/ARCHITECTURE_CN.md`](docs/ARCHITECTURE_CN.md) | 三层架构、4 触点、引擎、section 图、shared MCP、执行期闭包 |
| [`docs/OBSIDIAN_WIKI_CN.md`](docs/OBSIDIAN_WIKI_CN.md) | Obsidian Source binding、machine registry、manifest 与 fail-closed 诊断 |
| [`docs/HOST_INTEGRATION_CN.md`](docs/HOST_INTEGRATION_CN.md) | host 适配器模型、grill/plain 约定块全文、plugin 安装模型 |
| [`docs/USER_FLOW_CN.md`](docs/USER_FLOW_CN.md) | 最终用户端到端流程 |
| [`docs/LANHU_CN.md`](docs/LANHU_CN.md) | Lanhu 需求录入专章 |
| [`docs/DEVELOPMENT_CN.md`](docs/DEVELOPMENT_CN.md) | 开发与验收原则、测试分层 |
| [`docs/DECISIONS_CN.md`](docs/DECISIONS_CN.md) | 为什么这么设计 |
| [`docs/BUILD_PLAN_CN.md`](docs/BUILD_PLAN_CN.md) | 本项目的构建蓝图（存档） |

## Requirements

- Claude Code or Codex (CLI/app)
- Python 3.9+
- Node.js ≥ 20 (to run the bundled Wiki MCP servers; the plugin ships prebuilt bundles — nothing to build)

## License

[MIT](LICENSE)
