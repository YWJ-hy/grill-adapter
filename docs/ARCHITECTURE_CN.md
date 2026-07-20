# grill-adapter 架构

grill-adapter 是 host 无关的 coding-agent adapter，**同时以 Claude Code 与 Codex 插件形式发货**。它把 wiki / Lanhu / source-truth 作为独立 skill/agent-role/hook 挂进宿主工作流，**绝不 patch 宿主 skill**——只靠项目 `CLAUDE.md`/`AGENTS.md` 约定块 + plugin hook 接线。

## 三层 + 多子系统同构

```
        ┌──── 插件边界（.claude-plugin + .codex-plugin）──────────┐
        │  skills/ · agents/ · hooks/hooks.json · .mcp.json      │
        │  随 `claude plugin install` 一起激活，同一作用域         │
        └────────────────────────────────────────────────────────┘
┌─────────────────────────────────────────────────────────┐
│  Host 适配器（薄、可插拔、零 skill patch）                 │
│   ├─ grill-host  ← 默认：CLAUDE.md / AGENTS.md 约定块      │
│   └─ plain       ← 裸 Claude Code / Codex：手动调触点       │
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

**不变式**：host 适配器绝不 patch 宿主 skill。grill-host 只靠项目持久指令约定 + 插件自带 hook。

安装模型与 `${CLAUDE_PLUGIN_ROOT}` 替换边界见 `HOST_INTEGRATION_CN.md`。

## wiki 稳定契约：4 个 host 无关触点

| 触点 | 机制 | 落到 grill |
|---|---|---|
| **Disclose** 选 wiki | 独立 `/grill-adapter:wiki-research` skill（驱动 `grill-adapter:wiki-researcher` agent），任何 host 都能调 | grill-with-docs 质询期 |
| **Carry** 带约束 | schema-v6 `.adapter/context/<feature-slug>.wiki-context.json` 保存绑定 digest、atomic Note ID/path/hash/summary、独立 Skill Card 与 ticket roster 指纹，绝不保存 Note body；锚点是 feature，不是 plan 文件 | to-tickets 据 Obsidian selection 写 |
| **Bind** 执行期 reread | schema-v5/v6 都由每 ticket `/grill-adapter:wiki-materialize <ticket>` 精确读取；schema-v6 仅经 bound Obsidian MCP stable-ID 读取路由硬 Note、角色 Skill Card 和 1 跳 `depends_on`，任何漂移 fail-closed；`wiki-reread` hook 只做 SessionStart 提醒 | implement 逐 ticket |
| **Capture** 回写 | `/grill-adapter:update-wiki`（语义门），其可选前置步经 `grill_context_to_candidates.py` 吃 grill CONTEXT.md/ADR 增量；Obsidian provider 经 proposal → loopback bridge CAS apply | code-review 后 |

`/grill-adapter:wiki-materialize` 复用 `scripts/wiki_materialize_task.py`——本地 + `github_mcp` 两类 section 统一取，含**执行期有界 1 跳 `depends-on` 闭包**。

### 子系统触点

- **Lanhu Intake**：`lanhu-requirements` skill + 2 个 analyst role prompt（`agents/lanhu-{frontend,backend}-requirements-analyst.md`，由 `lib/sync_role_prd.py` 生成）→ `.lanhu/.../index.md` 证据包（**只作输入**）。Claude Code 直接注册 agent；Codex 由 skill 读取同一 prompt 后派生通用 sub-agent。
- **source-truth Verify**：`/grill-adapter:source-truth-check` skill（复用 `scripts/source_truth_settings.py`），规划期渲染 policy prompt（spec-pre/plan-pre/plan-review）。**Lint**：`hooks/source-truth-lint.sh`（PostToolUse/Stop）对真实 changed files 跑 `source_truth_common` lint。
- **break-loop**：`/grill-adapter:break-loop` skill，调试复盘 → 交 `/grill-adapter:update-wiki`。
- **Candidate Journal**：`/grill-adapter:candidate-journal` + `scripts/wiki_candidate_journal.py`。所有知识生产阶段只向同一 feature-scoped JSONL 追加 `candidate` / `supersede` / `outcome` 事件；Capture 前完整 replay，损坏、截断、冲突重复与非法状态转换 fail-closed。grill bridge 的完全相同 replay 按稳定 candidate identity 幂等跳过，使中断后的 Capture 能继续；journal 保留作恢复 receipt，不进入 Obsidian、不提交。

## 引擎组件

- **执行层脚本 `scripts/*.py`**：`wiki_common`（1 跳邻居、depends-on 闭包等共享逻辑）、`wiki_context_render`（schema-v5 只读兼容，以及 schema-v6 Obsidian metadata Carry 的校验/渲染/scaffold/finalize；task 身份与指纹来自 host 产出的 ticket roster）、`wiki_materialize_task`（schema-v5 的单一固定取数器：本地 + github_mcp reread + 1 跳闭包）、`wiki_candidate_journal`（候选事件校验、锁内追加、生命周期 fold）、`wiki_generate_section_index` / `wiki_update_check` / `wiki_migrate_helper`、`wiki_graph_neighbors`、`wiki_section` / `wiki_read_section` / `wiki_select_target` / `wiki_apply_update` / `wiki_import` / `init-wiki` / `update-wiki`；`source_truth_settings` / `source_truth_common`；`lanhu_settings`；`scaffold_practice_skill`；`grill_context_to_candidates`（grill→journal 桥）。
- **obsidian-wiki MCP + write bridge `mcp/obsidian-wiki/`**：同一提交型 bundle 暴露绑定只读工具、Note proposal/apply MCP/JSON CLI，以及独立 `serve-write-bridge` 入口。MCP 只按当前项目 binding 选择 Source；bridge 只监听 loopback，以环境 token 鉴权，且只接受启动白名单中的项目与 Source root。每次请求重新读取该项目 binding + Source manifest，独立计算 effective policy/neutrality，再执行 schema/identity/typed-link、`_meta` 与 expected-hash CAS 校验；per-Note lock 串行 bridge 写，create 以 no-replace atomic link 落盘，update 在临时文件准备后紧邻 atomic rename 重查 hash。bridge 不随 MCP 自动开放端口。
- **shared-wiki MCP `mcp/shared-wiki/`**：TypeScript MCP server，随插件 MCP 声明自启；Claude Code 从 `CLAUDE_PROJECT_DIR`、Codex 从 MCP request 的 `x-codex-turn-metadata.workspaces`（并兼容标准 roots capability）定位项目，再读该项目 `.shared-adapter/settings.json` 自配置；直接 CLI 仍可从进程 cwd 定位。MCP server 先注册工具，首次调用时解析绑定，未声明或多 root 歧义均 fail-closed。其余 read/graph/CLI 与 bundle 不变式不变。
- **模板与导出**：`wiki-template/`、`wiki-repo-skills/` + `wiki-repo-ci/`、`contracts/`（含 wiki context/selection、ticket roster 与 `wiki-candidate-journal-v1.example.jsonl` 契约示例）。

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
