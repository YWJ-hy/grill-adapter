# grill-adapter 安装与使用（从零开始）

面向**从未装过 grill** 的用户。跟着走一遍：装 Claude Code → 装 grill → 装 grill-adapter → 端到端跑一次。装过 grill 的人可直接看 `../QUICKSTART_CN.md`。

## 0. 前置

- **Claude Code**（CLI / 桌面 / IDE 扩展任一）。已登录可用。
- **Python 3.9+**（`python3 --version`）。
- **Node.js ≥ 20**（`node --version`）——只给 shared-wiki MCP server 用；plugin 里已带打包好的 bundle，**不需要你构建**。

## 1. 装 grill（mattpocock/skills）

grill 是一个**只读、随版本更新的托管 plugin bundle**（你订阅它，不 fork），提供 `/grill-with-docs → /to-spec → /to-tickets → /implement → /code-review`（外加 `/diagnosing-bugs`）。在 Claude Code 里：

```
/plugin marketplace add mattpocock/skills
/plugin install mattpocock-skills@mattpocock
/setup-matt-pocock-skills
```

`/setup-matt-pocock-skills` 会问 issue tracker（GitHub / Linear / local）、ticket 标签、docs 保存位置——按你的项目回答即可。

备选（命令行）：`npx skills@latest add mattpocock/skills`。

> 落地前以 grill 官方 README 为准；命令名可能随版本微调。grill 升级不影响 grill-adapter——这正是「零 skill patch」设计的意义。

## 2. 装 grill-adapter

grill-adapter **本身就是一个 Claude Code plugin**。装它分两步：先装 plugin，再给项目写约定块。

### 2.1 装 plugin（Claude Code 里）

```
/plugin marketplace add YWJ-hy/grill-adapter
/plugin install grill-adapter@grill-adapter
```

或命令行（在你的项目目录下）：

```bash
claude plugin install grill-adapter@grill-adapter --scope project
```

plugin 一启用，12 个 skill、3 个 agent、4 个 hook 和 shared-wiki MCP server **一起注册、自动生效**——不往 `~/.claude/skills`、`~/.claude/agents` 拷文件，也不往你项目的 `.claude/settings.json` 里并 hook 片段。

**关于 `--scope`**：skills / agents / hooks / MCP **共用 plugin 的 scope**，plugin 自带的 MCP 无法单独设 scope。想要 shared-wiki MCP 只在**这个项目**里起，就用 `--scope project`；想跨项目共用，用 `--scope user`。

shared-wiki MCP 装好即自动启动（工具名带 `mcp__plugin_grill-adapter_shared-wiki__` 前缀），**不需要再手工注册**。要不要真连上一个跨 repo 共享 wiki，取决于你项目里的**绑定声明**（见下）：server 启动读 `CLAUDE_PROJECT_DIR`，从该项目的 `.shared-adapter/settings.json` 的 `wiki.sharedMcp` 自配置；没声明的项目自动 fail-closed，属正常。

### 2.2 给项目写约定块

plugin 唯一管不到的是**你项目的 `CLAUDE.md`**——那是告诉宿主「在 grill 哪个阶段调哪个 skill」的约定。用仓库里的 `manage.sh` 写：

```bash
git clone https://github.com/YWJ-hy/grill-adapter.git
cd grill-adapter
./manage.sh install /path/to/your/project --host grill
```

它只做这一件事：把 grill 约定块（marker 包裹）写进 `<project>/CLAUDE.md`。块里**只点名 skill、不含任何安装路径**——路径由 skill 自己持有，plugin 升级换目录也不会失效。

校验：

```bash
./manage.sh verify /path/to/your/project --host grill
./manage.sh status /path/to/your/project      # 约定块状态 + plugin 是否启用（提示性）
```

## 3. 播种项目 wiki

```bash
./manage.sh bootstrap-wiki /path/to/your/project --template standard
./manage.sh doctor /path/to/your/project
```

`.adapter/wiki/` 就绪（标准模板：backend / frontend / guides）。或在 Claude Code 里 `/grill-adapter:init-wiki` 让 agent 基于项目盘点起草，`/grill-adapter:import-wiki` + `/grill-adapter:migrate-wiki` 导入并 section 化已有文档。

## 4. 端到端走一遍

打开 Claude Code，进入你的项目（`CLAUDE.md` 里已有 grill 约定块），按需求跑：

