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

并确认各子系统触点确实生效（wiki 被披露/Carry/freeze/角色化消费/回写、source-truth 校验与 lint、break-loop→capture）。**只证 `python3 scripts/*.py` 单跑成功，不算通过验收**——脚本级测试只能证明执行层正确，不能替代安装后的 skill 集成路径验证。

---

## 2. 测试分层（六层，从下到上）

| 层 | 载体 | 证明什么 | 能否替代上层 |
|---|---|---|---|
| ① 脚本级 smoke / regression | `tests/wiki-*.sh`、`tests/source-truth-*.sh` 等 | 执行层（引擎脚本）行为正确 | **否**，不能替代集成路径 |
| ② 项目接线测试 | `tests/install-project-wiring-smoke.sh` | `install` 只写/剥 `<project>/CLAUDE.md`、`AGENTS.md` 的约定块；覆盖 runtime/host 切换、幂等、干净卸载与零路径 | 否 |
| ③ hook / 激活行为测试 | `tests/hooks-smoke.sh`、`tests/project-opt-in-smoke.sh` | 三个 host 无关 hook 在事件 JSON 驱动下的注入与静默路径；全局 plugin 在 standalone grill 项目中的零写入，以及 workflow skill 的 marker/settings/显式调用 activation gate | 否 |
| ④ Journal / Outbox 测试 | `tests/wiki-candidate-journal-smoke.sh`、`mcp/obsidian-wiki/tests/outbox.test.ts`、`tests/grill-bridge-smoke.sh` | journal queued/legacy receipt 生命周期、Capture Plan snapshot/root policy/中断恢复、project-scoped hidden-ref Outbox、immutable corrections/semantic merge provenance、digest review、conflict defer + unrelated publish、可恢复 batch publish 与 merge 后 active；grill 增量桥 | 否 |
| ⑤ host 约定测试 | `tests/host-conventions-smoke.sh` | 单一规范源同步四个 grill/plain × Claude/Codex 薄 router；含全部触点、零 patch/路径、运行时命名空间和固定 4,096-byte block 预算 | 否 |
| ⑥ 集成验收 | 安装后 Claude Code/Codex 真跑 | 铁律那条端到端流真正跑通 | 这是**最终门** |

① 是回归网，②~⑤ 是安装/接线网，⑥ 是不可省的人工验收。**下四层全绿 ≠ 通过验收**，⑥ 必须真跑。

### 2.1 ① 层引擎 smoke / regression 清单（按子系统分组）

`tests/` 下近 40 个脚本，`self-test.sh` 一次跑全套。按子系统速查：

