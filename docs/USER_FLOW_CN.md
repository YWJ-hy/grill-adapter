# grill-adapter 用户流程（端到端）

grill-adapter 是一个**宿主无关（host-agnostic）的 Claude Code adapter**：它由一个原本与 Superpowers 强耦合的 adapter fork 而来，现已解耦。它以**独立 skill + hook** 的形式，为宿主工作流补上三样能力：

- 分节化、可跨仓库的**项目 wiki**；
- **真实源校验 / lint（source-of-truth verify/lint）**；
- **break-loop 调试复盘与知识回流**。

核心原则：grill-adapter **从不 patch 任何宿主 skill**，只在宿主阶段之间挂接自己的 skill 与 hook。默认宿主是 **grill**（mattpocock/skills）：

```
/grill-with-docs → /to-spec → /to-tickets → /implement → /code-review
已有 issue / 已确认对话需求 ─────→ /wiki-readiness → /implement
（外加平行支线 /diagnosing-bugs）
```

在没有 grill 的**纯 Claude Code** 上也能运行——只是失去了宿主阶段锚点，改由 hook 兜底。

---

## 四个 wiki 触点

grill-adapter 把「wiki 如何进入并回流到工作流」抽象成四个触点：

| 触点 | 含义 | 载体 |
| --- | --- | --- |
| **Disclose（披露）** | 规划前轻量披露相关 wiki 作上下文 | `/grill-adapter:wiki-research` |
| **Carry（携带）** | 把 bound Obsidian atomic Note/Skill Card 的 metadata 固化进 schema-v6 计划期 sidecar | `.wiki-context.json`（`wiki_context_render.py --scaffold` → `--finalize`，不含 Note body） |
| **Bind（绑定）** | 每个 ticket/reviewer 前 reread 当前任务路由的权威硬约束；v6 使用 Obsidian stable ID，包含角色所需 Skill Card 与 1 跳 `depends_on` 闭包 | `/grill-adapter:wiki-materialize <ticket>`（唯一 reread 路径）+ SessionStart 提醒 |
| **Capture（捕获）** | 各阶段先经 `/grill-adapter:candidate-journal` 追加候选事件；review 后校验/折叠并回写 durable 知识 | `/grill-adapter:update-wiki`（逐条记录 keep/skip/defer；可选前置步骤把 grill 增量转成同款事件） |

Candidate Journal 是贯穿四触点的横切契约：`grill-with-docs`、specification、tickets、implementation、review、debugging 发现的 Wiki Note / Skill Card 候选都进入同一个 `.adapter/context/<feature-slug>.wiki-candidates.jsonl`。Skill Card 候选由 `scaffold-practice-skill stage-card` 在 pack 校验后追加，包含 provider/name/version/contract hash/roles/triggers，并明确为 `pending`；中间阶段不写 Obsidian、不写 legacy discovery index。journal 只追加、不手改、不删除、不提交。

---

## 阶段映射总表

| # | grill 阶段 | grill-adapter 触点 | 命令 | 产物 |
| --- | --- | --- | --- | --- |
| 1 | `/grill-with-docs`（质询/发现） | Disclose | `/grill-adapter:wiki-research`（phase brainstorm） | 轻量上下文；durable 候选可追加 journal（不写 selection/context sidecar） |
| 2 | `/to-spec` | Verify | `/grill-adapter:source-truth-check`（render spec-pre） | 真实源校验结果 |
| 3 | `/to-tickets`（规划） | Disclose + Carry | `/grill-adapter:wiki-research`（phase plan）+ `wiki_context_render.py --scaffold` → 建 ticket roster → `--finalize` + `/grill-adapter:source-truth-check`（plan-pre / plan-review） | `.adapter/context/<feature-slug>.` 下的 `obsidian-wiki-selection.json`、schema-v6 `wiki-context.json`、`ticket-roster.json` |
| 4 | `/implement`（每 ticket/direct task） | Readiness + Bind | 首次代码修改前 `/grill-adapter:wiki-readiness`；`ready` 时做 fingerprint preflight + `/grill-adapter:wiki-materialize <ticket>` | 稳定 task identity + readiness receipt；可用时注入权威硬约束/角色 Skill Card/1 跳闭包，否则按显式 fail-open 结果继续 |
| 5 | `/code-review` | Reviewer Bind + Capture | 启动 Standards/Spec sub-agents 前用 `/grill-adapter:wiki-readiness` 生成共享 reviewer handoff；review 完成后 `/grill-adapter:update-wiki` | 原子 reviewer context 或非阻塞 caveat；随后 journal outcome receipt + staged Note change |
| 6 | `/diagnosing-bugs` | Disclose + Capture | `/grill-adapter:wiki-research`（phase debug）→ `/grill-adapter:break-loop` → `/grill-adapter:update-wiki` | 根因复盘 + wiki 回写 |

