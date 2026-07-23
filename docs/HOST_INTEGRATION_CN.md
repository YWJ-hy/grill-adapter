# grill-adapter Host 集成

grill-adapter 用**约定 + hook** 接入宿主，**零 skill patch**。同一仓库同时提供 Claude Code 与 Codex 插件入口；本文讲 host 适配器模型、grill / plain 约定块、双运行时安装模型，以及插件根路径边界。

## Host 适配器模型

grill-adapter 本身是一个双运行时插件：`.claude-plugin/plugin.json` 服务 Claude Code，`.codex-plugin/plugin.json` 服务 Codex；skills、hooks、两个 Wiki MCP（legacy `shared-wiki` 与 Source-binding `obsidian-wiki`）共享同一份实现。插件唯一做不到的事是改目标项目的持久指令文件——所以一个「host 适配器」现在只剩一样东西：

**一段运行时约定块**：Claude Code 使用 `host-adapters/<host>/CLAUDE.md` 并写入目标项目 `CLAUDE.md`；Codex 使用 `host-adapters/<host>/AGENTS.md` 并写入目标项目 `AGENTS.md`。两者均由 marker 包裹（`<!-- grill-adapter:host:<host>:start -->` … `end`），install 时机械写入，幂等、可换宿主、可整块移除。

```bash
./manage.sh install <project> --host grill --runtime claude
./manage.sh install <project> --host grill --runtime codex
./manage.sh install <project> --host grill --runtime both
```

**不变式**：约定块只引用 grill-adapter 自己的 skill（`/grill-adapter:wiki-research` 等），**不含任何安装路径**；绝不改宿主 skill 一行。宿主升级不影响 grill-adapter。

### 为什么约定块里一个路径都不能有

约定块落在**目标项目**的 `CLAUDE.md` 里，那不是插件内容，两条路都堵死：

- `${CLAUDE_PLUGIN_ROOT}` 只在插件内容里被替换（见下），写在项目 `CLAUDE.md` 里会原样留着。
- 安装时烤死绝对路径也不行：插件缓存路径带版本号（`~/.claude/plugins/cache/grill-adapter/grill-adapter/0.2.0/`），升级即换目录，旧目录约 7 天后被回收——约定块会**静默腐烂**。

所以约定块只**点名 skill**，由 skill 自己持有脚本路径（skill 是插件内容，替换正常）。原先约定块直接调的两样东西已各自归位：grill→wiki 桥 `grill_context_to_candidates.py` 搬进 `skills/update-wiki/SKILL.md`（它本就是那份产物的消费者），ticket-roster 契约形状由 `skills/wiki-research/SKILL.md` 承载。

## grill-host 约定块（`host-adapters/grill/{CLAUDE,AGENTS}.md`）

映射 grill 阶段 → grill-adapter 触点（全文见该文件，install 会写进目标 CLAUDE.md）：

