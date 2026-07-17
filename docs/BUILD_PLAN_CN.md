# grill-adapter 构建蓝图：host-agnostic adapter（脱 Superpowers，grill 作前端）

> ## ⚠️ 已归档 —— 历史文档，不要照此施工
>
> 本文是项目**初次构建**时的蓝图，保留作历史记录。它描述的**两级安装模型已整体废除**：grill-adapter 现在以 **Claude Code 插件**发货（`.claude-plugin/plugin.json`，skills/agents/hooks/MCP 随插件一起激活），`__GRILL_ADAPTER_ROOT__` 与用户级 payload 均已不存在。
>
> 当前事实以这些为准：`docs/ARCHITECTURE_CN.md`（架构）、`docs/HOST_INTEGRATION_CN.md`（安装模型与 `${CLAUDE_PLUGIN_ROOT}` 边界）、`docs/DECISIONS_CN.md` 决策 12（插件化的理由与代价）、`CLAUDE.md`（开发约定）。本文与它们冲突时，**一律以它们为准**。
>
> 下方原文保持不动。

---

> 本文是一份**自包含的新项目构建蓝图**。执行者是一个**全新的、无本对话上下文的 AI 会话**。请先完整读一遍，再动手。
>
> **工作名 `<PROJECT_NAME> = grill-adapter`**（wiki 是中心，但项目现在也含 Lanhu + source-truth；想要更中性的名字就全文替换）。

---

## 0. 给执行会话的执行须知（先读这条）

- **你在哪、建在哪**：源仓库 = 本蓝图所在的 `superpower-adapter/`（成熟但耦合 Superpowers 的 adapter）。你要在**它的同级**新建目录 `../grill-adapter/`，把新项目建在那里。**不要改动 `superpower-adapter/`**——它保留作 Superpowers 路径。
- **核心动作 = 移植功能 + 新建 host-agnostic 皮，不是重写**：wiki 引擎、Lanhu、source-truth 都是已验证的成熟代码，**原样移植、按 §7 改占位符/路径即可**。
- **本项目 = 旧 adapter 的几乎全部功能，只弃掉一样东西**：`lib/native_skill_patch.py`（那 6 处 Superpowers 专属 patch 接线）。功能都带过去，但**它们挂上宿主的方式**从「patch 宿主 skill 内部」换成「独立 skill/agent + host-adapter 约定 + 可选 hook」。
- **三条铁律**：
  1. **不 patch 任何宿主 skill**——grill / Claude Code 的 skill 内部一行不碰。
  2. **验收以 Claude Code 集成路径为准**——真跑 `grill → implement → update-wiki`，不是只跑通 Python（§13）。
  3. **markdown 唯一真相源，不引外部图数据库**——`.graph.json` 是派生物（§10）。
- **已定决策**：全部 adapter 功能（wiki + Lanhu + source-truth + break-loop）都带过去，只弃 Superpowers patch 接线；grill 作默认宿主 + wiki authoring 前端；**中途执行期 capture 接受降级**（靠 grill 规划期捕获 + 末尾 update-wiki，不单造 emergent-decision hook）。
- **新项目自包含**：建完把本蓝图复制进 `grill-adapter/docs/BUILD_PLAN_CN.md` 存档。
- **远程仓库（已建，空）**：`https://github.com/YWJ-hy/grill-adapter.git`。项目完成并过验收后，初始化 git、提交、推送到该 remote（§12 步 10）。

---

## 1. 背景与判断（为什么这么做）

- 旧 adapter 基于 **Superpowers**，wiki / Lanhu / source-truth 全靠 native skill patch 挂进它的工作流。痛点：Superpowers 流程长/耗 token，且往上游 skill 内部打锚点**耦合脆、随版本漂移**（6.0.0 breaking 有前科）。
- 目标：**彻底脱 Superpowers，功能全保留**。
- 关键判断（已查实）：
  - mattpocock/skills（grill）是**完整的 Superpowers 同类生态**：`/grill-with-docs → /to-spec → /to-tickets → /implement → /code-review`（+ `wayfinder`、`diagnosing-bugs`），有执行/评审/调试 seam。
  - grill 的知识层 = `CONTEXT.md`（glossary-only）+ `docs/adr/`，design-time only、无 section 图/跨 repo/执行期绑定，是 wiki 的 **tier-1**，缺**跨 repo 共享**与**执行期约束绑定**两根柱子。
  - **token 杠杆是「跑几段」不是「换谁家」**。
