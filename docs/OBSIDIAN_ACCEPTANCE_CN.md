# Obsidian Wiki rollout 最终验收

本页是 Obsidian runtime 的发布验收记录模板。脚本 smoke 只证明执行层；发布者必须在真实 Obsidian Desktop 和安装后的 Claude Code/Codex 中走用户路径，不能用直接执行 Python/Node 脚本替代。

## 1. 自动门与环境前置

准备一个消费项目、一个绑定 Source 的干净 base worktree、Obsidian Desktop 可见的 Vault、可用的 Obsidian CLI，以及需要测试 Capture 时才启动的 loopback write bridge。先运行：

```bash
./manage.sh release-check /path/to/consumer-project
./manage.sh doctor /path/to/consumer-project
```

doctor 必须报告 `Obsidian runtime healthy: yes`。新项目没有 legacy roots 时应为 `obsidian-native`；迁移中的项目应为 `shadow-validation`；已完成迁移的项目应为 `cutover-complete`。binding、registry、remote/base、Source manifest、bridge 或 migration 状态改变后都重跑 doctor。

## 2. Obsidian Desktop E2E

1. 在 Obsidian Desktop 打开 registry 中 `vaultRef` 对应的 Vault，确认绑定 Source 和 `_meta/wiki-source.md` 可见。
2. 在 Desktop 修改一张测试 Note，保存并确认 CLI 能立即读到；恢复 clean base 后再开始正式读取验收。
3. 从安装后的 host 调 `wiki-research`，确认搜索只返回 bound、active、agent-visible、base-eligible Notes，且未合并分支内容不可见。分别准备无 freshness metadata、review-due 和 expired Note：旧 Note 保持可用，review-due 可选且返回 warning，expired 不进入正式 selection；再制造 base 不同步，确认 knowledge freshness 与 repository health 两道门互不绕过。
4. 完成 schema-v6 Carry 后，让用户审核选中的约束并以一次 `freeze --all` 生成每个 task 的 `<taskId>.wiki-implement.md` / `<taskId>.wiki-review.md`。确认 snapshot metadata 包含对应角色的直接 Note/Card 与 1 跳闭包 freshness；推进时钟后 review-due warning 应在 Bind 出现，closure expired 必须 fail-closed，且批准 Markdown digest 不变。批量中任一 task 的 freeze 失败不得留下更早 task 的新批准快照。
5. code-review 启动两个 reviewer 前复用 readiness：健康 context 的 reviewer-only Card 必须经批准 `<taskId>.wiki-review.md` 到达派生 `<taskId>.wiki-review-handoff.md`，由两个轴共同读取并由实际 reviewer 执行；再编辑 reviewer snapshot 或制造 ticket fingerprint drift，确认 handoff 只产生 caveat、无部分内容且 Standards/Spec 正常完成。
6. 让自动 Capture 派生恰好一个 `wiki-capture` Agent；用 candidate/Note 私密 marker 证明主 session 只收到 plan ID、计数和 bounded caveat。核对 hidden Outbox ref、project-scoped status/draft view，并立即运行 formal research：base 仍 clean、queued 正文不可见、既有 merged Note 仍可读。
7. 跨两个 feature queue 同一路径的顺序更新，再运行可选 review 与无 feature slug publish。确认 review 先经隔离语义 consolidation，只显示最终 diff并保留 provenance；演练 exclude/defer/delete/revise/merge 均追加 successor 且旧 digest 失效，root `refuse` 不可绕过。每 repository 一个 allowlisted draft PR，开放 PR 仍不可检索。分别演练 Capture ref/manifest 中断恢复、PR 创建后恢复、same-path drift 自动 defer 且无关 path/repository 继续、disjoint fast-forward replay；不得手改 Outbox manifest 来“修复”。
8. 人工 merge 并同步 base，运行 status 确认 `pr-open -> active`，再从 formal research 读到新 Note。另用共享 registry/repository 的第二项目确认 status/review/publish 与 overlay 不泄漏跨项目内容。

## 3. installed Claude Code

以 marketplace 安装 plugin、对消费项目执行 `manage.sh install ... --runtime claude`，然后在该项目内真跑：

```text
grill-with-docs -> to-spec -> to-tickets
-> implement -> code-review -> update-wiki
```