| grill 阶段 | 约定动作 |
|---|---|
| `/grill-with-docs` | **Disclose**：`/grill-adapter:wiki-research`（phase brainstorm）披露相关 wiki |
| `/to-spec` | source-truth **Verify**：`/grill-adapter:source-truth-check`（spec-pre） |
| `/to-tickets` | **Disclose+Carry**：`/grill-adapter:wiki-research`（phase plan）选 bound Obsidian Notes/Skill Cards → `wiki_context_render.py --scaffold` 生成 schema-v6 → 编辑 `destination`（一次）→ `--finalize`；`/grill-adapter:source-truth-check`（plan-pre/plan-review） |
| 全阶段 | **Journal**：`/grill-adapter:candidate-journal` 把 Wiki Note / Skill Card 候选作为事件追加到同一 feature journal，不写 Obsidian |
| `/implement`（每 task） | **Readiness+Bind**：首次代码修改前 `/grill-adapter:wiki-readiness` 复用 formal context，或为 direct issue/manual 建单任务 roster 并 late Carry；`ready` 才做 fingerprint preflight + implementer materialize；`no-relevant`/`disabled` 直接继续，`broken` 由用户选择停止或无 Wiki 继续 |
| `/code-review`（启动 sub-agents 前） | **Reviewer Bind**：复用当前 task 的 readiness receipt；`ready` 以 reviewer 角色原子生成同一份只读 handoff 给 Standards/Spec 两轴，其他状态、无法确定 task 或任何验证失败只产生非阻塞 caveat，不 late research、不阻止 review |
| `/code-review` 后 | **Capture**：`/grill-adapter:update-wiki` 校验/折叠 journal，以最终证据 reconcile、显式归并 related claims、展示并应用 policy-compliant diff；grill ADR 只生成 project-only metadata projection candidate，Capture 只保留可执行约束并按 authority identity 更新；skill pack 先由 `scaffold-practice-skill stage-card` 产生内容寻址候选，再与普通 Note 一样经 reviewed proposal/apply。确认精确发布 scope 后，把 applied receipts 按 repository 发布为可恢复的 draft PR，并恢复 base worktree（内含 grill 增量桥接的可选前置步）。开放 PR 仍 pending，merge + base 同步后才可发现 |
| `/diagnosing-bugs` | 根因收窄后可 `/grill-adapter:wiki-research`（phase debug，≤2 节）；修复验证后 `/grill-adapter:break-loop` → `/grill-adapter:update-wiki` |

grill 自己的 skill（`/grill-with-docs`、`/to-spec` 等）按宿主原样引用，不加我们的命名空间。

## plain-host 约定块（`host-adapters/plain/{CLAUDE,AGENTS}.md`）

裸 Claude Code/Codex 没有固定规划框架，所以由用户在对应时刻**自己**调同样的触点。Claude Code 用 `/grill-adapter:<skill>`，Codex 用 `$grill-adapter:<skill>`；触点和引擎完全相同，只是触发方式从「grill 阶段约定」变「手动调用」。

### Agent 角色在两种运行时的差异

Claude Code 会直接注册 `agents/wiki-researcher.md`。Codex 插件当前不注册该目录，因此 `wiki-research` skill 会读取同一份自包含 agent prompt，并派生通用 sub-agent 执行。职责边界、输入与输出契约不变，只改变 dispatch 机制。

## hook 配置（`hooks/hooks.json`）

hook 随插件自动注册——**不再往任何项目的 `.claude/settings.json` 里并条目**。插件启用即生效，禁用即停。grill / plain 共用同一套（hook 本身 host 无关）：

| 事件 | hook | 作用 |
|---|---|---|
| `SessionStart` | `wiki-reread.sh` | 只做 active sidecar 健康/显式 Bind 提醒；绝不 materialize，schema-v5/v6 都必须经 `/grill-adapter:wiki-materialize <ticket>` 精确 reread |
| `PostToolUse`（Write/Edit/MultiEdit/Bash） | `source-truth-lint.sh` | 对真实 changed files 跑 source-truth lint，`block`/`ask` 注入提醒 |
| `Stop` | `wiki-capture-suggest.sh` + `source-truth-lint.sh` | Capture 兜底（pending/deferred journal 提醒，invalid journal 报错，全终态静默）+ 收尾 lint |

hook 命令写成 `${CLAUDE_PLUGIN_ROOT}/hooks/<hook>.sh`（Claude Code 在此替换）。hook 脚本自身用 `BASH_SOURCE` 定位 `../scripts`，无需任何改写。hook **无原生「当前 ticket」字段**，所以 `wiki-reread.sh` 只报告 active sidecar；per-ticket 精度完全靠显式 `/grill-adapter:wiki-materialize <ticket>`。

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

Codex 当前没有 `--scope project|user`；插件安装是用户级的，但 Wiki 读取仍由目标项目绑定 fail-closed，不会因全局安装而自动暴露其他项目的 Source。

一次装齐 13 skills + 1 agent + 3 hooks + 2 MCP servers（legacy `shared-wiki` 与 Source-binding `obsidian-wiki`）。开发期不必安装：

```bash
claude --plugin-dir "$PWD" plugin details grill-adapter   # 直接从磁盘加载 + 打印组件清单
```

