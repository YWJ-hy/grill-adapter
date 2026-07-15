# grill-adapter 快速上手（5 分钟）

面向**已经装好 grill**（mattpocock/skills）并在用 Claude Code 的人。没装过 grill 请看 `docs/SETUP_AND_USAGE_CN.md`。

## 1. 装 grill-adapter

```bash
git clone https://github.com/YWJ-hy/grill-adapter.git
cd grill-adapter
./manage.sh install /path/to/your/project --host grill
```

这会：用户级把 12 个 skill 装进 `~/.claude/skills/`、3 个 agent 装进 `~/.claude/agents/`、payload（含构建好的 shared-wiki MCP）装进 `~/.claude/grill-adapter/`；项目级把 hook 并进你项目的 `.claude/settings.json`、把 grill 约定块写进你项目的 `CLAUDE.md`。**不改 grill 一行。**

按提示把打印出来的 shared-wiki MCP 注册（一次、用户级）粘进你的用户 MCP 配置——只有要用跨 repo 共享 wiki 才需要。

## 2. 播种 wiki

```bash
./manage.sh bootstrap-wiki /path/to/your/project --template standard
./manage.sh doctor /path/to/your/project      # 确认安装 + 绑定状态
```

`.superpowers/wiki/` 就绪。也可以在 Claude Code 里用 `/init-wiki` 让 agent 基于项目盘点初始化，或 `/import-wiki` + `/migrate-wiki` 导入已有文档。

## 3. 跑一遍 grill → implement → update-wiki

在 Claude Code 里对你的项目：

1. `/grill-with-docs`：描述需求。约定会在质询期自动提示调 `/wiki-research` 披露相关 wiki。
2. `/to-tickets`：规划期 `/wiki-research`（plan）正式选 wiki → 生成 `<plan>.wiki-context.json` sidecar，plan 里出现 `## Referenced Project Wiki`。
3. `/implement`：每个 ticket 前跑 `/wiki-materialize <ticket>`，把该 ticket 的硬约束 wiki section 整段 reread 进上下文。改到 source-of-truth 保护路径时 `source-truth-lint` hook 会提醒。
4. `/code-review` 后：`grill_context_to_candidates.py` 把 grill 的 CONTEXT.md/ADR 增量转成候选行 → `/update-wiki` 审查是否有 durable 知识回写。

## 4. 验证

```bash
./manage.sh verify /path/to/your/project --host grill
./manage.sh self-test                          # 跑全套 smoke（可选）
```

## 常用命令速查

```
./manage.sh install|uninstall|verify|status [project] [--host grill|plain]
./manage.sh mcp-registration
./manage.sh bootstrap-wiki <project> [--template standard]
./manage.sh init-wiki <project> [hint]
./manage.sh export-wiki-skills <wiki-repo> [--no-graph-ci]
./manage.sh doctor <project>
./manage.sh self-test [project]
./manage.sh release-check <project>
```

要卸载：`./manage.sh uninstall /path/to/your/project`（删用户级安装 + 剥项目 hook/约定块）。
