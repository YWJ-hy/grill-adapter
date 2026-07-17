# grill-adapter 开发与验收指南

本文是 grill-adapter 的**开发与测试原则**。grill-adapter 是一个 **host-agnostic 的 Claude Code adapter**：把项目 wiki、Lanhu 需求录入、source-of-truth 校验、break-loop 调试复盘等能力作为**独立 skill / agent / hook** 挂到宿主上，**绝不 patch 宿主自带的任何 skill**。默认宿主 = grill（`mattpocock/skills`），也兼容裸 Claude Code（plain）。

---

## 1. 必读顺序 / 验收铁律

改动任何**用户可见行为**前，先按序读：

1. `docs/ARCHITECTURE_CN.md`：三层架构、wiki 四触点（Disclose·Carry·Bind·Capture）、Lanhu / source-truth / break-loop 触点、引擎组件、section 图与执行期闭包。
2. `docs/HOST_INTEGRATION_CN.md`：host 适配器模型、grill / plain 约定块全文、hook 配置、install 模型、`__GRILL_ADAPTER_ROOT__` 替换。
3. 与本次改动相关的 `skills/*/SKILL.md`（以及被它调用的 `scripts/*.py`、`agents/*.md`）。

**验收铁律：以 Claude Code 集成路径为准。** adapter 的最终验收，必须在 Claude Code 里真跑一遍完整用户流：

```
(可选 lanhu-requirements) → grill-with-docs → to-spec / to-tickets → implement → code-review → update-wiki
```

并确认各子系统触点确实生效（wiki 被披露/带入/执行期 reread/回写、source-truth 校验与 lint、Lanhu 证据包作输入、break-loop→capture）。**只证 `python3 scripts/*.py` 单跑成功，不算通过验收**——脚本级测试只能证明执行层正确，不能替代安装后的 skill 集成路径验证。

---

## 2. 测试分层（六层，从下到上）

| 层 | 载体 | 证明什么 | 能否替代上层 |
|---|---|---|---|
| ① 脚本级 smoke / regression | `tests/wiki-*.sh`、`tests/source-truth-*.sh`、`tests/lanhu-*.sh`、`tests/shared-wiki-*.sh` 等 | 执行层（引擎脚本）行为正确 | **否**，不能替代集成路径 |
| ② 安装模型测试 | `tests/install-two-level-smoke.sh` | 用户级 payload/skills/agents + 项目级 hook/CLAUDE.md 两级安装、占位符替换、幂等、host 切换、干净卸载 | 否 |
| ③ hook 行为测试 | `tests/hooks-smoke.sh` | 三个 host 无关 hook（wiki-reread / wiki-capture-suggest / source-truth-lint）在事件 JSON 驱动下的注入与静默路径 | 否 |
| ④ 桥测试 | `tests/grill-bridge-smoke.sh` | `scripts/grill_context_to_candidates.py` 把 grill `CONTEXT.md` / `docs/adr` 增量转成 update-wiki 候选行 | 否 |
| ⑤ host 约定测试 | `tests/host-conventions-smoke.sh` | grill / plain 约定块含全部触点、零 patch 不变式、hook 片段接对事件 | 否 |
| ⑥ 集成验收 | Claude Code 真跑（无脚本） | 铁律那条端到端流真正跑通 | 这是**最终门** |

① 是回归网，②~⑤ 是安装/接线网，⑥ 是不可省的人工验收。**下四层全绿 ≠ 通过验收**，⑥ 必须真跑。

### 2.1 ① 层引擎 smoke / regression 清单（按子系统分组）

`tests/` 下近 40 个脚本，`self-test.sh` 一次跑全套。按子系统速查：