**作用域是插件级的，不能拆**。插件自带的 MCP 严格跟随插件作用域——想要项目级 shared-wiki MCP，就把插件按 `--scope project` 装到那个项目；`--scope user` 则全局可用。没有「skills 全局 + MCP 单项目」这种组合，也没有安装期提问的钩子。

（逃生舱：插件 MCP 与手动注册的 MCP **按 endpoint 判重**，优先级 local > project > user > plugin。手动 `claude mcp add-json` 同一 command 会**压过**插件那份。灵活但双轨并存，排查成本高，不推荐。）

### 项目接线（插件做不到的那一件事）

```bash
./manage.sh install <project> [--host grill|plain]   # 引擎 lib/install.py
```

只做一件事：按 `--runtime` 把选定 host 约定块写进目标 `CLAUDE.md`、`AGENTS.md` 或两者（marker 包裹、幂等、换宿主先剥旧块、保留既有内容）。`uninstall` 逆向剥块，`verify` 检查块在不在；`status` 对相应运行时报告提示性插件状态。

wiki 数据/绑定仍是项目级的：新项目在 `.shared-adapter/settings.json` 声明 `wiki.provider: obsidian` 与 Source bindings，机器本地 registry 解析 Vault/repository；`doctor` 校验 active provider 并报告 `obsidian-native` / `shadow-validation` / `cutover-complete`。`bootstrap-wiki` 只服务尚未采用 Obsidian 的 legacy root，active Obsidian provider 机械拒绝它，不提供 runtime fallback。legacy `wiki.sharedMcp` 仍按项目绑定并 fail-closed。

`manifest.json` 现在只剩 `projectLevel.hostConventions`——组件清单由 `.claude-plugin/plugin.json` + 插件布局声明，Claude Code 自己发现，不再由 manifest 记账。

### 环境变量

- `CLAUDE_CONFIG_DIR`：覆盖 `~/.claude`（用于沙盒测试；`release-check` 用它做非破坏验证）。
- `GRILL_ADAPTER_HOME`：**已移除**（不再有用户级 payload）。

## `${CLAUDE_PLUGIN_ROOT}` 替换

共享 skill/agent/hook 内容里对执行层脚本 / contracts 的引用仍统一写成 `${CLAUDE_PLUGIN_ROOT}/...`，由两端兼容加载。MCP 声明按 manifest 分开：Claude 的 `.mcp.json` 使用 `${CLAUDE_PLUGIN_ROOT}`；Codex 的 `.codex-plugin/plugin.json` 按原生本地 MCP 形式使用 `cwd: "."` + `./mcp/...`，其中 cwd 解析到插件根。两者启动同一份提交型 bundle，不复制执行层。正因为 Codex 的 MCP cwd 是插件根，`shared-wiki` 通过 MCP request 的 workspace metadata（并兼容标准 roots capability）定位消费项目，而不是把 cwd 误当成项目根。

MCP 项目根解析同样是双运行时的：Claude Code 使用 `CLAUDE_PROJECT_DIR`，Codex 使用其受控 MCP request metadata 中的 Git workspace 根（未来客户端若提供标准 roots capability 也兼容）；直接 CLI 执行才使用进程工作目录。所有路径都只解析宿主声明的项目根中的 `.shared-adapter/settings.json`，不接受工具参数传任意根目录；没有绑定或多个 workspace root 同时声明绑定时 fail-closed。

两条边界必须记住：

1. **只匹配裸 token** `${CLAUDE_PLUGIN_ROOT}`。`$CLAUDE_PLUGIN_ROOT`（无花括号）和 `${CLAUDE_PLUGIN_ROOT:-fallback}`（bash 默认值语法）**不会**被替换。
2. **只在插件内容里替换**。`host-adapters/*/{CLAUDE,AGENTS}.md` 会被写进目标项目，属于插件外，写了也不会替换——那里一个路径都不许有（见上）。

hook 脚本与 payload 本身逐字发货（自定位，无占位符）。任何 `__GRILL_ADAPTER_ROOT__` / `__SUPERPOWER_ADAPTER_*__` 残留都是 bug，`release-check` 步骤 3 会机械拦截。
