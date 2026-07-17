# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in **this repository** (developing grill-adapter itself). It is not the convention block that gets installed into a target project — that lives under `host-adapters/`.

## 必读文档

修改 grill-adapter 功能前，必须先读：

1. `docs/DEVELOPMENT_CN.md`：开发和验收原则、测试分层。
2. `docs/HOST_INTEGRATION_CN.md`：host 适配器模型、grill/plain 约定块、install 模型。
3. `docs/ARCHITECTURE_CN.md`：三层架构、4 触点、引擎不变式。
4. 与当前改动相关的 `skills/*/SKILL.md` / `host-adapters/*/CLAUDE.md`。

**验收铁律：最终验收以 Claude Code 集成路径为准**——真跑 `(可选 lanhu-requirements) → grill-with-docs → to-spec/to-tickets → implement → code-review → update-wiki`，不能只以直接执行 Python 脚本成功为准。

## 常用命令

```bash
./manage.sh install [project] [--host grill|plain]   # 用户级 skills/agents/payload + 项目级 hooks/CLAUDE.md
./manage.sh uninstall [project]
./manage.sh verify [project] [--host grill|plain]
./manage.sh status [project]
./manage.sh mcp-registration                          # 打印通用 shared-wiki MCP 注册 JSON
./manage.sh bootstrap-wiki <project> [--template standard] [--wiki-root project|shared]
./manage.sh init-wiki <project> [hint]
./manage.sh export-wiki-skills <wiki-repo> [--no-graph-ci]
./manage.sh doctor <project>
./manage.sh self-test [project]
./manage.sh release-check <project>                   # 发布前总门
```

单个测试：`bash tests/<name>.sh <grill-adapter-root> [project-root]`（约定：`$1`=grill-adapter 根，`$2`=项目根）。

发布前总检查：`./manage.sh release-check /path/to/project`。

## 架构概览

本仓库是 grill-adapter 的**源码**，不是业务项目代码。它是 host 无关的 Claude Code adapter，通过安装独立 skill/agent/hook + 项目 CLAUDE.md 约定来增强宿主工作流，**绝不 patch 宿主 skill**。

三层：

- **Host 适配器（薄、可插拔、零 skill patch）**：`host-adapters/grill/CLAUDE.md`（默认宿主 grill：约定块）、`host-adapters/plain/CLAUDE.md`（裸 Claude Code）、`host-adapters/hooks.settings.json`（通用 hook 片段）。install 把选定约定块写进目标 `CLAUDE.md`、hook 片段并进目标 `.claude/settings.json`。
- **各子系统的 host 无关触点**：wiki 4 触点（Disclose `skills/wiki-research`、Carry `.wiki-context.json`、Bind `skills/wiki-materialize`、Capture `skills/update-wiki`）；Lanhu Intake（`skills/lanhu-requirements` + `agents/lanhu-*` + `role-prd/`）；source-truth Verify（`skills/source-truth-check`）+ Lint（`hooks/source-truth-lint.sh`）；break-loop（`skills/break-loop`）；`hooks/{wiki-reread,wiki-capture-suggest}.sh` 兜底。
- **引擎（从旧 adapter 原样移植）**：`scripts/*.py`（wiki + source_truth + lanhu 执行层）、`scripts/grill_context_to_candidates.py`（grill→wiki 桥）、`mcp/shared-wiki/`（shared-wiki MCP，读 `CLAUDE_PROJECT_DIR` 自配置）、`.graph.json`（派生物）、`wiki-template/`、`wiki-repo-skills/`、`wiki-repo-ci/`、`contracts/`。

`lib/`：安装引擎（`install.py` 两级安装、`package_manifest.py`、`resolve_install_target.py` 解析用户/项目目标、`export_wiki_skills.py`、`sync_role_prd.py` 从 `agents/lanhu-requirements-analyst.common.md` + `role-prd/*.md` 生成两个 self-contained analyst、`subagent_models.py`）。`manifest.json`：两级包清单（`userLevel.skills/agents/payload` + `projectLevel.hookSettings/hostConventions`）。

## 用户流程模型

见 `docs/USER_FLOW_CN.md`。要点：grill 是主工作流，grill-adapter 只在 grill 各阶段旁挂触点（Disclose/Verify/Carry/Bind/Capture），全靠 CLAUDE.md 约定 + hook，不动 grill 内部。执行阶段只消费 `.adapter/context/<feature-slug>.wiki-context.json` + 有界 1 跳 `depends-on` 闭包；任务完成后由 `update-wiki` 审查回写。

不要把 `python3 scripts/*.py` 描述成普通用户主要入口；它们是 skill/hook 的执行层。

## 开发和验收要求

- 改用户可见行为时，同步检查/更新 `docs/USER_FLOW_CN.md`、相关 skill、`host-adapters/*/CLAUDE.md` 与 `README.md`。
- 改测试原则或验收方式时，同步更新 `docs/DEVELOPMENT_CN.md`。
- 脚本级测试只证执行层，不能替代安装后 skill 集成路径验证。
- 改 hook / install / host 约定后，至少跑 `./manage.sh install`、`verify`、`bash tests/install-two-level-smoke.sh <root>`、`bash tests/host-conventions-smoke.sh <root>`，并对目标项目跑 `./manage.sh release-check`。
- 改 Lanhu 分析规则：改 `agents/lanhu-requirements-analyst.common.md` 或 `role-prd/*.md` **源**，跑 `python3 lib/sync_role_prd.py sync <root>` 重新生成两个 analyst（生成物别手改），再跑 lanhu smoke。
- 占位符只用 `__GRILL_ADAPTER_ROOT__`；禁止残留 `__SUPERPOWER_ADAPTER_*__`。
- 改 Carry/Bind 数据流：引擎**不解析任何 plan/ticket 文档**——task 身份与指纹只来自 host 产出的 ticket roster（`contracts/ticket-roster-v1.example.jsonc`）。要支持新 host，写它的约定块说明 roster 怎么填，**别改引擎**。改完跑 `bash tests/ticket-roster-smoke.sh <root>` + `wiki-context-{scaffold,json-render}-smoke.sh`。

## 不变式（改引擎时逐条别破）

- **markdown 唯一真相源**，`.graph.json` 派生物；不引外部图数据库。
- **执行期不追链**：只消费 `.wiki-context.json` + 有界 1 跳 `depends-on` 闭包（不传递、去重、缺图静默 no-op）。
- **section 级 `[[page#section]]` typed 边** + 渐进披露。
- **shared wiki 每项目绑定**：目标项目 `.shared-adapter/settings.json` 的 `wiki.sharedMcp` 声明连接；MCP 读 `CLAUDE_PROJECT_DIR` 自配置；未声明 fail-closed；换绑/revision 漂移 fail-closed。
- **root-specific 写授权**（wiki 与 source-truth 同款）：`updateExistingPage` 默认 `skip`、`createNewDocument` 默认 `ask`；`--authorized-update`/`--authorized-create` 不绕 `refuse`。
- **shared wiki 中性化**：`blockedTerms`/`blockedPatterns` 机械拒绝已知系统标识。
- **Lanhu evidence-package 边界**：只作输入，不写进 wiki / 最终 spec / 验收。
- **三条铁律**：不 patch 宿主 skill；验收以 Claude Code 集成路径为准；markdown 唯一真相源。
