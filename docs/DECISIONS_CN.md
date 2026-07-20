# grill-adapter 设计决策与取舍

本文记录 grill-adapter 的关键设计决策及其**理由**，是一份 rationale（取舍）文档，不是使用手册。

grill-adapter 是一个 **host-agnostic 的 Claude Code 适配器**，由一个成熟但与 Superpowers 深度耦合的 adapter 解耦而来。它**完整保留全部功能**（项目 wiki + 蓝湖 Lanhu 需求接入 + source-of-truth 真实源校验 + break-loop），只**丢掉唯一一件东西**：`native_skill_patch.py` 机制（往 Superpowers 自己的 skill 里打 6-9 个锚点补丁）。默认前端宿主 = **grill**（mattpocock/skills），同时也支持裸 Claude Code。

下面每条决策按 **背景 / 决策 / 理由** 三段展开。

---

## 决策 1：为什么脱离 Superpowers

**背景**
现有 adapter 功能成熟，但通过 `native_skill_patch.py` 往 Superpowers 自己的 skill 内部打了 6-9 个锚点补丁（anchor patch）。这意味着 adapter 的行为绑死在 Superpowers 上游 skill 的具体文本结构上。

**决策**
脱离 Superpowers，做一个 host-agnostic 适配器：功能全留，只丢掉 `native_skill_patch.py` 这一件事。默认前端宿主换成 grill（mattpocock/skills），同时保留对裸 Claude Code 的支持。

**理由**
- 往上游 skill 内部打锚点，耦合**脆**：只要 Superpowers 改动 skill 文本，锚点就可能失配。
- 会**随版本漂移**：6.0.0 的 breaking change 已有前科，证明这种耦合无法长期稳定。
- Superpowers 的工作流程**长、耗 token**。
- 目标明确：**功能全留 + host-agnostic + grill 前端**，不再让适配器的命运被单一宿主的版本节奏绑架。

---

## 决策 2：token 杠杆是「少跑几段」而不是「换谁家宿主」

**背景**
一个容易产生的直觉是：换一个更轻的宿主就能省 token。

**决策**
把 token 优化的杠杆点明确定为「**少跑几段工作流**」，而不是「换谁家宿主」。

**理由**
- grill 与 Superpowers 属于**同类生态**：都提供执行 / 评审 / 调试的 seam（接缝）。
- 换宿主**本身不省 token**——同类生态的段数结构相近。
- 真正省 token 的动作是**减少实际跑的工作流段数**。因此优化目标锚定在裁剪段数上，避免把「换宿主」误当成省 token 的手段。

---

## 决策 3：grill 作前端 + tier-1 / tier-2 知识分层

**背景**
grill 自带一个知识层：`CONTEXT.md`（扁平 glossary）+ `docs/adr/`。它是 **design-time only** 的，没有 section 图、没有跨 repo 能力、没有执行期绑定。

**决策**
- 把 grill 原生知识层定位为 wiki 的 **tier-1**。
- 把 grill-adapter 的 sectioned wiki 定位为 **tier-2**：具备 section 图 + 跨 repo 共享 + 执行期硬约束绑定。
- tier-2 的职责是补上 grill 缺的**两根柱子**：**跨 repo 共享** 和 **执行期约束绑定**。

**理由**
- 分层让 grill 的原生知识继续服务 design-time 场景，不推翻宿主既有能力。
- tier-2 只覆盖 grill 结构上原本没有的能力，**不重复造轮子**，也不与 tier-1 抢地盘。
- 两层各司其职：tier-1 管设计期的扁平语汇，tier-2 管执行期的带图、跨仓、硬绑定约束。

---

## 决策 4：三条铁律

**背景**
解耦的核心风险，是在脱离 Superpowers 之后又重新引入脆弱耦合，或在架构上走回头路。

**决策**
立三条不可动摇的铁律：

1. **不 patch 任何宿主 skill**。host 适配只依靠**项目 CLAUDE.md 约定 + Claude Code hook**，永远不去改宿主自己的 skill，因此不被上游 churn（频繁变更）波及。
2. **验收以 Claude Code 集成路径为准**。必须真跑 **grill → implement → update-wiki** 的完整路径，而不是只跑通 Python 脚本就算数。
3. **markdown 是唯一真相源，不引外部图数据库**。`.graph.json` 只是**派生物**（derived），可以随时从 markdown 重建。

