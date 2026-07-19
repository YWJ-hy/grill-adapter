# grill-adapter Host 集成

grill-adapter 用**约定 + hook** 接入宿主，**零 skill patch**。本文讲 host 适配器模型、grill / plain 约定块、插件安装模型，以及 `${CLAUDE_PLUGIN_ROOT}` 替换的边界。

## Host 适配器模型

grill-adapter 本身是一个 Claude Code 插件：skills、agents、hooks、两个 Wiki MCP（legacy `shared-wiki` 与 Source-binding `obsidian-wiki`）全部随插件发货、一起激活。插件唯一做不到的事是改目标项目的 `CLAUDE.md`——所以一个「host 适配器」现在只剩一样东西：

**一段 `CLAUDE.md` 约定块**（`host-adapters/<host>/CLAUDE.md`）：告诉在该宿主里运行的 Claude Code，在宿主每个阶段该调哪个 grill-adapter 触点。它 marker 包裹（`<!-- grill-adapter:host:<host>:start -->` … `end`），install 时机械写进目标项目 `CLAUDE.md`，幂等、可换宿主、可整块移除。

**不变式**：约定块只引用 grill-adapter 自己的 skill（`/grill-adapter:wiki-research` 等），**不含任何安装路径**；绝不改宿主 skill 一行。宿主升级不影响 grill-adapter。

### 为什么约定块里一个路径都不能有

约定块落在**目标项目**的 `CLAUDE.md` 里，那不是插件内容，两条路都堵死：

- `${CLAUDE_PLUGIN_ROOT}` 只在插件内容里被替换（见下），写在项目 `CLAUDE.md` 里会原样留着。
- 安装时烤死绝对路径也不行：插件缓存路径带版本号（`~/.claude/plugins/cache/grill-adapter/grill-adapter/0.2.0/`），升级即换目录，旧目录约 7 天后被回收——约定块会**静默腐烂**。

所以约定块只**点名 skill**，由 skill 自己持有脚本路径（skill 是插件内容，替换正常）。原先约定块直接调的两样东西已各自归位：grill→wiki 桥 `grill_context_to_candidates.py` 搬进 `skills/update-wiki/SKILL.md`（它本就是那份产物的消费者），ticket-roster 契约形状由 `skills/wiki-research/SKILL.md` 承载。

## grill-host 约定块（`host-adapters/grill/CLAUDE.md`）

映射 grill 阶段 → grill-adapter 触点（全文见该文件，install 会写进目标 CLAUDE.md）：

| grill 阶段 | 约定动作 |
|---|---|
| （前置）给了 Lanhu 链接 | 先 `/grill-adapter:lanhu-requirements <link> frontend\|backend`，确认 `.lanhu/.../index.md`，再喂给 grill-with-docs（**只作输入**） |
| `/grill-with-docs` | **Disclose**：`/grill-adapter:wiki-research`（phase brainstorm）披露相关 wiki |
| `/to-spec` | source-truth **Verify**：`/grill-adapter:source-truth-check`（spec-pre） |
| `/to-tickets` | **Disclose+Carry**：`/grill-adapter:wiki-research`（phase plan）→ `wiki_context_render.py --scaffold` → 编辑 `destination`（一次）→ `--finalize`；`/grill-adapter:source-truth-check`（plan-pre/plan-review） |
| `/implement`（每 ticket） | **Bind**：首 ticket 前 `--fingerprint-preflight`；每 ticket `/grill-adapter:wiki-materialize <ticket>`；`source-truth-lint` hook；涌现追加 `.wiki-candidates.jsonl` |
| `/code-review` 后 | **Capture**：`/grill-adapter:update-wiki`（内含 grill 增量桥接的可选前置步） |
| `/diagnosing-bugs` | 根因收窄后可 `/grill-adapter:wiki-research`（phase debug，≤2 节）；修复验证后 `/grill-adapter:break-loop` → `/grill-adapter:update-wiki` |

grill 自己的 skill（`/grill-with-docs`、`/to-spec` 等）按宿主原样引用，不加我们的命名空间。

## plain-host 约定块（`host-adapters/plain/CLAUDE.md`）

裸 Claude Code 没有固定规划框架，所以由用户在对应时刻**自己**调同样的触点：提方案前 `/grill-adapter:wiki-research`（brainstorm）；起草 spec/plan 时 `/grill-adapter:source-truth-check`；写实现计划时 `/grill-adapter:wiki-research`（plan）+ 生成 sidecar；实现每个任务前 `/grill-adapter:wiki-materialize <task-id>`；工作被评审接受后 `/grill-adapter:update-wiki`；调试后 `/grill-adapter:break-loop`。触点和引擎完全相同，只是触发方式从「grill 阶段约定」变「手动调用」。

## hook 配置（`hooks/hooks.json`）

hook 随插件自动注册——**不再往任何项目的 `.claude/settings.json` 里并条目**。插件启用即生效，禁用即停。grill / plain 共用同一套（hook 本身 host 无关）：

