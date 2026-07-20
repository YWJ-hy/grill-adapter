# Obsidian Wiki Source 绑定

本页描述 Obsidian Wiki 的受控运行边界：项目只能解析它明确绑定的 Source；规划期将受绑定限制的 atomic Note 和 Skill Card 选择承载为 schema-v6 sidecar；执行期按 stable ID reread 权威 Note；review 后普通 Note 只能经本机 loopback write bridge 做 proposal + expected-hash CAS 写入。schema-v5 sidecar 在过渡期只读，不能再由新规划生成；Git PR 发布和迁移仍由后续切片完成。

## 运行边界

插件同时发货两个 MCP：

- `shared-wiki`：现有 schema-v5 shared Wiki 路径，保持不变。
- `obsidian-wiki`：解析当前项目的 Obsidian Source bindings，并提供 Source/status、受绑定限制的 Note 搜索/读取、一跳 typed neighbor 查询，以及普通 Note proposal/apply 工具。

`obsidian-wiki` 只从宿主确定的项目根下 `.shared-adapter/settings.json` 读取 bindings：Claude Code 使用 `CLAUDE_PROJECT_DIR`，Codex 使用受控 MCP request 的 Git workspace metadata，直接 CLI 可使用进程 cwd。工具不接受 Vault、Source 或 root 路径参数，因此调用方不能扩大到未绑定内容；多个 Codex workspace 同时声明 settings 时按歧义 fail-closed。

## Candidate Journal 边界

`grill-with-docs`、specification、tickets、implementation、review 与 debugging 阶段发现的 Wiki Note / Skill Card 候选，只能经 `/grill-adapter:candidate-journal` 追加到 `.adapter/context/<feature-slug>.wiki-candidates.jsonl`，不能写 Obsidian。journal 事件只有 `candidate`、`supersede`、`outcome`；每次追加前完整 replay，并对损坏、截断、重复 identity、未知引用和非法状态转换 fail-closed。

review 后 `update-wiki` 先 validate/fold，再对 pending/deferred 候选做语义审查并追加 keep/skip/defer outcome。journal 是本地、不可提交的恢复 receipt，保留而不删除；它既不包含权威 Note body，也不是绕过 Source policy、write bridge 或后续 PR publishing 的写通道。

## 项目配置

项目提交 `.shared-adapter/settings.json` 中的逻辑绑定，不提交本机 Vault 路径、bridge token 或凭据：

```json
{
  "wiki": {
    "provider": "obsidian",
    "publishing": { "mode": "git-pr" },
    "obsidian": {
      "bindings": [
        {
          "sourceId": "grill-adapter-project",
          "role": "project",
          "vaultRef": "engineering-knowledge",
          "repositoryRef": "engineering-wiki-all",
          "root": "Projects/grill-adapter",
          "access": { "read": true, "update": "confirm" }
        }
      ]
    }
  }
}
```

每个项目最多一个 `role: project` binding，可有多个 `role: shared` binding。`sourceId` 与 `(vaultRef, root)` 均不可重复，同一 Vault 内的 root 也不得互为父子，避免较宽 root 覆盖较窄 Source 的访问策略。`root` 必须是 Vault 内相对目录，不能包含绝对路径或 `..`。

## 本机 Registry

本机在 `~/.config/grill-adapter/obsidian-wiki.json` 保存不应提交的信息。测试或受控环境可用 `OBSIDIAN_WIKI_REGISTRY` 覆盖其路径。

```json
{
  "vaults": {
    "engineering-knowledge": {
      "selector": "Engineering-Knowledge",
      "bridgeUrl": "http://127.0.0.1:27124",
      "bridgeTokenEnv": "OBSIDIAN_WIKI_BRIDGE_TOKEN"
    }
  },
  "repositories": {
    "engineering-wiki-all": {
      "worktreeRoot": "/Users/me/Knowledge/Engineering-Knowledge",
      "remote": "origin",
      "expectedRemote": "github.com/example/engineering-wiki",
      "baseBranch": "main"
    }
  }
}
```

