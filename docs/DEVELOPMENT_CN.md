# grill-adapter 开发与验收指南

本文是 grill-adapter 的**开发与测试原则**。grill-adapter 是一个 **host-agnostic 的 Claude Code/Codex adapter**：把项目 wiki、source-of-truth 校验、break-loop 调试复盘等能力作为独立 skill / agent-role / hook 挂到宿主上，**绝不 patch 宿主自带的任何 skill**。

---

## 1. 必读顺序 / 验收铁律

改动任何**用户可见行为**前，先按序读：

1. `docs/ARCHITECTURE_CN.md`：三层架构、wiki 四触点（Disclose·Carry·Bind·Capture）、source-truth / break-loop 触点、引擎组件、section 图与执行期闭包。
2. `docs/HOST_INTEGRATION_CN.md`：host 适配器模型、grill / plain 约定块全文、hook 配置、plugin 安装模型、`${CLAUDE_PLUGIN_ROOT}` 替换。
3. 与本次改动相关的 `skills/*/SKILL.md`（以及被它调用的 `scripts/*.py`、`agents/*.md`）。

**验收铁律：以安装后的真实集成路径为准。** 改动只涉及某一运行时时，必须在该运行时真跑完整用户流；改共享 skill/hook/MCP 时，Claude Code 与 Codex 都必须验收：

```
grill-with-docs → to-spec / to-tickets → implement → code-review → update-wiki
```

并确认各子系统触点确实生效（wiki 被披露/带入/执行期 reread/回写、source-truth 校验与 lint、break-loop→capture）。**只证 `python3 scripts/*.py` 单跑成功，不算通过验收**——脚本级测试只能证明执行层正确，不能替代安装后的 skill 集成路径验证。

---

## 2. 测试分层（六层，从下到上）

| 层 | 载体 | 证明什么 | 能否替代上层 |
|---|---|---|---|
| ① 脚本级 smoke / regression | `tests/wiki-*.sh`、`tests/source-truth-*.sh`、`tests/shared-wiki-*.sh` 等 | 执行层（引擎脚本）行为正确 | **否**，不能替代集成路径 |
| ② 项目接线测试 | `tests/install-project-wiring-smoke.sh` | `install` 只写/剥 `<project>/CLAUDE.md`、`AGENTS.md` 的约定块；覆盖 runtime/host 切换、幂等、干净卸载与零路径 | 否 |
| ③ hook 行为测试 | `tests/hooks-smoke.sh` | 三个 host 无关 hook（wiki-reread / wiki-capture-suggest / source-truth-lint）在事件 JSON 驱动下的注入与静默路径 | 否 |
| ④ 桥测试 | `tests/wiki-candidate-journal-smoke.sh`、`tests/grill-bridge-smoke.sh` | journal append/supersede/outcome/fold 的公开 CLI 契约；grill `CONTEXT.md` / `docs/adr` 增量批量转成标准 candidate events | 否 |
| ⑤ host 约定测试 | `tests/host-conventions-smoke.sh` | grill / plain 约定块含全部触点、零 patch 不变式、skill 调用带 `grill-adapter:` 命名空间、块内零安装路径 | 否 |
| ⑥ 集成验收 | 安装后 Claude Code/Codex 真跑 | 铁律那条端到端流真正跑通 | 这是**最终门** |

① 是回归网，②~⑤ 是安装/接线网，⑥ 是不可省的人工验收。**下四层全绿 ≠ 通过验收**，⑥ 必须真跑。

### 2.1 ① 层引擎 smoke / regression 清单（按子系统分组）

`tests/` 下近 40 个脚本，`self-test.sh` 一次跑全套。按子系统速查：

