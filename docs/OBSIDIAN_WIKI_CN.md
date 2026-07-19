# Obsidian Wiki Source 绑定

本页描述 Obsidian Wiki 运行时的第一阶段：项目只能解析它明确绑定的 Source。它不改变当前 section Wiki 的检索、sidecar、materialize 或回写路径；这些能力会在后续切片迁移到 `obsidian-wiki` MCP。

## 运行边界

插件同时发货两个 MCP：

- `shared-wiki`：现有 schema-v5 shared Wiki 路径，保持不变。
- `obsidian-wiki`：只解析当前项目的 Obsidian Source bindings，并提供 `obsidian_wiki_status` 与 `obsidian_wiki_sources`。

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

每个项目最多一个 `role: project` binding，可有多个 `role: shared` binding。`sourceId` 与 `(vaultRef, root)` 均不可重复。`root` 必须是 Vault 内相对目录，不能包含绝对路径或 `..`。

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

每个成功 binding 有 canonical `bindingDigest`，由 vault reference、Source identity、role、root、publishing mode、repository reference、base branch 与 effective read policy 计算。后续 schema-v6 sidecar 将保存它，用于执行期检测换绑。
