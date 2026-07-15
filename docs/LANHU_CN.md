# grill-adapter Lanhu 需求录入

本章说明 grill-adapter 的 **Lanhu（蓝湖）需求录入** 子系统。它是一个独立、由用户显式调用的 skill，把蓝湖链接整理成宿主流程可读取的原始需求输入包，供 grill-host 的发现 / spec 阶段（grill 的 `/grill-with-docs`）消费。

## 入口与组成

- 入口：`/lanhu-requirements <蓝湖链接> frontend|backend <可选需求命名>`。角色形式接受 `frontend`/`front-end`/`fe`/`前端` 与 `backend`/`back-end`/`be`/`后端`；缺省时读 `.superpowers/settings.json` 的 `lanhu.role`，仍缺失或歧义时向用户询问，角色未定不调用任何分析师或 Lanhu MCP。
- 角色分析师：前端路由到 `lanhu-frontend-requirements-analyst`，后端路由到 `lanhu-backend-requirements-analyst`，两者共享同一份基础来源（`lanhu-requirements-analyst.common.md`）。
- 模板：`role-prd/frontend.md`、`role-prd/backend.md` 定义各角色的固定包结构与职责边界。
- 产物：`.lanhu/MM-DD-需求名称/` 包目录，以 `index.md` 为唯一入口。

## 录入工作流与取数边界

- **角色优先**：先从 `.superpowers/settings.json` 的 `lanhu.role` 解析，其次从用户输入解析；仍缺失 / 歧义 / 前后端都要时先问用户选一个，角色未定前不派发分析师、不调 Lanhu MCP。
- **URL-rooted 页面选择**：URL 含 `pageId` / `page_id` 时把它当 `rootPageId`、当前 URL 当 `rootScopeUrl`。派发前主会话只允许用 `lanhu_resolve_invite_link` 和 `lanhu_get_prd_page_scope`（`scope_policy: pageid_children_only`）拿轻量页面树 `rootScopeTree`，据用户描述在树内匹配出 `selectedTargetPages`；不得在派发前读全页内容、读设计细节或让 Lanhu AI 分析页面。命名页在树外则停下改问，不扩范围。
- **分析师固定取数序列**：每个选中页派给且仅给一个角色分析师，分析师只用 `lanhu_resolve_invite_link` → `lanhu_get_prd_page_scope` → `lanhu_get_prd_scoped_evidence`（`mode: full`、`output_mode: evidence_only`），不得调用任意其他 Lanhu MCP 工具。
- **回传契约**：分析师只回紧凑 metadata、路径、`scopeConfirmationSummary`、`sourceFactCoverage`、确认门状态与 caveats；skill 不接收原始 MCP 文本、全量证据 Markdown 或全量 HTML。
- **命名与防覆盖**：`MM-DD` 用当前日期，需求名用用户提示或分析师 `suggestedSlug`，只保留安全文件名字符；不覆盖已有目录，冲突时加数字后缀或问用户。

## 1. 定位与边界

evidence 包只负责把原始资料中对实现有约束的信息梳理清楚，是宿主规划流程的**输入**，不是 spec，也不约束宿主必须产出什么。宿主仍独自拥有最终 spec、验收标准、测试策略、技术方案、实现任务，以及关于风险 / 例外 / 边界的用户确认。

它明确 **不写、不产出**：

- 不写 `.superpowers/wiki/`，不写 spec、plan、plan sidecar、`Referenced Project Wiki`。
- 不写验收标准、Given / When / Then、验收清单、测试用例 / 测试点 / 测试方案。
- 不出实现方案、技术 / 组件选型、接口设计、数据库设计、前后端边界推断、异常 / 风险推断、代码文件影响、开发任务拆解。
- `.lanhu/` 产物是用户确认过的原始需求输入，不是持久 project wiki，也不是 spec。

## 2. 两种落地形态

前端有唯一包形态（已废弃的 `lanhu.frontend.output.format` 被忽略）：

- **无设计稿 / 不需要交互 demo**：单文件形态 —— `index.md` + `frontend-prd/prd.md`，不生成 `design/`。
- **有设计稿 / 需要交互 demo**：`prd.md + design/` —— 额外生成 `frontend-prd/design/index.html`（原始需求的可交互结构镜像），`assets/` 仅在确认需要时保存本地资源。

```text
.lanhu/MM-DD-需求名称/
  index.md
  frontend-prd/
    prd.md
    design/                 # 仅当存在设计稿或需要交互 demo 时生成
      index.html
      assets/               # 按需；默认不保存蓝湖原图
```

后端始终 Markdown-only，产出 `backend-prd/prd.md`，源证据涉及多份文档时用 `backend-prd/prds/<源需求边界>.md` 拆分，绝不写任何 `.html`。后端正文以固定标题 `# 后端相关 Lanhu 原始需求证据包` 起。

`index.md` 是稳定入口、文件关系与阅读顺序、范围确认摘要与确认状态总览。不得写包根 `prd.md`、`prds/*.md`（前端）、包根 `index.html`、`prototype/index.html`，也不得写 XML-like 页面布局结构草图。

