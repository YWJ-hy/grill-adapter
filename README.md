# grill-adapter

A **host-agnostic Claude Code and Codex plugin** that adds a sectioned, cross-repo **project wiki**, **source-of-truth** verification, and **break-loop** debugging retrospectives as standalone skills, agent roles, and hooks. It **never patches a host skill**: it wires into your workflow through a project convention block (`CLAUDE.md` or `AGENTS.md`) and the plugin's own hooks, so host upgrades can't break it.

It defaults to [**grill** (mattpocock/skills)](https://github.com/mattpocock/skills) as the front-end (`grill-with-docs → to-spec → to-tickets → implement → code-review`), and also runs on **plain Claude Code or Codex**.

> grill-adapter is the host-agnostic successor to a Superpowers-coupled adapter. It keeps all of that adapter's functionality and drops exactly one thing: the mechanism that patched anchors into the host's own skills. See [`docs/DECISIONS_CN.md`](docs/DECISIONS_CN.md).

## What it solves

A code assistant forgets your project's durable rules between sessions and across repos. grill-adapter gives your project a **wiki as tier-2 knowledge**: bound Obsidian atomic Notes with stable IDs, typed links, governed Skill Cards, and — crucially — **execution-time binding**, so the rules that constrain a task are reread from the synchronized Source while that task is implemented. grill's own `CONTEXT.md` glossary + `docs/adr/` are tier-1; ADRs remain the sole decision authority, while the Wiki receives only project-scoped, identity-bound execution-constraint projections after review. Carry and Bind revalidate each projection's project-relative ADR path and content identity; drift makes Wiki context unavailable rather than silently using stale constraints.

## The four wiki touchpoints (stable contract)

| Touchpoint | Mechanism | grill stage |
|---|---|---|
| **Disclose** | `/grill-adapter:wiki-research` skill -> `wiki-researcher` selects relevant bound Obsidian atomic Notes and only merged/base-synchronized Skill Cards whose local pack identity is available | `/grill-with-docs` |
| **Carry** | schema-v6 `.wiki-context.json` records bound Source digests and metadata-only Note/Card identity, provider/version/contract hash, role routing, and ticket fingerprints | `/to-tickets` |
| **Bind** | `/grill-adapter:wiki-readiness` establishes/reuses a stable task receipt; `ready` rereads task-routed hard Notes, role-required Cards, and a bounded 1-hop `depends_on` closure for implementers, then revalidates the same receipt into one fail-open reviewer handoff shared by both review axes | `/implement` + before `/code-review` subagents |
| **Capture** | every stage appends to one feature journal; ADR increments become metadata-only execution-projection candidates, `scaffold-practice-skill` stages content-addressed Card candidates, and `/grill-adapter:update-wiki` reconciles final evidence, applies policy-compliant Note/Card changes, then publishes applied receipts as resumable per-repository draft PRs; open PRs remain pending | after `/code-review` |

Plus **source-of-truth** verify (`/grill-adapter:source-truth-check`) + lint hook and **break-loop** debugging retrospective (`/grill-adapter:break-loop`).

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

Both runtimes discover **13 skills, 3 hook events, and 2 MCP servers**. Claude Code also registers `agents/wiki-researcher.md` directly; Codex keeps that prompt as plugin payload and `wiki-research` dispatches a general sub-agent with the same role instructions. The legacy `shared-wiki` and Source-binding `obsidian-wiki` servers are registered together and start automatically. `obsidian-wiki` also exposes proposal/apply tools for governed Note writes plus a resumable GitHub draft-PR publishing CLI; the authenticated HTTP write bridge is an explicit loopback-only companion process and never auto-listens with the MCP server (setup: [`docs/OBSIDIAN_WIKI_CN.md`](docs/OBSIDIAN_WIKI_CN.md)).

> **Claude Code scope is shared.** Skills, agents, hooks, and bundled MCP servers all take the plugin's scope. Codex's current `plugin add` command has no project/user scope flag; project isolation comes from explicit Wiki bindings and fail-closed policy.

**2. Wire the project** — the one thing a plugin cannot touch is your project's durable instruction file:

```bash
git clone https://github.com/YWJ-hy/grill-adapter.git
cd grill-adapter
./manage.sh install /path/to/your/project --host grill --runtime claude
# Codex: --runtime codex; teams using both: --runtime both
./manage.sh doctor /path/to/your/project                   # validate active provider + adoption state
```

For a new project, configure Obsidian Source bindings and the machine-local registry from [`docs/OBSIDIAN_WIKI_CN.md`](docs/OBSIDIAN_WIKI_CN.md); `doctor` must report `obsidian-native` and healthy before formal research. `bootstrap-wiki` remains a legacy-only utility for projects that have not adopted `wiki.provider: obsidian`. Existing legacy projects use the migration flow below and remain in `shadow-validation` until verified cutover; there is no legacy runtime fallback.

- The convention block is marker-delimited and **names skills only — it carries no install path**, so plugin upgrades can't rot it. Claude Code uses `CLAUDE.md`; Codex uses `AGENTS.md`.
- **Zero host-skill patching.** To remove: drop `grill-adapter@grill-adapter` from the project's `.claude/settings.json` `enabledPlugins` (a project-scope plugin is a committed, team-shared setting, so `claude plugin uninstall` deliberately refuses to remove it for you — use `claude plugin disable grill-adapter@grill-adapter --scope local` to switch it off for yourself only), then `./manage.sh uninstall /path/to/your/project` to strip the convention block.
- On Codex, remove the bundle with `codex plugin remove grill-adapter@grill-adapter`, then run `./manage.sh uninstall /path/to/your/project --runtime codex`.

New to grill? Follow [`docs/SETUP_AND_USAGE_CN.md`](docs/SETUP_AND_USAGE_CN.md), which installs grill first.

## Commands

`manage.sh` only covers project wiring and the wiki utilities; the plugin itself is managed by `claude plugin` / `/plugin` or `codex plugin`.

```
./manage.sh install|uninstall|verify|status <project> [--host grill|plain] [--runtime claude|codex|both]
./manage.sh bootstrap-wiki <project> [--template name] [--wiki-root project|shared]  # legacy only
./manage.sh init-wiki <project> [hint]
./manage.sh export-wiki-skills <wiki-repo> [--no-graph-ci]
./manage.sh doctor <project>
./manage.sh self-test [project]
./manage.sh release-check <project>
```

Legacy Wiki migration to Obsidian runs through `/grill-adapter:migrate-wiki` (Claude) or `$grill-adapter:migrate-wiki` (Codex): deterministic no-write plan -> explicit confirmation -> dedicated PR branches + governed CAS apply -> one draft PR per repository -> merge/base sync -> read-only runtime verify -> separate cutover confirmation. Apply persists the full plan, binding/policy snapshot, and every CAS intent before the first bridge write; interrupted runs reconcile only exact expected states and never write migration content on base. Verify rejects open PRs, stale bases, source/binding/coverage drift, missing/duplicate/out-of-Source Notes, hash/search/edge/pack drift, and never overwrites human edits. Cutover reruns verify, rejects an active schema-v5 sidecar, and preserves only the plan-selected legacy roots byte-for-byte as mechanically enforced read-only archives.

## Relationship to grill / Claude Code / Codex

grill (mattpocock/skills) is a read-only, versioned plugin bundle you subscribe to; grill-adapter never forks or edits it. grill-adapter adds wiki, source-truth, and break-loop touchpoints *around* grill by convention. On plain Claude Code or Codex you invoke the same skills yourself at the matching moments (see the runtime-specific `plain` host block).

## Documentation

| Doc | For |
|---|---|
| [`docs/SETUP_AND_USAGE_CN.md`](docs/SETUP_AND_USAGE_CN.md) | 从未装过 grill 的用户：装 grill + 装 grill-adapter + 端到端走一遍 |
| [`QUICKSTART_CN.md`](QUICKSTART_CN.md) | 已装过 grill：5 分钟跑通 |
| [`docs/ARCHITECTURE_CN.md`](docs/ARCHITECTURE_CN.md) | 三层架构、4 触点、引擎、section 图、shared MCP、执行期闭包 |
| [`docs/OBSIDIAN_WIKI_CN.md`](docs/OBSIDIAN_WIKI_CN.md) | Obsidian Source binding、machine registry、manifest 与 fail-closed 诊断 |
| [`docs/OBSIDIAN_ACCEPTANCE_CN.md`](docs/OBSIDIAN_ACCEPTANCE_CN.md) | Desktop + installed Claude Code/Codex 最终验收、shadow validation 与恢复演练 |
| [`docs/HOST_INTEGRATION_CN.md`](docs/HOST_INTEGRATION_CN.md) | host 适配器模型、grill/plain 约定块全文、plugin 安装模型 |
| [`docs/USER_FLOW_CN.md`](docs/USER_FLOW_CN.md) | 最终用户端到端流程 |
| [`docs/DEVELOPMENT_CN.md`](docs/DEVELOPMENT_CN.md) | 开发与验收原则、测试分层 |
| [`docs/DECISIONS_CN.md`](docs/DECISIONS_CN.md) | 为什么这么设计 |
| [`docs/BUILD_PLAN_CN.md`](docs/BUILD_PLAN_CN.md) | 本项目的构建蓝图（存档） |

## Requirements

- Claude Code or Codex (CLI/app)
- Python 3.9+
- Node.js ≥ 20 (to run the bundled Wiki MCP servers; the plugin ships prebuilt bundles — nothing to build)

## License

[MIT](LICENSE)