记录 plugin/host 版本、日期、feature/task identity、角色 Markdown digest、两个 review 轴的共享 handoff、Capture child handle、Outbox plan ID/计数、batch plan digest、draft PR URL 与 active 结果。必须确认 Capture child 无继承上下文、只调用一次 staging、主 session 无 candidate/Note 正文，formal research 忽略 queued/pr-open。另跑 maintenance audit、candidate consolidation 与 Outbox consolidation，确认三者各自只加载 digest-bound 最小 role contract。Disclose/Carry/Bind/Capture、source-truth、hook、delayed publish 与恢复都必须由安装后的 skill/host 约定触发。

## 4. installed Codex

以 marketplace 安装 plugin、执行 `manage.sh install ... --runtime codex`，在 Codex 中走同一条完整路径。记录实际 `model` 和 `provider`，确认一个 Obsidian MCP server、13 skills、5 agents 和 host `AGENTS.md` 约定都来自安装后的 plugin。确认 `setup-init-obsidian` 先检查并使用 `grill-adapter` 与 `@grill-adapter/obsidian-wiki` 两个 npm 包；code-review 在两个 sub-agent 前复用 receipt，两个轴读取同一 reviewer Markdown；Wiki freeze/snapshot 故障只报告 caveat 且 review 仍完成。至少另跑一次跳过 formal to-tickets、从 direct issue/manual 进入 `$grill-adapter:wiki-readiness` 的单任务路径，并确认 `disabled`/`no-relevant` 可继续、`broken` 不注入部分内容。再分别运行 `$grill-adapter:wiki-maintenance audit <feature-slug>`、`consolidation <feature-slug>` 与 `update-wiki review`：三条路径分别确认唯一 digest-bound audit、candidate consolidation、Outbox consolidation child，coordinator 不读取或嵌入 role body，child 的第一个动作是 loader，并且只能使用该 mode 的工具与 compact schema。主 session 只能收到 metadata-only report 或 compact Outbox result。本仓提供 `GRILL_ADAPTER_RUN_CODEX_ACCEPTANCE=1 bash acceptance/codex-maintenance-installed.sh "$PWD"`，通过 PTY 顺序真跑三条交互式 Codex CLI 路径（禁止改回 `codex exec`），生成隔离 plugin cache、Source/Vault、`search`/`read` fake Obsidian CLI、私密正文/candidate marker 与 canonical journals，并机械验证每次唯一 spawn、合法 wait/terminal author、descriptor/digest/loader 顺序、语义分类、report/final response、事件流正文隔离、drift 失败保留旧报告及 Project/Vault/Git 不变性。该 fixture 不使用本机两个 npm 包，也不启动或要求 write bridge；该命令必须实际输出 `OK`，默认不纳入 smoke。隔离 `CODEX_HOME` 时只带入认证及 effective model/provider 最小配置；只验证 manifest 安装不算模型驱动集成验收。

Issue #35 的完整上下文隔离验收运行：

```bash
GRILL_ADAPTER_RUN_CODEX_ACCEPTANCE=1 \
  bash acceptance/codex-context-isolation-installed.sh "$PWD"
```

它从本地 marketplace 安装当前工作树，先分别真跑 `grill-with-docs`、`to-spec`、`to-tickets`、
`implement`、`code-review` 与 `diagnosing-bugs`，从 installed rollout 验证 host router 的入口触点；
随后覆盖 installed parent 内的 Carry/freeze/readiness、主 session 直接实现、独立 implementer、共享
handoff 的 Standards/Spec reviewer、Capture、research/maintenance dispatch failure 和 binding-broken
后用户继续，再复用 maintenance audit/consolidation installed gate。脚本对 malformed researcher output、binding drift、
stale maintenance report 和 proposal side effect 做机械断言；malformed/stale 两条路径也由安装后的
Codex coordinator 调用对应 validator，并核对正式 `broken` caveat 与旧报告保留，而不是只直跑脚本。
随后输出包含
hard-constraint miss、irrelevant selection、expired injection、correction recurrence、Note body
read 与端到端延迟的 JSON evaluation report；后两项 injection/recurrence 也从正式产物和实际
formatter 输出计算，不允许常量冒充。默认关闭且不属于普通 smoke；只有命令实际输出
`codex context isolation installed acceptance OK` 才算通过。未指定
`GRILL_ADAPTER_CODEX_ACCEPTANCE_REPORT` 时，report 保存在 `$TMPDIR` 下的固定 evaluation 路径，
不会随成功 sandbox 删除。

## 5. shadow-validation 与 cutover

已有 legacy Wiki 的项目先配置 `wiki.provider: obsidian` 和 Source bindings，但原字节保留 legacy roots。doctor 此时必须报告 `shadow-validation`。在这个阶段，正式 research/Carry/Bind/Capture 只走 Obsidian runtime；legacy 内容只作为 migration inventory/coverage 证据，**no legacy runtime fallback**。