- 结论：功能全留 + host-agnostic + grill 前端；执行期 reread + shared MCP 照旧；中途 capture 接受降级。

---

## 2. 目标架构（三层 + 多子系统同构）

```
┌─────────────────────────────────────────────────────────┐
│  Host 适配器（薄、可插拔、零 skill patch）                 │
│   ├─ grill-host  ← 默认：CLAUDE.md 约定块 + hook          │
│   └─ plain       ← 裸 Claude Code：/命令 + hook            │
│   （superpowers-host 不进本项目——留在旧 adapter，见 §4）  │
├─────────────────────────────────────────────────────────┤
│  各子系统的 host 无关触点（同构：独立 skill/agent          │
│   + host-adapter 约定 + 可选 hook）                        │
│   · wiki:        Disclose·Carry·Bind·Capture  (§3)        │
│   · Lanhu:       Intake                        (§8.5)     │
│   · source-truth: Verify·Lint                  (§8.6)     │
│   · break-loop:  Debug-retrospective→Capture   (§8.7)     │
├─────────────────────────────────────────────────────────┤
│  引擎（从旧 adapter 原样移植）                             │
│   scripts/* (wiki + lanhu + source_truth) · .graph.json  │
│   · shared-wiki MCP · 索引 · doctor · export · templates  │
└─────────────────────────────────────────────────────────┘
```

**不变式**：host 适配器绝不 patch 宿主 skill。grill-host 只靠项目 `CLAUDE.md` 约定 + Claude Code hook——这是不被 Matt churn 波及的关键。

---

## 3. wiki 稳定契约：4 个 host 无关触点

| 触点 | 机制 | 落到 grill 生态 |
|---|---|---|
| **Disclose** 选 wiki | 独立 `/wiki-research` skill（包 `wiki-researcher` agent），任何 host 都能调 | grill-with-docs 质询期调它 |
| **Carry** 带约束 | `.wiki-context.json` sidecar = 中立载体（记选中 section 的 source-aware 引用 + `sharedWiki` 身份） | to-spec / to-tickets 阶段据 selection 写它 |
| **Bind** 执行期 reread | ① 精确：每 ticket 调 `/wiki-materialize <ticket>` ② 粗兜底：hook 检测 active sidecar 注入（会话级——hook 无原生 ticket 字段，§14） | implement 逐 ticket 跑，**不 patch implement** |
| **Capture** 回写 | `/update-wiki`（语义门一字不动）经 Stop hook / 约定触发 | code-review 后跑 update-wiki；grill 质询也经 §9 桥写进 wiki |

`/wiki-materialize` 复用 `wiki_materialize_task.py`——本地 + `github_mcp` 两类 section 统一取，含**执行期有界 1 跳 `depends-on` 闭包**（不变式，§10）。Lanhu / source-truth / break-loop 的触点见 §8.5–8.7。

---

## 4. 项目边界：IN / OUT scope

**IN（全部带进 grill-adapter）**：
- **wiki**：引擎 + section 图 + shared MCP + 4 触点皮（`wiki-research`、`wiki-materialize`、`update-wiki`、`init-wiki`、`import-wiki`、`migrate-wiki`、`publish-shared-wiki`、`shared-wiki-mcp`）+ `scaffold-practice-skill`。
- **Lanhu 需求录入**：`lanhu-requirements` skill + 3 个 analyst agent + `role-prd/` 模板 + `lanhu_settings.py`。
- **source-of-truth**：`source_truth_settings.py` + `source_truth_common.py` + 其 plan 校验 / 执行 lint 触点（§8.6）。
- **break-loop**：调试复盘 → capture（§8.7）。
- 支撑：`wiki-template/`、`wiki-repo-skills/`、`wiki-repo-ci/`、`contracts/`、install/manage/manifest/tests/docs。

**OUT（唯一留在旧 `superpower-adapter/`）**：
- `lib/native_skill_patch.py`——6 处 Superpowers 专属 patch 接线。它的**功能**都在 IN 里重新落地，只有**这套「打进宿主 skill 内部」的机制**被 host-adapter 皮取代。
- superpowers-host：谁还要 Superpowers 路径就用旧 adapter，新项目不背。

