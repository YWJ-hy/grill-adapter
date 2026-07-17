# grill-adapter 用户流程（端到端）

grill-adapter 是一个**宿主无关（host-agnostic）的 Claude Code adapter**：它由一个原本与 Superpowers 强耦合的 adapter fork 而来，现已解耦。它以**独立 skill + hook** 的形式，为宿主工作流补上三样能力：

- 分节化、可跨仓库的**项目 wiki**；
- **蓝湖（Lanhu）需求录入**；
- **真实源校验 / lint（source-of-truth verify/lint）**。

核心原则：grill-adapter **从不 patch 任何宿主 skill**，只在宿主阶段之间挂接自己的 skill 与 hook。默认宿主是 **grill**（mattpocock/skills）：

```
/grill-with-docs → /to-spec → /to-tickets → /implement → /code-review
（外加平行支线 /diagnosing-bugs）
```

在没有 grill 的**纯 Claude Code** 上也能运行——只是失去了宿主阶段锚点，改由 hook 兜底。

---

## 四个 wiki 触点

grill-adapter 把「wiki 如何进入并回流到工作流」抽象成四个触点：

| 触点 | 含义 | 载体 |
| --- | --- | --- |
| **Disclose（披露）** | 规划前轻量披露相关 wiki 作上下文 | `/grill-adapter:wiki-research` |
| **Carry（携带）** | 把选中的 wiki 固化进计划期 sidecar | `.wiki-context.json`（`wiki_context_render.py --scaffold` → `--finalize`） |
| **Bind（绑定）** | 执行每个 ticket 前 reread 硬约束整段 | `/grill-adapter:wiki-materialize <ticket>`（跑 `wiki_materialize_task.py`，含 1 跳 depends-on 闭包）+ hook 兜底 |
| **Capture（捕获）** | review 后把新沉淀的知识回写 wiki | `/grill-adapter:update-wiki`（其可选前置步骤跑 `grill_context_to_candidates.py` 喂候选行） |

---

## 阶段映射总表

| # | grill 阶段 | grill-adapter 触点 | 命令 | 产物 |
| --- | --- | --- | --- | --- |
| 0 | （可选）蓝湖录入 | 输入准备 | `/grill-adapter:lanhu-requirements <link> frontend\|backend` | `.lanhu/.../index.md` 证据包 |
| 1 | `/grill-with-docs`（质询/发现） | Disclose | `/grill-adapter:wiki-research`（phase brainstorm） | 轻量上下文（**不写 sidecar**） |
| 2 | `/to-spec` | Verify | `/grill-adapter:source-truth-check`（render spec-pre） | 真实源校验结果 |
| 3 | `/to-tickets`（规划） | Disclose + Carry | `/grill-adapter:wiki-research`（phase plan）+ `wiki_context_render.py --scaffold` → 建 ticket roster → `--finalize` + `/grill-adapter:source-truth-check`（plan-pre / plan-review） | `.adapter/context/<feature-slug>.` 下的 `wiki-selection.json`、`wiki-context.json`、`ticket-roster.json` |
| 4 | `/implement`（每 ticket） | Bind | `/grill-adapter:wiki-materialize <ticket>`（首个 ticket 前 `--fingerprint-preflight`）+ `source-truth-lint` hook | reread 的硬约束整段、lint 结果、`.wiki-candidates.jsonl` 追加 |
| 5 | `/code-review` 后 | Capture | `/grill-adapter:update-wiki`（内部先跑 `grill_context_to_candidates.py` 转候选） | 更新后的 wiki 页 / 节 |
| 6 | `/diagnosing-bugs` | Disclose + Capture | `/grill-adapter:wiki-research`（phase debug）→ `/grill-adapter:break-loop` → `/grill-adapter:update-wiki` | 根因复盘 + wiki 回写 |

---

## 分步流程

### 步骤 0 ·（可选）蓝湖需求录入

当用户提供蓝湖链接时，先把原始需求梳理成证据包，供后续阶段引用。

```
/lanhu-requirements <link> frontend|backend
```

- 由 `lanhu-frontend-requirements-analyst` / `lanhu-backend-requirements-analyst` agent 完成解析。
- 产出 `.lanhu/.../index.md` 证据包。
- **边界**：证据包**只作输入**，不写进 wiki、不写进 spec、不写进验收标准、不写进测试。