- **wiki 引擎 / section 图 / 执行期闭包**：`test-wiki-section.sh`、`wiki-section-{e2e,graph,index}-smoke.sh`、`wiki-context-{json-render,scaffold}-smoke.sh`、`ticket-roster-smoke.sh`（host 无关 ticket roster 边界 + fail-closed）、`wiki-materialize-task-smoke.sh`、`wiki-depends-on-closure-smoke.sh`、`wiki-graph-neighbors-smoke.sh`、`wiki-index-graph-smoke.sh`、`wiki-update-check-smoke.sh`、`wiki-page-type-smoke.sh`、`wiki-card-roles-smoke.sh`、`wiki-summary-backfill-smoke.sh`。
- **wiki 授权 / 导入 / 导出 / 模板 / scaffold**：`wiki-authorization-policy-smoke.sh`、`wiki-import-skill-path-smoke.sh`、`export-wiki-skills-smoke.sh`、`bootstrap-wiki-template-import.sh`、`init-wiki-inventory-smoke.sh`、`scaffold-practice-skill-smoke.sh`。
- **shared wiki（MCP / 绑定 / 中性化）**：`shared-wiki-mcp-{copyable,policy,pr}-smoke.sh`、`shared-wiki-{neutrality,submodule}-smoke.sh`。
- **Lanhu 录入**：`lanhu-{confirmation-gate,contradiction-detection,effective-prd-sanitization,html-settings,scoped-evidence,selective-image-analysis,tree-prd-guardrails,url-root-selection}-smoke.sh`。
- **source-of-truth**：`source-truth-settings-smoke.sh`。

新增引擎行为时，优先扩现有对应 smoke，而不是只加一条 Python 直跑。

---

## 3. 常用命令（全量，来自 `manage.sh`）

在 grill-adapter 源码根目录运行：

```bash
./manage.sh install [project-root] [--host grill|plain]   # 装用户级 skills/agents/payload；如给 project 则接线该项目
./manage.sh uninstall [project-root]                       # 卸载用户级安装；如给 project 则解除接线
./manage.sh verify [project-root] [--host grill|plain]     # 校验安装（用户级；给 project 则连项目一起校验）
./manage.sh status [project-root]                          # 报告安装 + 绑定状态
./manage.sh mcp-registration                               # 打印通用（不含 repo）的 shared-wiki MCP 注册 JSON
./manage.sh bootstrap-wiki <project-root> [--template name] [--wiki-root project|shared]
./manage.sh init-wiki <project-root> [analysis-hint]       # 产出项目 inventory 供 agent 主导 wiki 初始化
./manage.sh export-wiki-skills <wiki-repo-root> [--no-graph-ci]
./manage.sh doctor <project-root>                          # 诊断安装 + 本项目 shared-wiki 绑定
./manage.sh self-test [project-root]                       # 跑 smoke/regression 全套
./manage.sh release-check <project-root>                   # 发布前总门（install → verify → tests）
```

跑**单个**测试（约定：`$1` = grill-adapter 根，`$2` = 项目根）：

```bash
bash tests/<name>.sh <grill-adapter-root> [project-root]
# 例：
bash tests/install-two-level-smoke.sh "$PWD"
bash tests/wiki-materialize-task-smoke.sh "$PWD" /path/to/project
bash tests/host-conventions-smoke.sh "$PWD"
```

---

## 4. 测试约定

- 每个 `tests/*.sh` 都接 `(grill-adapter-root, project-root)` 两个参数：`$1` 缺省时回退到仓库根（`tests/..`），`$2` 是可选的项目根。测试自己在 `mktemp -d` 里造沙盒，不碰真实 `~/.claude` 或用户项目。
- `self-test.sh` 跑 `tests/*.sh` **全套**；调用时**未给 project-root 就自建一个临时项目**（`mktemp -d` + `git init`），退出时清理。
- `release-check.sh` 是**发布前总门**，非破坏（安装进临时 sandbox home + 临时项目，传入的 `<project-root>` 只被 `doctor` 只读使用）。它按序执行：
  1. **py_compile**：`scripts/*.py` + `lib/*.py` 全编译。
  2. **role-prd sync 幂等**：跑 `lib/sync_role_prd.py sync`，再查 `agents/lanhu-*-requirements-analyst.md` 是否有 git 漂移（有漂移即 FAIL，提示提交重新生成的 analyst）。
  3. **占位符残留检查**：机械 `grep` `scripts/`、`skills/`、`agents/`、`lib/`、`hooks/`、`contracts/` 里的 `__SUPERPOWER_ADAPTER` 残留。
  4. **shared-wiki MCP build + test**：`mcp/shared-wiki` 里 `npm install && npm run build && npm test`（无 npm 则 SKIP）。
  5. **沙盒 install / verify**：临时 `CLAUDE_CONFIG_DIR` + `GRILL_ADAPTER_HOME`，`install --host grill` 后 `verify`。
  6. **全套 smoke**：跑 `self-test.sh`。
  7. **doctor**：对传入项目只读诊断。

任一步 FAIL，`release-check` 整体 FAIL。

---

## 5. 改不同层的验证要求