> 关键：Lanhu 与 source-truth 今天也是靠 native patch 挂上去的，所以"带过去"= 移植其代码 **+ 为它们各配一套 §8 的 host-agnostic 触点**，不是纯拷文件。

---

## 5. 新项目目录结构（完整树）

```
grill-adapter/
├── README.md · CLAUDE.md · QUICKSTART_CN.md · LICENSE · .gitignore
├── manage.sh                     # install/verify/doctor/bootstrap-wiki/export-wiki-skills/self-test/release-check
├── manifest.json                 # 包清单：哪些 skill/agent/hook 装到哪
├── docs/
│   ├── ARCHITECTURE_CN.md · HOST_INTEGRATION_CN.md · USER_FLOW_CN.md
│   ├── DEVELOPMENT_CN.md · DECISIONS_CN.md · LANHU_CN.md
│   └── SETUP_AND_USAGE_CN.md · BUILD_PLAN_CN.md
├── skills/                       # host 无关 Claude Code skills
│   ├── wiki-research/            # 【新建】Disclose 入口
│   ├── wiki-materialize/         # 【新建】Bind 入口
│   ├── update-wiki/ · init-wiki/ · import-wiki/ · migrate-wiki/          # 【移植】
│   ├── publish-shared-wiki/ · shared-wiki-mcp/ · scaffold-practice-skill/# 【移植】
│   ├── lanhu-requirements/       # 【移植】Lanhu 录入入口
│   ├── break-loop/               # 【移植】调试复盘→capture
│   └── source-truth-check/       # 【新建】source-truth Verify 入口
├── agents/
│   ├── wiki-researcher.md                              # 【移植】
│   ├── lanhu-frontend-requirements-analyst.md          # 【移植】
│   ├── lanhu-backend-requirements-analyst.md           # 【移植】
│   └── lanhu-requirements-analyst.common.md            # 【移植】共享规则源
├── scripts/                      # 【移植】Python 执行层
│   ├── wiki_common.py · wiki_context_render.py · wiki_materialize_task.py
│   ├── wiki_generate_section_index.py · wiki_update_check.py
│   ├── wiki_migrate_helper.py · wiki_graph_neighbors.py · wiki_section.py
│   ├── wiki_import.py · init-wiki.py
│   ├── source_truth_settings.py · source_truth_common.py    # source-of-truth
│   ├── lanhu_settings.py                                    # Lanhu
│   └── grill_context_to_candidates.py                      # 【新建】grill CONTEXT.md/ADR → wiki 候选行
├── mcp/shared-wiki/              # 【移植】MCP server（已读 CLAUDE_PROJECT_DIR，host 无关）
├── role-prd/                     # 【移植】Lanhu PRD 角色模板 frontend.md / backend.md
├── contracts/                    # 【移植】wiki-context-v4 / wiki-selection-v1 schema 示例
├── hooks/                        # 【新建】
│   ├── wiki-reread.sh            # UserPromptSubmit/SessionStart → 注入 materialized 硬约束
│   ├── wiki-capture-suggest.sh   # Stop → 提示/触发 update-wiki
│   └── source-truth-lint.sh      # PostToolUse/Stop → 对 changed files 跑 source-truth lint
├── host-adapters/
│   ├── grill/                    # 【新建】CLAUDE.md 约定块（wiki+Lanhu+source-truth+break-loop）+ hook 片段
│   └── plain/                    # 【新建】裸 Claude Code 等价约定 + hook 片段
├── wiki-template/ · wiki-repo-skills/ · wiki-repo-ci/       # 【移植】
├── lib/
│   ├── install.py                # 装 skills/agents/hooks 到用户级或目标项目 .claude/
│   ├── export_wiki_skills.py     # 【移植】
│   ├── package_manifest.py       # 【移植自 adapter_manifest.py】
│   └── resolve_install_target.py # 【改写自 resolve_target.py】不再找 Superpowers 目录
└── tests/                        # 【移植 + 适配】
```

---

## 6. 新项目必须写入的文档集

