# grill-adapter 用户流程（端到端）

grill-adapter 是一个**宿主无关（host-agnostic）的 Claude Code adapter**：它由一个原本与 Superpowers 强耦合的 adapter fork 而来，现已解耦。它以**独立 skill + hook** 的形式，为宿主工作流补上三样能力：

- 分节化、可跨仓库的**项目 wiki**；
- **真实源校验 / lint（source-of-truth verify/lint）**；
- **break-loop 调试复盘与知识回流**。

核心原则：grill-adapter **从不 patch 任何宿主 skill**，只在宿主阶段之间挂接自己的 skill 与 hook。默认宿主是 **grill**（mattpocock/skills）。安装 plugin 只让能力可用，不会让所有 grill 项目自动启用 adapter：项目必须有 install 写入的 host marker、已有 `.grill-adapter/settings.json`，或用户显式调用当前 adapter skill，才会进入 adapter workflow。三者都没有时就是 standalone grill，任何入口都不得创建 `.grill-adapter/`。项目已接线后，grill host 的约定块也只有在用户明确调用对应 grill 阶段时才激活，普通直接需求不会自动进入 Wiki 触点：

```
/grill-with-docs → /to-spec → /to-tickets → /implement → /code-review
已有 issue / 已确认对话需求 ─────→ /wiki-readiness → /implement
（外加平行支线 /diagnosing-bugs）
```

在没有 grill 的**纯 Claude Code** 上也能运行——只是失去了宿主阶段锚点，改由 hook 兜底。

如果某项目只想使用 grill，运行 `manage.sh uninstall <project> --runtime <runtime>` 移除
host marker 即可；全局安装的 grill-adapter plugin 可以保留。uninstall 不会删除既有
`.grill-adapter/` 工作态，避免隐式丢失用户数据。

### 本机运行时配置

Obsidian Source 的 Vault、Git worktree、bridge allowlist 和 token 环境变量由
`@grill-adapter/obsidian-wiki` npm CLI 统一维护。首次配置时运行
`obsidian-wiki init`，需要改位置时运行 `obsidian-wiki config set-location <path>`；
MCP 与独立 loopback write bridge 使用同一份 JSONC 配置。bridge 仍是独立进程，
由 `obsidian-wiki bridge start` 启动 detached 后台进程并在健康检查后退出终端，
不需要手动拼接多组环境变量；需要关闭或重启时分别运行
`obsidian-wiki bridge stop` / `obsidian-wiki bridge restart`。

---

## 四个 wiki 触点

grill-adapter 把「wiki 如何进入并回流到工作流」抽象成四个触点：

| 触点 | 含义 | 载体 |
| --- | --- | --- |
| **Disclose（披露）** | 规划前轻量披露相关 wiki 作上下文 | `/grill-adapter:wiki-research` |
| **Carry（携带）** | 把 bound Obsidian atomic Note/Skill Card 的 metadata 固化进 schema-v6 计划期 sidecar | `.wiki-context.json`（`wiki_context_render.py --scaffold` → `--finalize`，不含 Note body） |
| **Bind（绑定）** | 规划审核后一次冻结 roster 内所有 task 的角色化 Markdown；implement/review 各自消费对应文件，包含角色所需 Skill Card 与 1 跳 `depends_on` 闭包 | `wiki_readiness.py freeze --all` → `<taskId>.wiki-implement.md` / `<taskId>.wiki-review.md`；`wiki-readiness` 校验并消费，SessionStart 只提醒尚未进入 readiness 的已批准 task |
| **Capture（捕获）** | 各阶段先经 `/grill-adapter:candidate-journal` 追加候选事件；review 后校验/折叠并回写 durable 知识 | `/grill-adapter:update-wiki`（逐条记录 keep/skip/defer；可选前置步骤把 grill 增量转成同款事件） |

Candidate Journal 是贯穿四触点的横切契约：`grill-with-docs`、specification、tickets、implementation、review、debugging 发现的 Wiki Note / Skill Card 候选与 evidence-backed correction 都进入同一个 `.grill-adapter/context/<feature-slug>/wiki-candidates.jsonl`。correction 必须记录受影响的 bound `sourceId` + stable `wikiId`、修正主张、证据引用和 observed impact；pending/deferred correction 在 fold 中只投影为 metadata-only `unresolved_correction` maintenance signal，不自动隐藏、归档或改写 active Note。Skill Card 候选由 `scaffold-practice-skill stage-card` 在双运行时 pack 校验后追加，包含 name/version/contract hash/roles/triggers，并明确为 `pending`；中间阶段不写 Obsidian、不写 legacy discovery index。journal 只追加、不手改、不删除、不提交。