| 步 | 命令 | grill-adapter 触点 | 产物 |
|---|---|---|---|
| 0（可选）Lanhu 录入 | `/grill-adapter:lanhu-requirements <蓝湖链接> frontend\|backend` | Intake | `.lanhu/.../index.md` 证据包（只作输入） |
| 1 质询/发现 | `/grill-with-docs` | Disclose：约定提示 `/grill-adapter:wiki-research`（brainstorm） | spec 草稿 |
| 2 定 spec | `/to-spec` | source-truth Verify：`/grill-adapter:source-truth-check`（spec-pre） | spec |
| 3 拆 ticket | `/to-tickets` | Disclose+Carry：`/grill-adapter:wiki-research`（plan）→ scaffold sidecar → 由真实 ticket 建 roster → `--finalize` | `.adapter/context/<feature-slug>.{wiki-context,ticket-roster}.json` |
| 4 实现 | `/implement` | Bind：每 ticket `/grill-adapter:wiki-materialize <ticket>`；`source-truth-lint` hook | 代码 + 硬约束整段 reread |
| 5 评审后 | `/code-review` → `/grill-adapter:update-wiki` | Capture：`/grill-adapter:update-wiki`（内部可选前置步骤把 grill 的 CONTEXT.md/ADR 增量转成候选） | 回写的 wiki section |
| 6 调试（如需） | `/diagnosing-bugs` → `/grill-adapter:break-loop` | debug Disclose + 复盘→Capture | 修复 + 复盘候选 |

每一步的命令和约定都写在你项目 `CLAUDE.md` 的 grill 约定块里，Claude Code 会照着做。想看完整流程叙述见 `USER_FLOW_CN.md`。

## 5. 常见问题

- **我没用 grill，用裸 Claude Code 行吗？** 行。`./manage.sh install /path/to/project --host plain`，然后在对应时刻**自己**调同样的 skill（见 `HOST_INTEGRATION_CN.md` 的 plain 约定块）。
- **会改我的 grill 吗？** 不会。grill-adapter 零 skill patch。skill / agent / hook / MCP 全在 plugin 里自成一体；落到你仓库里的改动只有 `<project>/CLAUDE.md` 的那个约定块。
- **shared-wiki MCP 没连上？** 跑 `./manage.sh doctor <project>` 看绑定；确认 plugin 已启用（`/plugin` 里看得到 grill-adapter）；确认 `.shared-adapter/settings.json` 的 `wiki.sharedMcp.repoUrl` 有值。没声明就是 fail-closed（无 MCP shared wiki），属正常。
- **MCP 只想在某一个项目里起？** 那就用 `--scope project` 装 plugin。plugin 自带的 MCP 不能单独设 scope，它跟着 plugin 的 scope 走。
- **`/grill-adapter:wiki-materialize` 报 drift / 换绑？** 这是 fail-closed 设计：sidecar 记的 `sharedWiki.repoUrl` 和当前连的 repo 不一致，或 revision 漂移。回规划期确认 routing 后 `--bind-fingerprints` 重新钉，再继续。
- **怎么卸载？** 两步对应两步安装。
  1. **停用 plugin**：把 `grill-adapter@grill-adapter` 从项目 `.claude/settings.json` 的 `enabledPlugins` 删掉即可。注意 `claude plugin uninstall` 对 **project scope 会直接拒绝**（原话：「enabled at project scope (.claude/settings.json, shared with your team)」）——它不肯替你改一份团队共享的提交物。只想自己关掉、不动团队设置：`claude plugin disable grill-adapter@grill-adapter --scope local`。装在 `--scope user` 时 `claude plugin uninstall grill-adapter@grill-adapter` 才直接生效。
  2. **剥约定块**：`./manage.sh uninstall /path/to/your/project`（marker 包裹，干净移除，不动 `CLAUDE.md` 其余内容）。
- **升级 grill-adapter？** `/plugin update grill-adapter@grill-adapter` 升 plugin。约定块若有变，`git pull` 后重跑 `./manage.sh install`（幂等：整块替换）。

## 6. 验证你的安装

```bash
claude --plugin-dir "$PWD" plugin details grill-adapter   # 不安装即加载：应报 12 skills / 3 agents / 4 hooks / 1 MCP
./manage.sh self-test                # 跑全套 smoke/regression（别传仓库根，见 DEVELOPMENT_CN.md）
./manage.sh release-check <project>  # 发布前总门（plugin 加载 + 沙盒接线 + verify + 全套 + doctor，非破坏）
```