| 文件 | 用途 | 大纲要点 | 取材 |
|---|---|---|---|
| `README.md` | 门面 | 定位；解决什么；安装；30 秒上手；与 grill/Claude Code 的关系；文档索引 | §1、§2 |
| `CLAUDE.md` | 在本项目内**开发**时给 Claude Code 的指令 | 必读顺序；`manage.sh` 命令；架构（三层+子系统）；用户流程；开发与验收要求；不变式 | §2、§3、§8、§10、§13 |
| `docs/ARCHITECTURE_CN.md` | 架构参考 | 三层图；wiki 4 触点；Lanhu/source-truth/break-loop 触点；引擎组件；section 图；shared MCP；执行期闭包 | §2、§3、§8、§10 |
| `docs/HOST_INTEGRATION_CN.md` | 怎么接 host | host 适配器模型；**grill-host 约定块全文**（四子系统）+ hook 配置；plain 用法；install 模型；`__GRILL_ADAPTER_ROOT__` 替换 | §7、§8 |
| `docs/USER_FLOW_CN.md` | 最终用户全程流 | Lanhu 录入→grill 质询(disclose)→to-spec/tickets(carry)→implement(bind)→code-review→capture；source-truth 校验/ lint 穿插；每步命令与产物 | §3、§8、§9 |
| `docs/DEVELOPMENT_CN.md` | 开发与测试原则 | 验收铁律；测试分层；smoke/regression 清单；改 skill/hook/引擎的验证要求；`release-check` | §13 + 旧 `ADAPTER_DEVELOPMENT_CN.md` |
| `docs/DECISIONS_CN.md` | 为什么这么设计 | tier-1/tier-2；token 杠杆；grill 生态；hook/import 查实；中途 capture 降级 | §1、§11、§14 |
| `docs/LANHU_CN.md` | Lanhu 录入专章 | 无设计稿单文件 / 有设计稿 `prd.md+design/`；PRD 结构固定内容灵活；HTML 输出偏好；多页 subagent 分页；选择性图片解析；evidence-package 只作输入不约束 spec | 旧 `lanhu-requirements/SKILL.md` + `role-prd/` |
| `QUICKSTART_CN.md` | 5 分钟跑通（已装过 grill 的人） | 装 grill-adapter → bootstrap wiki → 跑一次 grill→implement→update-wiki → doctor | §12 |
| `docs/SETUP_AND_USAGE_CN.md` | **面向从未装过 grill 的用户**的安装+使用指南 | 前置(Claude Code)；**装 grill**（§6.1）；**装 grill-adapter**(`./manage.sh install`)；端到端走一遍(可选 Lanhu→grill→to-tickets→implement→code-review→update-wiki，每步命令+产物)；常见问题 | §6.1 + §8 + §12 + grill 官方 README |
| `docs/BUILD_PLAN_CN.md` | 本蓝图存档 | 复制本文件 | 本文 |

完整性件：`LICENSE`、`.gitignore`、`manifest.json`、`manage.sh`、`tests/`（§13 checklist 兜底）。

### 6.1 grill 安装方式（写 SETUP 文档时照此；落地前再核一次官方 README）

- 装：`/plugin marketplace add mattpocock/skills` → `/plugin install mattpocock-skills@mattpocock`
- 初始化：`/setup-matt-pocock-skills`（会问 issue tracker=GitHub/Linear/local、ticket 标签、docs 保存位置）
- 备选：`npx skills@latest add mattpocock/skills`
- 它是**只读、随版本更新**的托管 plugin bundle（订阅而非 fork）——正好呼应 grill-adapter「零 skill patch、不动 grill 内部」的设计；grill 升级不影响 grill-adapter。

---

## 7. 从 `../superpower-adapter/` 移植什么、怎么移（port map）

| 源 | 目标 | 改动 |
|---|---|---|
| `overlays/scripts/*.py` + 依赖闭包（含 `source_truth_*.py`、`lanhu_settings.py`） | `scripts/` | 占位符 `__SUPERPOWER_ADAPTER_PLUGIN_ROOT__` → `__GRILL_ADAPTER_ROOT__` |
| `overlays/agents/{wiki-researcher,lanhu-*}.md` | `agents/` | 去 Superpowers 措辞→中性 |
| `overlays/skills/*`（wiki 全套 + `lanhu-requirements` + `break-loop`） | `skills/` | 同上占位符；去 Superpowers-workflow 依赖措辞 |
| `mcp/shared-wiki/` | `mcp/shared-wiki/` | 原样（已 host 无关） |
| `role-prd/`、`overlays/contracts/` | `role-prd/`、`contracts/` | 原样 |
| `overlays/wiki-repo-skills/`、`overlays/wiki-repo-ci/`、`wiki-template/` | 同名 | 原样 + 占位符 |
| `lib/{export_wiki_skills,adapter_manifest,resolve_target,hook_patch,subagent_models}.py` | `lib/`（改写/改名） | resolve 不再找 Superpowers 目录；hook_patch 复用来写 §8 hook |
| `manage.sh`、`manifest.json`、`tests/` | 同名 | install 模型（§8.4）；tests 目标改独立 skills + 项目 root |
| **不移植** `lib/native_skill_patch.py` | — | 功能在 §8 重新落地 |