`obsidian_wiki_maintenance_summary` 是只读、metadata-only 的维护/导航投影：它只从当前可读 bound Source 的 frontmatter 和 canonical feature journal fold 聚合 active、review-due、expired、带 `contradicts` 边的 stable `wikiId`、repository/base health、pending correction 与未完成 Capture。调用者必须提供规范 UTC 秒级 `asOf`，重复 inventory 复用同一值；输出使用 `grill-adapter.wiki-maintenance-summary` schema v1，`identityLimit` 对每类 identity 全局生效，而不是每 Source 各一份额度。不返回 Note body/summary、correction claim/evidence/impact、outcome reason、任意路径、unbound correction identity 或 journal transcript。它不是 task identity、readiness、Bind、写 proposal 或授权输入；malformed journal、unhealthy binding 与 correction identity drift 都 fail-closed，不能伪装成空摘要。

### Feature 工作目录

每个 feature 都使用一个本地工作目录，而不是把同一任务的文件平铺在 `context/` 下：

```text
.grill-adapter/context/<feature-slug>/
  obsidian-wiki-selection.json  # Carry 的一次性输入，scaffold 成功后通常删除
  wiki-context.json
  ticket-roster.json
  issue.json                    # direct tracker task（如适用）
  task-brief.md                 # manual task（如适用）
  wiki-candidates.jsonl
  wiki-candidates.jsonl.lock
  wiki-readiness.json
  wiki-session-state.json      # 非权威续接摘要，不含 Wiki 正文
  <taskId>.wiki-approval.json
  <taskId>.wiki-implement.md
  <taskId>.wiki-review.md
  wiki-publish.json
```

这样用户可以展开一个 feature 查看它的完整本地状态。新流程统一写这个布局；已有的平铺文件仍可由显式路径继续读取和恢复，不能在任务执行中自动移动，尤其不要手动移动带 `.lock` 的 journal。迁移 manifest 等非 feature 级运行态仍保留在 `.grill-adapter/context/` 根目录。

---

## 阶段映射总表

| # | grill 阶段 | grill-adapter 触点 | 命令 | 产物 |
| --- | --- | --- | --- | --- |
| 1 | `/grill-with-docs`（质询/发现） | Disclose | `/grill-adapter:wiki-research`（phase brainstorm） | 轻量上下文；durable 候选可追加 journal（不写 selection/context sidecar） |
| 2 | `/to-spec` | Verify | `/grill-adapter:source-truth-check`（render spec-pre） | 真实源校验结果 |
| 3 | `/to-tickets`（规划） | Disclose + Carry | `/grill-adapter:wiki-research`（phase plan）+ `wiki_context_render.py --scaffold` → 建 ticket roster → `--finalize` + `/grill-adapter:source-truth-check`（plan-pre / plan-review） | `.grill-adapter/context/<feature-slug>/` 下的 `obsidian-wiki-selection.json`、schema-v6 `wiki-context.json`、`ticket-roster.json` |
| 4 | `/implement`（每 ticket/direct task） | Readiness + Bind | 首次代码修改前 `/grill-adapter:wiki-readiness`；`ready` 时做 fingerprint preflight + 消费 `<taskId>.wiki-implement.md` | 稳定 task identity + readiness receipt + 用户可见实现 Markdown；否则按显式 fail-open 结果继续 |
| 5 | `/code-review` | Reviewer Bind + Capture | 启动 Standards/Spec sub-agents 前用 `/grill-adapter:wiki-readiness` 生成共享 reviewer handoff；review 完成后 `/grill-adapter:update-wiki` | 原子 reviewer context 或非阻塞 caveat；随后 journal outcome receipt + staged Note change，发布另行显式请求 |
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

- 由 `wiki-researcher` agent 先查看每个 bound Source 的 metadata 目录，再按需展开相关分支、在该分支内检索，并只全文复核少量候选 Note/Card；正文不离开该子 agent。
- 此阶段**只披露、不写 selection/context sidecar**。若质询解决了 durable 决策，可经 `/candidate-journal` 以 `grill-with-docs` stage 追加候选，但不写 Obsidian。