### 步骤 1 · `/grill-with-docs`（质询/发现）— Disclose

grill 进入质询/发现阶段时，用 wiki-research 披露与当前话题相关的 wiki 作为**轻量上下文**。

```
/wiki-research      # phase: brainstorm
```

- 由 `wiki-researcher` agent 渐进式挑选相关页面 / 节。
- 此阶段**只披露、不写 sidecar**——不产生 `.wiki-selection.json` 或 `.wiki-context.json`。

### 步骤 2 · `/to-spec` — 真实源 Verify

生成 spec 前，先跑一次真实源校验，避免 spec 建立在过期或臆测的事实上。

```
/source-truth-check      # render: spec-pre
```

### 步骤 3 · `/to-tickets`（规划）— Disclose + Carry

这是 wiki 正式「入册」的阶段：从披露升级为**正式选择 + 固化进 sidecar**。

1. 正式选择 wiki，把结果写入 `.wiki-selection.json`：

   ```
   /wiki-research      # phase: plan
   ```

2. 用 render 脚本把选择 scaffold 成 sidecar，编辑每节归属，由真实 ticket 建 roster，再 finalize：

   ```bash
   wiki_context_render.py --scaffold --feature-slug <slug> --ticket-source <source>
   # 人工编辑每节的 destination（一次）
   # ticket 发布后：按 host 约定块建 .adapter/context/<slug>.ticket-roster.json
   wiki_context_render.py --finalize --ticket-roster <roster>   # 固化 sidecar + 盖指纹
   ```

   **task 身份来自 ticket roster，不来自 plan 文件**——grill 不产出 plan 文档，所以引擎不解析任何文档，只对 roster 交给它的 ticket 正文算 sha256 指纹。roster 怎么填由 host 约定块规定（grill 本地形态读 `.scratch/<slug>/issues/*.md`，GitHub 形态跑 `gh issue view`），引擎本身 host 无关、不碰网络。

3. sidecar 自身即记录：grill 不产出 plan 文档（ticket 发到 tracker 或 `.scratch/<slug>/issues/`），所以不往任何文档里加小节，而是把选中的 wiki 页/节告知用户。

4. 规划期同样穿插真实源校验：

   ```
   /source-truth-check      # render: plan-pre / plan-review
   ```

- `.adapter/context/` 下的东西**一律不提交**——sidecar、roster、candidates 都是本地工作态，执行期在同一工作树就地读取，不 `git add -f`。

### 步骤 4 · `/implement`（每 ticket）— Bind

执行阶段以 ticket 为单位，逐个 **reread 硬约束整段**，确保实现严格贴合 wiki 约束。

1. 首个 ticket 前做一次指纹预检：

   ```
   /wiki-materialize --fingerprint-preflight
   ```

2. 每个 ticket 执行前 bind：

   ```
   /wiki-materialize <ticket>
   ```

   - 背后跑 `wiki_materialize_task.py`，reread 硬约束整段。
   - 覆盖**本地** wiki 与 **github_mcp**（共享）wiki 两类来源。
   - 做**有界 1 跳 depends-on 闭包**：把当前节直接依赖的节一并 materialize。

3. `source-truth-lint` hook（PostToolUse / Stop）对**真实改动文件**做 lint；命中 **block / ask** 必须处理后才继续。

4. 执行中涌现的 durable 决策 / 坑，随手追加进 `.wiki-candidates.jsonl`，留待步骤 5 捕获。

### 步骤 5 · `/code-review` 后 — Capture

review 通过后，把本轮新沉淀的知识回写 wiki。约定块只让你调一个 skill：

```
/update-wiki
```

1. 项目若保留 grill 的 `CONTEXT.md` / `docs/adr`，`/grill-adapter:update-wiki` 会先跑自己的**可选前置步骤**，把这份知识增量转成候选行（`grill_context_to_candidates.py` → `.wiki-candidates.jsonl`）。grill 的术语表 / ADR 是 tier-1，wiki 是 tier-2；**不要**把 grill 知识走 `import-wiki`——那是平铺结构性拷贝，不是增量。

