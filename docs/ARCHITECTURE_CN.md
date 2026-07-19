# grill-adapter 架构

grill-adapter 是 host 无关的 Claude Code adapter，**本身以 Claude Code 插件形式发货**。它把 wiki / Lanhu / source-truth 作为**独立 skill/agent/hook** 挂进宿主工作流，**绝不 patch 宿主 skill**——只靠项目 `CLAUDE.md` 约定块 + Claude Code hook 接线。这是不被宿主（grill）版本 churn 波及的关键不变式。

## 三层 + 多子系统同构

```
        ┌───────── 插件边界（.claude-plugin/plugin.json）─────────┐
        │  skills/ · agents/ · hooks/hooks.json · .mcp.json      │
        │  随 `claude plugin install` 一起激活，同一作用域         │
        └────────────────────────────────────────────────────────┘
┌─────────────────────────────────────────────────────────┐
│  Host 适配器（薄、可插拔、零 skill patch）                 │
│   ├─ grill-host  ← 默认：CLAUDE.md 约定块                 │
│   └─ plain       ← 裸 Claude Code：手动调触点              │
│   ※ 约定块写进目标项目、在插件外，故只点名 skill、无路径     │
├─────────────────────────────────────────────────────────┤
│  各子系统的 host 无关触点                                  │
│   （独立 skill/agent + host-adapter 约定 + 可选 hook）      │
│   · wiki:        Disclose · Carry · Bind · Capture        │
│   · Lanhu:       Intake                                   │
│   · source-truth: Verify · Lint                          │
│   · break-loop:  Debug-retrospective → Capture           │
├─────────────────────────────────────────────────────────┤
│  引擎（从旧 adapter 原样移植）                             │
│   scripts/* (wiki + lanhu + source_truth) · .graph.json  │
│   · shared-wiki MCP · 索引 · doctor · export · templates  │
└─────────────────────────────────────────────────────────┘
```

**不变式**：host 适配器绝不 patch 宿主 skill。grill-host 只靠项目 `CLAUDE.md` 约定 + 插件自带 hook。

安装模型与 `${CLAUDE_PLUGIN_ROOT}` 替换边界见 `HOST_INTEGRATION_CN.md`。

## wiki 稳定契约：4 个 host 无关触点

| 触点 | 机制 | 落到 grill |
|---|---|---|
| **Disclose** 选 wiki | 独立 `/grill-adapter:wiki-research` skill（驱动 `grill-adapter:wiki-researcher` agent），任何 host 都能调 | grill-with-docs 质询期 |
| **Carry** 带约束 | schema-v6 `.adapter/context/<feature-slug>.wiki-context.json` 保存绑定 digest、atomic Note ID/path/hash/summary、独立 Skill Card 与 ticket roster 指纹，绝不保存 Note body；锚点是 feature，不是 plan 文件 | to-tickets 据 Obsidian selection 写 |
| **Bind** 执行期 reread | schema-v5：① 精确：每 ticket `/grill-adapter:wiki-materialize <ticket>` ② `wiki-reread` hook 粗兜底；schema-v6 的权威 stable-ID reread 属于后续 Bind 切片，当前 fail-closed | implement 逐 ticket |
| **Capture** 回写 | `/grill-adapter:update-wiki`（语义门），其可选前置步经 `grill_context_to_candidates.py` 吃 grill CONTEXT.md/ADR 增量 | code-review 后 |

`/grill-adapter:wiki-materialize` 复用 `scripts/wiki_materialize_task.py`——本地 + `github_mcp` 两类 section 统一取，含**执行期有界 1 跳 `depends-on` 闭包**。

### 子系统触点

- **Lanhu Intake**：`/grill-adapter:lanhu-requirements` skill + 2 个 analyst agent（`agents/lanhu-{frontend,backend}-requirements-analyst.md`，由 `lib/sync_role_prd.py` 从 `role-prd/analyst.common.md` + `role-prd/{frontend,backend}.md` 生成）→ `.lanhu/.../index.md` 证据包（**只作输入**）。生成源住在 `role-prd/` 而非 `agents/`：插件会把 `agents/*.md` 全部注册成 agent，模板放那儿会变幽灵 agent。详见 `LANHU_CN.md`。
- **source-truth Verify**：`/grill-adapter:source-truth-check` skill（复用 `scripts/source_truth_settings.py`），规划期渲染 policy prompt（spec-pre/plan-pre/plan-review）。**Lint**：`hooks/source-truth-lint.sh`（PostToolUse/Stop）对真实 changed files 跑 `source_truth_common` lint。
- **break-loop**：`/grill-adapter:break-loop` skill，调试复盘 → 交 `/grill-adapter:update-wiki`。

## 引擎组件