### 步骤 2 · `/to-spec` — 真实源 Verify

生成 spec 前，先跑一次真实源校验，避免 spec 建立在过期或臆测的事实上。

```
/source-truth-check      # render: spec-pre
```

specification 阶段若形成 durable contract/decision，经 `/candidate-journal` 追加到同一 feature journal；spec 本身不直接维护 Obsidian。

### 步骤 3 · `/to-tickets`（规划）— Disclose + Carry

这是 wiki 正式「入册」的阶段：从披露升级为**正式选择 + 固化进 sidecar**。

1. 正式选择受绑定的 Obsidian atomic Note 和独立 Skill Card：研究员先以 `obsidian_wiki_catalog` 浏览受限目录，每次显式给出硬 `limit`，必要时原样续传不透明 `page.nextCursor`；catalog 从已校验 bound Source 的 Git revision 缓存读取 frontmatter metadata，不调用 Obsidian 全文 read，也不返回 `contentHash`。Note 可选声明 `verified_at`、`review_after`、`expires_at`，值必须是秒精度 UTC `YYYY-MM-DDTHH:mm:ssZ`；缺失时保持旧行为。运行时独立计算知识 freshness：review-due 仍可检索并产生 maintenance warning，expired 从 catalog/search/formal read 排除。随后只在选中的 `sourceId` / `pathPrefix` 分支检索，search 同样使用最大 50 的硬 `limit`、稳定 path 顺序、scope-bound cursor 与 `page.truncated`；每轮最多全文复核 8 个候选（规划最多两轮），关键词、目录或一跳图邻居都必须经正文语义判断才可入选。正式选中的 Note 仍通过 stable batch 全文 reread 计算 `contentHash` / `snapshotHash`，并把可选 freshness 字段以 `verifiedAt` / `reviewAfter` / `expiresAt` 带入 metadata-only selection。Card 只有在 merged/base-synchronized 且本地双运行时 pack 的 name/version/hash 可用时才由 MCP 标记 `discoverable`；repository/base freshness 与知识 freshness 是两道独立门，任何一方都不能绕过另一方。

   ```
   /wiki-research      # phase: plan
   ```

2. 用 render 脚本把选择 scaffold 成 schema-v6 sidecar。Carry 会重新校验 timestamp 格式/顺序、未来 `verifiedAt` 和当下 expiry，自动补齐 review-due warning；expired Note 即使由旧 selection 注入也 fail-closed。随后逐项核对候选与确认后的任务；检索命中但实际无关的候选标记为 `destination.kind: not-applicable`（保留审计记录但不进入执行），再编辑其余 Note/Card 的 destination，由真实 ticket 建 roster，最后 finalize：

   ```bash
   wiki_context_render.py --scaffold --feature-slug <slug> --ticket-source <source>
   # 人工编辑每个 Note/Card 的 destination（一次）；sidecar 不保存 Note body
   # ticket 发布后：按 host 约定块建 .grill-adapter/context/<slug>/ticket-roster.json
   wiki_context_render.py --finalize --ticket-roster <roster>   # 固化 sidecar + 盖指纹
   wiki_readiness.py freeze --context <context> --roster <roster> --all --project-root <project-root>
   # 用户审核后一次冻结 roster 的角色化 Markdown task contracts
   ```

   **task 身份来自 ticket roster，不来自 plan 文件**——grill 不产出 plan 文档，所以引擎不解析任何文档，只对 roster 交给它的 ticket 正文算 sha256 指纹。roster 怎么填由 host 约定块规定（grill 本地形态读 `.scratch/<slug>/issues/*.md`，GitHub 形态跑 `gh issue view`），引擎本身 host 无关、不碰网络。

3. sidecar 自身即记录：grill 不产出 plan 文档（ticket 发到 tracker 或 `.scratch/<slug>/issues/`），所以不往任何文档里加小节，而是把选中的 wiki 页/节告知用户。

4. 规划期同样穿插真实源校验：

   ```
   /source-truth-check      # render: plan-pre / plan-review
   ```

5. tickets 阶段形成的 durable 候选同样经 `/candidate-journal` 追加；它与后续 implementation/review 使用同一 feature slug。

