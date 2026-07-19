# grill-adapter 快速上手（5 分钟）

面向**已经装好 grill**（mattpocock/skills）并在用 Claude Code 的人。没装过 grill 请看 `docs/SETUP_AND_USAGE_CN.md`。

## 1. 装 grill-adapter

grill-adapter 是个 Claude Code plugin。两步：

**① 装 plugin**（在你的项目目录下）：

```bash
claude plugin marketplace add YWJ-hy/grill-adapter
claude plugin install grill-adapter@grill-adapter --scope project
```

12 个 skill、3 个 agent、4 个 hook、两个 MCP（legacy `shared-wiki` 与 Source-binding `obsidian-wiki`）**一起注册、自动生效**——不拷文件进 `~/.claude`，不动你项目的 `.claude/settings.json`。MCP 装好即自动启动，**无需手工注册**；它们共用 plugin 的 scope（`--scope project` = 只在本项目起；`--scope user` = 跨项目）。

**② 给项目写约定块**（plugin 唯一管不到的东西）：

```bash
git clone https://github.com/YWJ-hy/grill-adapter.git
cd grill-adapter
./manage.sh install /path/to/your/project --host grill
```

只把 grill 约定块写进你项目的 `CLAUDE.md`（marker 包裹，只点名 skill、不含安装路径）。**不改 grill 一行。**

## 2. 播种 wiki

```bash
./manage.sh bootstrap-wiki /path/to/your/project --template standard
./manage.sh doctor /path/to/your/project      # 确认接线 + 绑定状态
```

`.adapter/wiki/` 就绪。也可以在 Claude Code 里用 `/grill-adapter:init-wiki` 让 agent 基于项目盘点初始化，或 `/grill-adapter:import-wiki` + `/grill-adapter:migrate-wiki` 导入已有文档。

## 3. 跑一遍 grill → implement → update-wiki

在 Claude Code 里对你的项目：

1. `/grill-with-docs`：描述需求。约定会在质询期自动提示调 `/grill-adapter:wiki-research` 披露相关 wiki。
2. `/to-tickets`：规划期 `/grill-adapter:wiki-research`（plan）正式选 wiki → 生成 `.adapter/context/<feature-slug>.wiki-context.json` sidecar；ticket 发布后由真实 ticket 建 roster，再 `--finalize` 盖指纹。
3. `/implement`：每个 ticket 前跑 `/grill-adapter:wiki-materialize <ticket>`，把该 ticket 的硬约束 wiki section 整段 reread 进上下文。改到 source-of-truth 保护路径时 `source-truth-lint` hook 会提醒。
4. `/code-review` 后：跑 `/grill-adapter:update-wiki` 审查是否有 durable 知识回写（它自己会先把 grill 的 CONTEXT.md/ADR 增量转成候选行）。

## 4. 验证

```bash
./manage.sh verify /path/to/your/project --host grill
./manage.sh self-test                          # 跑全套 smoke（可选）
```

## 常用命令速查

```
./manage.sh install|uninstall|verify|status <project> [--host grill|plain]
./manage.sh bootstrap-wiki <project> [--template standard]
./manage.sh init-wiki <project> [hint]
./manage.sh export-wiki-skills <wiki-repo> [--no-graph-ci]
./manage.sh doctor <project>
./manage.sh self-test [project]
./manage.sh release-check <project>
```

要卸载：把 `grill-adapter@grill-adapter` 从项目 `.claude/settings.json` 的 `enabledPlugins` 里删掉（project scope 是提交进仓库、与团队共享的设置，`claude plugin uninstall` 会**拒绝**替你删；只想自己关掉用 `claude plugin disable grill-adapter@grill-adapter --scope local`），再 `./manage.sh uninstall /path/to/your/project` 剥项目约定块。
