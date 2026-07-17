# grill-adapter 安装与使用（从零开始）

面向**从未装过 grill** 的用户。跟着走一遍：装 Claude Code → 装 grill → 装 grill-adapter → 端到端跑一次。装过 grill 的人可直接看 `../QUICKSTART_CN.md`。

## 0. 前置

- **Claude Code**（CLI / 桌面 / IDE 扩展任一）。已登录可用。
- **Python 3.9+**（`python3 --version`）。
- **Node.js ≥ 20**（`node --version`）——只给 shared-wiki MCP server 用，install 时会自动构建。

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

```bash
git clone https://github.com/YWJ-hy/grill-adapter.git
cd grill-adapter
./manage.sh install /path/to/your/project --host grill
```

会做两件事：

- **用户级（一次，跨项目）**：12 个 skill → `~/.claude/skills/`，3 个 agent → `~/.claude/agents/`，运行时 payload（`scripts/` `contracts/` `hooks/` 和**构建好的** shared-wiki MCP）→ `~/.claude/grill-adapter/`。
- **项目级（这个项目）**：hook 并进 `<project>/.claude/settings.json`，grill 约定块写进 `<project>/CLAUDE.md`。

install 末尾会**打印**一段 shared-wiki MCP 注册 JSON。只有你要用**跨 repo 共享 wiki** 才需要：按提示用 `claude mcp add-json -s user shared-wiki '...'` 注册一次（用户级）。server 启动读 `CLAUDE_PROJECT_DIR`，从每个项目的 `.shared-adapter/settings.json` 自配置；没声明的项目自动 fail-closed。

校验：

```bash
./manage.sh verify /path/to/your/project --host grill
./manage.sh status /path/to/your/project
```

## 3. 播种项目 wiki

```bash
./manage.sh bootstrap-wiki /path/to/your/project --template standard
./manage.sh doctor /path/to/your/project
```

`.adapter/wiki/` 就绪（标准模板：backend / frontend / guides）。或在 Claude Code 里 `/init-wiki` 让 agent 基于项目盘点起草，`/import-wiki` + `/migrate-wiki` 导入并 section 化已有文档。

## 4. 端到端走一遍

打开 Claude Code，进入你的项目（`CLAUDE.md` 里已有 grill 约定块），按需求跑：

| 步 | 命令 | grill-adapter 触点 | 产物 |
|---|---|---|---|
| 0（可选）Lanhu 录入 | `/lanhu-requirements <蓝湖链接> frontend\|backend` | Intake | `.lanhu/.../index.md` 证据包（只作输入） |
| 1 质询/发现 | `/grill-with-docs` | Disclose：约定提示 `/wiki-research`（brainstorm） | spec 草稿 |
| 2 定 spec | `/to-spec` | source-truth Verify：`/source-truth-check`（spec-pre） | spec |
| 3 拆 ticket | `/to-tickets` | Disclose+Carry：`/wiki-research`（plan）→ scaffold sidecar → 由真实 ticket 建 roster → `--finalize` | `.adapter/context/<feature-slug>.{wiki-context,ticket-roster}.json` |
| 4 实现 | `/implement` | Bind：每 ticket `/wiki-materialize <ticket>`；`source-truth-lint` hook | 代码 + 硬约束整段 reread |
| 5 评审后 | `/code-review` → `/update-wiki` | Capture：`grill_context_to_candidates.py` 转候选 → `/update-wiki` | 回写的 wiki section |
| 6 调试（如需） | `/diagnosing-bugs` → `/break-loop` | debug Disclose + 复盘→Capture | 修复 + 复盘候选 |

每一步的命令和约定都写在你项目 `CLAUDE.md` 的 grill 约定块里，Claude Code 会照着做。想看完整流程叙述见 `USER_FLOW_CN.md`。

## 5. 常见问题

- **我没用 grill，用裸 Claude Code 行吗？** 行。`./manage.sh install /path/to/project --host plain`，然后在对应时刻**自己**调同样的 skill（见 `HOST_INTEGRATION_CN.md` 的 plain 约定块）。
- **会改我的 grill 吗？** 不会。grill-adapter 零 skill patch，只写你项目的 `CLAUDE.md` + `.claude/settings.json` 和用户级 `~/.claude/skills`、`~/.claude/agents`、`~/.claude/grill-adapter`。
- **shared-wiki MCP 没连上？** 跑 `./manage.sh doctor <project>` 看绑定；确认 `.shared-adapter/settings.json` 的 `wiki.sharedMcp.repoUrl` 有值；确认已用 `./manage.sh mcp-registration` 打印的 JSON 注册过一次。没声明就是 fail-closed（无 MCP shared wiki），属正常。
- **`/wiki-materialize` 报 drift / 换绑？** 这是 fail-closed 设计：sidecar 记的 `sharedWiki.repoUrl` 和当前连的 repo 不一致，或 revision 漂移。回规划期确认 routing 后 `--bind-fingerprints` 重新钉，再继续。
- **怎么卸载？** `./manage.sh uninstall /path/to/your/project`——删用户级安装，剥项目 hook 条目和约定块（marker 包裹，干净移除）。
- **升级 grill-adapter？** `git pull` 后重跑 `./manage.sh install`（幂等：hook 不重复、约定块整块替换、payload 覆盖重装）。

## 6. 验证你的安装

```bash
./manage.sh self-test              # 跑全套 smoke/regression
./manage.sh release-check <project>  # 发布前总门（沙盒 install + verify + 全套 + doctor，非破坏）
```