**理由**
- 铁律 ① 从根上消灭了「脱 Superpowers」想解决的那类脆弱耦合，换宿主也不会复发。
- 铁律 ② 防止「脚本能跑」这种假绿灯——用户真实路径走的是 skill / hook 集成，不是裸脚本。
- 铁律 ③ 保证知识资产可移植、可审计、可版本控制，图结构永远可从真相源重算，不被外部数据库锁定。

---

## 决策 5：grill → wiki 桥不能用 import-wiki 一把梭（已查实）

**背景**
需要一座桥，把 grill 的 `CONTEXT.md` 知识接进 sectioned wiki。直觉方案是复用现成的 `import-wiki` 一把梭搞定。

**决策**
**不用 `import-wiki` 一把梭。** 分工如下：
- `import-wiki` 是**纯结构迁移**：把 `CONTEXT.md` 直接拷入只会得到**无图的扁平页**，拿不到 section 图。
- 语义升级归两条通道：
  - `update-wiki`：**日常增量**维护，经 `grill_context_to_candidates.py` 把 grill 知识转成**候选行**。
  - `migrate-wiki`：**一次性存量**迁移。

**理由**
- `import-wiki` 只做结构搬运，做不了语义升级，硬拿它一把梭会丢掉 tier-2 的核心价值（section 图）。
- 薄适配层走**候选行通道**，让 `update-wiki` 保持 **grill-agnostic**：它只看得见候选行，**不认识 `CONTEXT.md`**。grill 特有的格式知识被隔离在 `grill_context_to_candidates.py` 这一薄层里，主流程不被污染。

---

## 决策 6：hook 的能力边界与 per-ticket 精度（已查实）

**背景**
per-ticket（按工单）精度需要知道「当前 ticket 是哪个」。这依赖 Claude Code 的 hook 能力。

**决策**
基于 hook 的真实能力来设计：
- 可注入的事件 = **SessionStart / UserPromptSubmit / PostToolUse / Stop / PreCompact / PostCompact**，都经 `hookSpecificOutput.additionalContext` 注入上下文。
- `type: command` 的 hook 可以跑**任意脚本**（从 stdin 收事件 JSON）。
- **hook 没有原生的「当前 ticket」字段**。因此 per-ticket 精度靠三级降级取得：
  1. 显式 `/wiki-materialize <ticket>`（**首选**）。
  2. `current-ticket` marker / 环境变量。
  3. 解析 `tool_input` / transcript。

**理由**
- hook 无 ticket 字段是**已查实的硬限制**，设计必须正视，不能假设有。
- 首选显式 skill 调用，是因为它给出**确定的** ticket 身份；后两级作为退路，精度递减但保证不空转。

---

## 决策 7：诚实的降级（已接受）

**背景**
脱离 Superpowers 后，丢失了它的 executing / SDD 阶段钩子，某些原本 airtight 的能力必然打折。与其掩盖，不如诚实承认并补偿。

**决策**
接受两处降级，并各自配上补偿：

1. **Bind 从「强制门」降为「约定 + hook」**。
   - 原因：hook 无 ticket 字段。
   - 做法：per-ticket 精度靠**显式 skill 约定**，hook 只作**会话级粗兜底**。
   - 代价与补偿：airtight 略有下降，用**双保险**（显式 skill + hook 兜底）来补偿。

2. **中途 capture 降级**。
   - 原因：没有 executing / SDD 阶段可以边跑边追加。
   - 做法：退回「**末尾一次**」捕获。
   - 补偿：grill **规划期的质询当场写进 wiki**；「编码中涌现」的知识靠末尾 `update-wiki` 从 **git diff 复盘**。
   - 明确不做：**不单独造 emergent-decision hook**。

**理由**
- 这两处降级是脱耦的必然代价，透明记录比假装无损更可靠。
- 双保险 + 规划期即时落库 + 末尾 git diff 复盘，三者叠加后实际覆盖面接近原方案，且不引入一个脆弱的专用 hook 来维护。

---

## 决策 8：安装模型（**已被决策 12 取代**）

> 本节保留为历史记录。两级安装模型已整体废除，改为以 Claude Code 插件发货——见决策 12。

**背景**
安装要同时满足两个诉求：skill「一次装、跨项目复用」，以及 hook / 约定 / 数据「每项目独立」。

