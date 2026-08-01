# grill-adapter Host 集成

grill-adapter 用**约定 + hook** 接入宿主，**零 skill patch**。同一仓库同时提供 Claude Code 与 Codex 插件入口；本文讲 host 适配器模型、grill / plain 约定块、双运行时安装模型，以及插件根路径边界。

## Host 适配器模型

grill-adapter 本身是一个双运行时插件：`.claude-plugin/plugin.json` 服务 Claude Code，`.codex-plugin/plugin.json` 服务 Codex；skills、hooks 与 Source-binding `obsidian-wiki` MCP 共享同一份实现。插件唯一做不到的事是改目标项目的持久指令文件——所以一个「host 适配器」现在只剩一样东西：

**一段运行时约定块**：Claude Code 使用 `host-adapters/<host>/CLAUDE.md` 并写入目标项目 `CLAUDE.md`；Codex 使用 `host-adapters/<host>/AGENTS.md` 并写入目标项目 `AGENTS.md`。两者均由 marker 包裹（`<!-- grill-adapter:host:<host>:start -->` … `end`），install 时机械写入，幂等、可换宿主、可整块移除。

```bash
./manage.sh install <project> --host grill --runtime claude
./manage.sh install <project> --host grill --runtime codex
./manage.sh install <project> --host grill --runtime both
```

**不变式**：约定块只引用 grill-adapter 自己的 skill（`/grill-adapter:wiki-research` 等），**不含任何安装路径**；绝不改宿主 skill 一行。宿主升级不影响 grill-adapter。

### 项目激活边界

安装 plugin 只表示 grill-adapter 的能力在运行时**可用**，不表示每个项目都已启用 adapter。
所有会挂入 grill 日常流程的入口 skill 在任何 adapter 动作或文件写入前，必须先运行只读
`scripts/project_activation.py`。只有以下任一条件成立才继续：

- 用户在当前请求中显式点名/调用 grill-adapter skill；
- 项目根 `AGENTS.md` 或 `CLAUDE.md` 含 install 写入的
  `<!-- grill-adapter:host:<host>:start -->` marker；
- 项目已有 `.grill-adapter/settings.json`，明确声明 adapter 配置。

三者都不成立就是 **standalone grill**：skill 必须立即回到宿主流程，不调用其他 adapter
skill、不输出 adapter 噪声、不创建 `.grill-adapter/`。全局 hook 同样先执行项目
preflight；未接线且未配置的项目即使残留旧 context 也必须静默且零写入。这样 Codex
的用户级 plugin 安装可以与只使用 grill 的项目并存。

### 为什么约定块里一个路径都不能有

约定块落在**目标项目**的 `CLAUDE.md` 里，那不是插件内容，两条路都堵死：

- `${CLAUDE_PLUGIN_ROOT}` 只在插件内容里被替换（见下），写在项目 `CLAUDE.md` 里会原样留着。
- 安装时烤死绝对路径也不行：插件缓存路径带版本号（`~/.claude/plugins/cache/grill-adapter/grill-adapter/<version>/`），升级即换目录，旧目录约 7 天后被回收——约定块会**静默腐烂**。

所以约定块只**点名 skill**，由 skill 自己持有脚本路径（skill 是插件内容，替换正常）。原先约定块直接调的两样东西已各自归位：grill→wiki 桥 `grill_context_to_candidates.py` 搬进 `skills/update-wiki/SKILL.md`（它本就是那份产物的消费者），ticket-roster 契约形状由 `skills/wiki-research/SKILL.md` 承载。

## grill-host 约定块（`host-adapters/grill/{CLAUDE,AGENTS}.md`）

映射 grill 阶段 → grill-adapter 触点（全文见该文件，install 会写进目标 CLAUDE.md）：

grill host 约定块默认保持静默，只有当前任务明确调用对应的 grill skill/stage 才激活相应触点。普通用户需求、计划措辞或准备编辑代码都不能推断出 grill 阶段；用户仍可直接显式调用某个 `grill-adapter` skill。

