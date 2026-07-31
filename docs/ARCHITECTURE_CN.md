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

**激活边界**：plugin 安装只提供能力，不等于项目 opt-in。workflow-facing skill 在任何
adapter 动作或文件写入前调用只读 `scripts/project_activation.py`；项目 host marker、
`.grill-adapter/settings.json` 或用户对当前 skill 的显式调用三者至少满足一个才继续。
否则按 standalone grill 静默退出且不得创建 `.grill-adapter/`。三个全局 hook 也执行
同一项目 preflight；未接线项目即使残留旧 context 也不注入 adapter 提示。

安装模型与 `${CLAUDE_PLUGIN_ROOT}` 替换边界见 `HOST_INTEGRATION_CN.md`。

## wiki 稳定契约：4 个 host 无关触点

| 触点 | 机制 | 落到 grill |
|---|---|---|
| **Disclose** 选 wiki | 独立 `/grill-adapter:wiki-research` skill（驱动 `grill-adapter:wiki-researcher` agent）：先用硬 limit + scope-bound cursor 读 frontmatter-only bound Source catalog，再在选定分支做稳定有界检索并私下复核少量非 expired Note body；review-due 保留 warning，任何 host 都能调 | grill-with-docs 质询期 |
| **Carry** 带约束 | schema-v6 `.grill-adapter/context/<feature-slug>/wiki-context.json` 保存 binding digest、atomic Note ID/path/hash/summary/可选 freshness timestamps、已验证 Skill Card 的 name/version/contract hash/triggers/roles 与 ticket roster 指纹，绝不保存 Note body；Carry 重算 freshness 并拒绝 expired；锚点是 feature，不是 plan 文件；direct task 可由 readiness 在首次代码修改前 late Carry | to-tickets，或无 formal context 的 implement 入口 |
| **Bind** 角色化 task contract | 规划确认后以一次 roster batch 生成同一批准快照的 `<taskId>.wiki-implement.md` 与 `<taskId>.wiki-review.md`，并在 digest 保护的 metadata 中记录直接 Note 与 1 跳闭包 freshness；Bind 重算状态，拒绝期间到期的 Note，把新产生的 review-due warning 包在不变批准正文之外，reviewer 使用派生的 `<taskId>.wiki-review-handoff.md` | implement 逐 task + code-review 两轴前 |
| **Capture** 回写 | `/grill-adapter:update-wiki`（最终证据 reconciliation + related-claim 显式归并 + 语义门），其可选前置步经 `grill_context_to_candidates.py` 吃 grill CONTEXT.md/ADR 增量；ADR 只生成 project-only metadata projection candidate，Obsidian provider 经 proposal → loopback bridge CAS apply → receipt allowlist；Git/draft-PR publish 仅在用户显式请求时执行 | code-review 后 |

Readiness 不是第五个 Wiki 触点，而是 implement/review 对 Carry + Bind 的编排 seam：implement 入口为 formal ticket 原样复用 finalized context，或为 direct issue/manual 建稳定单任务 roster；规划确认后冻结一对角色化 Markdown task contract，review 只复用既有 receipt 与 reviewer 文件，绝不 late research。每次显式 task 选择会 best-effort 刷新 feature 级 `wiki-session-state.json`，仅投影 task ID、artifact digest、readiness、候选数与恢复命令，供跨会话提示；它不是 task contract，也不参与任何校验。Carry 允许把研究员候选显式标记为 `not-applicable`，保留审计记录但不路由进执行上下文。`no-relevant`/`disabled`/`broken`/`unknown` 与任何 snapshot 失败只生成 caveat。ADR projection 在 Carry 和 freeze 都重新定位项目内权威文件并核对 path-derived source ID 与 content hash；失败同样进入 `broken`。Wiki 内容验证仍 fail-closed，宿主 implement/review 可用性 fail-open；失败路径不允许部分、陈旧或编辑过的 Markdown 进入执行上下文。

