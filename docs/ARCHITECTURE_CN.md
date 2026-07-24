# grill-adapter 架构

grill-adapter 是 host 无关的 coding-agent adapter，**同时以 Claude Code 与 Codex 插件形式发货**。它把 wiki / source-truth / break-loop 作为独立 skill/agent-role/hook 挂进宿主工作流，**绝不 patch 宿主 skill**——只靠项目 `CLAUDE.md`/`AGENTS.md` 约定块 + plugin hook 接线。

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
│   · source-truth: Verify · Lint                          │
│   · break-loop:  Debug-retrospective → Capture           │
├─────────────────────────────────────────────────────────┤
│  引擎（从旧 adapter 原样移植）                             │
│   scripts/* (wiki + source_truth) · .graph.json          │
│   · Obsidian MCP · 索引 · doctor · export · templates    │
└─────────────────────────────────────────────────────────┘
```

**不变式**：host 适配器绝不 patch 宿主 skill。grill-host 只靠项目持久指令约定 + 插件自带 hook。

安装模型与 `${CLAUDE_PLUGIN_ROOT}` 替换边界见 `HOST_INTEGRATION_CN.md`。

## wiki 稳定契约：4 个 host 无关触点

| 触点 | 机制 | 落到 grill |
|---|---|---|
| **Disclose** 选 wiki | 独立 `/grill-adapter:wiki-research` skill（驱动 `grill-adapter:wiki-researcher` agent），任何 host 都能调 | grill-with-docs 质询期 |
| **Carry** 带约束 | schema-v6 `.adapter/context/<feature-slug>.wiki-context.json` 保存 binding digest、atomic Note ID/path/hash/summary、已验证 Skill Card 的 provider/name/version/contract hash/triggers/roles 与 ticket roster 指纹，绝不保存 Note body；锚点是 feature，不是 plan 文件；direct task 可由 readiness 在首次代码修改前 late Carry | to-tickets，或无 formal context 的 implement 入口 |
| **Bind** 执行期 reread | `/grill-adapter:wiki-readiness` 先固定/复用 task identity 并记录原子结果；`ready` 时由 `/grill-adapter:wiki-materialize <ticket>` 经 bound Obsidian MCP 按 stable-ID 读取路由硬 Note、当前角色 Card 和 1 跳 `depends_on`；implement 用 implementer 角色，review 在两个隔离 reviewer 前复用同一 receipt、以 reviewer 角色生成单一原子 handoff | implement 逐 task + code-review 两轴前 |
| **Capture** 回写 | `/grill-adapter:update-wiki`（最终证据 reconciliation + related-claim 显式归并 + 语义门），其可选前置步经 `grill_context_to_candidates.py` 吃 grill CONTEXT.md/ADR 增量；ADR 只生成 project-only metadata projection candidate，Obsidian provider 经 proposal → loopback bridge CAS apply → receipt allowlist Git/draft-PR publish | code-review 后 |

Readiness 不是第五个 Wiki 触点，而是 implement/review 对 Carry + Bind 的编排 seam：implement 入口为 formal ticket 原样复用 finalized context，或为 direct issue/manual 建稳定单任务 roster；review 只复用既有 receipt，绝不 late research。reviewer handoff 只有在 receipt/context/render/materialize 全部验证后才原子写入，并由 Standards/Spec 两轴共同只读；`no-relevant`/`disabled`/`broken`/`unknown` 与任何失败只生成 caveat。ADR projection 在 Carry 和 Bind 都重新定位项目内权威文件并核对 path-derived source ID 与 content hash；失败同样进入 `broken`。Wiki 内容验证仍 fail-closed，宿主 implement/review 可用性 fail-open；失败路径不允许部分/陈旧内容进入执行上下文。

`/grill-adapter:wiki-materialize` 复用 `scripts/wiki_materialize_task.py`——只从绑定的 Obsidian Source 取数，含**执行期有界 1 跳 `depends-on` 闭包**。

### 子系统触点

- **source-truth Verify**：`/grill-adapter:source-truth-check` skill（复用 `scripts/source_truth_settings.py`），规划期渲染 policy prompt（spec-pre/plan-pre/plan-review）。**Lint**：`hooks/source-truth-lint.sh`（PostToolUse/Stop）对真实 changed files 跑 `source_truth_common` lint。
- **break-loop**：`/grill-adapter:break-loop` skill，调试复盘 → 交 `/grill-adapter:update-wiki`。
- **Candidate Journal**：`/grill-adapter:candidate-journal` + `scripts/wiki_candidate_journal.py`。所有知识生产阶段只向同一 feature-scoped JSONL 追加 `candidate` / `supersede` / `outcome` 事件；Capture 前完整 replay，损坏、截断、冲突重复与非法状态转换 fail-closed。Obsidian outcome 可带严格的 `writeReceipt`，只保存 provider/repository/binding/Note/path/hash 写身份，不保存 Note body 或 secret；`proposed` 只能配 `deferred`，`applied` 只能配 `kept`。Skill Card 候选还强制 provider/name/version/contract hash/roles/triggers 与 `pending` 状态；其 kept receipt 必须携带与 staged registration 完全一致的 bridge-validated identity。ADR 增量使用独立 `adr_execution_projection` kind，只保存 `project-adr` source ID/path/content hash 与 project-only scope；Capture 只写 hard constraint 派生投影，按 source ID 唯一更新，空约束跳过，MCP 与 bridge 都拒绝 Shared target 和重复 authority identity。普通 `decision` candidate 不变。`stage-card` 计算 pack hash 并幂等追加，不写 discovery index；同一 pack 只允许一张 Card；applied/open-PR Card 仍 pending，merge + base 同步后 MCP 重验通过才 discoverable。grill bridge 的完全相同 replay 按稳定 candidate identity 幂等跳过，使中断后的 Capture 能继续；journal 保留作恢复 receipt，不进入 Obsidian、不提交。

## 引擎组件

- **执行层脚本 `scripts/*.py`**：`wiki_common`（1 跳邻居、depends-on 闭包等共享逻辑）、`wiki_context_render`（schema-v6 Obsidian metadata Carry 的校验/渲染/scaffold/finalize；task 身份与指纹来自 host 产出的 ticket roster）、`wiki_readiness`（direct issue/manual 单任务 roster + per-task readiness receipt 原子记录/校验 + fail-open reviewer handoff）、`wiki_materialize_task`（绑定 Obsidian Note/Card reread + 1 跳闭包）、`wiki_candidate_journal`（候选事件校验、锁内追加、生命周期 fold）、`wiki_adr_projection`（经 agent 提炼后的约束机械渲染/空约束 skip）、`wiki_migration_plan`（本地或用户显式 Git legacy source 的 snapshot-bound no-write plan）、`wiki_migration_apply`（CAS apply / merged-base verify / cutover）、`wiki_generate_section_index` / `wiki_update_check` / `wiki_migrate_helper`、`wiki_graph_neighbors`、`wiki_section` / `wiki_read_section` / `wiki_select_target` / `wiki_apply_update` / `wiki_import` / `init-wiki` / `update-wiki`；`source_truth_settings` / `source_truth_common`；`scaffold_practice_skill`；`grill_context_to_candidates`（grill→journal 桥）。
- **obsidian-wiki MCP + write/publish bundle `mcp/obsidian-wiki/`**：同一提交型 bundle 暴露绑定只读工具、Note proposal/apply MCP/JSON CLI、可恢复 `publish` JSON CLI，以及独立 `serve-write-bridge` 入口。bridge 只监听 loopback，以 token 鉴权并对 bound Source 做 policy/neutrality/CAS 校验。publisher 只消费 journal 中 `kept+applied` receipts，按 `repositoryRef` 锁仓并在锁内重验 base/remote/path/hash；commit 前用 Git staged-tree object ID 保存可恢复身份，创建 allowlist commit + draft PR、协调 peer PR，并把 worktree 恢复到 clean base。run manifest 留在项目 `.adapter/context/`，开放 PR 不进入 formal read。
- **模板、迁移与导出**：`wiki-template/`、`wiki-repo-skills/` + `wiki-repo-ci/`、`contracts/`。`wiki_migration_plan.py` fail-closed 产出 deterministic plan，并为 update 固化审核时 Note hash；`wiki_migration_apply.py` 在首个 bridge 写前固化完整 plan、binding/policy snapshot 与 CAS intent roster，并先切到专用 PR branch，再经两阶段 CAS 与 receipt publisher 写 draft PR。恢复只接受精确 before/seed/final state，`publishing` 中断从 publisher manifest 对账。verify 从不可变 plan 推导 coverage，重验 legacy source 与 binding/policy，只认 merged + synchronized base；cutover 另需确认、拒绝 active schema-v5 sidecar，并只把 plan 覆盖的 legacy root 标成机械只读 archive，bootstrap/init/update/import/migration 写路径都必须拒绝归档 root。契约示例还包括 migration plan/manifest、wiki context/selection、ticket roster、candidate journal 与 publish run manifest。
- **rollout 运维门**：`doctor.sh` 只读识别 `obsidian-native`、`shadow-validation`、`cutover-complete`；active Obsidian provider 的 bundle/status/health 任一失败均非零退出并卡 release-check。shadow 只保留 legacy roots 作为 migration evidence，正式四触点不双读、不 fallback；`bootstrap-wiki` 在 active Obsidian provider 下拒绝重新播种 legacy root。

## section 图

wiki 页被 `<!-- wiki-section:xxx summary="..." -->` 标记切成 section；section 间以 `[[page#section]]` **typed 边**（如 `depends-on`）互链。跨页根 `.graph.json`（section 边 + backlinks）是**派生物**，由 `wiki_migrate_helper.py --generate-indexes` 从 markdown 生成，供维护 + lint + MCP `graph-neighbors` + 执行期 1 跳闭包读。渐进披露：先读目录 `index.md` 与逐文档 `<stem>.index.md`，再选相关 section，不整树扫。

## Obsidian Source（跨 repo 共享）

跨项目共享通过项目 `.shared-adapter/settings.json` 的 `wiki.obsidian.bindings` 声明 `role: shared` 的 Source。legacy GitHub shared-wiki 仓库不属于运行时绑定；迁移时由用户显式提供 URL，planner 临时 clone 并固定 commit。

## 执行期闭包

执行期**不追链**：每个选中的硬约束 Note 只做**有界 1 跳 `depends-on` 闭包**，由绑定 Obsidian MCP 的 `graph-neighbors` 返回并去重读取。

## 必保引擎不变式

- markdown 唯一真相源，`.graph.json` 派生物；不引外部图数据库。
- 执行期不追链：只消费 `.wiki-context.json` + 有界 1 跳 `depends-on` 闭包（不传递、去重、缺图 no-op）。
- section 级 `[[page#section]]` typed 边 + 渐进披露。
- Obsidian Source 每项目绑定：`wiki.obsidian.bindings` 声明；未绑定、换绑或 revision 漂移 fail-closed。
- root-specific 写授权：默认 skip/ask；授权标志不绕 `refuse`。
- shared wiki 中性化：`blockedTerms`/`blockedPatterns`。
- 换绑/revision 漂移 fail-closed。
- Obsidian rollout 不引入 legacy runtime fallback；cutover 前 legacy roots 只供 migration verify，cutover 后只读归档。