移植后验证：占位符无残留、脚本依赖闭包完整、MCP 独立可启。

---

## 8. 新建的 host-agnostic 皮

### 8.1–8.4 wiki（同前）

- **8.1 skills**：`wiki-research`（薄 router 调 wiki-researcher agent）、`wiki-materialize`（薄 router 跑 wiki_materialize_task.py，含有界 1 跳 depends-on 闭包）。
- **8.2 hooks**：`wiki-reread.sh`（UserPromptSubmit/SessionStart，`type: command`，检测 active `.wiki-context.json` → 跑 materialize → `hookSpecificOutput.additionalContext` 注入）、`wiki-capture-suggest.sh`（Stop → 提示 update-wiki）。
- **8.3 host 适配器**：grill / plain 的 `CLAUDE.md` 约定块 + `settings.json` hook 片段，**零 skill patch**。
- **8.4 install 模型（已定：用户级 skill + 项目级 config）**：`manage.sh install` 分两级——**用户级**（一次装、跨项目）：`skills/`+`agents/` → `~/.claude/skills`、shared-wiki MCP 通用注册（读 `CLAUDE_PROJECT_DIR` 自配置），替换占位符；**项目级**（每项目）：hook 片段写目标 `settings.json`（marker、幂等、只增）、选定 host 约定块写目标 `CLAUDE.md`、wiki 数据/绑定（`.adapter/wiki/`、`.shared-adapter/settings.json`）。`manifest.json` 两级都记账。

### 8.5 Lanhu（Intake 触点）

`/lanhu-requirements` 保持独立 user-invoked skill（+ 3 analyst agent + role-prd）。原 brainstorming 的 lanhu-redirect patch → **grill-host CLAUDE.md 约定一行**：「用户给 Lanhu 链接时，先跑 `/lanhu-requirements <link> frontend|backend`，确认 `.lanhu/.../index.md` 证据包，再把它当 grill-with-docs 的 requirements 输入」。无需 hook（纯 user-invoked）。evidence-package 只作输入、不写进 wiki / spec / 验收（保持旧边界）。

### 8.6 source-of-truth（Verify + Lint 触点）

`source_truth_settings.py` + `source_truth_common.py` 原样移植（settings-driven prompt policy + changed-path lint）。两个触点：
- **Verify（已定做成独立 skill）**：`/source-truth-check`（复用 `source_truth_settings.py`），grill 的 plan 阶段（to-spec/to-tickets）由约定显式调它对计划主张做真实源校验——与 wiki 的 `/wiki-research` 同构、比纯 prose 约定注入更确定。
- **Lint**：implement / code-review 阶段 → `hooks/source-truth-lint.sh`（PostToolUse/Stop）对**真实 changed files** 跑 `source_truth_common` lint。
- 与 wiki 同构：root-specific settings 控制，policy 门不被授权标志绕过。

### 8.7 break-loop（Debug-retrospective → Capture）

`/break-loop` 保持独立 skill。grill-host 约定：`diagnosing-bugs` 修复并验证后，需要复盘时跑 `/break-loop`，它把 durable candidates 交给 `/update-wiki`（对齐旧 systematic-debugging→break-loop→update-wiki 链）。

---

## 9. grill → wiki authoring 桥（已查实，修正版）

grill 照常写 `CONTEXT.md` + `docs/adr/`，**不改 grill 任何 skill**。变成 wiki 知识分两条路，**别用 import-wiki 一把梭**：

- **日常增量** → 走 **`update-wiki` 把 CONTEXT.md/ADR 增量当 candidate input**（复用其 candidate-input 机制）。它才做 durable 闸 + sectionize + 设 `type:` + 加 `[[page#section]]` 边 + dedup + 中性化 + 授权。
- **一次性存量** → `import-wiki`（纯结构落位）→ `migrate-wiki` 模式2（section 化 + typed 图谱）。