- **wiki 引擎 / readiness / section 图**：`test-wiki-section.sh`、`wiki-section-{e2e,graph,index}-smoke.sh`、`wiki-context-scaffold-smoke.sh`、`obsidian-wiki-context-v6-smoke.sh`（metadata-only Obsidian Carry、freshness 校验 + freeze 时 materialize fail-closed）、`adr-projection-identity-smoke.sh`（ADR Carry/freeze authority identity、drift 与 implement/review fail-open）、`ticket-roster-smoke.sh`（host 无关 ticket roster 边界 + fail-closed）、`wiki-readiness-smoke.sh`（direct issue/manual 单任务 roster、disabled terminal、late Carry 的双角色原子提交/失败清理、formal reuse、hard/soft/1 跳闭包 freshness 跨双角色 schema-v2 Markdown freeze/消费、v1 快照拒绝、receipt/body digest、fingerprint drift）、`wiki-session-state-smoke.sh`（schema-v2 lifecycle/report counts、最多三条跨 feature action、digest drift/malformed 拒绝、双运行时命令前缀、schema-v1 continuation 与 SessionStart 回退）、`wiki-review-context-smoke.sh`（reviewer-only Card、双轴共享 handoff、unknown/non-ready/legacy materialize failure fail-open）、`wiki-graph-neighbors-smoke.sh`、`wiki-index-graph-smoke.sh`、`wiki-update-check-smoke.sh`、`update-wiki-atomic-note-targeting-smoke.sh`（Obsidian atomic Note 的 update/create/defer target 契约）、`wiki-page-type-smoke.sh`、`wiki-summary-backfill-smoke.sh`。
- **wiki 初始化 / 授权 / 导入 / 导出 / 模板 / scaffold / 迁移**：`setup-init-obsidian-skill-smoke.sh`（双 npm 包检查、等待/恢复边界、legacy 授权路由）、`wiki-authorization-policy-smoke.sh`（含 cutover archive 的 update/import/migration 写保护）、`wiki-import-skill-path-smoke.sh`、`export-wiki-skills-smoke.sh`、`bootstrap-wiki-template-import.sh`（含 archive bootstrap 写保护）、`init-wiki-inventory-smoke.sh`、`scaffold-practice-skill-smoke.sh`、`obsidian-wiki-migration-plan-smoke.sh`（source/target 快照、update 审核 hash、逐项决策、确认门、确定性与零写入）、`obsidian-wiki-migration-apply-smoke.sh`（首写前专用 branch、持久 intent、崩溃恢复、CAS seed/finalize、publisher 对账恢复、typed edge/Card、幂等 PR、immutable-plan coverage、source/binding drift、merged-base verify、schema-v5 与 scoped cutover 门、legacy archive 不改写）、`migrate-wiki-repartition-smoke.sh`（legacy section 重组与 Obsidian Note maintenance/repartition 契约）。
- **Obsidian runtime（绑定 / 中性化 / MCP）**：`mcp/obsidian-wiki/tests/` 与 `obsidian-runtime-operations-smoke.sh` 覆盖 Source bindings、policy、读取和写桥 contract；`retrieval.test.ts` 还以大型 synthetic Source 验证 search 硬 limit / scope-bound cursor、稳定顺序、catalog revision cache、零 catalog 全文 read、正式 stable batch reread，以及 deterministic clock 下 fresh/review-due/expired 与 base synchronization 的正交组合；`maintenance-summary.test.ts` 覆盖空/多 binding、freshness/contradiction、correction/Capture lifecycle、deterministic ordering、identity/candidate 上限、private consolidation input、正文排除、并发改写与 malformed journal fail-closed；`wiki-maintenance-agent-contract-smoke.sh` 覆盖 digest-bound audit role、dispatch/wait、report schema/compaction、正文/路径字段拒绝、calendar timestamp、read budget 与 symlink 边界，`wiki-maintenance-consolidation-smoke.sh` 覆盖独立 candidate consolidation contract 的等价/矛盾/独立分类、identity coverage、truncation/evidence caveat、binding/journal drift 与原子恢复。真实 installed Codex audit、candidate consolidation、带两个矛盾 queued draft 的 Outbox consolidation，以及 audit role digest drift 由 `GRILL_ADAPTER_RUN_CODEX_ACCEPTANCE=1 bash acceptance/codex-maintenance-installed.sh "$PWD"` 显式运行：脚本通过 PTY 驱动四次交互式 Codex CLI，不使用 `codex exec`，机械核对每次 descriptor/digest、唯一 child + wait、child-first loader、mode 最小工具权限、正文隔离、Outbox correction 后 digest 一致性、零 formal Wiki/Git 写入以及 drift 时 fail-closed，也不计作普通 smoke。Issue #35 的完整上下文隔离门由 `GRILL_ADAPTER_RUN_CODEX_ACCEPTANCE=1 bash acceptance/codex-context-isolation-installed.sh "$PWD"` 显式运行：它先在安装后的 grill host 中分别 sampling `grill-with-docs`、`to-spec`、`to-tickets`、`implement`、`code-review` 与 `diagnosing-bugs`，从 rollout 验证每个 stage 的 router 入口，再覆盖 researcher、由 installed parent 执行的 Carry/freeze/readiness、主 session 直接实现、隔离 implementer、双轴 reviewer、Capture、research/maintenance dispatch failure 与 binding-broken 后用户继续，并复用前述 maintenance 门；最终从 rollout/tool call、正式产物和两个 formatter 的实际输出生成六项 evaluation metrics。`tests/codex-context-isolation-acceptance-contract-smoke.sh` 只固定这条 opt-in 门的机器契约，不能替代真实 sampling。
- **Codex 上下文预算**：`bash acceptance/codex-context-budget-installed.sh "$PWD"` 在隔离 `CODEX_HOME` 和临时项目中真实安装 plugin，用 `codex debug prompt-input` 分别量化全局 skill catalog、项目 host 约定，以及由版本化 resource roster 组装后经 Codex 实际渲染的 research/readiness/Capture/Maintenance stage payload；用 live MCP `tools/list` 量化逐工具 schema。readiness 取包含 late Carry 的最坏路径，并在报告中列出实际 roster。research/readiness roster 只量 coordinator payload；child-side role loader 后 researcher role 正文不得重新进入其中，role 的实际加载由 installed rollout 验收单独证明。报告只含稳定名称、UTF-8 字节数、占比、来源、阈值和状态，不保存 prompt 正文、Wiki 正文、路径、凭据或用户配置。resource roster 与默认阈值在 `contracts/codex-context-budget-v1.json`；`projectHostInstructions` 的默认固定上限是 **4,096 bytes**。用 `--thresholds <json>` 或 `GRILL_ADAPTER_CONTEXT_BUDGETS=<json>` 临时覆盖限额，但不能改写 roster。`tests/codex-context-budget-smoke.sh` 固定报告、隐私和失败诊断契约；预算门只防上下文体积回归，**不能替代** plugin smoke 或安装后模型行为验收。
- **Obsidian rollout 运维面**：`obsidian-runtime-operations-smoke.sh` 覆盖 provider-aware bootstrap、doctor adoption state/health exit、release gate、host recovery 约定、plugin metadata 与最终验收文档。
- **npm 自动发布**：`npm-release-plan-smoke.sh` 覆盖 root-only、Obsidian 双包、test-only 与手动强制发布的变更分类；GitHub Actions 只对 package payload 自动递增 patch 并发布。
- **source-of-truth**：`source-truth-settings-smoke.sh`。