Registry 不可包含 PAT、bridge token 或带凭据的 remote URL。`bridgeUrl` 必须是无 credential/path 的 loopback HTTP URL；`bridgeTokenEnv` 只保存环境变量名，真实 token 留在进程环境中。两项必须同时存在，否则 binding fail-closed。

## Source Manifest

每一个绑定 root 都必须含有 `_meta/wiki-source.md`。该文件是 Source 自己的治理边界，项目 binding 只能收紧它：

```md
---
wiki_schema: grill-adapter.obsidian-source/v1
wiki_source_id: engineering-shared
scope: shared
update_existing: confirm
create_note: confirm
blocked_terms:
  - acme-internal
blocked_patterns:
  - "https://internal\\.example\\.com"
---
```

Shared Source 必须声明 `blocked_terms` 与 `blocked_patterns`。manifest 的 `wiki_source_id` 与 `scope` 必须分别匹配 binding 的 `sourceId` 与 `role`。`_meta/` 永远不是普通 Note 候选，也不能经后续普通 Note 写工具修改。

`access.update` 是 binding 层对所有写操作的上限；它与 manifest 的 `update_existing`、`create_note` 分别按更严格的结果生效：`deny` 高于 `confirm`，高于 `direct`。因此 binding 只能收紧、不能放宽 Source 的创建或更新治理。`access.read: false` 使该 Source 不可读，且不会出现在 `obsidian_wiki_sources` 的可用清单中。

## 只读检索

`obsidian_wiki_search`、`obsidian_wiki_read_note`、`obsidian_wiki_read_notes` 与 `obsidian_wiki_graph_neighbors` 只操作当前项目可读 binding 下的 atomic Note。每次 Obsidian CLI 调用都带 resolver 得到的 Vault selector；调用者只能提供搜索语句、Vault 相对 Note 路径或 `wiki_id`，不能指定 Vault、Source 或 root。

- 搜索结果会机械排除 `_meta/`、未绑定路径、`status` 非 `active` 与 `agent_visible: false` 的 Note；同时返回 `constraintStrength` 与可选 `skillRoles`，供规划期独立挑选约束 Note 和 Skill Card。
- 批量读取经两轮 Obsidian CLI 重读，返回每条 Note 的 canonical `contentHash` 及整批稳定 `snapshotHash`；读取期间内容、路径或 ID 改变，以及重复 `wiki_id`，都会 fail-closed。
- typed neighbor 查询仅解析请求 Note 的 `depends_on`、`see_also`、`supersedes`、`contradicts` 一跳目标，去重且不递归跟随 target 的边。

执行层可使用 bundle 的固定 JSON 子命令，避免另写一套 Vault reader：

```bash
printf '%s' '{"paths":["Projects/grill-adapter/Architecture/runtime.md"]}' \
  | node mcp/obsidian-wiki/dist/index.js read-notes

printf '%s' '{"wikiIds":["project/grill-adapter/architecture/runtime"]}' \
  | node mcp/obsidian-wiki/dist/index.js graph-neighbors
```

这些命令从 stdin 接收一个 JSON object，在 stdout 输出单行 JSON；不合法请求与任何 binding/一致性错误都以非零退出。

## 受控写桥

写桥是 `obsidian-wiki` bundle 的独立本机服务入口，不随 MCP 自动监听端口。启动时必须明确 Vault、允许写入的 Source roots 与 token；host 固定为 loopback（默认 `127.0.0.1`），不能绑定 `0.0.0.0` 或外网地址：

```bash
export OBSIDIAN_WIKI_BRIDGE_TOKEN='<machine-local-random-token>'
export OBSIDIAN_WIKI_BRIDGE_VAULT_ROOT='/Users/me/Knowledge/Engineering-Knowledge'
export OBSIDIAN_WIKI_BRIDGE_VAULT_SELECTOR='Engineering-Knowledge'
export OBSIDIAN_WIKI_BRIDGE_ALLOWED_ROOTS='["Projects/grill-adapter","Shared/Engineering"]'
export OBSIDIAN_WIKI_BRIDGE_PROJECT_DIRS='["/Users/me/dev/grill-adapter"]'
node mcp/obsidian-wiki/dist/index.js serve-write-bridge
```