- `.grill-adapter/context/` 下的东西**一律不提交**——sidecar、roster、candidates 都是本地工作态，执行期在同一工作树就地读取，不 `git add -f`。

### 步骤 4 · `/implement`（每 ticket/direct task）— Readiness + Bind

首次代码修改前先调用 `/grill-adapter:wiki-readiness`，把所有入口统一成一个稳定执行任务：

1. 正式拆票流程复用已有 finalized context、ticket roster、路由和 fingerprint，不做 late research，也不改写这些产物。
2. 直接实现 tracker issue 时，以真实 issue 编号为 `taskId`、完整 issue body 为 `text`，机械生成单任务 roster；已确认的对话需求使用 `ticketSource: manual` + 固定 `taskId: manual`，完整实现简报是 fingerprint 输入，不隐式拆任务。
3. 无匹配 formal context 时才做单任务 late formal selection + Carry。Wiki 未启用记为 `disabled`，健康但无相关知识记为 `no-relevant`；二者都不伪造 context，直接继续。
4. Wiki 已配置但 health/research/Carry/Bind 任一失败记为 `broken`。向用户说明影响并让其选择停止修复或继续；adapter 不把它升级成不可绕过的实现门。继续时丢弃全部不完整/陈旧输出，不读取、不注入 sidecar 摘要或部分 materialize 内容。
5. `ready` 时，执行阶段以 task 为单位校验并消费已批准的 implementer Markdown。schema-v6 的 freeze 已通过绑定 Obsidian MCP 按 stable `wikiId` materialize 路由的 hard Note、当前角色所需 Skill Card 与直接 `depends_on` Note；sidecar 摘要永远不能替代已冻结的全文 task contract。

   `wiki-readiness` 自己先做指纹预检，再 Bind；普通实现入口不需要再单独调一次 materialize：

   ```
   /wiki-readiness <ticket>
   ```

   Freeze 阶段由 `wiki_materialize_task.py` 经绑定 Obsidian MCP 读取权威全文，并做有界、去重 1 跳闭包；生成的 schema-v2 `<taskId>.wiki-implement.md` 与 `<taskId>.wiki-review.md` 在实现和评审阶段固定消费，其 `freshnessEntries` 覆盖所有角色可见 Note/Card 与闭包。缺少清单的 schema-v1 快照不可执行，必须重新 freeze。ADR-backed projection 仍会在 freeze 时重算 `adrSourceId`、路径和 `adrSourceContentHash`；缺失、越界、格式错误或内容漂移都让 freeze fail-closed，不生成可消费快照。binding/Note/Card/base/pack 任一漂移都要求重新审核并 freeze；宿主是否停止实现则由 readiness 的用户选择决定。

6. readiness 结果写入 `.grill-adapter/context/<feature-slug>/wiki-readiness.json`，保存 task identity、fingerprint、状态、context 文件名和两份 role Markdown 的 digest；同时 best-effort 刷新 `wiki-session-state.json`。后者只记录 featureSlug、最后显式选择的 task、roster/context/snapshot digest、readiness 状态、候选数和下一条 readiness 命令，不含 Note body，也不参与执行期校验。Note body 只存在于用户可见的 task Markdown，不复制进 JSON receipt。roster/context/snapshot/receipt 都是本地工作态，不提交。

7. `source-truth-lint` hook（PostToolUse / Stop）对**真实改动文件**做 lint；命中 **block / ask** 必须处理后才继续。执行中涌现的 durable 决策 / 坑，经 `/candidate-journal`（stage `implementation`）机械追加，留待步骤 5 捕获。

### 步骤 5 · `/code-review` — Reviewer Bind + Capture

code-review 确定当前任务后、启动 Standards/Spec 两个隔离 reviewer 前，复用 implement 阶段的 readiness receipt 运行 `review-handoff`。`ready` 会重新校验 roster/fingerprint/context、`<taskId>.wiki-review.md` digest 以及快照中直接/闭包 Note 的 freshness；批准 snapshot 保持不变，运行时 warning 与正文共同派生为 `<taskId>.wiki-review-handoff.md`。两轴读取同一个 handoff，但各自职责和输出结构不变。Card 到达实际 reviewer 后，其 `MUST invoke` project skill 要求必须执行。

   `no-relevant`、`disabled`、`broken`、无法确定 task 的 `unknown`，以及 receipt/context/snapshot 任一失败，都只生成不含 Wiki 正文的非阻塞 caveat。评审继续，不做 late research、不要求先修 Wiki；失败路径只覆盖派生 handoff，永不覆盖批准的 reviewer snapshot，并丢弃所有部分输出。这里是“Wiki 内容验证 fail-closed、宿主 review 可用性 fail-open”。