- **wiki 引擎 / readiness / section 图 / 执行期闭包**：`test-wiki-section.sh`、`wiki-section-{e2e,graph,index}-smoke.sh`、`wiki-context-{json-render,scaffold}-smoke.sh`、`obsidian-wiki-context-v6-smoke.sh`（metadata-only Obsidian Carry + v6 materialize fail-closed）、`adr-projection-identity-smoke.sh`（ADR Carry/Bind authority identity、drift 与 implement/review fail-open）、`ticket-roster-smoke.sh`（host 无关 ticket roster 边界 + fail-closed）、`wiki-readiness-smoke.sh`（direct issue/manual 单任务 roster、formal reuse、fail-open receipt、fingerprint drift）、`wiki-review-context-smoke.sh`（reviewer-only Card、双轴共享 handoff、unknown/non-ready/materialize failure fail-open）、`wiki-materialize-task-smoke.sh`、`wiki-depends-on-closure-smoke.sh`、`wiki-graph-neighbors-smoke.sh`、`wiki-index-graph-smoke.sh`、`wiki-update-check-smoke.sh`、`wiki-page-type-smoke.sh`、`wiki-card-roles-smoke.sh`、`wiki-summary-backfill-smoke.sh`。
- **wiki 授权 / 导入 / 导出 / 模板 / scaffold / 迁移**：`wiki-authorization-policy-smoke.sh`（含 cutover archive 的 update/import/migration 写保护）、`wiki-import-skill-path-smoke.sh`、`export-wiki-skills-smoke.sh`、`bootstrap-wiki-template-import.sh`（含 archive bootstrap 写保护）、`init-wiki-inventory-smoke.sh`、`scaffold-practice-skill-smoke.sh`、`obsidian-wiki-migration-plan-smoke.sh`（source/target 快照、update 审核 hash、逐项决策、确认门、确定性与零写入）、`obsidian-wiki-migration-apply-smoke.sh`（首写前专用 branch、持久 intent、崩溃恢复、CAS seed/finalize、publisher 对账恢复、typed edge/Card、幂等 PR、immutable-plan coverage、source/binding drift、merged-base verify、schema-v5 与 scoped cutover 门、legacy archive 不改写）。
- **shared wiki（MCP / 绑定 / 中性化）**：`shared-wiki-mcp-{copyable,policy,pr}-smoke.sh`、`shared-wiki-{neutrality,submodule}-smoke.sh`。Obsidian Source bindings 的 MCP contract 在 `mcp/obsidian-wiki/tests/` 中覆盖。
- **Obsidian rollout 运维面**：`obsidian-runtime-operations-smoke.sh` 覆盖 provider-aware bootstrap、doctor adoption state/health exit、release gate、host recovery 约定、plugin metadata 与最终验收文档。
- **source-of-truth**：`source-truth-settings-smoke.sh`。

新增引擎行为时，优先扩现有对应 smoke，而不是只加一条 Python 直跑。

---

## 3. 常用命令（全量，来自 `manage.sh`）

grill-adapter 同时提供 Claude Code 与 Codex plugin manifest。共享 skills/hooks/MCP；Claude Code 原生注册 `agents/`，Codex 由入口 skill 派生相同角色的通用 sub-agent。`manage.sh` 只管目标项目 `CLAUDE.md`/`AGENTS.md` 约定块。

开发期不必安装即可加载 plugin 并核对组件清单：

```bash
claude --plugin-dir "$PWD" plugin details grill-adapter   # 应报 13 skills / 1 agent / 3 hooks / 2 MCP servers
codex plugin marketplace add "$PWD"                       # 开发期本地 marketplace
codex plugin add grill-adapter@grill-adapter
```

在 grill-adapter 源码根目录运行：

```bash
./manage.sh install <project-root> [--host grill|plain] [--runtime claude|codex|both]
./manage.sh uninstall <project-root> [--runtime claude|codex|both]
./manage.sh verify <project-root> [--host grill|plain]     # 校验该项目已接线
./manage.sh status [project-root]                          # 报告 plugin 启用（仅提示性）+ 约定块状态
./manage.sh bootstrap-wiki <project-root> [--template name] [--wiki-root project|shared]  # 仅 legacy runtime
./manage.sh init-wiki <project-root> [analysis-hint]       # 产出项目 inventory 供 agent 主导 wiki 初始化
./manage.sh export-wiki-skills <wiki-repo-root> [--no-graph-ci]
./manage.sh doctor <project-root>                          # 诊断 active provider + adoption state；Obsidian unhealthy 非零退出
./manage.sh self-test [project-root]                       # 跑 smoke/regression 全套（<project-root> 是**项目**根，见 §4）
./manage.sh release-check <project-root>                   # 发布前总门（plugin 加载 → 接线 → verify → tests）
```

### Windows / macOS shell 入口

macOS/Linux 直接使用上面的 `.sh` 命令。Windows 的 `bash` 可能只是
`C:\Windows\System32\bash.exe` WSL shim；当 WSL 没有 `/bin/bash` 时不要调用它。
项目提供 PowerShell 转发入口，自动探测 Git Bash、MSYS2 或 Cygwin，并保留同一套
退出码和参数：

```powershell
.\manage.ps1 install <project-root> --host grill --runtime both
.\manage.ps1 self-test
.\release-check.ps1 <project-root>
.\tests\run-smoke.ps1 -Name install-project-wiring-smoke.sh
```

resolver 会实际执行 `bash -lc 'exit 0'` 排除 WSL shim。若机器上有多个 Bash，可设置
`GRILL_ADAPTER_BASH` 为真实 `bash.exe` 的绝对路径。找不到可用 Bash 时，入口会明确提示
安装 Git for Windows；无需修改现有 smoke 的 Bash 实现。

跑**单个**测试（约定：`$1` = grill-adapter 根，`$2` = 项目根）：