---

## 已知 grill 接线缺口（待设计）

以下路径尚未实现完整接线。本节只记录问题，不代表当前运行时已经提供对应兜底：

- **非连续 `/to-spec` 缺少条件式 Disclose**：标准主流程依赖同一上下文中较早的 `/grill-with-docs` brainstorm 结果；直接调用 `/to-spec`、从 `/wayfinder` 汇入、或经 prototype/handoff/compact 换会话后进入 `/to-spec` 时，当前不会先确认本流程是否已经披露相关 Wiki，可能到 `/to-tickets` 才发现冲突。
- **长周期决策与独立设计入口缺少聚焦 Disclose**：`/wayfinder` 的 map/decision ticket、`/improve-codebase-architecture`，以及 `/triage` 进入 grilling/domain-modeling 的分支尚未查询相关 Wiki，可能重复已有调查或重新提出已沉淀的约束。通用 `/research` 仍应保持一手来源调查职责，不应被改造成 Wiki 查询入口。
- **host 约定测试只证明触点名称存在**：当前 smoke 主要验证约定块包含各 adapter skill，尚未证明调用顺序、角色路由和替代流程语义。后续验收需覆盖 direct-to-spec、wayfinder 汇入、独立设计入口等真实 Codex 路径。

---

## 分步流程

### 步骤 1 · `/grill-with-docs`（质询/发现）— Disclose

grill 进入质询/发现阶段时，用 wiki-research 披露与当前话题相关的 wiki 作为**轻量上下文**。

```
/wiki-research      # phase: brainstorm
```

- 由 `wiki-researcher` agent 渐进式挑选相关页面 / 节。
- 此阶段**只披露、不写 selection/context sidecar**。若质询解决了 durable 决策，可经 `/candidate-journal` 以 `grill-with-docs` stage 追加候选，但不写 Obsidian。

### 步骤 2 · `/to-spec` — 真实源 Verify

生成 spec 前，先跑一次真实源校验，避免 spec 建立在过期或臆测的事实上。

```
/source-truth-check      # render: spec-pre
```

specification 阶段若形成 durable contract/decision，经 `/candidate-journal` 追加到同一 feature journal；spec 本身不直接维护 Obsidian。

### 步骤 3 · `/to-tickets`（规划）— Disclose + Carry

这是 wiki 正式「入册」的阶段：从披露升级为**正式选择 + 固化进 sidecar**。

1. 正式选择受绑定的 Obsidian atomic Note 和独立 Skill Card。Card 只有在 merged/base-synchronized 且本地 pack provider/version/hash 可用时才由 MCP 标记 `discoverable`，选择结果把这组身份写入 metadata-only selection：

   ```
   /wiki-research      # phase: plan
   ```

2. 用 render 脚本把选择 scaffold 成 schema-v6 sidecar，编辑每个 Note/Card 的 destination，由真实 ticket 建 roster，再 finalize：

   ```bash
   wiki_context_render.py --scaffold --feature-slug <slug> --ticket-source <source>
   # 人工编辑每个 Note/Card 的 destination（一次）；sidecar 不保存 Note body
   # ticket 发布后：按 host 约定块建 .adapter/context/<slug>.ticket-roster.json
   wiki_context_render.py --finalize --ticket-roster <roster>   # 固化 sidecar + 盖指纹
   ```

   **task 身份来自 ticket roster，不来自 plan 文件**——grill 不产出 plan 文档，所以引擎不解析任何文档，只对 roster 交给它的 ticket 正文算 sha256 指纹。roster 怎么填由 host 约定块规定（grill 本地形态读 `.scratch/<slug>/issues/*.md`，GitHub 形态跑 `gh issue view`），引擎本身 host 无关、不碰网络。