`/grill-adapter:wiki-materialize` 复用 `scripts/wiki_materialize_task.py`——规划 freeze 时只从绑定的 Obsidian Source 取数，生成角色化 Markdown，含**有界 1 跳 `depends-on` 闭包**；执行期只验证并消费冻结文件。

知识 freshness 是 Note frontmatter 的可选语义：`verified_at`、`review_after`、`expires_at` 只接受规范化 UTC 秒级时间。状态在每次 catalog/search/read/Carry/finalize/freeze/Bind 时派生，不持久化为权威字段；无 metadata 视为 fresh，review-due 保持可用并给 warning，expired 不得进入正式 selection、sidecar 或角色合同。freeze 把所有角色可见 Note/Card 与 1 跳 `depends_on` 闭包的 freshness 身份写进 schema-v2 批准快照 `freshnessEntries`，Bind 因而能在不访问当前 Source、不修改批准正文的前提下处理跨时钟边界；缺少该清单的 schema-v1 快照必须重新 freeze。它与 Source binding、Git repository/base synchronization freshness 正交，不能互相降级或绕过。受治理写路径可以定位 expired Note，但 proposal/apply 的新内容必须不再 expired 且不得声明未来验证时间。

### 子系统触点

- **source-truth Verify**：`/grill-adapter:source-truth-check` skill（复用 `scripts/source_truth_settings.py`），规划期渲染 policy prompt（spec-pre/plan-pre/plan-review）。**Lint**：`hooks/source-truth-lint.sh`（PostToolUse/Stop）对真实 changed files 跑 `source_truth_common` lint。
- **break-loop**：`/grill-adapter:break-loop` skill，调试复盘 → 交 `/grill-adapter:update-wiki`。
- **Candidate Journal**：`/grill-adapter:candidate-journal` + `scripts/wiki_candidate_journal.py`。所有知识生产阶段只向同一 feature-scoped JSONL 追加 `candidate` / `supersede` / `outcome` 事件；Capture 前完整 replay，损坏、截断、冲突重复与非法状态转换 fail-closed。`correction` kind 结构化保存 affected `sourceId` + stable `wikiId`、修正主张、证据引用与 observed impact；pending/deferred 状态只派生 metadata-only maintenance signal，不改变 active Note，kept 必须携带命中同一 identity 的 applied update receipt。Obsidian outcome 可带严格的 `writeReceipt`，只保存 provider/repository/binding/Note/path/hash 写身份，不保存 Note body 或 secret；`proposed` 只能配 `deferred`，`applied` 只能配 `kept`。Skill Card 候选还强制 name/version/contract hash/roles/triggers 与 `pending` 状态；其 kept receipt 必须携带与 staged registration 完全一致的 bridge-validated identity。ADR 增量使用独立 `adr_execution_projection` kind，只保存 `project-adr` source ID/path/content hash 与 project-only scope；Capture 只写 hard constraint 派生投影，按 source ID 唯一更新，空约束跳过，MCP 与 bridge 都拒绝 Shared target 和重复 authority identity。普通 `decision` candidate 不变。`stage-card` 计算 pack hash 并幂等追加，不写 discovery index；同一 pack 只允许一张 Card；applied/open-PR Card 仍 pending，merge + base 同步后 MCP 重验通过才 discoverable。grill bridge 的完全相同 replay 按稳定 candidate identity 幂等跳过，使中断后的 Capture 能继续；journal 保留作恢复 receipt，不进入 Obsidian、不提交。
- **Maintenance Summary**：`obsidian_wiki_maintenance_summary` 只读聚合当前可读 binding 的 frontmatter metadata 与 canonical feature journal fold，输出 schema-v1 非权威 envelope。调用必须带规范 UTC 秒级 `asOf` 作为显式确定性 freshness clock；knowledge freshness、typed `contradicts` identity、repository/base health 与 candidate lifecycle 分组独立，`identityLimit` 对每类 stable identity 全局生效并带 `truncated` 标志，readable binding 另有 200 的结构硬上限。MCP 复用 `wiki_candidate_journal.py` 的完整 replay，不复制状态机；任何 journal 损坏、binding 不健康或 correction identity 不属于当前 readable active bound identities 都 fail-closed。输出不含 Note body/summary、candidate claim/evidence/impact、outcome reason、journal transcript、unbound identity、secret 或项目/Vault 路径，也绝不参与 task identity、readiness、Bind 或写授权。