review 通过后，把本轮新沉淀的知识回写 wiki。约定块只让你调一个 skill：

```
/update-wiki
```

1. 项目若保留 grill 的 `CONTEXT.md` / `docs/adr`，`/grill-adapter:update-wiki` 会先跑自己的**可选前置步骤**，把这份知识增量批量转成标准 candidate events（`grill_context_to_candidates.py` → feature journal）。术语表仍产生普通候选；ADR 只产生 metadata-only `adr_execution_projection`，携带稳定 source ID、项目相对路径与 content hash，不复制 Context / Options / Decision 理由 / Status / Consequences。中断后重跑会按稳定 identity 跳过完全相同的 candidate，但同 ID 不同内容仍 fail-closed。grill 的术语表 / ADR 是 tier-1，wiki 是 tier-2；**不要**把 grill 知识走 `import-wiki`——那是平铺结构性拷贝，不是增量。

2. 调 `/candidate-journal validate` + `fold`；损坏、尾部截断、重复 identity、未知引用或非法状态转换一律在 Capture 前 fail-closed。

3. 以最终 review 结论与已验证 code/tests 为最高优先级，其次才是 final spec/ticket，再次才是原 candidate 文案；逐条做 keep-or-skip。correction 先按 stable `wikiId` 做 bound read 并要求返回 `sourceId` 精确匹配；零命中、重复、Source 不符、binding/drift 或证据未决都保持 `deferred`，绝不从标题/路径猜测或创建新 Note 来让未知 identity 成功。接受 correction 后 target 固定为受影响 Note 的 `update`，仍必须展示 structured diff、通过 policy/授权并取得 matching apply receipt；被最终证据否定则明确 `skipped`。ADR projection 必须重读 hash 匹配的权威 ADR，只提炼未来实现必须遵守的 durable 约束；没有约束就明确 `skipped`。投影固定写 project Source，以 `adr_source_id` 更新唯一既有 Note，声明自身为派生内容；不得中性化后转投 Shared Wiki。非 ADR 的普通 decision candidate 继续走原 durable gate。可执行流程先交 `scaffold-practice-skill` 生成/转换带 version 的 pack，再用 `stage-card` 计算全 pack contract hash 并追加结构化候选；脚手架不直接写 Wiki。若多个 unresolved candidate 表达同一最终 claim，先追加一个 `capture` stage 的原子 replacement candidate，再用 `supersede` 把相关候选显式归并，只对 replacement 写一次。

   `/grill-adapter:update-wiki` 对每条候选逐一过闸：**durable 闸 → 原子候选拆分 → target decision → sectionize（分节）→ type（定类型）→ `[[page#section]]` 边 → dedup（去重）→ 中性化 → 授权**，最终只保留真正值得沉淀的知识。对 Obsidian，same-theme refinement 才 update 既有 Note；不同触发条件、生命周期、失败模式或验证路径的独立 contract 必须 create sibling Note 并使用新的稳定 `wiki_id`；无法判断时 defer/询问，不默认追加到最近的 Note。

4. Obsidian provider 对准备保留的 Note/Card 调 `obsidian_wiki_propose_note_change`，向用户展示 structured diff；effective policy 为 `confirm` 时取得明确授权后，才以完全相同输入调用 `obsidian_wiki_apply_note_change`。Skill Card 是 `type: guide` atomic Note，完整复制 staged name/version/hash/roles/triggers；MCP 与 bridge 都验证 `.agents/skills/<name>` 与 `.claude/skills/<name>` 的本地 pack identity。bridge 通过 loopback token 鉴权并做 expected-hash CAS；任何 binding/path/schema/identity/typed-link/neutrality/policy/pack identity/并发冲突都保持 `deferred`，禁止直接改 Vault 文件绕过。proposal 后暂停时把精确身份记录为 `writeReceipt.state: proposed`，不把 proposal 误当已写入；恢复后若漂移则可追加新的 deferred proposal receipt，fold 以最新 proposal 为准但历史不丢。

