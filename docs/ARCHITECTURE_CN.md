# grill-adapter 架构与不变式

本页是跨层边界的唯一叙事权威。它说明数据从哪里来、哪些边界不能绕过；host 的安装细节、用户时序、MCP 运维和逐项测试不在这里重复。

## 三层

```text
插件层       skills/ · agents/ · hooks/hooks.json · .mcp.json
                    │ 独立入口 + 可选 hook
Host 层      host-adapters/<host>/{CLAUDE,AGENTS}.md
                    │ 项目 marker / stage router / activation
引擎层       scripts/ · contracts/ · mcp/obsidian-wiki/ · 派生索引
```

插件层共享 host 无关能力；Host 层只写项目持久指令块；引擎层负责确定性校验、读取、快照和授权。任何层都不得通过修改宿主自带 skill 来建立耦合。

## 稳定触点

| 触点 | 权威载体 | 关键边界 |
|---|---|---|
| **Disclose** | `skills/wiki-research/SKILL.md` + `agents/wiki-researcher.md` | 只披露绑定 Source 中有界、未过期的候选；Codex child 自己加载 role |
| **Carry** | `contracts/wiki-context-v6.example.jsonc` + `scripts/wiki_context_render.py` | sidecar 只携带 metadata/hash、binding digest、Skill Card 与 ticket roster 指纹，不携带 Note body |
| **Bind** | `contracts/wiki-task-snapshot-v2.example.jsonc` + `contracts/wiki-readiness-v1.example.jsonc` | freeze 生成 implement/review 双角色 Markdown；执行/评审只消费批准快照 |
| **Capture** | `skills/update-wiki/SKILL.md` + `contracts/wiki-candidate-journal-v1.example.jsonl` | journal append-only；Capture/Outbox 先进入本地受保护草稿，正式发布另需显式授权 |
| **Verify / Lint** | `skills/source-truth-check/SKILL.md` + `hooks/source-truth-lint.sh` | 规划期校验、执行期 lint；真实 changed files 是唯一检查输入 |
| **Break-loop** | `skills/break-loop/SKILL.md` | 验证后的调试复盘回到 candidate journal，再交 Capture |

详细用户时序见 [`USER_FLOW_CN.md`](USER_FLOW_CN.md)，入口路由见 [`HOST_INTEGRATION_CN.md`](HOST_INTEGRATION_CN.md)。

## 必保不变式

### 真相与派生物

- Markdown 是知识唯一真相源；`.graph.json`、index、session state、maintenance report 和 context budget report 都是可重建的派生物。
- 不引入外部图数据库；section 级 `[[page#section]]` typed edge 只从 Markdown 生成。

### 身份与快照

- Carry/Bind 的 task 身份、fingerprint 和 roster 边界只来自 host 产出的 `ticket-roster`，engine 不解析 plan/ticket 文档。
- freeze 只展开有界 1 跳 `depends-on` 闭包，去重且不传递；缺图是静默 no-op，执行期不重新 research。
- implement/review 使用各自角色 Markdown；缺少 schema-v2 freshness 清单、body digest、role digest 或任何输入漂移都拒绝消费。

### Source、binding 与授权（本页唯一不变式位置）

- 每个项目只能读取 `.grill-adapter/settings.json` 声明的 Obsidian Source binding；未声明、换绑、revision/base 不同步或 Source 不健康都 fail-closed。`OBSIDIAN_WIKI_CN.md` 只说明运行时操作，不重新定义这些不变式。
- root-specific 写授权默认 `updateExistingPage=skip`、`createNewDocument=ask`；`refuse` 永远不能被授权标志绕过。
- shared Source 机械执行 `blockedTerms` / `blockedPatterns` 中性化；legacy GitHub Wiki 只在用户显式 migration 路径中只读出现。

### Host 与激活

- 安装 plugin 只提供能力，不等于项目 opt-in。host marker、项目 settings 或用户显式调用至少一个成立后才允许 workflow-facing skill 继续；standalone 项目保持静默且零写入。
- Host convention 绝不带插件安装路径、绝不 patch 宿主 skill。规范源是 `contracts/host-conventions-v1.json`，四个运行时文件是生成物。

### 角色隔离与 Codex

- Codex coordinator 只传受信 role descriptor、source identity 和 expected digest；child 校验后加载当前 role，主 session 不摄入 role 正文、Note body 或 reasoning。
- dispatch 返回句柄；等待同一 child 到终态是下一步唯一合法操作。capacity、transport、lifecycle、role source/digest/load 失败走 `broken`，不能伪装成 `no-relevant`。

## 权威索引

以下契约是 schema 权威，不在本页复制完整示例：

- `contracts/ticket-roster-v1.example.jsonc`
- `contracts/wiki-context-v6.example.jsonc`
- `contracts/wiki-task-snapshot-v2.example.jsonc`
- `contracts/wiki-readiness-v1.example.jsonc`
- `contracts/host-conventions-v1.json`
- `contracts/project-activation-v1.json`

组件、smoke 和变更路由见 [`DOCUMENTATION_INDEX_CN.md`](DOCUMENTATION_INDEX_CN.md)。历史蓝图与被取代决策明确不是本页的当前实现来源。