## 引擎组件

- **执行层脚本 `scripts/*.py`**：`project_activation`（workflow skill 的只读项目 opt-in preflight）、`wiki_common`（1 跳邻居、depends-on 闭包等共享逻辑）、`wiki_context_render`（schema-v6 Obsidian metadata Carry 的校验/渲染/scaffold/finalize；task 身份与指纹来自 host 产出的 ticket roster）、`wiki_task_snapshot`（角色化 Markdown task contract 的生成、摘要校验、body digest 与原子写入）、`wiki_readiness`（direct issue/manual 单任务 roster + per-task readiness receipt 原子记录/校验 + role snapshot freeze + fail-open reviewer handoff）、`wiki_session_state`（非权威的 feature 级续接摘要投影）、`wiki_materialize_task`（冻结 task Markdown 消费；仅 freeze 路径做绑定 Obsidian Note/Card 读取 + 1 跳闭包）、`wiki_candidate_journal`（候选事件校验、锁内追加、生命周期 fold）、`wiki_adr_projection`（经 agent 提炼后的约束机械渲染/空约束 skip）、`wiki_migration_plan`（本地或用户显式 Git legacy source 的 snapshot-bound no-write plan）、`wiki_migration_apply`（CAS apply / merged-base verify / cutover）、`wiki_generate_section_index` / `wiki_update_check` / `wiki_migrate_helper`、`wiki_graph_neighbors`、`wiki_section` / `wiki_read_section` / `wiki_select_target` / `wiki_apply_update` / `wiki_import` / `init-wiki` / `update-wiki`；`source_truth_settings` / `source_truth_common`；`scaffold_practice_skill`；`grill_context_to_candidates`（grill→journal 桥）。
- **obsidian-wiki MCP + write/publish bundle `mcp/obsidian-wiki/`**：同一提交型 bundle 暴露绑定只读工具、metadata-only maintenance summary、Note proposal/apply MCP/JSON CLI、可恢复 `publish` JSON CLI，以及独立 `serve-write-bridge` 入口。bundle 同时携带 summary 所需的 canonical journal reader。bridge 只监听 loopback，以 token 鉴权并对 bound Source 做 policy/neutrality/CAS 校验。publisher 只消费 journal 中 `kept+applied` receipts，按 `repositoryRef` 锁仓并在锁内重验 base/remote/path/hash；commit 前用 Git staged-tree object ID 保存可恢复身份，创建 allowlist commit + draft PR、协调 peer PR，并把 worktree 恢复到 clean base。run manifest 留在项目 `.grill-adapter/context/`，开放 PR 不进入 formal read。
- **模板、迁移与导出**：`wiki-template/`、`wiki-repo-skills/` + `wiki-repo-ci/`、`contracts/`。`migrate-wiki` 在迁移前提供 bounded legacy section-repartition proposal，在迁移后提供 Obsidian Note maintenance/repartition；两者都只先产出 proposal/plan，确认后复用既有 Source binding、proposal/apply、candidate journal、publisher、CAS 与 verify。`wiki_migration_plan.py` fail-closed 产出 deterministic plan，并为 update 固化审核时 Note hash；`wiki_migration_apply.py` 在首个 bridge 写前固化完整 plan、binding/policy snapshot 与 CAS intent roster，并先切到专用 PR branch，再经两阶段 CAS 与 receipt publisher 写 draft PR。恢复只接受精确 before/seed/final state，`publishing` 中断从 publisher manifest 对账。verify 从不可变 plan 推导 coverage，重验 legacy source 与 binding/policy，只认 merged + synchronized base；cutover 另需确认、拒绝 active schema-v5 sidecar，并只把 plan 覆盖的 legacy root 标成机械只读 archive，bootstrap/init/update/import/migration 写路径都必须拒绝归档 root。契约示例还包括 migration plan/manifest、wiki context/selection、ticket roster、candidate journal 与 publish run manifest。
- **rollout 运维门**：`doctor.sh` 只读识别 `obsidian-native`、`shadow-validation`、`cutover-complete`；active Obsidian provider 的 bundle/status/health 任一失败均非零退出并卡 release-check。shadow 只保留 legacy roots 作为 migration evidence，正式四触点不双读、不 fallback；`bootstrap-wiki` 在 active Obsidian provider 下拒绝重新播种 legacy root。