5. 每条候选经 `/candidate-journal outcome` 追加 `kept` / `skipped` / `deferred`。只有 apply 返回与最新 proposal 完全匹配的 post-write identity 才能记 `kept`，并写入 `writeReceipt.state: applied`；receipt 绑定 candidate 与 repository/Source/binding/Note/path/hash。correction 还机械要求 applied `update` receipt 的 `sourceId`/`wikiId` 与 affected identity 完全相同；无 receipt、create 或错 Note 都 fail-closed。Skill Card 的 receipt 还复制 write result 的完整 `skillRegistration`，必须与 staged registration 逐字段相等；没有这份 applied binding 不能记 kept。receipt 不含 Note body、token 或授权 secret。kept/skipped 是终态，deferred 可继续 defer/keep/skip。journal 保留为中断恢复 receipt，不删除、不提交；后续 publishing 只消费这些 allowlisted staged identities。此时 Note 不代表已合并或已进入正式检索。

6. 默认 Capture 再次 fold journal，按 `repositoryRef` 报告所有 `kept+applied` receipt 的 Source、Note path、operation 与 after-hash，然后停止。Note apply 授权不等于 Git 发布授权；Capture 完成、review 完成或已应用 Note 都不推断 publish 意图。全终态 journal 允许 `wiki-capture-suggest` hook 保持静默。

7. 用户明确请求 publish（例如 `/grill-adapter:update-wiki publish <feature-slug>`）时，才展示精确 commit/push/draft-PR scope 并取得显式确认，再把 folded JSON 交给 `obsidian-wiki ... publish`。publisher 核对 binding digest、base/remote、wiki ID/hash 和 worktree 精确变更集，并在每仓 lock 内重验内容与 scope，只提交 receipt allowlist；每仓一个 draft PR，并把 peer PR 相互关联，最后恢复全部 clean base worktree。发布 run 写在本地 `.grill-adapter/context/<feature-slug>/wiki-publish.json`。commit 前失败时，manifest 用 `stagedTree` Git object ID 保留已验证内容身份、清理 base index/worktree；多仓中途失败时修复外部问题并重跑相同的显式 publish 命令，publisher 从 staged tree / commit / Git refs / `gh pr list` 恢复，不重复 Note apply、commit、push 或 PR。禁止自动 merge/approve/force-push/reset/stash/clean/delete branch。开放 PR 中的 Card 仍是 `pending`，不进入 formal research；必须人工 merge、base worktree 同步并重新通过 binding/Note 与本地 pack identity 校验后，搜索才返回 `discoveryState: discoverable`。

8. `wiki-capture-suggest` hook（Stop）只在 pending/deferred 时提醒，journal 全终态静默；invalid journal 单独报错，阻止静默漏 Capture。已应用但尚未发布的 receipt 是有意保留的 staged state，不作为 Stop 噪声。

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

- 当前运行时只使用项目 `.grill-adapter/settings.json` 中声明的 `wiki.obsidian.bindings`。
- legacy GitHub shared-wiki 仓库不参与运行期读取；需要迁移时由用户把仓库 URL 显式传给 `migrate-wiki`，planner 临时只读 clone 后生成迁移计划。
- `setup-init-obsidian` 先明确询问这个项目需要几个 Wiki 库及每个库的用途，再逐个用人话询问 Vault 名称、Vault 内 Wiki 文件夹、Git worktree/remote/base branch、project/shared 用途，以及该库是否承接旧版 Wiki 内容；由 AI 生成 `sourceId`、`vaultRef`、`repositoryRef` 候选并按 Wiki purpose 展示完整映射供用户一次确认。每个项目最多一个 `role: project` binding，可有多个 `role: shared` binding；项目 settings 不保存 Vault 本地路径或凭据。
- setup 写入的 Obsidian `wiki` 配置必须是 canonical shape：`publishing` 只允许 `mode`；每个 binding 显式写 `access.update: "confirm"`；root 授权写在 `wiki.roots.project/shared.updateAuthorization`；`wiki.roots.shared.sharedNeutrality` 即使为空也必须显式存在。schema/doctor 对 publishing 下错位字段 fail-closed；旧配置缺少 binding 写上限时按 `deny` 计算并给出修复 warning，避免 manifest 变宽后意外放权。
- 一个 repository 可以承载多个不重叠 Source roots；多个 repository 也可以同时使用，迁移/发布按 `repositoryRef` 分仓处理。不存在“一个 Source root 横跨多个仓库”的隐式模式。

