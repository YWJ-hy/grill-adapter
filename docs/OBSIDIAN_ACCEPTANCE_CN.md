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
3. 从安装后的 host 调 `wiki-research`，确认搜索只返回 bound、active、agent-visible、base-synchronized Notes，且未合并分支内容不可见。
4. 完成 schema-v6 Carry 后移动或重命名一张测试 Note；`wiki-materialize` 必须按 stable `wiki_id` reread。改变正文 hash、binding 或 base 状态时必须 fail-closed。
5. 对测试 candidate 走 proposal -> explicit confirmation -> apply，核对 journal 的 proposed/applied write receipts。再授权 publish，确认每 repository 一个 draft PR、base worktree恢复 clean、开放 PR 内容仍不可检索。
6. 在 apply 或 publish 中断一次并恢复：保留 journal、write receipts 和 publish run manifest，rerun the same publish step；不得手改 Vault worktree 或删除 manifest 来“修复”。

## 3. installed Claude Code

以 marketplace 安装 plugin、对消费项目执行 `manage.sh install ... --runtime claude`，然后在该项目内真跑：

```text
(可选 lanhu-requirements) -> grill-with-docs -> to-spec -> to-tickets
-> implement -> code-review -> update-wiki
```

记录 plugin 版本、Claude Code 版本、日期、feature slug、ticket IDs、schema-v6 sidecar 路径、materialize 结果、journal fold、write receipts、draft PR URL 与最终结果。必须确认 Disclose/Carry/Bind/Capture、source-truth verify/lint、hook 提醒与 publish recovery 均由安装后的 skill/host 约定触发。

## 4. installed Codex

以 marketplace 安装 plugin、执行 `manage.sh install ... --runtime codex`，在 Codex 中走同一条完整路径。记录实际 `model` 和 `provider`，确认两个 MCP server、13 skills 和 host `AGENTS.md` 约定都来自安装后的 plugin。隔离 `CODEX_HOME` 时必须保留 effective provider 配置；只验证 manifest 安装不算模型驱动集成验收。

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
