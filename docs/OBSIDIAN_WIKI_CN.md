# Obsidian Wiki Source 绑定

本页描述 Obsidian Wiki 运行时的前两个切片：项目只能解析它明确绑定的 Source；规划期将受绑定限制的 atomic Note 和 Skill Card 选择承载为 schema-v6 sidecar。schema-v5 sidecar 在过渡期只读，不能再由新规划生成；权威 Note reread、写入、发布和迁移仍在后续切片完成。

## 运行边界

插件同时发货两个 MCP：

- `shared-wiki`：现有 schema-v5 shared Wiki 路径，保持不变。
- `obsidian-wiki`：解析当前项目的 Obsidian Source bindings，并提供 Source/status、受绑定限制的 Note 搜索/读取，以及一跳 typed neighbor 查询。

`obsidian-wiki` 只从 `CLAUDE_PROJECT_DIR` 指向项目的 `.shared-adapter/settings.json` 读取 bindings。工具不接受 Vault、Source 或 root 路径参数，因此调用方不能扩大到未绑定内容。

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
    "engineering-knowledge": { "selector": "Engineering-Knowledge" }
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

Registry 不可包含 PAT 或带凭据的 remote URL。后续 bridge 配置仍只使用 loopback URL 和环境变量中的 token。

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

以下条件均为 fail-closed 错误：缺少项目配置、缺少 registry entry、重复 Source/root、多个 project Source、缺失或不匹配 manifest、路径逃逸或 Source root 的符号链接逃逸、Obsidian CLI 未安装或无法列出 Vault selector、带凭据或不匹配的 repository remote、非 `baseBranch`、脏 worktree，以及未解决的 merge/rebase/cherry-pick 等 Git 操作。`obsidian_wiki_sources` 在任一 binding 错误时拒绝列出 Source；`obsidian_wiki_status` 返回结构化错误以及已验证的 Vault/repository 健康摘要以便修复配置。

每个成功 binding 有 canonical `bindingDigest`，由 vault reference、Source identity、role、root、publishing mode、repository reference、base branch 与 effective read policy 计算。schema-v6 sidecar 保存它、每个 Note 的 `wikiId`/path/`contentHash`/summary，以及批量读取的 `snapshotHash`，但不保存 Note body；这些字段为后续执行期检测换绑和内容漂移提供身份快照。

正式读取默认会在 registry 的 `syncBeforeResearch` 未显式关闭时 fetch 并 `--ff-only` 对齐 `remote/baseBranch`；无法证明 freshness 时仅在 `allowStaleRead: true` 时可继续。repository 根的 `.grill-adapter-wiki.publish.lock` 存在时所有读取都会拒绝，以防发布分支切换期间让 Obsidian 索引暴露混合内容。