### 诚实降级（honest degradation）

grill-adapter 明确承认自己不是无缝的，并把降级点讲清楚：

- **Bind 靠约定 + SessionStart 提醒**：`wiki_readiness.py freeze --all` 是规划期唯一批量生成 task 正文的路径；`wiki-readiness` 是正常按 ticket/role 精确消费冻结 Markdown 的路径；`wiki-session-state.json` 能提示最后显式选择的 task 和恢复命令，`wiki-reread.sh` 优先显示这条非权威提示，否则提醒已批准但尚无 readiness 结果的 task。两条路径都绝不在 `UserPromptSubmit` 或 SessionStart 注入 Note 全文，恢复时仍须执行 `wiki-readiness` 的完整校验。
- **中间阶段只 journal、不写 Obsidian**：所有 durable 候选先经机械 helper 追加；只有 review 后的 `/grill-adapter:update-wiki` 能做最终语义判断与后续回写。
- **可恢复但非自动恢复**：journal 保留完整生命周期；损坏或非法转换 fail-closed，必须回到产生事件的 workflow 修复，不能手改 JSONL 绕过。

### Legacy Wiki → Obsidian 迁移生命周期

调用 `migrate-wiki` 的 **Obsidian migration plan** 模式。若 legacy shared-wiki 只存在于 GitHub，用户必须把不含凭据的 HTTPS/SSH Git URL 明确交给 AI，作为 `--legacy-shared-wiki-url`；不能从项目 `origin` 或目标 `repositoryRef` 猜。需要排除 legacy 子树时，重复传入 `--exclude-path shared:.claude/skills` 这类 `root:relative/path` 参数；排除项写入 plan 和 source digest，并由 apply/verify 确定性复核。它先 fail-closed 校验 binding topology 与 symlink 边界，只读 legacy project/shared Wiki、`access.read: true` 的选定 Source snapshot 与本地 skill packs，输出 source/target digest 和逐项 `create/update/skip/conflict` 映射；不会修改 legacy Markdown、indexes、`.graph.json`、Source Notes、settings 或 registry。semantic split、duplicate ID/Card identity、occupied target path、dangling edge、unavailable pack、Shared neutrality violation、non-migratable navigation 与 heuristic constraint strength 全部进入显式 confirmation gate。

用户确认精确 plan 后，apply 重算 plan/snapshots，零 conflict 才先持久化完整 plan、binding/policy snapshot 与全部 CAS intents，并 checkout 每仓专用 PR branch；所有 bridge 写只发生在这些 branch 上。两阶段 CAS 生成 Notes/Cards 后，最终 receipts 按 repository 发布成 draft PR；中断恢复只接受原始 before、seed 或 final hash，不收养人工改动。这一步不等于 merge。PR 全部由用户合并、base worktree 同步后，verify 从 immutable plan 推导 coverage，并只读重验 legacy source、binding/policy、mapping/ID/Source/schema/hash/search/pack/edge/hard-reread。最后另行确认 cutover；cutover 会重新 verify，且 active schema-v5 sidecar 存在时拒绝。成功后仅 plan 选择的旧 roots 原字节保留并标记为 read-only archive，legacy 写 helper 机械拒绝再写。

迁移前若旧页面已经有 section marker，先在 `migrate-wiki` 的 section-repartition pass 中做 bounded 语义审查：已有 marker 不是 atomicity 证明。agent 先提出 section 边界、ID、body span 和 backlink 变更，用户确认后才移动/新增 marker；不改写正文，不静默重组。这样 migration plan 才能把每个独立 section 映射为最小 atomic Note。

迁移完成后若需要批量整理已绑定 Obsidian Note，使用 `migrate-wiki` 的 Obsidian Note maintenance/repartition 模式。它先读取有界的 `obsidian_wiki_maintenance_summary` 选择 audit batch，再按明确 Source 范围分批读取 Note，输出 `keep/update/split` plan；split 保留旧 `wiki_id`，通常落成旧 Note `update` + sibling Note `create`，经 proposal/apply、maintenance journal、publisher 和 merge/base-sync 后 verify。摘要始终非权威，不进入 task contract。该模式不重开 cutover legacy roots，也不提供直接改 Vault 的快捷路径。

