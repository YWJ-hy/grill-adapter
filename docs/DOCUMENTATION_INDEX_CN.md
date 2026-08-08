# grill-adapter 文档索引

本页是文档的导航与边界索引。它不复制 host convention、skill 正文或 smoke 实现；这些内容只在各自的规范源中维护。

## 权威边界

| 主题 | 唯一权威位置 | 说明 |
|---|---|---|
| 三条铁律、跨层不变式、四触点 | [`ARCHITECTURE_CN.md`](ARCHITECTURE_CN.md) | 叙事架构与不可绕过的边界 |
| host 路由与安装输出 | [`contracts/host-conventions-v1.json`](../contracts/host-conventions-v1.json) | `host-adapters/*/{CLAUDE,AGENTS}.md` 是生成物 |
| ticket roster 身份 | [`contracts/ticket-roster-v1.example.jsonc`](../contracts/ticket-roster-v1.example.jsonc) | engine 不解析 plan/ticket 文档 |
| 角色 task snapshot | [`contracts/wiki-task-snapshot-v2.example.jsonc`](../contracts/wiki-task-snapshot-v2.example.jsonc) | implement/review 只消费冻结 Markdown |
| Source binding 与 root authorization 不变式 | [`ARCHITECTURE_CN.md`](ARCHITECTURE_CN.md) | 唯一跨层不变式位置；`OBSIDIAN_WIKI_CN.md` 只补运行时操作说明 |
| Codex installed acceptance | [`DEVELOPMENT_CN.md`](DEVELOPMENT_CN.md) | 真实 plugin/skill/MCP 集成路径是最终门 |
| 用户端到端时序 | [`USER_FLOW_CN.md`](USER_FLOW_CN.md) | 只讲阶段与产物，不承载实现清单 |
| 历史 rationale | [`DECISIONS_CN.md`](DECISIONS_CN.md) | 决策记录；状态为 `SUPERSEDED` 的条目不是当前契约 |
| 历史 build plan | [`BUILD_PLAN_CN.md`](BUILD_PLAN_CN.md) | 仅存档，不是当前实现说明 |

## 按需披露

维护者先读 [`DEVELOPMENT_CN.md`](DEVELOPMENT_CN.md) 的变更路由矩阵，再只读取当前路由列出的文档和契约。普通的单子系统修改不需要预读完整 host、用户流程、Obsidian 运维和历史蓝图。

<!-- generated:documentation-inventory:start -->
### Plugin components (generated)

- Skills (12): `skills/break-loop/SKILL.md`, `skills/candidate-journal/SKILL.md`, `skills/import-wiki/SKILL.md`, `skills/init-wiki/SKILL.md`, `skills/migrate-wiki/SKILL.md`, `skills/scaffold-practice-skill/SKILL.md`, `skills/setup-init-obsidian/SKILL.md`, `skills/source-truth-check/SKILL.md`, `skills/update-wiki/SKILL.md`, `skills/wiki-maintenance/SKILL.md`, `skills/wiki-readiness/SKILL.md`, `skills/wiki-research/SKILL.md`
- Agents (5): `agents/wiki-capture.md`, `agents/wiki-maintenance-audit.md`, `agents/wiki-maintenance-consolidation.md`, `agents/wiki-outbox-consolidation.md`, `agents/wiki-researcher.md`
- Hook events (3): `PostToolUse`, `SessionStart`, `Stop`
- MCP servers (1): `obsidian-wiki`

### Smoke tests (generated)