## section 图与渐进披露

legacy Markdown Wiki 页被 `<!-- wiki-section:xxx summary="..." -->` 标记切成 section；section 间以 `[[page#section]]` **typed 边**（如 `depends-on`）互链。跨页根 `.graph.json`（section 边 + backlinks）是**派生物**，由 `wiki_migrate_helper.py --generate-indexes` 从 markdown 生成，供维护 + lint + MCP `graph-neighbors` + 执行期 1 跳闭包读。legacy/migration 维护时的渐进披露先读目录 `index.md` 与逐文档 `<stem>.index.md`，再选相关 section，不整树扫。

正式 Obsidian runtime 不读取 legacy index：researcher 先通过受 binding 限制、硬上限分页的 `obsidian_wiki_catalog` 看 Source 相对目录和 Note 元数据，再只在相关 `sourceId` / `pathPrefix` 分支中检索。catalog 由已验证 Git revision + binding digest 定位的 frontmatter metadata view 提供，branch pagination 不调用 Obsidian 全文 read，也不提供正文 hash；search 在任何 Note 呈现前完成 Source/path containment，并按稳定 path 顺序、最大 50 的 limit 与绑定 query/scope 的不透明 cursor 分页。目录、关键词和一跳图关系只负责召回候选；正文只在 researcher 子 agent 内做有界语义复核，最终入选 Note 仍经 stable batch reread 生成权威 `contentHash` / `snapshotHash`，selection 与 schema-v6 sidecar 只保存 metadata/hash，不保存 Note body。

## Obsidian Source（跨 repo 共享）

跨项目共享通过项目 `.grill-adapter/settings.json` 的 `wiki.obsidian.bindings` 声明 `role: shared` 的 Source。legacy GitHub shared-wiki 仓库不属于运行时绑定；迁移时由用户显式提供 URL，planner 临时 clone 并固定 commit。

## Freeze 期闭包

Freeze **不追链**：每个选中的硬约束 Note 只做**有界 1 跳 `depends-on` 闭包**，由绑定 Obsidian MCP 的 `graph-neighbors` 返回并去重读取；生成的 role-specific Markdown 在实现与评审期间固定消费。

## 必保引擎不变式

- markdown 唯一真相源，`.graph.json` 派生物；不引外部图数据库。
- task contract 不追链：只消费批准的 role-specific Markdown + 已冻结的有界 1 跳 `depends-on` 闭包（不传递、去重、缺图 no-op）。
- section 级 `[[page#section]]` typed 边 + 渐进披露。
- Obsidian Source 每项目绑定：`wiki.obsidian.bindings` 声明；freeze 时未绑定、换绑或 revision 漂移 fail-closed。
- root-specific 写授权：默认 skip/ask；授权标志不绕 `refuse`。
- shared wiki 中性化：`blockedTerms`/`blockedPatterns`。
- 换绑/revision 漂移 fail-closed。
- Obsidian rollout 不引入 legacy runtime fallback；cutover 前 legacy roots 只供 migration verify，cutover 后只读归档。