## 3. PRD 结构固定、内容灵活

`role-prd/` 定义的是标准 evidence package 结构，不是运行时可随意改写的建议大纲。AI 可以自定义**内容组织、表述、归类、待确认问题的提炼**，但**不得改变顶层包结构、章节职责、产物边界，以及后续宿主依赖的输入形态**。

- 前端 `prd.md` 不固定主题目录，可按页面 / 流程 / 模块 / 业务对象 / 状态 / 权限差异等最清晰的源事实结构组织。
- 后端固定必覆盖维度：来源与需求概览、业务对象 / 流程 / 规则 / 状态源事实、权限与数据可见性、数据相关源事实、待确认问题。
- 当明确有效源事实装不进固定主题时，必须**新建按源需求内容命名的具体源事实主题**（如 `计费规则源事实`、`通知规则源事实`、`导入导出源事实`）承接；不得用 `其他` / `杂项` / `补充信息` 等泛化兜底标题，也不得把 `AI 自定源事实主题` 当可见标题。
- 证据图默认 Mermaid `flowchart`，只在结构小而浅时用 `mindmap`；节点用短关键词、限制层级与分支，密集细节移入表格。
- 蓝湖返回的格式指令（如 `__AI_INSTRUCTION__`、`功能清单表`、`字段规则表`、`遗漏/矛盾检查`、开发 / 测试视角、四阶段分析等）只当原始证据，不是 adapter 输出 schema，绝不透传成包内标题或元数据。

## 4. 前端 PRD 结构偏好

前端遵循「同一类需求事实只保留一个主承载」的主承载矩阵：

- **页面布局草图并入展示规则**：页面布局、控件位置 / 类型、弹窗 / 抽屉 / tab / dropdown 等交互结构由 HTML demo 主承载展示，`prd.md` 最多列页面清单，不再长篇复述布局与控件类型，更不产出独立的 XML-like 布局草图。
- **用户操作流程放在字段 UI 之后**：HTML demo 的 1:1 复刻顺序是页面清单 → 页面模块 → 字段和控件 → 按钮 / 操作入口 → 弹窗等交互结构 → **用户操作路径** → 系统响应可视化 → 状态 / 界面文案，即用户操作流程排在字段与控件之后。
- 需要规则文本才能准确表达的信息（字段必填 / 格式 / 长度 / 默认值 / 可编辑性、数据范围 / 筛选 / 排序 / 枚举含义、权限差异、提交成功 / 失败等系统响应、状态触发条件、边界、待确认问题）优先放 `prd.md`。
- 需求范围只需精简清单加待确认项，不写「背景与目标」式宣讲段落。

## 5. HTML 输出偏好

`design/index.html` 是可交互结构镜像，1:1 复刻原始需求表达出来的页面结构、控件、状态和交互路径，但不是生产级前端实现，也不是第二份完整 PRD。

- **呈现字段与控件的章节使用真实 HTML 控件**（而非截图或「类型：输入框」式文字复述），系统响应、空态 / 错误态用可视化模拟。
- **布局为左侧导航 + 右侧激活章节**：左侧导航页面 / 模块 / 弹窗 / 状态 / 关键流程，右侧只展示当前激活章节，避免长页面滚动干扰核对。
- 为展示结构使用的示例数据必须显式标注 `示例数据，仅用于展示页面结构`。
- 不得为让 demo 顺畅而新增原始资料没有的业务规则，不得把未说明的交互写成确定结论，不得因「更合理」而改动原始流程或页面结构。

## 6. 多页面流程

当 URL-rooted 页面选择解析出多个目标页时，采用「一个聚合包 + 完整逐页子包」的 fan-out：主 agent 对每个选中页各派发一次同一角色分析师（`pagePackageMode: true`），子包写入 `pages/<order>-<page-slug>/`。

- 每页由 subagent 独立分析、独立成完整子包，**page fan-out 不是按页数机械切分**。
- 主 agent 只写聚合 `index.md`（页面包表格、阅读顺序、跨页关系摘要、可选 Mermaid 关系图、聚合范围摘要、选中目标页与确认状态总览），它指引宿主 / AI 去读每个页面子包自己的 `index.md`。
- 主 agent **基于完整的逐页 PRD 包汇总**：不得从压缩后的 subagent 输出、`.yaml` 摘要或摘要 Markdown 重新生成最终产物；compact metadata 只是聚合线索，不是证据来源。
- 所有页面网关清零后，可选地询问用户是否要跨包综合（关系抽取、共同业务目标、页面流 / 依赖），综合只追加聚合章节，绝不替换逐页子包，也不在派发前先综合。

## 7. 选择性图片解析

图片文件、base64、远程图片引用、截图、`designInfo.images` 都只是**候选证据**，按证据价值选择性分析，避免全量视觉解析消耗 token。