3. sidecar 自身即记录：grill 不产出 plan 文档（ticket 发到 tracker 或 `.scratch/<slug>/issues/`），所以不往任何文档里加小节，而是把选中的 wiki 页/节告知用户。

4. 规划期同样穿插真实源校验：

   ```
   /source-truth-check      # render: plan-pre / plan-review
   ```

5. tickets 阶段形成的 durable 候选同样经 `/candidate-journal` 追加；它与后续 implementation/review 使用同一 feature slug。

- `.adapter/context/` 下的东西**一律不提交**——sidecar、roster、candidates 都是本地工作态，执行期在同一工作树就地读取，不 `git add -f`。

### 步骤 4 · `/implement`（每 ticket/direct task）— Readiness + Bind

首次代码修改前先调用 `/grill-adapter:wiki-readiness`，把所有入口统一成一个稳定执行任务：

1. 正式拆票流程复用已有 finalized context、ticket roster、路由和 fingerprint，不做 late research，也不改写这些产物。
2. 直接实现 tracker issue 时，以真实 issue 编号为 `taskId`、完整 issue body 为 `text`，机械生成单任务 roster；已确认的对话需求使用 `ticketSource: manual` + 固定 `taskId: manual`，完整实现简报是 fingerprint 输入，不隐式拆任务。
3. 无匹配 formal context 时才做单任务 late formal selection + Carry。Wiki 未启用记为 `disabled`，健康但无相关知识记为 `no-relevant`；二者都不伪造 context，直接继续。
4. Wiki 已配置但 health/research/Carry/Bind 任一失败记为 `broken`。向用户说明影响并让其选择停止修复或继续；adapter 不把它升级成不可绕过的实现门。继续时丢弃全部不完整/陈旧输出，不读取、不注入 sidecar 摘要或部分 materialize 内容。
5. `ready` 时，执行阶段以 task 为单位 **reread 当前任务的权威硬约束**。schema-v5 materialize section 整段；schema-v6 只通过绑定的 Obsidian MCP 按 stable `wikiId` materialize 路由的 hard Note、当前角色所需 Skill Card 与直接 `depends_on` Note。sidecar 摘要永远不能替代运行期全文。

   首先做指纹预检，再 bind：

   ```
   /wiki-materialize --fingerprint-preflight
   /wiki-materialize <ticket>
   ```

   背后仍由 `wiki_materialize_task.py` 唯一读取权威全文；schema-v5 覆盖本地 + `github_mcp`，schema-v6 只经 Obsidian MCP，并做有界、去重 1 跳闭包。binding/Note/Card/base/pack 任一漂移都让 Wiki 校验 fail-closed；宿主是否停止实现则由 readiness 的用户选择决定。

6. readiness 结果写入 `.adapter/context/<feature-slug>.wiki-readiness.json`，只保存 task identity、fingerprint、状态和安全的 context 文件名引用，不保存 Note body。roster/context/receipt 都是本地工作态，不提交。

7. `source-truth-lint` hook（PostToolUse / Stop）对**真实改动文件**做 lint；命中 **block / ask** 必须处理后才继续。执行中涌现的 durable 决策 / 坑，经 `/candidate-journal`（stage `implementation`）机械追加，留待步骤 5 捕获。

### 步骤 5 · `/code-review` — Reviewer Bind + Capture

code-review 确定当前任务后、启动 Standards/Spec 两个隔离 reviewer 前，复用 implement 阶段的 readiness receipt 运行 `review-handoff`。`ready` 会重新校验 roster/fingerprint/context，并以 reviewer 角色只读取该任务的 hard Note、直接 `depends_on` 与 reviewer-required Skill Card；两轴读取同一个本地 handoff，但各自职责和输出结构不变。Card 到达实际 reviewer 后，其 `MUST invoke` project skill 要求必须执行。

`no-relevant`、`disabled`、`broken`、无法确定 task 的 `unknown`，以及 receipt/context/Source/Card/revision/materialize 任一失败，都只生成不含 Wiki 正文的非阻塞 caveat。评审继续，不做 late research、不要求先修 Wiki，且失败路径会覆盖旧 handoff、丢弃所有部分输出。这里是“Wiki 内容完整性 fail-closed、宿主 review 可用性 fail-open”。

review 通过后，把本轮新沉淀的知识回写 wiki。约定块只让你调一个 skill：

```
/update-wiki
```