**决策**
- **skills 装到用户级** `~/.claude/skills`：一次安装、跨项目共用。
- **hooks / host 约定 / wiki 数据走项目级**：每个项目各自持有。
- `__GRILL_ADAPTER_ROOT__` = **payload 根**，默认 `~/.claude/grill-adapter`，内含 `scripts / contracts / hooks / mcp`。
- **零 skill patch**。

**理由**
- skill 逻辑无项目差异，放用户级避免每个项目重复安装。
- hook、host 约定、wiki 数据天然是项目私有的，放项目级才能各自隔离、各自演进。
- 用 `__GRILL_ADAPTER_ROOT__` 统一 payload 根，安装路径可配置、可迁移。
- 「零 skill patch」呼应决策 4 的铁律 ①，安装模型本身就不碰宿主 skill。

---

## 决策 9：source-of-truth 校验 = 独立 skill + lint hook

**背景**
真实源（source-of-truth）校验需要**确定性**，不能只靠往上下文里注入一段 prose 约定就指望模型每次都照做。

**决策**
- **Verify = 独立的 `/source-truth-check` skill**，与 `/wiki-research` **同构**。它比纯 prose 约定注入**更确定**。
- **Lint = `source-truth-lint.sh` hook**，对**真实的 changed files** 跑检查。
- **policy 门不被授权标志绕过**：授权标志只表示 skill 已取得用户授权，不能越过 policy 拒绝。

**理由**
- 把校验做成独立 skill，触发点明确、行为可复现，比散落在 prose 里的软约定确定得多。
- lint hook 对真实变更文件跑，抓的是实际改动而非空谈。
- policy 门不可被授权标志绕过，保证「授权」和「合规」是两件事，授权不等于放行违规内容。

---

## 决策 10：shared wiki 每项目绑定

**背景**
多项目共享 wiki 时，「哪个项目连哪个 shared wiki」的归属必须清晰、可 fail-closed。

**决策**
shared wiki 采用**每项目绑定**：
- 连接配置写进**项目自己的** `.shared-adapter/settings.json` 的 `wiki.sharedMcp`。
- MCP 以**一份通用、不含 repo 的注册**存在，启动时读 Claude Code 注入的 `CLAUDE_PROJECT_DIR`，从该项目 settings **自我配置**。
- 未声明连接的项目 **fail-closed**（即没有 MCP shared wiki）。
- **换绑 / revision 漂移一律 fail-closed**。

**理由**
- 连接即身份：把绑定放进项目 settings，让「连哪个 shared wiki」成为项目自身的显式声明，而不是全局隐式状态。
- 一份通用注册 + 读 `CLAUDE_PROJECT_DIR` 自配置，避免为每个项目注册一份 MCP，降低维护面。
- fail-closed 是安全默认：没声明就不连、换绑或版本漂移就停，宁可不给也不给错，杜绝跨项目串味。

---

## 决策 11：脱 plan 文件假设 —— 命名中性化 + ticket roster 锚点

**背景**
本项目从 `superpower-adapter` 移植而来，带过来两样 Superpowers 时代的遗留：

1. **命名**：项目里的 `.superpowers/`（项目 wiki + settings + current-ticket marker）与 `.shared-superpowers/`（shared wiki + settings + submodule scripts）。
2. **更深的一层——plan 文件假设**：引擎 `wiki_context_render.py` 的 `extract_plan_tasks()` 要求**一个** markdown 文件里有 `### Task T1: 标题` 形式的标题，`--finalize` / `--bind-fingerprints` / `--scaffold-tasks` / `--fingerprint-preflight` 全部硬依赖 `--plan-path`。这是 Superpowers 的 plan 产物格式。

查证 grill（mattpocock/skills）源码后确认：**grill 根本不产出 plan 文件**。`/setup-matt-pocock-skills` 为每个 repo 配置 issue tracker 并记在 `docs/agents/issue-tracker.md`，两种形态都对不上引擎：

| | grill 本地 markdown 形态 | grill GitHub 形态（默认） | 旧引擎要求 |
|---|---|---|---|
| 文件 | N 个（`.scratch/<slug>/issues/<NN>-<slug>.md`，每 ticket 一个） | 零个（issue 在 tracker 上） | 1 个 |
| 标题 | `# 01 — Title` | 无 | `### Task T1: Title` |