- 默认**不保存**蓝湖图片 / 截图 / base64 / 远程图片，不写 `.lanhu/.../assets/` 或 `images/`；本地资源需用户明确要求或确认的离线审计 / demo 支持需要。
- 不得为取图片而扩用广义 Lanhu 设计工具。
- 与图片相关的事实只来自**选中页的 scoped evidence** 加上用户明确输入；present 或评估图片资源时须报告 `selectiveImageAnalysis.policyApplied: true`、`persistedImages: false`（除非显式确认）。

## 8. 确认门 / 矛盾检测 / 净化

- **确认门**：分析师返回 `status: need_confirmation` 时，主会话只展示紧凑的 `confirmationGate.blockingQuestions`（角色、阶段、包路径、问题数），**不得**自行重判是否阻塞，不得直接绕过 `confirmationGate`，不得贴全量证据 / HTML / 原始 MCP 输出。宿主的 `/grill-with-docs` 在网关清零前不启动。
- **回灌**：用户作答后以 `resolutionMode: resolve_confirmation` 路由回**同一角色分析师**修复同一个包并返回新的紧凑 metadata；「继续吧」只有在用户明确接受分析师默认假设时才算作答。
- **矛盾检测**：分析师自己发现的源事实冲突（同一字段 / 控件 / 状态 / 权限 / 流程被赋予互斥的产品级事实）经 `confirmationGate.blockingQuestions` 以 `impact: source-fact-conflict` 暴露（非阻塞的进 `openQuestions`），绝不自行合并、不写成「矛盾分析」标题、不照抄蓝湖 `遗漏/矛盾检查` 段落。
- **净化**：最终包只保留清洗后的**有效源事实**（在用户修正 / 删除 / 忽略 / 确认 / 范围排除 / 冲突解决 / 工具输出安全过滤之后仍权威的事实）。被拒绝 / 被取代 / 被忽略 / 被删除 / 越界的事实不作为「丢失源事实」写回，也不得留任何过程 / 历史留痕。forbidden trace 词包括 `已确认口径`、`已剔除`、`不采用`、`另一套口径不采用`、`用户要求删除`、`按明确口径`、`经用户确认`、`根据用户要求`、`已忽略`、`原口径`、`历史口径`。
- **反臆想**：未说明的信息不得写成确定结论，常见产品逻辑不能自动补齐，不为章节完整而补内容 —— 没有权限差异就不写权限章节，没有异常态就不补异常态，没有角色说明就不推断使用者；所有不确定内容集中进「待确认问题」或确认门，不散落成正文留痕。缺实现级字段名 / 接口属性名 / 数据库列名 / 枚举编码不阻塞录入，只有缺产品级字段 / 控件语义、必填 / 默认 / 只读、校验、权限、状态、交互或源范围才可阻塞。
- 遵守 scoped evidence 硬边界：`scope_policy: pageid_children_only`、`include_child_pages: false`、`confirmed_child_page_ids: []`、`returnedOutOfScopePages == 0`，且分析师不得调用任意 Lanhu MCP 工具（`arbitraryLanhuToolsUsed: false`）。

## 9. 接入方式（host 约定）

Lanhu 录入是**纯用户显式调用**的 skill，无需 hook，也不自动触发宿主的完成 / 审查 / 验证等 workflow skill。grill-host 的约定接入顺序：

1. 用户给出蓝湖链接时，先跑 `/lanhu-requirements <链接> frontend|backend`，选定角色并做 URL-rooted 页面选择。
2. 分析师写出 `.lanhu/MM-DD-需求名称/` 包；主会话过轻量 post-write metadata gate（角色已定、`status: ok`、`confirmationGate.status: clear`、路径都在包内、模板合规且无 forbidden trace）。
3. 请用户 review 并确认 `.lanhu/.../index.md` 入口与分析师的 `scopeConfirmationSummary`（新增 / 差量调整 / 现有上下文 / 待确认）。
4. **仅在用户确认后**，把该包作为 requirements 描述喂给宿主的发现 / spec 阶段（grill 的 `/grill-with-docs`）：`index.md` 是入口，包内产物是详细需求来源。

post-write gate 机械校验的关键约束（任一失败即不进宿主）：

- 前端 `writtenFiles[]` 必含 `frontend-prd/prd.md`，可含 `frontend-prd/design/index.html`，`assets/` 仅在确认时；不得含包根 `prd.md` / `prds/*.md` / 包根 `index.html` / `prototype/index.html` / XML-like 草图。
- 后端 `writtenFiles[]` 必含 `backend-prd/prd.md` 或 `backend-prd/prds/*.md`，不含任何 `.html`，不含 `frontend-prd/design/` 文件。
- `packageDir` / `indexPath` / 每个 `writtenFiles[]` 都在 `.lanhu/MM-DD-需求名称/` 内（多页模式在 `pages/<page-slug>/` 内），`indexPath` 以 `index.md` 结尾。
- `templateCompliance` 合规、无泛化标题、无 forbidden trace 词；`role` 与选定角色一致；metadata / 门禁 / caveats 内不含原始 MCP / 全量证据 / 透传的 persona / 格式指令文本。

该 evidence 包始终只作宿主输入，不回写 wiki / spec / 验收标准 / 测试。