| grill 阶段 | 约定动作 |
|---|---|
| `/grill-with-docs` | **Disclose**：`/grill-adapter:wiki-research`（phase brainstorm）披露相关 wiki |
| `/to-spec` | source-truth **Verify**：`/grill-adapter:source-truth-check`（spec-pre） |
| `/to-tickets` | **Disclose+Carry**：`/grill-adapter:wiki-research`（phase plan）以硬 limit + scope-bound cursor 浏览 frontmatter-only catalog / 搜索选定分支，排除 expired、保留 review-due warning，再 stable-batch 全文复核入选的 bound Obsidian Notes/Skill Cards → `wiki_context_render.py --scaffold` 生成 schema-v6 并重验 freshness → 编辑 `destination`（一次）→ `--finalize` → 用户批准后一次 `wiki_readiness.py freeze --all` 生成所有 task 的 implement/review Markdown；`/grill-adapter:source-truth-check`（plan-pre/plan-review） |
| 全阶段 | **Journal**：`/grill-adapter:candidate-journal` 把 Wiki Note / Skill Card 候选作为事件追加到同一 feature journal，不写 Obsidian |
| `/implement`（每 task） | **Readiness+Bind**：首次代码修改前 `/grill-adapter:wiki-readiness` 复用 formal context，或为 direct issue/manual 建单任务 roster 并 late Carry；`ready` 做 fingerprint preflight + 消费 `<taskId>.wiki-implement.md`；`no-relevant`/`disabled` 直接继续，`broken` 由用户选择停止或无 Wiki 继续 |
| `/code-review`（启动 sub-agents 前） | **Reviewer Bind**：复用当前 task 的 readiness receipt；`ready` 校验同一批准快照的 `<taskId>.wiki-review.md`，重算直接/闭包 Note freshness，再派生 `<taskId>.wiki-review-handoff.md` 给 Standards/Spec 两轴；其他状态、无法确定 task 或任何验证失败只产生非阻塞 caveat，不 late research、不阻止 review |
| `/code-review` 后 | **Capture**：`/grill-adapter:update-wiki` 校验/折叠 journal，以最终证据 reconcile、显式归并 related claims、展示并应用 policy-compliant diff；correction 以 affected `sourceId` + stable `wikiId` 保持 unresolved maintenance signal，只有 exact bound identity、最终证据、显式 update target、授权与 matching apply 都成立才 kept；grill ADR 只生成 project-only metadata projection candidate，Capture 只保留可执行约束并按 authority identity 更新；skill pack 先由 `scaffold-practice-skill stage-card` 产生内容寻址候选，再与普通 Note 一样经 reviewed proposal/apply。默认停在 applied receipt；只有用户显式请求 publish 才确认精确发布 scope、按 repository 建可恢复 draft PR 并恢复 base worktree。开放 PR 仍 pending，merge + base 同步后才可发现 |

Wiki maintenance/navigation 通过 `/grill-adapter:wiki-maintenance audit|consolidation <feature-slug>` 进入，两种模式都只派生一个 maintenance agent 并立即等待同一路径。audit 以规范 UTC 秒级 `asOf` 和硬 `identityLimit` 调用 metadata-only summary，再私下全文复核最多 24 个 Note。consolidation 通过只读 `obsidian_wiki_consolidation_candidates` 确定性 replay canonical feature journals，只在 agent 内比较有界 unresolved candidate prose；等价 durable claim 形成单一 replacement proposal group，矛盾 claim 要求用户决定，不同 trigger/lifecycle/failure mode/validation path/task routing/Card/ADR identity 的 contract 保持独立。主 session 只得到经 journal/candidate digest 重验的 schema-v1 metadata report path 与 compact summary；report 不含 Note/candidate 正文、evidence、journal prose 或 agent reasoning，非权威且不能替代 task identity、Wiki readiness、Bind、Capture、proposal 或授权。dispatch/容量/transport/lifecycle、journal/binding/identity drift 或 report validation 错误全部走 `broken`，不得 inline fallback 或伪装成空维护结果。
| `/diagnosing-bugs` | 根因收窄后可 `/grill-adapter:wiki-research`（phase debug，≤2 节）；修复验证后 `/grill-adapter:break-loop` → `/grill-adapter:update-wiki` |

grill 自己的 skill（`/grill-with-docs`、`/to-spec` 等）按宿主原样引用，不加我们的命名空间。

## plain-host 约定块（`host-adapters/plain/{CLAUDE,AGENTS}.md`）