原因：`import-wiki` 结构迁移、不做语义合并；CONTEXT.md 是扁平 glossary，直接拷入只得无图价值的扁平页。

**薄适配（已定：走候选行通道，让 update-wiki 保持 grill-agnostic）**：新增 `scripts/grill_context_to_candidates.py`——diff grill 的 CONTEXT.md/ADR 增量、转候选行追加进 `.wiki-candidates.jsonl`；`update-wiki` 原样消费候选（它只见候选行、不认识 CONTEXT.md），不加 CONTEXT.md 专属读路径。

---

## 10. 必保引擎不变式（移植时逐条验证未破）

- **markdown 唯一真相源**，`.graph.json` 派生物；**不引外部图数据库**。
- **执行期不追链**：图只供维护 + lint；执行期只消费 `.wiki-context.json` + **有界 1 跳 `depends-on` 闭包**（不传递、去重、缺图静默 no-op）。
- **section 级 `[[page#section]]` typed 边** + 渐进披露。
- **shared wiki 每项目绑定**：目标项目 `wiki.sharedMcp` 声明连接；MCP 读 `CLAUDE_PROJECT_DIR` 自配置；未声明 fail-closed。
- **root-specific 写授权**（wiki 与 source-truth 同款）：默认 skip/ask；授权标志不绕 `refuse`。
- **shared wiki 中性化**：blockedTerms/blockedPatterns。
- **换绑/revision 漂移 fail-closed**。
- **Lanhu evidence-package 边界**：只作输入，不写进 wiki / 最终 spec / 验收。

---

## 11. 诚实的降级（已定接受）

1. **Bind 从「强制门」变「约定 + hook」**：hook 无原生 ticket 字段（§14），per-ticket 精度靠显式 `/wiki-materialize <ticket>` 约定，hook 作会话级粗兜底。airtight 略降，双保险补偿。
2. **中途 capture 降级（✅ 已接受）**：无 executing/SDD 阶段可边跑边追加 → 退回「末尾一次」。补偿：grill 规划期质询当场写进 wiki；「编码中涌现」靠末尾 update-wiki 从 git diff 复盘。**不单造 hook。**

---

## 12. 构建步骤（执行顺序）

| 步 | 交付物 | 验证 |
|---|---|---|
| 0. 骨架 | `../grill-adapter/` + §5 目录树空壳 + `.gitignore` + `git init` | 树就位 |
| 1. 移植引擎 | `scripts/`（wiki+source_truth+lanhu）、`mcp/`、`role-prd/`、`contracts/`、`wiki-template/`、`wiki-repo-*`；替换占位符 | 依赖闭包完整；MCP 独立可启；`wiki_*.py --wiki-dir` 跑通 |
| 2. 移植 skills + agents | wiki 全套 + `lanhu-requirements` + `break-loop` + scaffold + 4 lanhu/wiki agents | 去 Superpowers 措辞后独立可跑 |
| 3. 新建 wiki 4 触点皮 | `wiki-research`、`wiki-materialize` | Disclose/Bind 跑通 |
| 4. 新建 hooks | `wiki-reread.sh`、`wiki-capture-suggest.sh`、`source-truth-lint.sh` | plain 下 hook 触发+注入正确 |
| 5. 子系统触点 | Lanhu(§8.5) 约定；source-truth `/source-truth-check` skill + lint hook(§8.6)；break-loop(§8.7) 约定；`grill_context_to_candidates.py` 桥(§9) | 约定块可粘进目标 CLAUDE.md；桥+skill 跑通 |
| 6. host 适配器 + install | `host-adapters/{grill,plain}` + `lib/install.py` + `manage.sh` + `manifest.json` | install/verify/doctor 走通 |
| 7. 文档集 | §6 全部 | 完整性 checklist（§13）过 |
| 8. tests | 目标改独立 skills + 项目 root | smoke/regression 过 |
| 9. 集成验收 | — | **Claude Code 真跑 Lanhu?→grill→implement→code-review→update-wiki**（§13） |
| 10. 推送远程 | 初始 commit(s) + `git remote add origin https://github.com/YWJ-hy/grill-adapter.git` + `git push -u origin main` | remote 有完整项目；GitHub 上 README 正常渲染 |