1. 项目若保留 grill 的 `CONTEXT.md` / `docs/adr`，`/grill-adapter:update-wiki` 会先跑自己的**可选前置步骤**，把这份知识增量批量转成标准 candidate events（`grill_context_to_candidates.py` → feature journal）。术语表仍产生普通候选；ADR 只产生 metadata-only `adr_execution_projection`，携带稳定 source ID、项目相对路径与 content hash，不复制 Context / Options / Decision 理由 / Status / Consequences。中断后重跑会按稳定 identity 跳过完全相同的 candidate，但同 ID 不同内容仍 fail-closed。grill 的术语表 / ADR 是 tier-1，wiki 是 tier-2；**不要**把 grill 知识走 `import-wiki`——那是平铺结构性拷贝，不是增量。

2. 调 `/candidate-journal validate` + `fold`；损坏、尾部截断、重复 identity、未知引用或非法状态转换一律在 Capture 前 fail-closed。

3. 以最终 review 结论与已验证 code/tests 为最高优先级，其次才是 final spec/ticket，再次才是原 candidate 文案；逐条做 keep-or-skip。ADR projection 必须重读 hash 匹配的权威 ADR，只提炼未来实现必须遵守的 durable 约束；没有约束就明确 `skipped`。投影固定写 project Source，以 `adr_source_id` 更新唯一既有 Note，声明自身为派生内容；不得中性化后转投 Shared Wiki。非 ADR 的普通 decision candidate 继续走原 durable gate。可执行流程先交 `scaffold-practice-skill` 生成/转换带 version 的 pack，再用 `stage-card` 计算全 pack contract hash 并追加结构化候选；脚手架不直接写 Wiki。若多个 unresolved candidate 表达同一最终 claim，先追加一个 `capture` stage 的原子 replacement candidate，再用 `supersede` 把相关候选显式归并，只对 replacement 写一次。

   `/grill-adapter:update-wiki` 对每条候选逐一过闸：**durable 闸 → sectionize（分节）→ type（定类型）→ `[[page#section]]` 边 → dedup（去重）→ 中性化 → 授权**，最终只保留真正值得沉淀的知识。

4. Obsidian provider 对准备保留的 Note/Card 调 `obsidian_wiki_propose_note_change`，向用户展示 structured diff；effective policy 为 `confirm` 时取得明确授权后，才以完全相同输入调用 `obsidian_wiki_apply_note_change`。Skill Card 是 `type: guide` atomic Note，完整复制 staged provider/name/version/hash/roles/triggers；MCP 与 bridge 都验证本地 pack identity。bridge 通过 loopback token 鉴权并做 expected-hash CAS；任何 binding/path/schema/identity/typed-link/neutrality/policy/pack identity/并发冲突都保持 `deferred`，禁止直接改 Vault 文件绕过。proposal 后暂停时把精确身份记录为 `writeReceipt.state: proposed`，不把 proposal 误当已写入；恢复后若漂移则可追加新的 deferred proposal receipt，fold 以最新 proposal 为准但历史不丢。

5. 每条候选经 `/candidate-journal outcome` 追加 `kept` / `skipped` / `deferred`。只有 apply 返回与最新 proposal 完全匹配的 post-write identity 才能记 `kept`，并写入 `writeReceipt.state: applied`；receipt 绑定 candidate 与 repository/Source/binding/Note/path/hash。Skill Card 的 receipt 还复制 write result 的完整 `skillRegistration`，必须与 staged registration 逐字段相等；没有这份 applied binding 不能记 kept。receipt 不含 Note body、token 或授权 secret。kept/skipped 是终态，deferred 可继续 defer/keep/skip。journal 保留为中断恢复 receipt，不删除、不提交；后续 publishing 只消费这些 allowlisted staged identities。此时 Note 不代表已合并或已进入正式检索。

6. 再次 fold journal，按 `repositoryRef` 展示所有 `kept+applied` receipt 的 Source、Note path、operation 与 after-hash。Note apply 授权不等于 Git 发布授权；取得精确 commit/push/draft-PR scope 的显式确认后，`update-wiki` 把 folded JSON 交给 `obsidian-wiki ... publish`。publisher 核对 binding digest、base/remote、wiki ID/hash 和 worktree 精确变更集，并在每仓 lock 内重验内容与 scope，只提交 receipt allowlist；每仓一个 draft PR，并把 peer PR 相互关联，最后恢复全部 clean base worktree。