即 grill-adapter 的 Carry/Bind 触点在 grill 下**跑不起来**：host 约定块让 agent 跑 `--scaffold → --finalize`，而 `--finalize` 在 grill 项目里必然报 `FingerprintError: No stable task headings found`。`docs/superpowers/plans/` 这串路径只是露出来的尖角。

**决策**
- **命名硬切换、不做回退**：`.superpowers/` → `.adapter/`，`.shared-superpowers/` → `.shared-adapter/`。不读旧名、不提供迁移脚本；已有项目手工改。指代 Superpowers 产品本身的散文、`superpower-adapter`（旧仓库）、`__SUPERPOWER_ADAPTER_*__`（release-check 的违禁占位符护栏）一律保留。
- **裸 `superpowers/` 目录 marker 直接删除**，不映射成裸 `adapter/`——后者在真实项目里是极常见的源码目录名（适配器模式），会让 `repo_root()` 误判项目根。只保留 `.adapter` / `.shared-adapter` 两个点目录 marker。
- **锚点从 plan 文件换成 feature**：sidecar 全部收进 `.adapter/context/<feature-slug>.{wiki-selection,wiki-context,ticket-roster,wiki-candidates}`。取消「往 plan 加 `## Referenced Project Wiki` 小节」的要求——没有 plan 文档可加，**sidecar 自身即记录**。
- **task 身份 + 指纹来自 host 无关的 ticket roster**（契约 `contracts/ticket-roster-v1.example.jsonc`）：引擎收 N 个 `(taskId, taskTitle, text)`，不解析文档、不读 tracker、不碰网络。roster 怎么填由各 host 约定块规定（grill local 读 `.scratch/`、grill GitHub 跑 `gh issue view`、plain 由用户指定）。`ticketSource` 仅作审计记录，引擎不据此分支。
- **契约升 v5**（`wiki-context-v4` → `v5`）：`planPath` → `featureSlug` + `ticketSource`；`taskRouting.planTaskFormat` → `ticketRosterFormat`。硬切换，不认 v4。
- **`.adapter/context/` 一律不提交**：sidecar、roster、candidates 都是本地工作态，执行期在同一工作树就地读。

**理由**
- **命名按工具命名空间而非内容**：这两个点目录装的是 wiki/ + settings + scripts + marker，是工具的命名空间，不是纯 wiki 目录；叫 `.wiki/` 会得到 `.wiki/wiki/`。
- **roster 是 host 无关的正确边界**：hosts 对「ticket 放哪」意见不一，grill 默认形态甚至没有任何本地文档可供解析——没有任何单一文档能让引擎去 parse。把 roster 交给引擎，新增 host 只需写约定块，**不必改引擎**；引擎也因此不必依赖网络、`gh` CLI 或 grill 的 `docs/agents/` 约定。
- **指纹机制原样保留**：`load_ticket_roster()` 返回与旧 `extract_plan_tasks()` 完全相同的 `{taskId: {title, text, hash}}`，所以 `bind_fingerprints` / `scaffold_tasks` / `fingerprint_preflight` 的逻辑一行未动。漂移检测（ticket 正文改了就 fail-closed）语义不变，只是从「plan 段落漂移」变成「ticket 正文漂移」。
- **feature 锚点两种 tracker 形态都成立**，而「从 planPath 推导」只是把一个硬编码假设换成另一个不存在的假设。
- **不提交**与既有设计自洽：host 块本来就有「sidecar 被 gitignore 时留在盘上、execution 就地读」的兜底，现在这条从兜底变成常态。

**代价（已知并接受）**
- 与 `superpowers-adapter` **彻底分叉**：它仍是 `### Task N:` plan 模型。`.shared-adapter/settings.json` 这层（wiki 绑定）仍可共用，Carry/Bind 数据流不兼容。

---

## 决策 12：以 Claude Code 插件发货（取代决策 8）

**背景**
两级安装（用户级 skills/agents/payload + 项目级 hook/约定）有三个实际问题：12 个 skill + 3 个 agent 无差别出现在**每个**项目（包括不用 wiki 的），装卸靠 `manage.sh` 手工搬文件，shared-wiki MCP 还要用户手动 `claude mcp add-json` 注册。Claude Code 的插件机制恰好原生解决这三点。

