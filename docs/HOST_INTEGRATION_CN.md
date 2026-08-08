# grill-adapter Host 集成

本页只定义 host 适配器的协议与安装边界。具体 grill/plain 约定块由 `contracts/host-conventions-v1.json` 生成，输出落在 `host-adapters/{grill,plain}/{CLAUDE,AGENTS}.md`；不要在文档中复制这些块。

## 适配器模型

grill-adapter 同时作为 Claude Code 与 Codex plugin 发货。skills、agents、hooks 和 `obsidian-wiki` MCP 属于插件层；插件唯一不能替目标项目完成的动作，是写入项目的持久指令文件：

- Claude Code 写入项目 `CLAUDE.md`；
- Codex 写入项目 `AGENTS.md`；
- `--runtime claude|codex|both` 选择目标运行时；
- `<!-- grill-adapter:host:<host>:start -->` / `end` marker 包裹整块，install 幂等、换 host 可剥离、uninstall 保留用户内容。

```bash
./manage.sh install <project> --host grill --runtime both
./manage.sh verify <project> --host grill --runtime both
python3 scripts/render_host_conventions.py --check
```

`contracts/host-conventions-v1.json` 是路由、激活门、roster 边界和状态边界的唯一规范源；`scripts/render_host_conventions.py --write` 生成四个运行时输出。`manifest.json` 只记录 install 需要的输出路径，插件组件清单由 plugin manifest 和布局索引维护。

## 激活边界

安装 plugin 只表示能力可用，不表示项目已启用 adapter。每个 workflow-facing skill 和全局 hook 在 adapter 动作或写入前先运行只读 `scripts/project_activation.py`。以下任一条件满足才继续：

1. 当前请求显式调用 adapter skill；
2. 项目 `CLAUDE.md` / `AGENTS.md` 含 host marker；
3. 项目 `.grill-adapter/settings.json` 存在并声明配置。

三者都没有时是 standalone grill：不得创建 `.grill-adapter/`、读取旧 context、调用 MCP 或输出 adapter 噪声。项目 marker 只表达 opt-in 和阶段路由，不拥有状态机、权限、失败或恢复语义；这些由对应入口 skill 与 contract 定义。

## Host 路由

grill host 的 stage moment 与 plain host 的显式 workflow moment 均在生成 contract 中维护。维护者入口、最小必读文档和验证命令见 [`DEVELOPMENT_CN.md`](DEVELOPMENT_CN.md) 的变更路由矩阵；用户端到端产物见 [`USER_FLOW_CN.md`](USER_FLOW_CN.md)。

约定块只能点名 adapter skill，不能写插件路径，也不能 patch 宿主 skill。宿主自带的 `/grill-with-docs`、`/to-spec`、`/to-tickets`、`/implement`、`/code-review` 等始终由宿主自己提供；adapter 只在对应 moment 旁挂入口。

## Hook 与安装

hook 随 plugin 自动注册，不再修改项目 settings：

| 事件 | 当前职责 |
|---|---|
| `SessionStart` | 重验 metadata-only session state，最多给三条可恢复 action 和一条 Outbox 计数提醒 |
| `PostToolUse` | 对真实 changed files 执行 source-truth lint |
| `Stop` | Capture 兜底提醒并做收尾 lint |

插件安装：

```bash
claude plugin install grill-adapter@grill-adapter --scope project
codex plugin marketplace add YWJ-hy/grill-adapter
codex plugin add grill-adapter@grill-adapter
```

项目接线（插件做不到的那一件事）：

```bash
./manage.sh install <project> [--host grill|plain] --runtime claude|codex|both
./manage.sh uninstall <project> --runtime claude|codex|both
./manage.sh status [project] --runtime claude|codex|both
```

`install.py` 只改选定 runtime 的 `CLAUDE.md` / `AGENTS.md` 约定块，不安装 skill、不写插件路径、不删除 `.grill-adapter/` 用户数据。`verify` 只校验 marker 与生成输出；`doctor` 只读诊断 active provider/adoption state。

## 路径替换边界

插件内容（`skills/`、`agents/`、`hooks/hooks.json`、`.mcp.json`）中的脚本和 contract 路径统一写裸 token `${CLAUDE_PLUGIN_ROOT}`。Claude Code 在加载时替换；Codex 使用插件根 `cwd: "."` 与 `./mcp/...`。

两条机械规则：

1. 只匹配裸 `${CLAUDE_PLUGIN_ROOT}`；`${CLAUDE_PLUGIN_ROOT:-fallback}` 和 `$CLAUDE_PLUGIN_ROOT` 不会替换。
2. `host-adapters/*/{CLAUDE,AGENTS}.md` 会被写到插件外的项目文件，一个路径都不许有。`__GRILL_ADAPTER_ROOT__`、`__SUPERPOWER_ADAPTER_*__` 残留由 release-check 拦截。

Source binding、root authorization、Obsidian runtime 和迁移边界见 [`OBSIDIAN_WIKI_CN.md`](OBSIDIAN_WIKI_CN.md)；它们不是 host convention 的职责。