7. 发布 run 写在本地 `.adapter/context/<feature-slug>.wiki-publish.json`。commit 前失败时，manifest 用 `stagedTree` Git object ID 保留已验证内容身份、清理 base index/worktree；多仓中途失败时修复外部问题并重跑相同命令，publisher 从 staged tree / commit / Git refs / `gh pr list` 恢复，不重复 Note apply、commit、push 或 PR。禁止自动 merge/approve/force-push/reset/stash/clean/delete branch。开放 PR 中的 Card 仍是 `pending`，不进入 formal research；必须人工 merge、base worktree 同步并重新通过 binding/Note 与本地 pack identity 校验后，搜索才返回 `discoveryState: discoverable`。

8. `wiki-capture-suggest` hook（Stop）只在 pending/deferred 时提醒，journal 全终态静默；invalid journal 单独报错，阻止静默漏 Capture。

### 步骤 6 · `/diagnosing-bugs`（排障）— Disclose + Capture

排障是一条平行支线，同样接入 Disclose 与 Capture。

1. 根因收窄后，可做一次**受限披露**：

   ```
   /wiki-research      # phase: debug（≤2 节）
   ```

2. 修复验证通过后，复盘；durable findings 经 `/candidate-journal`（stage `debugging`）落到同一 feature journal，再交由 Capture：

   ```
   /break-loop      # 复盘
   /update-wiki     # 回写沉淀
   ```

---

## 横切关注点

### 真实源 Verify / Lint 的穿插

真实源校验不是单点，而是贯穿规划与执行：

- **Verify**：`/grill-adapter:source-truth-check` 在 `/to-spec`（spec-pre）与 `/to-tickets`（plan-pre / plan-review）处 render，把关 spec / plan 的事实基础。
- **Lint**：`source-truth-lint.sh` hook 在 `/implement` 期间（PostToolUse / Stop）对**真实改动文件**做 lint，命中 block / ask 必须处理。

二者共享同一「真实源」立场：规划时校验、执行时 lint。

### 共享 wiki 的每项目绑定

跨仓库共享 wiki 采用**每项目绑定**：

- 绑定声明写在项目的 `.shared-adapter/settings.json` 的 `wiki.sharedMcp` 里，声明本项目连哪个 shared wiki。
- **未声明即 fail-closed**：没有绑定的项目拿不到 MCP shared wiki，不会静默回退到任意来源。
- 执行期 Bind 的 github_mcp 来源、以及 Capture 期的授权回写，都受这一绑定约束。
- 相关 skill：`shared-wiki-mcp`（读取）、`publish-shared-wiki`（发布）。

### 诚实降级（honest degradation）

grill-adapter 明确承认自己不是无缝的，并把降级点讲清楚：

- **Bind 靠约定 + SessionStart 提醒**：`/grill-adapter:wiki-materialize <ticket>` 是唯一按 ticket/rôle 精确 reread 的路径；`wiki-reread.sh` 只在 SessionStart 提醒 active sidecar，绝不在 `UserPromptSubmit` 或 SessionStart 注入 Note 全文。
- **中间阶段只 journal、不写 Obsidian**：所有 durable 候选先经机械 helper 追加；只有 review 后的 `/grill-adapter:update-wiki` 能做最终语义判断与后续回写。
- **可恢复但非自动恢复**：journal 保留完整生命周期；损坏或非法转换 fail-closed，必须回到产生事件的 workflow 修复，不能手改 JSONL 绕过。

### Legacy Wiki → Obsidian 迁移生命周期

调用 `migrate-wiki` 的 **Obsidian migration plan** 模式。它先 fail-closed 校验 binding topology 与 symlink 边界，只读 legacy project/shared Wiki、`access.read: true` 的选定 Source snapshot 与本地 skill packs，输出 source/target digest 和逐项 `create/update/skip/conflict` 映射；不会修改 legacy Markdown、indexes、`.graph.json`、Source Notes、settings 或 registry。semantic split、duplicate ID/Card identity、occupied target path、dangling edge、unavailable pack、Shared neutrality violation、non-migratable navigation 与 heuristic constraint strength 全部进入显式 confirmation gate。