裸 Claude Code/Codex 没有固定规划框架，所以由用户在对应时刻**自己**调同样的触点。Claude Code 用 `/grill-adapter:<skill>`，Codex 用 `$grill-adapter:<skill>`；触点和引擎完全相同，只是触发方式从「grill 阶段约定」变「手动调用」。

### Agent 角色在两种运行时的差异

Claude Code 会直接注册 `agents/wiki-researcher.md` 与 `agents/wiki-maintenance.md`。Codex 插件当前不注册该目录，因此 `wiki-research` / `wiki-maintenance` skill 会读取各自完整的自包含 agent prompt，并派生一个通用 sub-agent 执行。Codex dispatch 返回的是句柄；必须把等待同一路径作为 dispatch 后唯一的下一步，在任何用户消息、提问、MCP 调用或后续流程前重复有界等待直到终态。dispatch/容量/生命周期失败分别进入 researcher 或 maintenance 的 `broken` 路径，不得伪装成 `no-relevant` 或空维护结果。职责边界、输入与输出契约不变，只改变 dispatch 机制。

## hook 配置（`hooks/hooks.json`）

hook 随插件自动注册——**不再往任何项目的 `.claude/settings.json` 里并条目**。插件启用即生效，禁用即停。grill / plain 共用同一套（hook 本身 host 无关）：

| 事件 | hook | 作用 |
|---|---|---|
| `SessionStart` | `wiki-reread.sh` | 重验 schema-v2 feature state 的 artifact/report digest 与 lifecycle counts，按 recovery → maintenance → 未完成 Capture → continuation 的确定优先级和最近活动排序，最多显示三条 feature/status/权威重入命令；无有效 action 时才提醒已冻结但尚无 readiness 结果的 schema-v6 task；绝不 materialize |
| `PostToolUse`（Write/Edit/MultiEdit/Bash） | `source-truth-lint.sh` | 对真实 changed files 跑 source-truth lint，`block`/`ask` 注入提醒 |
| `Stop` | `wiki-capture-suggest.sh` + `source-truth-lint.sh` | Capture 兜底（pending/deferred journal 提醒，invalid journal 报错，全终态静默）+ 收尾 lint |

hook 命令写成 `${CLAUDE_PLUGIN_ROOT}/hooks/<hook>.sh`（Claude Code 在此替换）。hook 脚本自身用 `BASH_SOURCE` 定位自身 payload，无需任何改写。hook **无原生「当前 ticket」字段**；schema-v2 `wiki-session-state.json` 保存最后一次显式选择的 task、本地 artifact/report digest 和 metadata-only lifecycle counts，SessionStart 只把通过当前文件重验的最多三条 action 当作导航。schema-v1 旧 state 仍可产生单 feature continuation，但不产生 maintenance/Capture action。任何提示都不能认定当前 prompt 正在处理某 ticket，也不能绕过正常 `wiki-readiness`；主 session 不接收 Note body、candidate transcript 或 maintenance reasoning。

## 安装模型

### 插件（承载一切）

```bash
claude plugin install grill-adapter@grill-adapter --scope project   # 或 --scope user
```

Codex：

```bash
codex plugin marketplace add YWJ-hy/grill-adapter
codex plugin add grill-adapter@grill-adapter
```

Codex 当前没有 `--scope project|user`；插件安装是用户级的。项目 activation preflight
先阻止未接线项目进入 adapter workflow，Wiki Source 读取再由目标项目 binding
fail-closed。两层边界分别防止意外本地状态和跨项目 Source 暴露。

一次装齐 13 skills + 2 agents + 3 hooks + 1 MCP server（Source-binding `obsidian-wiki`）。开发期不必安装：

```bash
claude --plugin-dir "$PWD" plugin details grill-adapter   # 直接从磁盘加载 + 打印组件清单
```

**作用域是插件级的，不能拆**。插件自带的 Obsidian MCP 严格跟随插件作用域；没有「skills 全局 + MCP 单项目」这种组合，也没有安装期提问的钩子。

（逃生舱：插件 MCP 与手动注册的 MCP **按 endpoint 判重**，优先级 local > project > user > plugin。手动 `claude mcp add-json` 同一 command 会**压过**插件那份。灵活但双轨并存，排查成本高，不推荐。）