- **执行层脚本 `scripts/*.py`**：`wiki_common`（1 跳邻居、depends-on 闭包等共享逻辑）、`wiki_context_render`（schema-v5 只读兼容，以及 schema-v6 Obsidian metadata Carry 的校验/渲染/scaffold/finalize；task 身份与指纹来自 host 产出的 ticket roster）、`wiki_materialize_task`（schema-v5 的单一固定取数器：本地 + github_mcp reread + 1 跳闭包；v6 在 stable-ID Bind 支持前明确拒绝）、`wiki_generate_section_index` / `wiki_update_check` / `wiki_migrate_helper`（支持 `--wiki-dir`，仓库根即 wiki）、`wiki_graph_neighbors`（有界 1 跳邻居查询）、`wiki_section` / `wiki_read_section` / `wiki_select_target` / `wiki_apply_update` / `wiki_import` / `init-wiki` / `update-wiki`；`source_truth_settings` / `source_truth_common`；`lanhu_settings`；`scaffold_practice_skill`；`grill_context_to_candidates`（grill→wiki 桥）。
- **shared-wiki MCP `mcp/shared-wiki/`**：TypeScript MCP server，随插件 `.mcp.json` 自启，启动读 Claude Code 注入的 `CLAUDE_PROJECT_DIR`，从该项目 `.shared-adapter/settings.json` 的 `wiki.sharedMcp` 自我配置；提供 `shared_wiki_read` / `read-section(s)` / `graph-neighbors` / PR 等工具（插件内工具名前缀 `mcp__plugin_grill-adapter_shared-wiki__`）；`read-sections` / `graph-neighbors` 也以 CLI 子命令暴露给执行层（`wiki_materialize_task.py` 硬约束 reread 唯一走这条，不在别处用 python 重新 clone；命令解析顺序：`--shared-wiki-cmd` > `SHARED_WIKI_MCP_CMD` > 注册发现 > 插件内 bundle 自定位）。`npm run build` 是 **esbuild 单文件打包**，产物 `dist/index.js` **提交进仓库**——插件缓存没有安装期构建步骤；类型检查另走 `npm run typecheck`。
- **模板与导出**：`wiki-template/`（bootstrap 到目标项目 `.adapter/wiki/`）、`wiki-repo-skills/` + `wiki-repo-ci/`（`export-wiki-skills` 钉版本写入独立 wiki 仓库 `.claude/` 的作者侧 skill + 图重建 Action）、`contracts/`（`wiki-context-v5` / `wiki-selection-v1` / `ticket-roster-v1` schema 示例）。

## section 图

wiki 页被 `<!-- wiki-section:xxx summary="..." -->` 标记切成 section；section 间以 `[[page#section]]` **typed 边**（如 `depends-on`）互链。跨页根 `.graph.json`（section 边 + backlinks）是**派生物**，由 `wiki_migrate_helper.py --generate-indexes` 从 markdown 生成，供维护 + lint + MCP `graph-neighbors` + 执行期 1 跳闭包读。渐进披露：先读目录 `index.md` 与逐文档 `<stem>.index.md`，再选相关 section，不整树扫。

## shared MCP（跨 repo 共享）

连接是**每项目**的：消费项目在自己的 `.shared-adapter/settings.json` 的 `wiki.sharedMcp`（`repoUrl`/`baseBranch`/`remote`/`wikiRoot`/`displayRoot`/`draftPr`）声明连哪个 shared wiki。MCP server 随插件发货、**一份通用、不含 repo 的注册**（插件根 `.mcp.json`），启动读 `CLAUDE_PROJECT_DIR` 从该项目 settings 自配置。没声明的项目 fail-closed（无 MCP shared wiki）。server 的**可见范围跟随插件作用域**（`--scope project` 即只在该项目可见），插件自带 MCP 无法单独选作用域。注意区分：消费项目的 `wiki.sharedMcp` 是「连接」，shared wiki 仓库内的 `.shared-adapter/settings.json` 才是该 wiki 的「治理」（policy）。

## 执行期闭包

执行期**不追链**：图只供维护 + lint。每个选中的硬约束 section 只做**有界 1 跳 `depends-on` 闭包**——把 `indexed` 的 `depends-on` section 目标折进同一批 materialize（renderer 已闭合 project / 本地 shared 两类本地 root；`github_mcp` 因图在远端由 `wiki_materialize_task.py` 经 `graph-neighbors` CLI 补齐）；未 `indexed` 的目标按 gate 跳过并计数报告。核心逻辑 `wiki_common.one_hop_neighbors` + `wiki_common.depends_on_closure_targets`，两条路径共用，「什么算被闭合的边」永不分叉。1 跳、去重、缺 `.graph.json` 静默降级为空 + caveat。

## 必保引擎不变式

- markdown 唯一真相源，`.graph.json` 派生物；不引外部图数据库。
- 执行期不追链：只消费 `.wiki-context.json` + 有界 1 跳 `depends-on` 闭包（不传递、去重、缺图 no-op）。
- section 级 `[[page#section]]` typed 边 + 渐进披露。
- shared wiki 每项目绑定：`wiki.sharedMcp` 声明；MCP 读 `CLAUDE_PROJECT_DIR`；未声明 fail-closed。
- root-specific 写授权：默认 skip/ask；授权标志不绕 `refuse`。
- shared wiki 中性化：`blockedTerms`/`blockedPatterns`。
- 换绑/revision 漂移 fail-closed。
- Lanhu evidence-package 边界：只作输入，不写进 wiki / 最终 spec / 验收。