用户确认精确 plan 后，apply 重算 plan/snapshots，零 conflict 才先持久化完整 plan、binding/policy snapshot 与全部 CAS intents，并 checkout 每仓专用 PR branch；所有 bridge 写只发生在这些 branch 上。两阶段 CAS 生成 Notes/Cards 后，最终 receipts 按 repository 发布成 draft PR；中断恢复只接受原始 before、seed 或 final hash，不收养人工改动。这一步不等于 merge。PR 全部由用户合并、base worktree 同步后，verify 从 immutable plan 推导 coverage，并只读重验 legacy source、binding/policy、mapping/ID/Source/schema/hash/search/pack/edge/hard-reread。最后另行确认 cutover；cutover 会重新 verify，且 active schema-v5 sidecar 存在时拒绝。成功后仅 plan 选择的旧 roots 原字节保留并标记为 read-only archive，legacy 写 helper 机械拒绝再写。

运维上，配置 Obsidian provider 且 legacy roots 尚在时称为 `shadow-validation`：正式四触点只走 Obsidian，legacy 只供 migration plan/coverage/verify，绝不作为 runtime fallback。`manage.sh doctor` 只有在 active Obsidian bindings 全部健康时成功；verify + 单独 cutover 后状态才是 `cutover-complete`。真实 Desktop 与 installed Claude Code/Codex 验收见 `OBSIDIAN_ACCEPTANCE_CN.md`。

---

## 附录 · plugin 组件一览

grill-adapter 同时以 **Claude Code plugin** 与 **Codex plugin** 形式发布。Claude 使用 `claude plugin install grill-adapter@grill-adapter --scope project|user`；Codex 使用 `codex plugin marketplace add YWJ-hy/grill-adapter` 后 `codex plugin add grill-adapter@grill-adapter`。

唯一不由 plugin 承载的是目标项目的 host 约定块：Claude 写 `CLAUDE.md`，Codex 写 `AGENTS.md`。由 `./manage.sh install <project> --host grill|plain --runtime claude|codex|both` 写入；块里只点名 skill，不含任何安装路径。

**Skills（13）**：`wiki-readiness`、`wiki-research`、`wiki-materialize`、`candidate-journal`、`update-wiki`、`init-wiki`、`import-wiki`、`migrate-wiki`、`publish-shared-wiki`、`shared-wiki-mcp`、`scaffold-practice-skill`、`break-loop`、`source-truth-check`。

> 其中 `wiki-readiness` / `wiki-research` / `wiki-materialize` / `candidate-journal` / `update-wiki` / `source-truth-check` / `break-loop` 直接出现在上面的端到端流程；`init-wiki` / `import-wiki` / `migrate-wiki` 是建库与 wiki 生命周期 skill，`migrate-wiki` 也承载 legacy → Obsidian 的 plan/apply/verify/cutover；`publish-shared-wiki` / `shared-wiki-mcp` 服务共享 wiki；`scaffold-practice-skill` 负责把可复用实践固化成技能包。
>
> 约定块里对 grill-adapter 自己的 skill 一律带命名空间调用（`/grill-adapter:wiki-research` 等）；grill 自带的 `/grill-with-docs`、`/to-spec`、`/implement` 等不加。

**Agent roles（1）**：`wiki-researcher`。Claude Code 直接注册；Codex 由入口 skill 读取同一 prompt 并派生通用 sub-agent。

**MCP servers（2）**：`shared-wiki` 保留 schema-v5 shared Wiki 路径；`obsidian-wiki` 解析受约束的 Obsidian Source binding，并提供状态、Source、读取、proposal 与 apply 工具。两者随 plugin 自动启动，无需手工注册；`obsidian-wiki` 只操作当前项目 `.shared-adapter/settings.json` 声明的 binding，未绑定、Vault/仓库不健康或 policy 不兼容时 fail-closed。实际写入由另行启动、只监听 loopback 的 write bridge 完成，MCP 自身不开放 HTTP 端口。

**Hooks（3 个事件）**：随 plugin 启用自动注册，不往项目设置里并片段。

| hook | 触发时机 | 作用 |
| --- | --- | --- |
| `wiki-reread.sh` | SessionStart | active sidecar 健康/显式 Bind 提醒；不 reread Note |
| `wiki-capture-suggest.sh` | Stop | Capture 兜底：pending/deferred 提醒、invalid 报错、全终态静默 |
| `source-truth-lint.sh` | PostToolUse / Stop | 对真实改动文件做真实源 lint |