```bash
bash tests/<name>.sh <grill-adapter-root> [project-root]
# 例：
bash tests/install-project-wiring-smoke.sh "$PWD"
bash tests/wiki-materialize-task-smoke.sh "$PWD" /path/to/project
bash tests/host-conventions-smoke.sh "$PWD"
```

---

## 4. 测试约定

- 每个 `tests/*.sh` 都接 `(grill-adapter-root, project-root)` 两个参数：`$1` 缺省时回退到仓库根（`tests/..`），`$2` 是可选的项目根。测试自己在 `mktemp -d` 里造沙盒，不碰真实 `~/.claude` 或用户项目。
- `self-test.sh` 跑 `tests/*.sh` **全套**；调用时**未给 project-root 就自建一个临时项目**（`mktemp -d` + `git init`），退出时清理。
  **`self-test.sh <project-root>` 的 `$1` 是「项目」根，不是仓库根**——别把 grill-adapter 仓库根传进去：bootstrap / import 类测试会真往传入项目里播 wiki，污染仓库。要么不传参（自建临时项目），要么传一个一次性目录。
- `release-check.sh` 是**发布前总门**，非破坏（plugin 用 `--plugin-dir` 只读加载，接线打在临时项目上，传入的 `<project-root>` 只被 `doctor` 只读使用）。它按序执行：
  1. **py_compile**：`scripts/*.py` + `lib/*.py` 全编译。
  2. **已移除能力残留检查**：扫描所有 tracked product surfaces，任何已删除能力的名称残留都直接 FAIL。
  3. **占位符残留检查**：机械 `grep` `__SUPERPOWER_ADAPTER` 残留，以及 `skills/`、`agents/`、`host-adapters/` 里已作废的 `__GRILL_ADAPTER_ROOT__`。
  4. **所有 MCP typecheck + build + test**：每个 `mcp/*` 包运行 `npm install && npm run typecheck && npm run build && npm test`（无 npm 则 SKIP）。`build` 是 esbuild 打包、**不做类型检查**，所以 `typecheck` 必须单独跑。
  5. **MCP bundle 已提交且与 src 一致**：每个插件注册 MCP 的 `dist/index.js` 必须存在且在步骤 4 重新构建后无 git 漂移。
  6. **plugin 组件清单**：Claude 必须报满 13 skills / 1 agent / 3 hooks / 2 MCP；`tests/codex-plugin-smoke.sh` 必须通过 manifest 校验、隔离 marketplace 安装，并从 `codex debug prompt-input` 验证安装后模型可见的 13 个 skills。
  7. **沙盒项目接线 + verify**：对临时项目 `install --host grill` 后 `verify`。
  8. **全套 smoke**：跑 `self-test.sh`。
  9. **doctor**：对传入项目只读诊断；若 active provider 是 Obsidian，bundle/status/health 任一失败都会卡 release-check。

任一步 FAIL，`release-check` 整体 FAIL。

真实 Desktop、installed Claude Code/Codex、shadow-validation、migration verify/cutover 与中断恢复的最终验收记录按 `docs/OBSIDIAN_ACCEPTANCE_CN.md` 执行；smoke 和直接 CLI 不替代它。

### 4.1 隔离 Codex 集成验收的 provider 配置

`tests/codex-plugin-smoke.sh` 的隔离 `CODEX_HOME` 验证 marketplace/plugin 安装，并通过 `codex debug prompt-input` 检查安装后模型可见的 skill 清单；该命令不发模型请求。要在隔离 home 里继续跑**模型驱动**的 skill 集成验收，除了认证，还必须保留当前会话的 effective `model`、`model_provider` 及对应 `[model_providers.<name>]` 配置；只复制/链接 `auth.json` 不够。

启动输出里的 `model:` 与 `provider:` 是验收前置断言。若自定义 provider 的模型在隔离 home 中退回 `provider: openai`，CLI 可能表现为反复 `stream disconnected`，这不是 plugin/skill/hook 故障。先修复隔离配置，再判断集成路径；不得通过把完整用户配置或凭据提交进测试 fixture 来解决。远端 plugin catalog 在 API-key 登录下产生的同步 warning 与本地 plugin skill 执行是两条独立路径，也不能拿它替代实际 sampling/skill 结果。

---

## 5. 改不同层的验证要求