运维上，配置 Obsidian provider 且 legacy roots 尚在时称为 `shadow-validation`：正式四触点只走 Obsidian，legacy 只供 migration plan/coverage/verify，绝不作为 runtime fallback。`manage.sh doctor` 只有在 active Obsidian bindings 全部健康时成功；verify + 单独 cutover 后状态才是 `cutover-complete`。真实 Desktop 与 installed Claude Code/Codex 验收见 `OBSIDIAN_ACCEPTANCE_CN.md`。

---

## 附录 · plugin 组件一览

grill-adapter 同时以 **Claude Code plugin** 与 **Codex plugin** 形式发布。Claude 使用 `claude plugin install grill-adapter@grill-adapter --scope project|user`；Codex 使用 `codex plugin marketplace add YWJ-hy/grill-adapter` 后 `codex plugin add grill-adapter@grill-adapter`。

唯一不由 plugin 承载的是目标项目的 host 约定块：Claude 写 `CLAUDE.md`，Codex 写 `AGENTS.md`。由 `./manage.sh install <project> --host grill|plain --runtime claude|codex|both` 写入；块里只点名 skill，不含任何安装路径，同时作为该项目的 workflow opt-in marker。

**Skills（12）**：`wiki-readiness`、`wiki-research`、`wiki-materialize`、`candidate-journal`、`update-wiki`、`init-wiki`、`import-wiki`、`migrate-wiki`、`setup-init-obsidian`、`scaffold-practice-skill`、`break-loop`、`source-truth-check`。

> 其中 `wiki-readiness` / `wiki-research` / `wiki-materialize` / `candidate-journal` / `update-wiki` / `source-truth-check` / `break-loop` 直接出现在上面的端到端流程；`setup-init-obsidian` 负责检查并复用两个 npm 包初始化 Obsidian、在必要时等待用户处理外部环境，并在获准后把旧 Wiki 路由给 `migrate-wiki`；`init-wiki` / `import-wiki` / `migrate-wiki` 是建库与 wiki 生命周期 skill，`migrate-wiki` 也承载 legacy → Obsidian 的 plan/apply/verify/cutover，并可从用户显式提供的 GitHub legacy 仓库读取迁移源；`scaffold-practice-skill` 负责把可复用实践固化成技能包。
>
> 约定块里对 grill-adapter 自己的 skill 一律带命名空间调用（`/grill-adapter:wiki-research` 等）；grill 自带的 `/grill-with-docs`、`/to-spec`、`/implement` 等不加。

**Agent roles（1）**：`wiki-researcher`。Claude Code 直接注册；Codex 由入口 skill 读取同一 prompt 并派生通用 sub-agent。dispatch 返回句柄后，等待同一 agent path 是唯一允许的下一步；在终态前不得发送用户消息、提问、调用 MCP 或继续主流程，且有界等待超时要继续等待。dispatch/容量/生命周期失败走 `broken`，不能降级为 `no-relevant`。

**MCP server（1）**：`obsidian-wiki` 解析受约束的 Obsidian Source binding，并提供状态、Source、读取、proposal 与 apply 工具。它随 plugin 自动启动，无需手工注册；只操作当前项目 `.grill-adapter/settings.json` 声明的 binding，未绑定、Vault/仓库不健康或 policy 不兼容时 fail-closed。实际写入由另行启动、只监听 loopback 的 write bridge 完成，MCP 自身不开放 HTTP 端口。

**Hooks（3 个事件）**：随 plugin 启用自动注册，不往项目设置里并片段。

| hook | 触发时机 | 作用 |
| --- | --- | --- |
| `wiki-reread.sh` | SessionStart | 优先显示非权威 feature 续接摘要；否则提示已批准且尚无 readiness 结果的 task；不 reread Note |
| `wiki-capture-suggest.sh` | Stop | Capture 兜底：pending/deferred 提醒、invalid 报错、全终态静默 |
| `source-truth-lint.sh` | PostToolUse / Stop | 对真实改动文件做真实源 lint |