起点是一个更糟的提议：把 adapter 的 skill 直接塞进宿主插件目录（`~/.claude/plugins/cache/mattpocock/mattpocock-skills/`）。这条路**必须否掉**——见下方「否掉的方案」。

**决策**
- **本仓库即插件**：`.claude-plugin/plugin.json` 声明包，Claude Code 自动发现 `skills/`、`agents/`、`hooks/hooks.json`、`.mcp.json`。安装 `claude plugin install grill-adapter@grill-adapter --scope project|user`；开发期 `claude --plugin-dir "$PWD"` 免安装加载。
- **`__GRILL_ADAPTER_ROOT__` → `${CLAUDE_PLUGIN_ROOT}`**，且**只在插件内容里**。Claude Code 在加载时做文本替换（并把反斜杠归一为正斜杠，故 PowerShell / bash 皆可）；只匹配裸 token。
- **约定块零路径**：`host-adapters/*/CLAUDE.md` 写进目标项目、属插件外，不许含任何安装路径，只**点名 skill**。原先它直接调的 grill→wiki 桥搬进 `skills/update-wiki`，ticket-roster 契约形状归 `skills/wiki-research`。
- **hook 随插件注册**（`hooks/hooks.json`），不再并进项目 `.claude/settings.json`；`host-adapters/hooks.settings.json` 删除。
- **MCP 随插件自启**（`.mcp.json`），`manage.sh mcp-registration` 删除。`npm run build` 改为 esbuild 单文件打包，**`dist/index.js` 提交进仓库**；类型检查拆到 `npm run typecheck`。
- **`install.py` 只剩一件事**：写/剥目标项目 `CLAUDE.md` 的 host 约定块。`manifest.json` 只剩 `projectLevel.hostConventions`；`GRILL_ADAPTER_HOME` 移除。
- **Lanhu 生成源 `agents/lanhu-requirements-analyst.common.md` → `role-prd/analyst.common.md`**。

**理由**
- **作用域**：`--scope project` 让 skills/agents/hooks/MCP 只在需要的项目出现，用户级命名空间不再被污染；这也正是宿主 grill 自己的安装方式。
- **`${CLAUDE_PLUGIN_ROOT}` 比安装期替换更强**：插件升级后自动跟着走，而烤死的绝对路径会腐烂。
- **约定块零路径是被逼出来的、不是洁癖**：它落在插件外，`${CLAUDE_PLUGIN_ROOT}` 不会被替换；而插件缓存路径带版本号（`.../0.2.0/`）、旧版本约 7 天后回收，烤死路径必然静默腐烂。只点名 skill 是唯一稳的形态。
- **提交 bundle 是插件模型的硬约束**：插件缓存**没有安装期构建步骤**，`.mcp.json` 直接启动提交进去的那份。
- **生成源不能放 `agents/`**：插件把 `agents/*.md` 全部注册成 agent，模板放那儿会变成幽灵 agent（实测：挪走前 `plugin details` 报 4 个 agent）。

**否掉的方案：把 skill 装进宿主插件目录**
- **版本化路径 + GC**：真实路径是 `cache/mattpocock/mattpocock-skills/1.2.0/`，宿主发 1.2.1 即换目录，写进去的东西失联，旧目录约 7 天后被回收。官方文档明言该目录是 ephemeral、不要往里写状态，跨插件写入不受支持。
- **违反铁律 ①**：把我们的 skill 塞进宿主包，就是 patch 宿主包。
- **plain host 无处安放**：`--host plain` 根本没有 grill 插件。

**代价（已知并接受）**
- **skills 与 MCP 无法分别作用域**：插件自带 MCP 严格跟随插件作用域，做不到「skills 全局 + MCP 单项目」。（逃生舱：插件 MCP 与手动注册按 endpoint 判重，local/project/user 优先级均高于 plugin，手动注册会压过插件那份——但双轨并存排查成本高，不推荐。）
- **仓库多一个构建产物** `mcp/shared-wiki/dist/index.js`，release-check 步骤 5 卡它与 src 的漂移。
- **skill 引用一律变长**：`/wiki-research` → `/grill-adapter:wiki-research`（插件 skill 强制带命名空间）。

---

## 决策 13：同仓库提供 Codex 原生插件入口

**背景**
Codex 能兼容读取 Claude marketplace，但真实安装探针显示，仅靠 `.claude-plugin` 不足以完成运行：12 个 skills 可见，`agents/` 不注册，hooks 因宽松 JSON 注释字段被严格解析拒绝，MCP 也不能依赖 `CLAUDE_PROJECT_DIR`。