- **改 skill**（`skills/*/SKILL.md`）→ 加载 plugin 后，在 Claude Code 里**从该 skill 的入口**真正走一遍用户路径验证；不要只跑它背后的 Python。
- **改 hook**（`hooks/*.sh`、`hooks/hooks.json`）→ 跑 `tests/hooks-smoke.sh`、`tests/codex-plugin-smoke.sh`，并用 Claude plugin details 确认 3 个 hook 仍被发现。
- **改接线逻辑**（`lib/install.py`、`manifest.json`）→ 跑 `tests/install-project-wiring-smoke.sh`，并对 `--runtime claude|codex|both` 走 install + verify。
- **改引擎脚本**（`scripts/wiki_*.py`、`scripts/source_truth_*.py`）→ 跑相关 `tests/wiki-*.sh` / `tests/source-truth-*.sh` smoke，再 `./manage.sh release-check <project>` 兜底。
- **改 host 约定块**（`host-adapters/*/{CLAUDE,AGENTS}.md`）→ 跑 `tests/host-conventions-smoke.sh`，并在对应真实运行时验证。块里不许出现安装路径；Claude 用 `/grill-adapter:<skill>`，Codex 用 `$grill-adapter:<skill>`。
- **改 shared-wiki MCP**（`mcp/shared-wiki/src/`）→ `npm run typecheck` + `npm run build` + `npm test`，并**把重新构建的 `dist/index.js` 一起提交**。`build` 是 esbuild 单文件打包（SDK/zod 内联），plugin 缓存**没有安装期构建步骤**，`.mcp.json` 直接启动仓库里提交的这份 bundle——bundle 不提交或与 src 漂移，用户拿到的就是旧代码，`release-check` 步骤 5 会 FAIL。
- **改 Obsidian MCP/CLI**（`mcp/obsidian-wiki/src/`）→ 同样运行 `npm run typecheck` + `npm run build` + `npm test`，提交 `dist/index.js`；`package.json` 同时定义可发布的 `obsidian-wiki` CLI，发布前用 `npm pack --dry-run` 确认 tarball 只包含 `dist/`、README 和 package metadata。

---

## 6. 不变式与授权门（改引擎时逐条别破，详见 `docs/ARCHITECTURE_CN.md`）

- **markdown 唯一真相源**：`.graph.json` 是派生物，**不引外部图数据库**。
- **执行期有界 1 跳 `depends-on` 闭包**：执行期只消费 `.wiki-context.json` sidecar + 有界 1 跳闭包（不传递、去重、缺图静默 no-op），绝不追链。
- **section 级 `[[page#section]]` typed 边** + 渐进披露。
- **shared wiki 每项目绑定，fail-closed**：消费项目在自己的 `.shared-adapter/settings.json` 的 `wiki.sharedMcp`（`repoUrl`/`baseBranch`/`remote`/`wikiRoot`/`displayRoot`/`draftPr`）声明连接；MCP 读 `CLAUDE_PROJECT_DIR` 自配置；未声明即 fail-closed（无 MCP shared wiki）。换绑 / revision 漂移也 fail-closed。
- **root-specific 写授权门**：`.adapter/settings.json` 管 project wiki，`.shared-adapter/settings.json` 管 shared wiki。二者的 `wiki.updateAuthorization`：`updateExistingPage` 默认 **skip**，`createNewDocument` 默认 **ask**（可选 `skip` / `ask` / `refuse`）。执行层的 `--authorized-update` / `--authorized-create` 只表示 skill 已取得授权，**不能绕过 `refuse`**。source-truth 的 lint / edit 门同构，授权标志同样不绕硬门。
- **shared wiki 中性化**：`.shared-adapter/settings.json` 的 `wiki.sharedNeutrality.blockedTerms` / `blockedPatterns` 机械拒绝系统特有标识；shared wiki 不得含内部 URL、环境名、本地路径、部署实例或专属业务规则。

---

## 7. 占位符规则

- **共享 plugin 内容里**（`skills/`、`agents/`、`hooks/hooks.json`、`.mcp.json`）继续统一用裸 token **`${CLAUDE_PLUGIN_ROOT}`**。Claude Code 原生替换，Codex 兼容加载层也识别；不要另造一份只含 `PLUGIN_ROOT` 的 skills 树。
- **plugin 内容之外不许用它**。`host-adapters/*/{CLAUDE,AGENTS}.md` 会写进目标项目，不是 plugin 内容；这些块里根本不放安装路径。
- **`__GRILL_ADAPTER_ROOT__` 已作废**，`${CLAUDE_PLUGIN_ROOT}` 取代它。没有任何安装期改写会再碰这些文件，残留的占位符会原样发给用户，`release-check` 步骤 3 会在 `skills/`、`agents/`、`host-adapters/` 里 `grep` 到即 FAIL。
- **禁止残留任何 `__SUPERPOWER_ADAPTER_*__`**（旧 superpower-adapter 的占位符）。这是移植遗留的机械红线，`release-check` 步骤 3 会 `grep` 检查残留并在命中时 FAIL。

---

> 一句话记牢：**下四层测试证接线，① 证引擎，⑥（Claude Code 真跑）才是验收。改 MCP 连 `dist/` 一起提交，plugin 内容里占位符只认 `${CLAUDE_PLUGIN_ROOT}`。**