通过 `migrate-wiki` 生成并确认 plan，完成专用 branch CAS apply、draft PR、人工 merge/base sync 后运行 migration verify。只有 verify 对 immutable plan、coverage、binding/policy、Note/Card identity/hash/search/edges 和 hard reread 全部通过，才可另行确认 cutover。cutover 后 doctor 必须报告 `cutover-complete`，且仅 plan 覆盖的 roots 成为机械只读 archive。

## 6. 验收记录

每次发布保留以下记录（issue comment 或发布记录均可，不提交 token、registry 私有路径或 Note body）：

- commit / plugin version / host versions / date
- 自动 `release-check` 结果
- Obsidian Desktop E2E 各步骤结果
- installed Claude Code 完整路径结果
- installed Codex 完整路径结果
- shadow-validation / migration verify / cutover 状态（适用时）
- 中断恢复演练结果与 draft PR URL

## 7. Issue #19 installed Codex direct-task 记录（2026-07-23）

本记录只证明 #19 新增的「跳过 formal to-tickets，直接进入单任务 readiness」路径，不替代
本页其余 Obsidian Desktop、完整主流程和发布恢复验收。

- 环境：`codex-cli 0.144.6`，`model: gpt-5.6-sol`，`provider: custom`；隔离
  `CODEX_HOME` 复制当前 effective provider 配置与认证，未复制项目数据。
- 插件：从当前 `codex/issue-19-wiki-readiness` 工作树加入隔离 local marketplace，安装
  `grill-adapter@grill-adapter`（plugin version `0.2.2`）；临时 Git 项目通过
  `manage.sh install --host grill --runtime codex` 写入 `AGENTS.md` 约定。
- 输入：confirmed conversational request，feature slug `issue-19-integration`，未经过
  `/to-tickets`，项目故意不配置 Wiki provider。
- 实际模型路径：Codex 注入并读取安装缓存中的 `$grill-adapter:wiki-readiness`，创建完整
  manual brief，调用 `wiki_readiness.py prepare-manual` 生成固定 `taskId: manual` 的单任务
  roster，再记录 `status: disabled`。
- 机械结果：`wiki_readiness.py validate --task-id manual` 返回
  `readiness disabled is valid for task manual`；receipt 为
  `ticketSource: manual`、`contextDisposition: none`，task fingerprint 为
  `f15ec79c0c3f8d6d56156f312e9a193f2945abcb6c1c1ea14fcc3f5409e9fd30`。
- 边界：只生成 `.grill-adapter/context/` 下的 brief/roster/receipt，没有 context sidecar、
  Wiki research/materialize、产品文件修改或实现动作；验收后隔离临时目录已删除。

结论：**PASS**。安装后的 Codex 能在 direct manual 入口建立稳定单任务身份，并在
Wiki 未启用时记录可继续且不携带伪造约束的 `disabled` readiness。

## 8. Issue #35 installed Codex 上下文隔离记录（2026-08-01）

- 环境：`model: gpt-5.6-sol`，`provider: custom`；隔离 `CODEX_HOME` 只复制认证和
  effective model/provider 配置，并从当前工作树安装 `grill-adapter@grill-adapter`。
- 实际路径：discovery/planning、Carry/freeze/readiness、主 session 直接实现、隔离
  implementer、Standards/Spec reviewer、Capture、maintenance audit/consolidation 全部通过；
  最终输出 `codex context isolation installed acceptance OK`。
- 故障路径：researcher/maintenance dispatch failure 均返回 `broken` caveat，malformed
  researcher output 未留下部分 context，stale maintenance report 保留旧报告，binding drift
  记录 `broken` 后仅按显式用户决定继续且不注入 Wiki 内容。
- 隔离结果：coordinator 只收到 metadata/envelope、批准的 role contract 或 receipt；researcher、
  maintenance、implementer 与 reviewer 的私有 reasoning/未选正文未进入 parent transcript；
  maintenance proposal 未修改 Note、journal、Git 或 PR。
- evaluation report：`/tmp/grill-adapter-issue35-evaluation.json`，`status: pass`；
  `hardConstraintMisses: 0`、`irrelevantSelections: 0`、`expiredInjections: 0`、
  `correctionRecurrences: 0`、`noteBodyReads: 44`、`endToEndLatencyMs: 664313`。

结论：**PASS**。Issue #35 的安装后 Codex 全路径、上下文隔离、角色 contract 绑定、proposal-only
维护和 fail-closed/fail-open 边界均由真实 rollout、child tool-call input 与正式产物机械验证。