**决策**
- 新增 `.codex-plugin/plugin.json`，复用现有 skills、hooks、MCP bundle 与 marketplace；Codex MCP 声明使用原生 `cwd: "."` + 相对 bundle 路径，不复制执行层。
- `manage.sh` 增加独立的 `--runtime claude|codex|both` 维度；workflow host 仍由 `--host grill|plain` 决定。Claude 写 `CLAUDE.md`，Codex 写 `AGENTS.md`。
- 保留 `agents/*.md` 为单一角色真相源。Claude 直接注册；Codex 由 `wiki-research` / `lanhu-requirements` 读取完整 prompt 后派生通用 sub-agent。
- hooks/MCP 配置使用两端都接受的严格 JSON 子集。MCP 项目根在 Claude Code 下取 `CLAUDE_PROJECT_DIR`，在 Codex 下取 MCP request 的 Git workspace metadata，并兼容标准 roots capability；直接 CLI 才回退进程 cwd。Codex 的 plugin MCP cwd 是插件根，不能充当消费项目根。
- 发布门加入隔离 `CODEX_HOME` 下的真实 marketplace add + plugin add smoke；共享运行时改动最终仍需真跑完整 Codex 集成路径。

**理由**
- 双 manifest 让 Codex UI、校验和安装使用原生 metadata，同时不破坏既有 Claude 用户。
- runtime 与 host 正交，避免把「用 grill 还是 plain」错误地等同于「用 Claude 还是 Codex」。
- agent prompt、skills 与引擎保持单源，防止双平台规则漂移。

**代价（已知并接受）**
- Codex 当前没有 Claude 的 plugin project/user scope；隔离依赖项目绑定与 fail-closed policy。
- 两端的 skill 引用语法不同：Claude 用 `/grill-adapter:<skill>`，Codex 用 `$grill-adapter:<skill>`，因此 host 约定块必须各有一份薄模板。

---

## 决策 14：候选输入升级为 feature-scoped append-only event journal

**背景**
旧 `.wiki-candidates.jsonl` 是 implementation 阶段随手写的裸 candidate rows，`update-wiki` 消费后删除。它不能覆盖 discovery/spec/tickets/review/debugging 的候选，不能表达 supersede/outcome，也无法区分「已处理」与「文件还在」；坏 JSON、重复 candidate 或中断写入只能拖到 Capture 时由 agent 偶然发现。

**决策**
- 保留 `.adapter/context/<feature-slug>.wiki-candidates.jsonl` 路径，但内容升级为 schema-v1 `candidate` / `supersede` / `outcome` events。
- 新增 `/grill-adapter:candidate-journal` 稳定入口；host convention 只点名 skill，不携带插件路径。所有知识生产阶段都追加到同一 feature journal，中间阶段不写 Obsidian。
- `wiki_candidate_journal.py` 在文件锁内先完整 replay，再单次 append + fsync。损坏、尾部缺换行、重复 event/candidate ID、跨 feature、未知引用与非法终态转换一律拒绝且不修改 journal。唯一幂等入口是 grill bridge：稳定 candidate ID 与完整 payload 都相同才跳过，使 Capture 中断后可重跑；同 ID 不同内容仍拒绝。
- fold 状态为 `pending` / `superseded` / `kept` / `skipped` / `deferred`。kept/skipped/superseded 为终态；deferred 可在恢复后转 kept/skipped。
- journal 不删除，保留为中断恢复 receipt；Stop hook 根据 fold 结果提醒 pending/deferred，全终态静默，invalid 单独报警。

**理由**
- append-only event history 同时保住原始候选、替代关系和 Capture 决策，不靠覆写恢复状态。
- 机械 helper 只保证数据完整性，不替代 `update-wiki` 的 durable/ownership/policy 语义门。
- 同一 feature identity 与 Carry/Bind sidecar 对齐，host 不需要暴露 plan 文档或引擎路径。

**代价（已知并接受）**
- 插件组件从 12 增至 13 skills；release inventory 与双 runtime smoke 必须同步。
- 旧裸 candidate rows 不兼容新 journal，过渡中的活动 feature 必须重新经 skill 追加，不能混写或自动猜测迁移。