### 项目接线（插件做不到的那一件事）

```bash
./manage.sh install <project> [--host grill|plain]   # 引擎 lib/install.py
```

正式发布后也可以从 npm 全局安装版本化 CLI，不需要进入 grill-adapter 源码仓库：

```bash
npm install --global grill-adapter
grill-adapter install <project> --host grill --runtime both
grill-adapter verify <project> --host grill --runtime both
```

要让宿主也消费这份 npm 包，先用 `grill-adapter package-root` 把该目录加入 Claude/Codex marketplace，再按宿主命令安装 plugin；仅执行 `npm update` 不会替换宿主自己的 plugin cache。

`npm update --global grill-adapter` 只更新本机 CLI 和 plugin payload；它不会自动修改项目文件。项目路径省略时，`install`、`uninstall`、`verify`、`status`、`doctor` 默认使用当前目录。

只做一件事：按 `--runtime` 把选定 host 约定块写进目标 `CLAUDE.md`、`AGENTS.md` 或两者（marker 包裹、幂等、换宿主先剥旧块、保留既有内容）。这个 marker 同时是项目 workflow opt-in。`uninstall` 逆向剥块，使项目恢复 standalone grill；它保留既有 `.grill-adapter/` 工作态，不隐式删除用户数据。`verify` 检查块在不在；`status` 对相应运行时报告提示性插件状态。

wiki 数据/绑定仍是项目级的：新项目在 `.grill-adapter/settings.json` 声明 `wiki.provider: obsidian` 与 Source bindings，机器本地 registry 解析 Vault/repository；`doctor` 校验 active provider 并报告 `obsidian-native` / `shadow-validation` / `cutover-complete`。legacy 内容只通过 `migrate-wiki` 的本地根或用户显式 Git URL 进入迁移计划，不提供 runtime fallback。

`manifest.json` 现在只剩 `projectLevel.hostConventions`——组件清单由 `.claude-plugin/plugin.json` + 插件布局声明，Claude Code 自己发现，不再由 manifest 记账。

### 环境变量

- `CLAUDE_CONFIG_DIR`：覆盖 `~/.claude`（用于沙盒测试；`release-check` 用它做非破坏验证）。
- `GRILL_ADAPTER_HOME`：**已移除**（不再有用户级 payload）。

## `${CLAUDE_PLUGIN_ROOT}` 替换

共享 skill/agent/hook 内容里对执行层脚本 / contracts 的引用仍统一写成 `${CLAUDE_PLUGIN_ROOT}/...`，由两端兼容加载。MCP 声明按 manifest 分开：Claude 的 `.mcp.json` 使用 `${CLAUDE_PLUGIN_ROOT}`；Codex 的 `.codex-plugin/plugin.json` 按原生本地 MCP 形式使用 `cwd: "."` + `./mcp/...`，其中 cwd 解析到插件根。两者启动同一份提交型 Obsidian bundle，不复制执行层。

MCP 项目根解析同样是双运行时的：Claude Code 使用 `CLAUDE_PROJECT_DIR`，Codex 使用其受控 MCP request metadata 中的 Git workspace 根（未来客户端若提供标准 roots capability 也兼容）；直接 CLI 执行才使用进程工作目录。所有路径都只解析宿主声明的项目根中的 `.grill-adapter/settings.json`，不接受工具参数传任意根目录；没有绑定或多个 workspace root 同时声明绑定时 fail-closed。

两条边界必须记住：

1. **只匹配裸 token** `${CLAUDE_PLUGIN_ROOT}`。`$CLAUDE_PLUGIN_ROOT`（无花括号）和 `${CLAUDE_PLUGIN_ROOT:-fallback}`（bash 默认值语法）**不会**被替换。
2. **只在插件内容里替换**。`host-adapters/*/{CLAUDE,AGENTS}.md` 会被写进目标项目，属于插件外，写了也不会替换——那里一个路径都不许有（见上）。

hook 脚本与 payload 本身逐字发货（自定位，无占位符）。任何 `__GRILL_ADAPTER_ROOT__` / `__SUPERPOWER_ADAPTER_*__` 残留都是 bug，`release-check` 步骤 3 会机械拦截。
