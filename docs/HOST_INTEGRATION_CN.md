# grill-adapter Host 集成

grill-adapter 用**约定 + hook** 接入宿主，**零 skill patch**。本文讲 host 适配器模型、grill / plain 约定块、install 两级模型，以及 `__GRILL_ADAPTER_ROOT__` 替换。

## Host 适配器模型

一个「host 适配器」= 两样东西：

1. **一段 `CLAUDE.md` 约定块**（`host-adapters/<host>/CLAUDE.md`）：告诉在该宿主里运行的 Claude Code，在宿主每个阶段该调哪个 grill-adapter 触点。它 marker 包裹（`<!-- grill-adapter:host:<host>:start -->` … `end`），install 时机械写进目标项目 `CLAUDE.md`，幂等、可换宿主、可整块移除。
2. **一份通用 hook 片段**（`host-adapters/hooks.settings.json`，grill/plain 共用）：install 并进目标 `.claude/settings.json`。

**不变式**：约定块只引用 grill-adapter 自己的 slash-command（`/wiki-research` 等）和 `__GRILL_ADAPTER_ROOT__/scripts/...`；绝不改宿主 skill 一行。宿主升级不影响 grill-adapter。

## grill-host 约定块（`host-adapters/grill/CLAUDE.md`）

映射 grill 阶段 → grill-adapter 触点（全文见该文件，install 会写进目标 CLAUDE.md）：

| grill 阶段 | 约定动作 |
|---|---|
| （前置）给了 Lanhu 链接 | 先 `/lanhu-requirements <link> frontend\|backend`，确认 `.lanhu/.../index.md`，再喂给 grill-with-docs（**只作输入**） |
| `/grill-with-docs` | **Disclose**：`/wiki-research`（phase brainstorm）披露相关 wiki |
| `/to-spec` | source-truth **Verify**：`/source-truth-check`（spec-pre） |
| `/to-tickets` | **Disclose+Carry**：`/wiki-research`（phase plan）→ `wiki_context_render.py --scaffold` → 编辑 `destination`（一次）→ `--finalize`；`/source-truth-check`（plan-pre/plan-review）；gitignore-aware commit |
| `/implement`（每 ticket） | **Bind**：首 ticket 前 `--fingerprint-preflight`；每 ticket `/wiki-materialize <ticket>`；`source-truth-lint` hook；涌现追加 `.wiki-candidates.jsonl` |
| `/code-review` 后 | **Capture**：`grill_context_to_candidates.py` 转候选行 → `/update-wiki` |
| `/diagnosing-bugs` | 根因收窄后可 `/wiki-research`（phase debug，≤2 节）；修复验证后 `/break-loop` → `/update-wiki` |

## plain-host 约定块（`host-adapters/plain/CLAUDE.md`）

裸 Claude Code 没有固定规划框架，所以由用户在对应时刻**自己**调同样的触点：提方案前 `/wiki-research`（brainstorm）；起草 spec/plan 时 `/source-truth-check`；写实现计划时 `/wiki-research`（plan）+ 生成 sidecar；实现每个任务前 `/wiki-materialize <task-id>`；工作被评审接受后 `/update-wiki`；调试后 `/break-loop`。触点和引擎完全相同，只是触发方式从「grill 阶段约定」变「手动调用」。

## hook 配置（`host-adapters/hooks.settings.json`）

grill / plain 共用同一套 hook（hook 本身 host 无关）：

| 事件 | hook | 作用 |
|---|---|---|
| `SessionStart` / `UserPromptSubmit` | `wiki-reread.sh` | Bind 粗兜底：检测 active `.wiki-context.json` → materialize → `hookSpecificOutput.additionalContext` 注入 |
| `PostToolUse`（Write/Edit/MultiEdit/Bash） | `source-truth-lint.sh` | 对真实 changed files 跑 source-truth lint，`block`/`ask` 注入提醒 |
| `Stop` | `wiki-capture-suggest.sh` + `source-truth-lint.sh` | Capture 兜底（有 pending `.wiki-candidates.jsonl` 才提醒）+ 收尾 lint |

hook 命令路径写成 `__GRILL_ADAPTER_ROOT__/hooks/<hook>.sh`，install 时替换为 payload 绝对路径。hook 脚本自身经 `$(dirname "$0")/../scripts` 定位执行层脚本，无需二次改写。hook **无原生「当前 ticket」字段**——per-ticket 精度靠显式 `/wiki-materialize <ticket>`（首选），或 `GRILL_CURRENT_TICKET` env / `.superpowers/current-ticket` marker（`wiki-reread.sh` 会读）。

## Install 两级模型

`./manage.sh install [project] [--host grill|plain]`（引擎 `lib/install.py`）：

**用户级（一次装、跨项目）**
- payload dirs（`scripts/` `contracts/` `hooks/` `mcp/`）→ `$GRILL_ADAPTER_HOME`（默认 `~/.claude/grill-adapter`）——这就是 `__GRILL_ADAPTER_ROOT__`。
- skills → `~/.claude/skills/<name>/`（替换占位符；拒绝覆盖无 marker 的非托管文件）。
- agents → `~/.claude/agents/<name>.md`（替换占位符 + 可选 model override）。
- 构建 shared-wiki MCP（`npm install && npm run build`），并**打印**通用注册（读 `CLAUDE_PROJECT_DIR` 自配置；不自动写用户 MCP 配置，避免覆盖既有 `shared-wiki`）。

**项目级（每项目，传了 project root 才做）**
- hook 片段并进目标 `.claude/settings.json`（marker=命令含 `grill-adapter/hooks/`、幂等、只增）。
- 选定 host 约定块写进目标 `CLAUDE.md`（marker 包裹、换宿主先剥旧块）。
- wiki 数据/绑定：`bootstrap-wiki` 播种 `.superpowers/wiki/`；`.shared-superpowers/settings.json` 声明 shared 绑定。

`manifest.json` 两级都记账（`userLevel.skills/agents/payload` + `projectLevel.hookSettings/hostConventions`）。`uninstall` 逆向：删 payload/skills/agents、剥 hook 条目与 host 块。

### 环境变量

- `GRILL_ADAPTER_HOME`：覆盖 payload 根（= `__GRILL_ADAPTER_ROOT__`）。
- `CLAUDE_CONFIG_DIR`：覆盖 `~/.claude`（用于沙盒 install / 测试；`release-check` 用它做非破坏验证）。

## `__GRILL_ADAPTER_ROOT__` 替换

源码里所有对执行层脚本 / contracts 的引用都写成 `__GRILL_ADAPTER_ROOT__/scripts/...`、`__GRILL_ADAPTER_ROOT__/contracts/...`。install 把它替换为 payload 绝对路径写进 `~/.claude/skills`、`~/.claude/agents` 与目标 `CLAUDE.md`。payload dirs 本身逐字复制（脚本自定位，无占位符）。任何 `__SUPERPOWER_ADAPTER_*__` 残留都是 bug，`release-check` 会机械拦截。
