# CLAUDE.md

This file guides maintenance of grill-adapter itself. It is not the convention block installed into a target project; those generated host outputs live under `host-adapters/`.

## 必读文档

先读 [`docs/DEVELOPMENT_CN.md`](docs/DEVELOPMENT_CN.md) 的变更路由矩阵。它按变更类型指向最小权威文档和验证命令；普通单子系统修改不再强制读取完整 architecture、host、user-flow、Obsidian 运维和历史蓝图。再按矩阵读取相关 `skills/*/SKILL.md`、`agents/*.md`、`contracts/` 或 `host-adapters/*/CLAUDE.md`。

最终验收以 Claude Code 集成路径为准：真跑 `grill-with-docs → to-spec/to-tickets → implement → code-review → update-wiki`，不能只以直接执行 Python 脚本成功为准。

## 常用命令

```bash
claude plugin install grill-adapter@grill-adapter --scope project
claude --plugin-dir "$PWD" plugin details grill-adapter
./manage.sh install <project> [--host grill|plain] --runtime both
./manage.sh uninstall <project> --runtime both
./manage.sh verify <project> [--host grill|plain] --runtime both
./manage.sh status [project] --runtime both
./manage.sh doctor <project>
./manage.sh self-test [project]
./manage.sh release-check <project>
```

单个测试：`bash tests/<name>.sh <grill-adapter-root> [project-root]`。整套测试：`bash self-test.sh <temporary-project>`；传入的一定是项目根，不是本仓库根。发布前总门：`./manage.sh release-check <project>`。

## 开发约束

- 改用户可见行为时，按 workflow 路由同步检查/更新 `docs/USER_FLOW_CN.md`、对应 skill/agent、`host-adapters/*/CLAUDE.md` 和 `README.md`。
- 改测试原则或验收方式时更新 `docs/DEVELOPMENT_CN.md` 与 `docs/DOCUMENTATION_INDEX_CN.md`。
- 改 hook/install/host 约定时运行 install、verify、`install-project-wiring-smoke.sh` 和 `host-conventions-smoke.sh`。
- 改插件布局时运行 Claude plugin details、`codex-plugin-smoke.sh` 与 `documentation-index-smoke.sh`，并同步 `release-check.sh` 的组件计数。
- 改 `mcp/obsidian-wiki/src/` 时运行 `npm run typecheck && npm run build && npm test`，并提交 `dist/index.js`。
- Carry/Bind 的 task 身份只来自 host ticket roster；引擎不解析 plan/ticket 文档。改动后运行 ticket-roster 与 wiki-context/readiness smoke。
- 插件内容只使用裸 `${CLAUDE_PLUGIN_ROOT}`；`host-adapters/*/CLAUDE.md` 不得包含路径；禁止残留 `__GRILL_ADAPTER_ROOT__` / `__SUPERPOWER_ADAPTER_*__`。

## 当前不变式

唯一叙事权威是 [`docs/ARCHITECTURE_CN.md`](docs/ARCHITECTURE_CN.md)；schema 权威是 `contracts/`。必须保持 Markdown truth、零 host skill patch、Claude installed acceptance、ticket roster、角色 snapshot、Source binding 和 root-specific authorization 的 fail-closed 边界。文档导航与生成索引见 [`docs/DOCUMENTATION_INDEX_CN.md`](docs/DOCUMENTATION_INDEX_CN.md)。

## Agent skills

### Issue tracker

Issues and PRDs are tracked in this repository's GitHub Issues. See `docs/agents/issue-tracker.md`.

### Domain docs

This repository uses a single-context domain-document layout. See `docs/agents/domain.md`.
