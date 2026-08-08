# grill-adapter 开发入口

这是维护者的短入口，不是所有子系统的百科。先读本页的路由矩阵，再按变更类型披露最小的权威上下文；完整流程、host 输出、MCP 运维和历史 rationale 都按需读取。

## 三条铁律

1. **不 patch 宿主 skill**：适配只通过独立 skill/agent、插件 hook 和项目级 host router。
2. **验收以安装后的 Codex/Claude 集成路径为准**：脚本 smoke 只能证明执行层，不能替代真实 workflow。
3. **Markdown 是唯一知识真相源**：`.graph.json`、索引和报告都是可重建的派生物。

架构不变式（四个 Wiki 触点、激活边界、ticket roster、角色快照、binding 和授权）只在 [`ARCHITECTURE_CN.md`](ARCHITECTURE_CN.md) 与对应 `contracts/` 中定义。文档边界和组件/测试索引见 [`DOCUMENTATION_INDEX_CN.md`](DOCUMENTATION_INDEX_CN.md)。

## 变更路由矩阵

| 变更类型 | 必读的最小上下文 | 完成后验证 |
|---|---|---|
| 文档入口、索引或路由 | 本页、[`DOCUMENTATION_INDEX_CN.md`](DOCUMENTATION_INDEX_CN.md)、`contracts/developer-doc-routing-v1.json` | `bash tests/documentation-index-smoke.sh <root>` |
| host 约定、install、激活或 hook 接线 | [`HOST_INTEGRATION_CN.md`](HOST_INTEGRATION_CN.md)、`contracts/host-conventions-v1.json`、目标 `host-adapters/<host>/{CLAUDE,AGENTS}.md` | `python3 scripts/render_host_conventions.py --check`；`bash tests/install-project-wiring-smoke.sh <root>`；`bash tests/host-conventions-smoke.sh <root>` |
| 用户流程或入口 skill/agent | [`USER_FLOW_CN.md`](USER_FLOW_CN.md)、对应 `skills/<entry>/SKILL.md`、对应 `agents/<role>.md`；同步目标：`host-adapters/<host>/{CLAUDE,AGENTS}.md`、`README.md` | `bash tests/skill-catalog-smoke.sh <root>`；`bash tests/codex-plugin-smoke.sh <root>`；Codex installed acceptance |
| Carry、ticket roster、Readiness、Bind 或角色 snapshot | [`ARCHITECTURE_CN.md`](ARCHITECTURE_CN.md)、`contracts/ticket-roster-v1.example.jsonc`、`contracts/wiki-context-v6.example.jsonc`、`contracts/wiki-task-snapshot-v2.example.jsonc`、`contracts/wiki-readiness-v1.example.jsonc` | `bash tests/ticket-roster-smoke.sh <root>`；`bash tests/wiki-context-scaffold-smoke.sh <root>`；`bash tests/wiki-readiness-smoke.sh <root>` |
| Obsidian binding、授权、MCP 或运行时运维 | [`OBSIDIAN_WIKI_CN.md`](OBSIDIAN_WIKI_CN.md)、[`OBSIDIAN_ACCEPTANCE_CN.md`](OBSIDIAN_ACCEPTANCE_CN.md)、`mcp/obsidian-wiki/src/<module>.ts` | 在 `mcp/obsidian-wiki/` 运行 `npm run typecheck && npm run build && npm test`；`bash tests/obsidian-runtime-operations-smoke.sh <root>` |
| scripts/ 引擎、schema 或 section/graph 语义 | [`ARCHITECTURE_CN.md`](ARCHITECTURE_CN.md)、`contracts/<engine-contract>.jsonc`、`scripts/<engine>.py` | `bash tests/<subsystem>-smoke.sh <root>`；`bash self-test.sh <temporary-project>`；`./manage.sh release-check <project>` |
| 测试实现、测试分层或验收清单 | 本页、[`DOCUMENTATION_INDEX_CN.md`](DOCUMENTATION_INDEX_CN.md)、对应 `tests/<name>.sh` | `bash tests/<name>.sh <root>`；`bash tests/documentation-index-smoke.sh <root>`；`bash self-test.sh <temporary-project>` |
| source-truth 或 break-loop 触点 | [`ARCHITECTURE_CN.md`](ARCHITECTURE_CN.md)、对应 `skills/source-truth-check/SKILL.md`、`skills/break-loop/SKILL.md` | `bash tests/source-truth-settings-smoke.sh <root>`；`bash tests/hooks-smoke.sh <root>`；`bash tests/project-opt-in-smoke.sh <root>` |
| 插件布局、组件清单或发布门 | [`DOCUMENTATION_INDEX_CN.md`](DOCUMENTATION_INDEX_CN.md)、`.claude-plugin/plugin.json`、`.codex-plugin/plugin.json`、`release-check.sh`（组件计数同步） | `bash tests/documentation-index-smoke.sh <root>`；`bash tests/codex-plugin-smoke.sh <root>`；`./manage.sh release-check <project>` |

`<root>` 是 grill-adapter 仓库根；`<temporary-project>` 必须是一次性项目目录，不能把本仓库根传给会写 Wiki 的测试。矩阵的机器可验证副本是 `contracts/developer-doc-routing-v1.json`，新增路线先改 contract，再更新本页。

## 验收分层

- **执行层**：对应 `tests/*-smoke.sh`、MCP 单测和 schema fixture，证明脚本/contract 行为。
- **接线层**：install、host convention、hook、activation 和 plugin catalog smoke，证明安装输出与运行时发现一致。
- **发布层**：`./manage.sh release-check <project>`，串联 py_compile、MCP bundle、插件清单、Codex context budget、接线和全套 smoke。
- **最终层**：在隔离安装的 Codex 中真实走 `grill-with-docs → to-spec/to-tickets → implement → code-review → update-wiki`；Claude 同样走完整阶段时验证对应 host。失败、dispatch/role load、binding drift 和授权拒绝必须保留 fail-closed 语义。

常用入口：

```bash
./manage.sh install <project> --host grill --runtime both
./manage.sh verify <project> --host grill --runtime both
bash tests/<name>.sh "$PWD" [project-root]
bash self-test.sh <temporary-project>
./manage.sh release-check <project>
```

Codex context budget（#38）是安装后固定门，不替代行为验收：

```bash
bash acceptance/codex-context-budget-installed.sh "$PWD"
```

它量化真实 `codex debug prompt-input`、MCP `tools/list` 和四个 stage payload；文档 required-read 另用 `python3 scripts/docs_context_budget.py --all` 量化，单位同为 UTF-8 bytes。报告只包含稳定路径、字节数、占比、阈值和状态，不保存 Wiki 正文、凭据或用户配置。

## 组件与测试索引

组件清单由 `.claude-plugin/plugin.json`、`.codex-plugin/plugin.json`、`hooks/hooks.json` 和目录布局声明；smoke 文件由 `tests/` 目录声明。不要手工维护第二份逐项清单。运行：

```bash
python3 scripts/check_documentation_index.py --check
python3 scripts/check_documentation_index.py --write  # 新增组件或 smoke 后更新生成块
```

新增引擎行为时扩展现有 subsystem smoke；新增入口/role/MCP 时先更新 manifest 或目录，再让 inventory smoke 卡住文档漂移。