- **改 skill**（`skills/*/SKILL.md`）→ 安装 adapter 后，在 Claude Code 里**从该 skill 的入口**真正走一遍用户路径验证；不要只跑它背后的 Python。
- **改 hook 或 install 逻辑**（`hooks/*.sh`、`lib/install.py`、`host-adapters/hooks.settings.json`）→ 跑 `tests/install-two-level-smoke.sh` + `tests/hooks-smoke.sh`，并 `./manage.sh install` + `./manage.sh verify` 走一遍。
- **改引擎脚本**（`scripts/wiki_*.py`、`scripts/source_truth_*.py`）→ 跑相关 `tests/wiki-*.sh` / `tests/source-truth-*.sh` smoke，再 `./manage.sh release-check <project>` 兜底。
- **改 host 约定块**（`host-adapters/grill/CLAUDE.md`、`host-adapters/plain/CLAUDE.md`）→ 跑 `tests/host-conventions-smoke.sh`，并**手动把约定块粘进目标项目的 `CLAUDE.md`** 在真实宿主下验证触点措辞可用。
- **改 Lanhu 分析 agent** → **改源，不改生成物**：编辑共享骨架 `agents/lanhu-requirements-analyst.common.md` 或 `role-prd/{frontend,backend}.md`，然后跑 `python3 lib/sync_role_prd.py sync <root>` 重新生成两个 analyst（`agents/lanhu-frontend-requirements-analyst.md`、`agents/lanhu-backend-requirements-analyst.md`），再跑 Lanhu 相关 smoke（`tests/lanhu-*.sh`）。**生成的 analyst 文件不要手改**——`release-check` 步骤 2 会因漂移 FAIL。

---

## 6. 不变式与授权门（改引擎时逐条别破，详见 `docs/ARCHITECTURE_CN.md`）

- **markdown 唯一真相源**：`.graph.json` 是派生物，**不引外部图数据库**。
- **执行期有界 1 跳 `depends-on` 闭包**：执行期只消费 `.wiki-context.json` sidecar + 有界 1 跳闭包（不传递、去重、缺图静默 no-op），绝不追链。
- **section 级 `[[page#section]]` typed 边** + 渐进披露。
- **shared wiki 每项目绑定，fail-closed**：消费项目在自己的 `.shared-adapter/settings.json` 的 `wiki.sharedMcp`（`repoUrl`/`baseBranch`/`remote`/`wikiRoot`/`displayRoot`/`draftPr`）声明连接；MCP 读 `CLAUDE_PROJECT_DIR` 自配置；未声明即 fail-closed（无 MCP shared wiki）。换绑 / revision 漂移也 fail-closed。
- **root-specific 写授权门**：`.adapter/settings.json` 管 project wiki，`.shared-adapter/settings.json` 管 shared wiki。二者的 `wiki.updateAuthorization`：`updateExistingPage` 默认 **skip**，`createNewDocument` 默认 **ask**（可选 `skip` / `ask` / `refuse`）。执行层的 `--authorized-update` / `--authorized-create` 只表示 skill 已取得授权，**不能绕过 `refuse`**。source-truth 的 lint / edit 门同构，授权标志同样不绕硬门。
- **shared wiki 中性化**：`.shared-adapter/settings.json` 的 `wiki.sharedNeutrality.blockedTerms` / `blockedPatterns` 机械拒绝系统特有标识；shared wiki 不得含内部 URL、环境名、本地路径、部署实例或专属业务规则。
- **Lanhu evidence 边界**：Lanhu 证据包（`.lanhu/.../index.md`）**只作 Superpowers/grill 的输入**，不写进 wiki、不进最终 spec、不进验收。

---

## 7. 占位符规则

- 源码里所有指向 payload 根的路径统一用占位符 **`__GRILL_ADAPTER_ROOT__`**。
- `install` 时把它**替换为真实 payload 根**（用户级安装的 `GRILL_ADAPTER_HOME`，例如 `~/.claude/grill-adapter`），装出去的 skill / hook 里不得再有该占位符残留。
- **禁止残留任何 `__SUPERPOWER_ADAPTER_*__`**（旧 superpower-adapter 的占位符）。这是移植遗留的机械红线，`release-check` 步骤 3 会 `grep` 检查残留并在命中时 FAIL。

---

> 一句话记牢：**下四层测试证接线，① 证引擎，⑥（Claude Code 真跑）才是验收。改 Lanhu analyst 改源不改生成物，占位符只认 `__GRILL_ADAPTER_ROOT__`。**