---

## 13. 验收标准 + 完整性 checklist

**验收铁律**：以 **Claude Code 集成路径**为准——真跑 `(可选 lanhu-requirements) → grill-with-docs → to-spec/to-tickets → implement → code-review → update-wiki`，确认各子系统触点生效，而非只证 Python 成功。

- [ ] wiki 四触点、Lanhu Intake、source-truth Verify+Lint、break-loop→capture 各自端到端可用。
- [ ] shared wiki 跨 repo 共享 + 执行期硬约束 reread 两根柱子在 grill 宿主下可用。
- [ ] `./manage.sh release-check <目标项目>` 过。
- [ ] 执行期有界 1 跳闭包、shared MCP 换绑 fail-closed、中性化、source-truth 授权门、Lanhu 边界都有测试覆盖。
- [ ] §10 不变式逐条未破。

**项目完整性 checklist**：

- [ ] §6 全套文档存在且非空。
- [ ] `LICENSE`/`.gitignore`/`manifest.json`/`manage.sh`/`tests/` 就位。
- [ ] `manage.sh` 各子命令可用。
- [ ] 占位符 `__GRILL_ADAPTER_ROOT__` 无残留 `__SUPERPOWER_ADAPTER_*__`。
- [ ] 本蓝图已复制进 `docs/BUILD_PLAN_CN.md`。
- [ ] `docs/SETUP_AND_USAGE_CN.md` 覆盖 grill 安装 + grill-adapter 安装与使用，一个**没装过 grill 的人**能照着跑通。
- [ ] 已 `git push` 到 `https://github.com/YWJ-hy/grill-adapter.git`，GitHub 上项目完整、README 正常渲染。

---

## 14. 查实结论 / 已定 / 仍待核

### 已查实（2026-07-15）

- **✅ import-wiki 作 grill→wiki 桥**：不能一把梭（纯结构迁移）；语义升级归 `update-wiki`（增量）/ `migrate-wiki`（存量）。§9。
- **✅ hook 无原生「当前 ticket」**：事件只给会话级 + 事件级字段。per-ticket 靠 ① 显式 `/wiki-materialize <ticket>`（首选）② `current-ticket` marker/env ③ 解析 tool_input/transcript。
- **✅ hook 能注入 context + shell 脚本**：可注入事件 = SessionStart/UserPromptSubmit/PostToolUse/Stop/PreCompact/PostCompact，经 `hookSpecificOutput.additionalContext`；`type: command` hook 可跑任意脚本（stdin 收事件 JSON、timeout 默认 600s、并行）。reread 用 UserPromptSubmit/SessionStart，capture 用 Stop，source-truth lint 用 PostToolUse/Stop。

### 已定决策

- 方向 = 功能全留 + host-agnostic + grill 前端。
- **Lanhu + source-truth + break-loop 都带过去**（§4）；唯一不带 = `native_skill_patch.py` 机制。
- **中途 capture 接受降级**（§11）。

### 本轮敲定（2026-07-15，按推荐值）

- **项目名 = `grill-adapter`**（贴合"整个 adapter re-based"，与 `superpower-adapter` 成对；要改全局替换）。
- **skills 装用户级** `~/.claude/skills`（一次装、跨项目）；hooks / host 约定 / wiki 数据走项目级（§8.4）。
- **update-wiki 吃 CONTEXT.md = 候选行通道**：新增 `scripts/grill_context_to_candidates.py` 转候选行，update-wiki 保持 grill-agnostic（§9）。
- **source-truth Verify = 独立 `/source-truth-check` skill**（复用 `source_truth_*.py`，与 `/wiki-research` 同构，§8.6）。

至此蓝图无阻塞待定，可交冷启动会话执行。

---

## 附：执行会话「先读这些」清单

1. 本蓝图全文（尤其 §0 铁律、§4 边界、§7 port map、§8 各子系统触点、§12 步骤）。
2. 源仓库 `CLAUDE.md`、`ADAPTER_DEVELOPMENT_CN.md`、`ADAPTER_USER_FLOW_CN.md`、`ADAPTER_INTEGRATION_CN.md`。
3. 移植前逐个读待移植 skill 的 `SKILL.md` 与其调用的 `scripts/*.py`，确认依赖闭包。