- Bash smoke files (52): `tests/adr-projection-identity-smoke.sh`, `tests/bootstrap-wiki-template-import.sh`, `tests/child-role-loader-smoke.sh`, `tests/codex-context-budget-smoke.sh`, `tests/codex-context-isolation-acceptance-contract-smoke.sh`, `tests/codex-plugin-smoke.sh`, `tests/documentation-index-smoke.sh`, `tests/export-wiki-skills-smoke.sh`, `tests/grill-bridge-smoke.sh`, `tests/hooks-smoke.sh`, `tests/host-conventions-smoke.sh`, `tests/init-wiki-inventory-smoke.sh`, `tests/install-project-wiring-smoke.sh`, `tests/migrate-wiki-repartition-smoke.sh`, `tests/npm-package-smoke.sh`, `tests/npm-release-plan-smoke.sh`, `tests/obsidian-runtime-operations-smoke.sh`, `tests/obsidian-wiki-bind-smoke.sh`, `tests/obsidian-wiki-bindings-smoke.sh`, `tests/obsidian-wiki-context-v6-smoke.sh`, `tests/obsidian-wiki-migration-apply-smoke.sh`, `tests/obsidian-wiki-migration-plan-smoke.sh`, `tests/project-opt-in-smoke.sh`, `tests/removed-capability-residue-smoke.sh`, `tests/scaffold-practice-skill-smoke.sh`, `tests/setup-init-obsidian-skill-smoke.sh`, `tests/skill-catalog-smoke.sh`, `tests/source-truth-settings-smoke.sh`, `tests/subagent-models-smoke.sh`, `tests/test-wiki-section.sh`, `tests/ticket-roster-smoke.sh`, `tests/update-wiki-atomic-note-targeting-smoke.sh`, `tests/wiki-authorization-policy-smoke.sh`, `tests/wiki-candidate-journal-smoke.sh`, `tests/wiki-capture-agent-contract-smoke.sh`, `tests/wiki-context-scaffold-smoke.sh`, `tests/wiki-graph-neighbors-smoke.sh`, `tests/wiki-import-skill-path-smoke.sh`, `tests/wiki-index-graph-smoke.sh`, `tests/wiki-maintenance-agent-contract-smoke.sh`, `tests/wiki-maintenance-consolidation-smoke.sh`, `tests/wiki-page-type-smoke.sh`, `tests/wiki-readiness-smoke.sh`, `tests/wiki-researcher-contract-smoke.sh`, `tests/wiki-review-context-smoke.sh`, `tests/wiki-routing-exclusion-smoke.sh`, `tests/wiki-section-e2e-smoke.sh`, `tests/wiki-section-graph-smoke.sh`, `tests/wiki-section-index-smoke.sh`, `tests/wiki-session-state-smoke.sh`, `tests/wiki-summary-backfill-smoke.sh`, `tests/wiki-update-check-smoke.sh`
- MCP test files (11): `mcp/obsidian-wiki/tests/bindings.test.ts`, `mcp/obsidian-wiki/tests/config.test.ts`, `mcp/obsidian-wiki/tests/maintenance-summary.test.ts`, `mcp/obsidian-wiki/tests/outbox.test.ts`, `mcp/obsidian-wiki/tests/publish.test.ts`, `mcp/obsidian-wiki/tests/retrieval.test.ts`, `mcp/obsidian-wiki/tests/server.test.ts`, `mcp/obsidian-wiki/tests/skill-card-lifecycle.test.ts`, `mcp/obsidian-wiki/tests/skill-card.test.ts`, `mcp/obsidian-wiki/tests/write-bridge.test.ts`, `mcp/obsidian-wiki/tests/write-tools.test.ts`
- Installed acceptance gates (3): `acceptance/codex-context-budget-installed.sh`, `acceptance/codex-context-isolation-installed.sh`, `acceptance/codex-maintenance-installed.sh`

The generated lists come from the plugin manifests and repository layout. Run `python3 scripts/check_documentation_index.py --check` after adding a component or smoke test.
<!-- generated:documentation-inventory:end -->

## 体积报告

`contracts/developer-doc-routing-v1.json` 保存 #46 前的 required-read 基线（UTF-8 bytes）。用下面命令量化当前路由的分项体积，并确认显著低于基线：

```bash
python3 scripts/docs_context_budget.py --route documentation
python3 scripts/docs_context_budget.py --all
```

该报告沿用 #38 的“按来源、UTF-8 bytes、可比较基线”方法；它只输出文档路径、字节数、占比和阈值，不读取 Wiki 正文、凭据或用户配置。