2. 然后消费候选，逐条做 keep-or-skip：

   `/grill-adapter:update-wiki` 对每条候选逐一过闸：**durable 闸 → sectionize（分节）→ type（定类型）→ `[[page#section]]` 边 → dedup（去重）→ 中性化 → 授权**，最终只保留真正值得沉淀的知识。

3. `wiki-capture-suggest` hook（Stop）作**兜底提醒**：仅当存在非空、待处理的 `*.wiki-candidates.jsonl` 时才触发。

### 步骤 6 · `/diagnosing-bugs`（排障）— Disclose + Capture

排障是一条平行支线，同样接入 Disclose 与 Capture。

1. 根因收窄后，可做一次**受限披露**：

   ```
   /wiki-research      # phase: debug（≤2 节）
   ```

2. 修复验证通过后，复盘并交由 capture：

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

- **Bind 靠约定 + hook**：`/grill-adapter:wiki-materialize <ticket>` 是按约定逐 ticket 调用的；`wiki-reread.sh` hook（UserPromptSubmit / SessionStart）只是**粗粒度兜底**——因为 hook 拿不到 ticket 字段，无法精确到单个 ticket。所以 hook 是 backstop，不是替代。
- **中途 capture 退回末尾一次**：执行中途无法逐条即时回写，durable 候选先攒进 `.wiki-candidates.jsonl`，到步骤 5 末尾统一由 `/grill-adapter:update-wiki` 消费一次。
- **grill 规划期当场写 wiki**：在 grill 规划阶段能当场确定的 wiki，就当场写，不硬等到末尾。

---

## 附录 · plugin 组件一览

grill-adapter 以 **Claude Code plugin** 形式发布：`claude plugin install grill-adapter@grill-adapter --scope project|user` 一次装好，下列组件由 plugin 布局声明、Claude Code 自动发现并注册。skill / agent / hook / MCP **共用 plugin 的 scope**（plugin 自带的 MCP 不能单独设 scope，`--scope project` 就是让 shared-wiki MCP 只在本项目起）。

唯一不由 plugin 承载的是**目标项目 `CLAUDE.md` 里的 host 约定块**，由 `./manage.sh install <project> --host grill|plain` 写入；块里只点名 skill，不含任何安装路径。

**Skills（12）**：`wiki-research`、`wiki-materialize`、`update-wiki`、`init-wiki`、`import-wiki`、`migrate-wiki`、`publish-shared-wiki`、`shared-wiki-mcp`、`scaffold-practice-skill`、`lanhu-requirements`、`break-loop`、`source-truth-check`。

> 其中 `wiki-research` / `wiki-materialize` / `update-wiki` / `source-truth-check` / `lanhu-requirements` / `break-loop` 直接出现在上面的端到端流程；`init-wiki` / `import-wiki` / `migrate-wiki` 是建库与 wiki 生命周期 skill；`publish-shared-wiki` / `shared-wiki-mcp` 服务共享 wiki；`scaffold-practice-skill` 负责把可复用实践固化成技能包。
>
> 约定块里对 grill-adapter 自己的 skill 一律带命名空间调用（`/grill-adapter:wiki-research` 等）；grill 自带的 `/grill-with-docs`、`/to-spec`、`/implement` 等不加。

**Agents（3）**：`wiki-researcher`、`lanhu-frontend-requirements-analyst`、`lanhu-backend-requirements-analyst`。

**MCP servers（1）**：`shared-wiki`——随 plugin 自动启动（工具名前缀 `mcp__plugin_grill-adapter_shared-wiki__`），无需手工注册；连不连得上取决于项目自己的 `.shared-adapter/settings.json` 绑定声明。

**Hooks（4 个事件）**：随 plugin 启用**自动注册**，不往任何项目的 `.claude/settings.json` 里并片段。

| hook | 触发时机 | 作用 |
| --- | --- | --- |
| `wiki-reread.sh` | UserPromptSubmit / SessionStart | Bind 的粗粒度兜底 |
| `wiki-capture-suggest.sh` | Stop | Capture 兜底提醒（仅当有非空、待处理的 `*.wiki-candidates.jsonl`） |
| `source-truth-lint.sh` | PostToolUse / Stop | 对真实改动文件做真实源 lint |