| 事件 | hook | 作用 |
|---|---|---|
| `SessionStart` / `UserPromptSubmit` | `wiki-reread.sh` | Bind 粗兜底：检测 active `.wiki-context.json` → materialize → `hookSpecificOutput.additionalContext` 注入 |
| `PostToolUse`（Write/Edit/MultiEdit/Bash） | `source-truth-lint.sh` | 对真实 changed files 跑 source-truth lint，`block`/`ask` 注入提醒 |
| `Stop` | `wiki-capture-suggest.sh` + `source-truth-lint.sh` | Capture 兜底（有 pending `.wiki-candidates.jsonl` 才提醒）+ 收尾 lint |

hook 命令写成 `${CLAUDE_PLUGIN_ROOT}/hooks/<hook>.sh`（Claude Code 在此替换）。hook 脚本自身用 `BASH_SOURCE` 定位 `../scripts`，无需任何改写。hook **无原生「当前 ticket」字段**——per-ticket 精度靠显式 `/grill-adapter:wiki-materialize <ticket>`（首选），或 `GRILL_CURRENT_TICKET` env / `.adapter/current-ticket` marker（`wiki-reread.sh` 会读）。

## 安装模型

### 插件（承载一切）

```bash
claude plugin install grill-adapter@grill-adapter --scope project   # 或 --scope user
```

一次装齐 12 skills + 3 agents + 4 hooks + 2 MCP servers（legacy `shared-wiki` 与 Source-binding `obsidian-wiki`）。开发期不必安装：

```bash
claude --plugin-dir "$PWD" plugin details grill-adapter   # 直接从磁盘加载 + 打印组件清单
```

**作用域是插件级的，不能拆**。插件自带的 MCP 严格跟随插件作用域——想要项目级 shared-wiki MCP，就把插件按 `--scope project` 装到那个项目；`--scope user` 则全局可用。没有「skills 全局 + MCP 单项目」这种组合，也没有安装期提问的钩子。

（逃生舱：插件 MCP 与手动注册的 MCP **按 endpoint 判重**，优先级 local > project > user > plugin。手动 `claude mcp add-json` 同一 command 会**压过**插件那份。灵活但双轨并存，排查成本高，不推荐。）

### 项目接线（插件做不到的那一件事）

```bash
./manage.sh install <project> [--host grill|plain]   # 引擎 lib/install.py
```

只做一件事：把选定 host 约定块写进目标 `CLAUDE.md`（marker 包裹、幂等、换宿主先剥旧块、保留既有内容）。`uninstall` 逆向剥块。`verify` 检查块在不在；`status` 另外顺带读 `~/.claude/plugins/installed_plugins.json` 报告插件启用情况（**仅供参考**：`--plugin-dir` 开发模式看不见）。

wiki 数据/绑定仍是项目级的：`bootstrap-wiki` 播种 `.adapter/wiki/`；`.shared-adapter/settings.json` 的 `wiki.sharedMcp` 声明 shared 绑定（MCP 读 `CLAUDE_PROJECT_DIR` 自配置，未声明 fail-closed）。

`manifest.json` 现在只剩 `projectLevel.hostConventions`——组件清单由 `.claude-plugin/plugin.json` + 插件布局声明，Claude Code 自己发现，不再由 manifest 记账。

### 环境变量

- `CLAUDE_CONFIG_DIR`：覆盖 `~/.claude`（用于沙盒测试；`release-check` 用它做非破坏验证）。
- `GRILL_ADAPTER_HOME`：**已移除**（不再有用户级 payload）。

## `${CLAUDE_PLUGIN_ROOT}` 替换

插件内容里所有对执行层脚本 / contracts 的引用都写成 `${CLAUDE_PLUGIN_ROOT}/scripts/...`、`${CLAUDE_PLUGIN_ROOT}/contracts/...`。Claude Code **加载时做文本替换**（skill/agent 正文、`hooks/hooks.json`、`.mcp.json` 都替换），把它换成插件的版本化安装目录，并把**反斜杠归一为正斜杠**——所以 Windows 上得到 `C:/Users/.../scripts/foo.py`，PowerShell 和 bash 都能直接吃，无需 shell 展开。

两条边界必须记住：

1. **只匹配裸 token** `${CLAUDE_PLUGIN_ROOT}`。`$CLAUDE_PLUGIN_ROOT`（无花括号）和 `${CLAUDE_PLUGIN_ROOT:-fallback}`（bash 默认值语法）**不会**被替换。
2. **只在插件内容里替换**。`host-adapters/*/CLAUDE.md` 会被写进目标项目，属于插件外，写了也不会替换——那里一个路径都不许有（见上）。

hook 脚本与 payload 本身逐字发货（自定位，无占位符）。任何 `__GRILL_ADAPTER_ROOT__` / `__SUPERPOWER_ADAPTER_*__` 残留都是 bug，`release-check` 步骤 3 会机械拦截。