新增引擎行为时，优先扩现有对应 smoke，而不是只加一条 Python 直跑。

---

## 3. 常用命令（全量，来自 `manage.sh`）

grill-adapter 同时提供 Claude Code 与 Codex plugin manifest。共享 skills/hooks/MCP；Claude Code 原生注册 `agents/`，Codex 由入口 skill 派生相同角色的通用 sub-agent。`manage.sh` 只管目标项目 `CLAUDE.md`/`AGENTS.md` 约定块。

开发期不必安装即可加载 plugin 并核对组件清单：

```bash
claude --plugin-dir "$PWD" plugin details grill-adapter   # 应报 13 skills / 5 agents / 3 hooks / 1 MCP server
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

根级 npm 发行包的版本和 tarball 验收：

```bash
npm run pack:dry
npm run test:package
npm version patch|minor|major
npm publish --access public
```

`npm version` 是唯一版本入口，会同步 `.claude-plugin/plugin.json`、`.codex-plugin/plugin.json` 和 `manifest.json`。`prepack` 会拒绝版本漂移、缺少插件运行时文件或错误的发布内容；`test:package` 会从实际 tarball 安装后调用 `grill-adapter` CLI。npm 包只承载运行时 payload，`self-test` / `release-check` 仍在源码仓库中执行。

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
  6. **plugin 组件清单**：Claude 必须报满 13 skills / 5 agents / 3 hooks / 1 MCP；`tests/codex-plugin-smoke.sh` 必须通过 manifest 校验、隔离 marketplace 安装，并从 `codex debug prompt-input` 验证安装后模型可见的 13 个 skills 与 5 个 role prompts。
  6b. **安装后 Codex 上下文预算**：隔离安装后从真实 prompt/tool discovery 量化固定成本和四个关键阶段，按 `contracts/codex-context-budget-v1.json` 卡回归；不发模型请求，也不替代行为验收。
  7. **沙盒项目接线 + verify**：对临时项目 `install --host grill` 后 `verify`。
  8. **全套 smoke**：跑 `self-test.sh`。
  9. **doctor**：对传入项目只读诊断；若 active provider 是 Obsidian，bundle/status/health 任一失败都会卡 release-check。

任一步 FAIL，`release-check` 整体 FAIL。

真实 Desktop、installed Claude Code/Codex、shadow-validation、migration verify/cutover 与中断恢复的最终验收记录按 `docs/OBSIDIAN_ACCEPTANCE_CN.md` 执行；smoke 和直接 CLI 不替代它。

### 4.1 隔离 Codex 集成验收的 provider 配置

`tests/codex-plugin-smoke.sh` 的隔离 `CODEX_HOME` 验证 marketplace/plugin 安装，并通过 `codex debug prompt-input` 检查安装后模型可见的 skill 清单；该命令不发模型请求。要在隔离 home 里继续跑**模型驱动**的 skill 集成验收，除了认证，还必须保留当前会话的 effective `model`、`model_provider` 及对应 `[model_providers.<name>]` 配置；只复制/链接 `auth.json` 不够。

启动输出里的 `model:` 与 `provider:` 是验收前置断言。若自定义 provider 的模型在隔离 home 中退回 `provider: openai`，CLI 可能表现为反复 `stream disconnected`，这不是 plugin/skill/hook 故障。先修复隔离配置，再判断集成路径；不得通过把完整用户配置或凭据提交进测试 fixture 来解决。远端 plugin catalog 在 API-key 登录下产生的同步 warning 与本地 plugin skill 执行是两条独立路径，也不能拿它替代实际 sampling/skill 结果。

installed acceptance 只从当前 Codex home 复制认证以及选中 model/provider 的最小配置到临时 home；marketplace、其他 plugin、MCP、hook 与 project trust 均不复制。上下文隔离门会从当前 Codex cache 或已配置 marketplace 显式安装 `mattpocock-skills`，依次真实调用六个 grill host stage 并验证 router，而不是只采样 `to-tickets`；默认发现不到时可用 `GRILL_ADAPTER_MATTPOCOCK_SKILLS_ROOT` 指向其插件根。Source、Vault、Obsidian CLI 和插件缓存都在临时目录生成，fake CLI 自带 `search`/`read`，不调用本机 `grill-adapter` / `@grill-adapter/obsidian-wiki` npm 包，也不要求 write bridge 已启动。`expect` 只负责交互式 TUI 的确认与终态等待；最终断言读取 Codex rollout、实际 child tool-call input、正式 task contract 和 canonical report，而不是终端渲染文本或继承到 child rollout 的 parent prompt。Codex 会加密持久化 rollout 中的 spawn `message`；验收因此机械核对 sealed payload、任务名和 `fork_turns`，再从 child rollout 的实际读取/工具调用及正式产物证明解密后的角色与 phase/task contract 被消费。provider transport 在重试耗尽后失败属于环境前置失败，不能改写成 adapter PASS。

`--ask-for-approval never` 只覆盖 Codex 的普通命令审批，不能假定它会自动批准带写入 annotation 的 MCP 工具。上下文隔离门在临时验收 home 中只对白名单 `obsidian_wiki_stage_capture_plan` 设置 tool-specific `approval_mode="approve"`，仍禁止 server 级 `default_tools_approval_mode="approve"`，因此不会顺带放行 apply/correct/publish 等其他写路径。Capture 仍必须经 installed skill → isolated child → `functions.exec` → MCP → Outbox 真链路；不得通过改 prompt 跳过 staging。runner 同时监控 rollout 中已发出但未结束的 staging call，默认 45 秒后以专用诊断失败，而不是等完整阶段超时；可用 `GRILL_ADAPTER_CODEX_CAPTURE_MCP_STALL_SECONDS`、`GRILL_ADAPTER_CODEX_CAPTURE_TIMEOUT_SECONDS` 和 `GRILL_ADAPTER_CODEX_ACCEPTANCE_TIMEOUT_SECONDS` 调整环境预算。

当当前模型触发额度限制但同一 provider 仍有可用模型时，可用 `GRILL_ADAPTER_CODEX_MODEL=<model>` 覆盖两条 installed acceptance 的 sampling model；脚本会把覆盖值传给每个交互式 parent（child 继承）并记录进 evaluation report。未设置时仍继承当前 Codex 配置，且 transport 失败仍必须整体失败。

---

## 5. 改不同层的验证要求

- **改 skill**（`skills/*/SKILL.md`）→ 加载 plugin 后，在 Claude Code 里**从该 skill 的入口**真正走一遍用户路径验证；不要只跑它背后的 Python。
- **改 hook**（`hooks/*.sh`、`hooks/hooks.json`）→ 跑 `tests/hooks-smoke.sh`、`tests/codex-plugin-smoke.sh`，并用 Claude plugin details 确认 3 个 hook 仍被发现。
- **改接线逻辑**（`lib/install.py`、`manifest.json`）→ 跑 `tests/install-project-wiring-smoke.sh`，并对 `--runtime claude|codex|both` 走 install + verify。
- **改引擎脚本**（`scripts/wiki_*.py`、`scripts/source_truth_*.py`）→ 跑相关 `tests/wiki-*.sh` / `tests/source-truth-*.sh` smoke，再 `./manage.sh release-check <project>` 兜底。
- **改 host 约定块**（`contracts/host-conventions-v1.json`、`scripts/render_host_conventions.py` 或 `host-adapters/*/{CLAUDE,AGENTS}.md`）→ 先运行 `python3 scripts/render_host_conventions.py --write`，再运行 `--check` 与 `tests/host-conventions-smoke.sh`，并在对应真实运行时验证。块里不许出现安装路径；Claude 用 `/grill-adapter:<skill>`，Codex 用 `$grill-adapter:<skill>`。
- **改 Obsidian MCP/CLI**（`mcp/obsidian-wiki/src/`）→ 同样运行 `npm run typecheck` + `npm run build` + `npm test`，提交 `dist/index.js`；`package.json` 同时定义可发布的 `obsidian-wiki` CLI，发布前用 `npm pack --dry-run` 确认 tarball 只包含 `dist/`、README 和 package metadata。

---

## 6. 不变式与授权门（改引擎时逐条别破，详见 `docs/ARCHITECTURE_CN.md`）

- **markdown 唯一真相源**：`.graph.json` 是派生物，**不引外部图数据库**。
- **task contract 有界 1 跳 `depends-on` 闭包**：freeze 只展开有界、去重的 1 跳闭包；执行期只消费批准的 role-specific Markdown，绝不追链或重新读取 live Note。
- **section 级 `[[page#section]]` typed 边** + 渐进披露。
- **Obsidian Source 每项目绑定，fail-closed**：消费项目在自己的 `.grill-adapter/settings.json` 的 `wiki.obsidian.bindings` 声明 Source；未声明、换绑或 revision 漂移都 fail-closed。legacy GitHub 仓库只允许作为 `migrate-wiki` 的显式只读输入。
- **root-specific 写授权门**：统一由 `.grill-adapter/settings.json` 的 `wiki.roots.project` / `wiki.roots.shared` 分别管理两个 legacy root。`updateExistingPage` 默认 **skip**，`createNewDocument` 默认 **ask**（可选 `skip` / `ask` / `refuse`）。执行层的 `--authorized-update` / `--authorized-create` 只表示 skill 已取得授权，**不能绕过 `refuse`**。
- **shared wiki 中性化**：`.grill-adapter/settings.json` 的 `wiki.roots.shared.sharedNeutrality.blockedTerms` / `blockedPatterns` 机械拒绝系统特有标识；shared wiki 不得含内部 URL、环境名、本地路径、部署实例或专属业务规则。

---

## 7. 占位符规则

- **共享 plugin 内容里**（`skills/`、`agents/`、`hooks/hooks.json`、`.mcp.json`）继续统一用裸 token **`${CLAUDE_PLUGIN_ROOT}`**。Claude Code 原生替换，Codex 兼容加载层也识别；不要另造一份只含 `PLUGIN_ROOT` 的 skills 树。
- **plugin 内容之外不许用它**。`host-adapters/*/{CLAUDE,AGENTS}.md` 会写进目标项目，不是 plugin 内容；这些块里根本不放安装路径。
- **`__GRILL_ADAPTER_ROOT__` 已作废**，`${CLAUDE_PLUGIN_ROOT}` 取代它。没有任何安装期改写会再碰这些文件，残留的占位符会原样发给用户，`release-check` 步骤 3 会在 `skills/`、`agents/`、`host-adapters/` 里 `grep` 到即 FAIL。
- **禁止残留任何 `__SUPERPOWER_ADAPTER_*__`**（旧 superpower-adapter 的占位符）。这是移植遗留的机械红线，`release-check` 步骤 3 会 `grep` 检查残留并在命中时 FAIL。

---

> 一句话记牢：**下四层测试证接线，① 证引擎，⑥（Claude Code 真跑）才是验收。改 MCP 连 `dist/` 一起提交，plugin 内容里占位符只认 `${CLAUDE_PLUGIN_ROOT}`。**
