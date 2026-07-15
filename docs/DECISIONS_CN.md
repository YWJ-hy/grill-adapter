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

## 决策 8：安装模型

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
- 连接配置写进**项目自己的** `.shared-superpowers/settings.json` 的 `wiki.sharedMcp`。
- MCP 以**一份通用、不含 repo 的注册**存在，启动时读 Claude Code 注入的 `CLAUDE_PROJECT_DIR`，从该项目 settings **自我配置**。
- 未声明连接的项目 **fail-closed**（即没有 MCP shared wiki）。
- **换绑 / revision 漂移一律 fail-closed**。

**理由**
- 连接即身份：把绑定放进项目 settings，让「连哪个 shared wiki」成为项目自身的显式声明，而不是全局隐式状态。
- 一份通用注册 + 读 `CLAUDE_PROJECT_DIR` 自配置，避免为每个项目注册一份 MCP，降低维护面。
- fail-closed 是安全默认：没声明就不连、换绑或版本漂移就停，宁可不给也不给错，杜绝跨项目串味。
