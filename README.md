# grill-adapter

A **host-agnostic Claude Code and Codex plugin** that adds a sectioned, cross-repo **project wiki**, **source-of-truth** verification, and **break-loop** debugging retrospectives as standalone skills, agent roles, and hooks. It **never patches a host skill**: it wires into your workflow through a project convention block (`CLAUDE.md` or `AGENTS.md`) and the plugin's own hooks, so host upgrades can't break it.

It defaults to [**grill** (mattpocock/skills)](https://github.com/mattpocock/skills) as the front-end (`grill-with-docs → to-spec → to-tickets → implement → code-review`), and also runs on **plain Claude Code or Codex**.

> grill-adapter is the host-agnostic successor to a Superpowers-coupled adapter. It keeps all of that adapter's functionality and drops exactly one thing: the mechanism that patched anchors into the host's own skills. See [`docs/DECISIONS_CN.md`](docs/DECISIONS_CN.md).

## What it solves

A code assistant forgets your project's durable rules between sessions and across repos. grill-adapter gives your project a **wiki as tier-2 knowledge**: bound Obsidian atomic Notes with stable IDs, typed links, governed Skill Cards, and — crucially — **approved task binding**, so planning freezes user-visible role-specific Markdown contracts that implementation and review consume unchanged. grill's own `CONTEXT.md` glossary + `docs/adr/` are tier-1; ADRs remain the sole decision authority, while the Wiki receives only project-scoped, identity-bound execution-constraint projections after review. Carry and freeze revalidate each projection's project-relative ADR path and content identity; drift blocks snapshot generation rather than silently capturing stale constraints.

## The four wiki touchpoints (stable contract)

| Touchpoint | Mechanism | grill stage |
|---|---|---|
| **Disclose** | `/grill-adapter:wiki-research` skill -> `wiki-researcher` navigates a revision-keyed frontmatter-only catalog and searches selected branches with hard limits plus scope-bound cursors, privately stable-rereads candidate Note bodies, then selects relevant non-expired atomic Notes and only merged/base-synchronized Skill Cards whose local pack identity is available; review-due Notes remain eligible with warnings | `/grill-with-docs` |
| **Carry** | schema-v6 `.wiki-context.json` records bound Source digests and metadata-only Note/Card identity, optional normalized freshness timestamps, name/version/contract hash, role routing, and ticket fingerprints; candidates verified as unrelated use `not-applicable` and never enter execution | `/to-tickets` |
| **Bind** | Planning freezes all roster tasks' schema-v2 `<taskId>.wiki-implement.md` and `<taskId>.wiki-review.md` from the same approved Source snapshot in one batch; `/grill-adapter:wiki-readiness` binds their digests, revalidates every role-visible Note/Card plus one-hop closure freshness, and derives `<taskId>.wiki-review-handoff.md` without overwriting the approved reviewer snapshot | `/to-tickets` approval + `/implement` + before `/code-review` subagents |
| **Capture** | every stage appends to one feature journal. After review, `/grill-adapter:update-wiki` dispatches exactly one isolated `wiki-capture` agent; semantic candidate/target/content judgment stays private, while deterministic staging revalidates journal, binding/root policy, identity, hash, schema, links and paths. Accepted drafts enter the current project's machine-local Outbox without modifying formal base. Optional `status`/`review` inspect the queue; review/publish use isolated semantic consolidation, immutable exclude/defer/delete/revise/merge corrections, and explicit no-feature-slug `publish` creates one resumable draft PR per eligible repository while deferring conflicts | after `/code-review`; publish later when convenient |

Plus **source-of-truth** verify (`/grill-adapter:source-truth-check`) + lint hook and **break-loop** debugging retrospective (`/grill-adapter:break-loop`).

The read-only `obsidian_wiki_maintenance_summary` MCP operation provides a bounded,
metadata-only view of active/review-due/expired/contradictory Note identities, repository/base
health, unresolved corrections, and unfinished Capture work across canonical feature journals. Its
versioned envelope requires an explicit normalized `asOf` clock and applies `identityLimit`
globally to each identity category. It is advisory maintenance/navigation input only: it contains
no Note body or journal prose and never participates in task identity, Wiki readiness, or Bind.
`/grill-adapter:wiki-maintenance audit <feature-slug>` (or the Codex `$` form) delegates bounded
freshness, contradiction, and overloaded-Note judgment to the single read-only
`wiki-maintenance` role. The same role also supports `wiki-maintenance consolidation
<feature-slug>`: a dedicated read-only MCP operation deterministically replays unresolved
canonical feature candidates, exposes their prose only inside the child, and binds the result to
journal/candidate digests. Equivalent durable claims become one replacement proposal group,
contradictory claims require a user decision, and contracts with different triggers, lifecycles,
failure modes, or validation paths stay separate. The coordinator persists only a validated
schema-v1 metadata report and returns its path plus a compact summary; candidate claims, evidence,
Note bodies, and agent reasoning never enter the main session. The role cannot write Notes,
journals, Git, or publishing state, and failures or journal drift are `broken` rather than empty
success.

## Local feature workspace

Each feature's local, uncommitted workflow state is grouped under
`.grill-adapter/context/<feature-slug>/`, with fixed names such as
`wiki-context.json`, `ticket-roster.json`, `<taskId>.wiki-approval.json`,
`<taskId>.wiki-implement.md`, `<taskId>.wiki-review.md`, `wiki-candidates.jsonl`,
`wiki-readiness.json`, `wiki-session-state.json`, `wiki-maintenance-audit.json`,
`wiki-maintenance-consolidation.json`, plus legacy recovery-only `wiki-publish.json`.
The session state and Wiki maintenance summary are non-authoritative navigation projections. The
schema-v2 session state contains the last explicitly selected task, local artifact digests,
canonical candidate lifecycle counts, and validated maintenance-report counts. At SessionStart the
hook rejects drifted/malformed projections and deterministically emits at most three recovery,
maintenance, Capture, or continuation actions. It never substitutes for `wiki-readiness` validation.
This keeps selection, task identity, review handoffs, and recovery state together in the file explorer.
Existing legacy flat artifacts remain resumable through their explicit paths;
new work uses the directory layout.

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

For Obsidian runtime configuration and the loopback write bridge, install the
companion local CLI once:

```bash
npm install --global grill-adapter @grill-adapter/obsidian-wiki
obsidian-wiki init
obsidian-wiki doctor
obsidian-wiki bridge start
```

It creates a commented JSONC example and a non-overwriting active config under
`~/.config/grill-adapter/`. Use `obsidian-wiki config set-location <path>` to
move the active file. The plugin MCP and the independently running bridge use
the same config; the bridge remains loopback-only and token-authenticated.
`obsidian-wiki bridge start` starts it in the background and exits after the
health check passes. Use
`obsidian-wiki bridge stop` for a graceful shutdown and
`obsidian-wiki bridge restart` to stop the old process and start a detached
background instance.

Both runtimes discover **13 skills, 3 agents, 3 hook events, and 1 MCP server**. Claude Code registers `wiki-researcher`, `wiki-maintenance`, and `wiki-capture` directly; Codex entry skills dispatch one general sub-agent with the same complete role prompt and no inherited conversation. The returned agent path is only a handle: waiting on that exact path is the only permitted next operation, and the main session must repeat bounded waits until terminal before messaging the user, asking questions, calling MCP, or continuing. Dispatch/capacity/lifecycle failures are classified as `broken` rather than an empty success. The `obsidian-wiki` server exposes bound formal reads, bounded private Capture inputs, the constrained Capture Plan staging interface, and the project-scoped Outbox runtime (`status`, `review`, immutable `correct`, digest-bound batch `publish`). `SessionStart` emits at most one counts-only queued-work reminder. Governed proposal/apply and the loopback write bridge remain for migration and legacy recovery; normal Capture never invokes them or edits formal base. Use `$grill-adapter:setup-init-obsidian` (or `/grill-adapter:setup-init-obsidian`) to initialize a project (details: [`docs/OBSIDIAN_WIKI_CN.md`](docs/OBSIDIAN_WIKI_CN.md)).

> **Plugin installation is availability, not project opt-in.** Skills, agents, hooks, and bundled
> MCP servers take the plugin's scope, and Codex's current `plugin add` command has no project/user
> scope flag. Workflow-facing skills therefore run a read-only activation preflight before any
> adapter action or filesystem write. They proceed only when the user explicitly invokes a
> grill-adapter skill, the project contains the host marker installed in `AGENTS.md`/`CLAUDE.md`,
> or `.grill-adapter/settings.json` exists. A standalone grill project remains inert and does not
> create `.grill-adapter/`; global hooks run the same project preflight and remain silent even when
> an unwired project contains leftover adapter context.

**2. Wire the project** — the one thing a plugin cannot touch is your project's durable instruction file:

```bash
git clone https://github.com/YWJ-hy/grill-adapter.git
cd grill-adapter
./manage.sh install /path/to/your/project --host grill --runtime claude
# Codex: --runtime codex; teams using both: --runtime both
./manage.sh doctor /path/to/your/project                   # validate active provider + adoption state
```

For a new project, use `setup-init-obsidian` to state how many Wiki libraries the project needs and what each is for; it then guides each Source binding and the machine-local registry. Each project may have at most one project Source plus multiple shared Sources. `doctor` must report `obsidian-native` and healthy before formal research. Existing legacy projects use `migrate-wiki`; for a GitHub-backed legacy shared Wiki, pass its repository URL explicitly to the migration planner. There is no legacy runtime fallback.

- The convention block is marker-delimited and **names skills only — it carries no install path**, so plugin upgrades can't rot it. Claude Code uses `CLAUDE.md`; Codex uses `AGENTS.md`.
- To use **grill only** while keeping a globally installed grill-adapter bundle, run
  `./manage.sh uninstall /path/to/your/project --runtime claude|codex|both` to remove the project
  marker. Existing `.grill-adapter/` working state is not deleted automatically.
- **Zero host-skill patching.** To remove: drop `grill-adapter@grill-adapter` from the project's `.claude/settings.json` `enabledPlugins` (a project-scope plugin is a committed, team-shared setting, so `claude plugin uninstall` deliberately refuses to remove it for you — use `claude plugin disable grill-adapter@grill-adapter --scope local` to switch it off for yourself only), then `./manage.sh uninstall /path/to/your/project` to strip the convention block.
- On Codex, remove the bundle with `codex plugin remove grill-adapter@grill-adapter`, then run `./manage.sh uninstall /path/to/your/project --runtime codex`.

New to grill? Follow [`docs/SETUP_AND_USAGE_CN.md`](docs/SETUP_AND_USAGE_CN.md), which installs grill first.

## Commands

`manage.sh` only covers project wiring and the wiki utilities; the plugin itself is managed by `claude plugin` / `/plugin` or `codex plugin`.

The repository also publishes a root `grill-adapter` npm package. It carries the plugin payload and exposes a versioned CLI, so you do not need to clone or enter this repository after installing it:

```bash
npm install --global grill-adapter
cd /path/to/your/project
grill-adapter install --runtime codex --host grill
grill-adapter doctor
npm update --global grill-adapter
```

To make the installed npm package the local plugin source, run `grill-adapter package-root`, then add that path as a Claude/Codex marketplace. See [`docs/NPM_RELEASE_CN.md`](docs/NPM_RELEASE_CN.md) for automatic versioning and publishing, Trusted Publishing, local plugin refresh, `npm pack --dry-run`, and `npx` workflows.

On macOS/Linux, run the Bash entrypoints directly. On Windows, `C:\Windows\System32\bash.exe` is often only the WSL launcher; if WSL has no `/bin/bash`, use the PowerShell entrypoints below. They select a working Git Bash/MSYS2/Cygwin installation automatically.

```
./manage.sh install|uninstall|verify|status <project> [--host grill|plain] [--runtime claude|codex|both]
./manage.sh bootstrap-wiki <project> [--template name] [--wiki-root project|shared]  # legacy only
./manage.sh init-wiki <project> [hint]
./manage.sh export-wiki-skills <wiki-repo> [--no-graph-ci]
./manage.sh doctor <project>
./manage.sh self-test [project]
./manage.sh release-check <project>
bash acceptance/codex-context-budget-installed.sh "$PWD"  # installed Codex context budget, no model request
```

```powershell
.\manage.ps1 install <project> --host grill --runtime both
.\manage.ps1 self-test
.\release-check.ps1 <project>
.\tests\run-smoke.ps1 -Name install-project-wiring-smoke.sh
```

Install Git for Windows if no usable Bash is found. To select a non-default installation, set `GRILL_ADAPTER_BASH` to its `bash.exe` path.

The installed Codex context budget command reports the plugin skill catalog, project host block,
live MCP tool schemas, and Codex-rendered research/readiness/Capture/Maintenance stage payloads in UTF-8 bytes.
Default limits live in `contracts/codex-context-budget-v1.json`; pass `--thresholds <json>` to test
an alternate budget. The report contains measurements and stable resource names only. This size
gate complements, and does not replace, plugin discovery smoke or installed model-driven acceptance.

Legacy Wiki migration to Obsidian runs through `/grill-adapter:migrate-wiki` (Claude) or `$grill-adapter:migrate-wiki` (Codex): deterministic no-write plan -> explicit confirmation -> dedicated PR branches + governed CAS apply -> one draft PR per repository -> merge/base sync -> read-only runtime verify -> separate cutover confirmation. Before planning, use the bounded legacy section-repartition pass when existing markers are too broad; it proposes marker/index/graph metadata changes without rewriting body prose. After migration, the Obsidian Note maintenance/repartition mode audits active bound Notes in batches and applies confirmed old-Note updates plus new sibling Notes through the existing bridge/journal/publisher/verify path. Use repeatable `--exclude-path shared:.claude/skills` when a legacy subtree must not migrate; the exclusion is part of the plan and source digest. Apply persists the full plan, binding/policy snapshot, and every CAS intent before the first bridge write; interrupted runs reconcile only exact expected states and never write migration content on base. Verify rejects open PRs, stale bases, source/binding/coverage drift, missing/duplicate/out-of-Source Notes, hash/search/edge/pack drift, and never overwrites human edits. Cutover reruns verify, rejects an active schema-v5 sidecar, and preserves only the plan-selected legacy roots byte-for-byte as mechanically enforced read-only archives.

## Relationship to grill / Claude Code / Codex

grill (mattpocock/skills) is a read-only, versioned plugin bundle you subscribe to; grill-adapter never forks or edits it. grill-adapter adds wiki, source-truth, and break-loop touchpoints *around* grill by convention. Without a grill-adapter host marker or settings, grill runs alone and adapter skills do not create local state. With the `grill` host block installed, that block remains inert until the corresponding grill stage is explicitly invoked; an ordinary direct request does not activate Wiki touchpoints. On plain Claude Code or Codex you invoke the same skills yourself at the matching moments (see the runtime-specific `plain` host block).

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
- npm (for the published `grill-adapter` CLI or the Obsidian runtime CLI)

## License

[MIT](LICENSE)