`PROJECT_DIRS` 是 bridge 启动时的项目白名单。每个 proposal/apply 都携带 MCP 已解析的当前项目根；bridge 只接受白名单成员，并在**每次请求**重新读取该项目 `.shared-adapter/settings.json` 与 Source manifest，重新计算 binding + manifest 的 effective policy 和 neutrality，运行中收紧治理无需重启。一个 bridge 可列出多个明确项目，但请求不能提供白名单之外的任意项目路径。

`update-wiki` 的固定写路径是：

1. `obsidian_wiki_propose_note_change` 接受已绑定 `sourceId`、Vault 相对 `.md` 路径、完整 atomic Note 内容、`create|update` 和 expected hash（create 为 `null`），完成 schema、stable ID、typed links、root、effective policy 与 Shared neutrality 校验，返回 structured diff，但不写。
2. agent 向用户展示 diff。effective policy 为 `confirm` 时必须获得明确授权；`deny` 永远不能被 `authorized: true` 绕过。
3. `obsidian_wiki_apply_note_change` 把同一输入交给 bridge。bridge 再独立校验 Bearer token、项目 binding + Source manifest effective policy、identity/typed links、允许 root、`_meta` 禁写与 Shared neutrality，并以每 Note 独占写锁串行 bridge 请求。create 使用 no-replace 原子 link；update 通过随包 Python helper 调用宿主的原生 atomic exchange（macOS `renamex_np(RENAME_SWAP)`、Linux `renameat2(RENAME_EXCHANGE)`、Windows `ReplaceFileW`），交换后校验被换出的旧目标 hash。若外部编辑抢先，bridge 原子交换回滚并返回 409，保留外部内容。
4. bridge 随后返回 `wikiId`、path、content hash，MCP 客户端还会核对 post-write identity 与 proposal 是否完全匹配。成功只表示工作树中的 staged knowledge state；合并、base 同步与正式 runtime 可见性由后续 Git PR publishing 流程负责。

JSON CLI 同样暴露 `propose-note-change` / `apply-note-change`，请求从 stdin 读取；它们仍从当前项目 binding 解析 Source，不能接受任意 Vault/root 覆盖。

## 诊断与失败模式

运行：

```bash
./manage.sh doctor /path/to/project
```

该命令会显示 legacy shared-wiki binding，并调用 `obsidian-wiki` bundle 输出 Source binding 状态。也可以直接运行：

```bash
CLAUDE_PROJECT_DIR=/path/to/project \
node mcp/obsidian-wiki/dist/index.js status
```

以下条件均为 fail-closed 错误：缺少项目配置、缺少 registry entry、重复 Source/root、多个 project Source、缺失或不匹配 manifest、路径逃逸或 Source root 的符号链接逃逸、Obsidian CLI 未安装或无法列出 Vault selector、非法/不完整的 bridge 配置、带凭据或不匹配的 repository remote、非 `baseBranch`、脏 worktree，以及未解决的 merge/rebase/cherry-pick 等 Git 操作。写路径还会拒绝 token 缺失/错误、`_meta`、未绑定 root、policy deny/未确认 confirm、stable ID 漂移/重复、typed link 失效、expected-hash 冲突及 Shared neutrality 命中。`obsidian_wiki_sources` 在任一 binding 错误时拒绝列出 Source；`obsidian_wiki_status` 返回结构化错误以及已验证的 Vault/repository/bridge 配置摘要以便修复配置，但不暴露 token。

每个成功 binding 有 canonical `bindingDigest`，由 vault reference、Source identity、role、root、publishing mode、repository reference、base branch 与 effective read policy 计算。schema-v6 sidecar 保存它、每个 Note 的 `wikiId`/path/`contentHash`/summary，以及批量读取的 `snapshotHash`，但不保存 Note body；这些字段为后续执行期检测换绑和内容漂移提供身份快照。

正式读取默认会在 registry 的 `syncBeforeResearch` 未显式关闭时 fetch 并 `--ff-only` 对齐 `remote/baseBranch`；无法证明 freshness 时仅在 `allowStaleRead: true` 时可继续。repository 根的 `.grill-adapter-wiki.publish.lock` 存在时所有读取都会拒绝，以防发布分支切换期间让 Obsidian 索引暴露混合内容。
