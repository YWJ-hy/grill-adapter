# Obsidian Wiki Source 绑定

本页描述 Obsidian Wiki 的受控运行边界：项目只能解析它明确绑定的 Source；规划期将受绑定限制的 atomic Note 和 Skill Card 选择承载为 schema-v6 sidecar；执行期按 stable ID reread 权威 Note；review 后 atomic Note（含 Skill Card）只能经本机 loopback write bridge 做 proposal + expected-hash CAS 写入，再由 applied receipts 驱动可恢复的 GitHub draft-PR 发布。schema-v5 sidecar 在过渡期只读，不能再由新规划生成；legacy Wiki 通过 snapshot-bound plan、受治理 apply、base verify 与显式 cutover 迁移，旧目录始终保留。

## Legacy Wiki 迁移规划

`migrate-wiki` 的 **Obsidian migration plan** 模式调用 `scripts/wiki_migration_plan.py`，只读 `.adapter/wiki/`、`.shared-adapter/wiki/`、当前项目绑定、machine registry 指向的 Source worktree，以及 legacy discovery card 对应的本地 pack。它不调用 Obsidian、MCP、Git、write bridge 或 publisher，也不修改任何源/目标文件；JSON 只写 stdout，契约见 `contracts/obsidian-migration-plan-v1.example.jsonc`。

planner 先按正式治理规则校验 binding topology（重复 ID/root、root 重叠/越界、多个 project binding 均 fail-closed），在任何 inventory/graph 读取前拒绝 legacy/Source/manifest/pack 符号链接，且只读取 `access.read: true` 的选定 Source。inventory 同时覆盖 indexed/unindexed pages、section markers、navigation indexes、`.graph.json` edge/dangling、hard/soft constraint 与 `guides/skills.md` discovery content。每个 source item 恰有一个 plan decision，并携带目标 Source、稳定 Note ID、Vault 相对 proposed path、edge transformation 与 `create|update|skip|conflict`。目标 path 在同一 Source 内被其他/缺失 ID 的 Note 占用、或任意状态 Skill Card 的 provider/name 已由不同 ID 占用时均输出 conflict。输出保存 source/target snapshot digest；相同字节输入得到相同 plan。

`semantic-split`、`duplicate-id`、`target-path-collision`、`dangling-edge`、`unavailable-pack`、`shared-neutrality-violation`、`non-migratable-navigation`、`strength-confirmation` 必须逐项展示并等待确认，不能在 planner 内静默修正。所有未分节页面均触发 semantic split；词法推断的 hard/soft 都标为 `strengthConfidence: heuristic`。plan confirmation 只确认这份映射，不替代 Source 写 policy、PR merge 或 cutover confirmation。

## Legacy Wiki 迁移 apply / verify / cutover

`scripts/wiki_migration_apply.py apply` 只接受原始 schema-v1 plan、零 `conflict`、显式 `--confirmed`。首次写前会用相同 Source selector 重跑 planner，并要求整个结构化 plan 完全一致；source/target snapshot 或 plan 内容漂移均拒绝。它先把完整 plan、binding/policy snapshot 和所有 operation 的路径、Note identity、原始 before hash、seed/final hash 原子写进 migration manifest，再由 publisher 建立并 checkout 每仓专用 PR branch；首个 bridge 写发生时已不在 base。为了让任意顺序乃至循环 typed edge 通过既有 bridge 校验，coordinator 先为所有 create 建立无边的合法 atomic Note seed，再以原始 expected-hash CAS 写入最终 frontmatter/body。中断恢复只接受精确 before/seed/final 状态，其他内容均视作人工 drift，绝不把当前 hash 收养成新 CAS 基线。每一步仍经过 binding、Source manifest、effective policy、neutrality、stable ID、Skill Card pack identity 与 typed-link 校验，不绕 bridge 直写 Vault。

最终 Note receipts 作为 allowlist 交给既有 publisher：按 `repositoryRef` 生成 draft PR、恢复 clean base，并与迁移状态一起持久化到 `.adapter/context/migration-<plan-hash>.{wiki-publish,obsidian-migration}.json`。manifest 契约见 `contracts/obsidian-migration-manifest-v1.example.jsonc`。中断重跑复用 seed/final receipt 和 publish run，不重复 Note、commit、push 或 PR；开放 PR 内容仍不进入正式读取。

PR 由用户审查/合并且 configured base worktree 同步后，`verify` 才运行。它先重算 manifest 内完整 plan 的 `planHash`、legacy source snapshot、binding/policy snapshot，并从 immutable plan + operation roster 推导完整 coverage，删除 receipt 行或改写 receipt 身份都会失败。随后核实所有 PR `MERGED` 与 base freshness，再通过 bundled `status/search/read-notes-by-wiki-ids/graph-neighbors` seam 检查唯一 ID、Source/path containment、schema/policy、精确 content hash、search identity、Skill Card availability、typed edges 与 hard Note 全文 reread。verify 不写 Note；任何人工修改都表现为 drift，绝不覆盖。

`cutover` 需要另一次显式 `--confirmed`，并在写 settings 前重新跑完整 verify。若当前最新 `.adapter/context/*.wiki-context.json` 仍是 schema v5，则 fail-closed。成功后 `.shared-adapter/settings.json` 保持 `wiki.provider: obsidian`，并记录 `wiki.legacyRuntime.mode: read-only-archive`、confirmed plan 实际覆盖的旧 roots 和 migration manifest；未被 plan 选择的另一 root 不会被误归档。旧 Markdown/index/graph 不删除、不移动、不重写；legacy bootstrap/init/update/import/migration 路径都会拒绝对 archive roots 的后续写入。

## 运行边界

插件同时发货两个 MCP：

- `shared-wiki`：现有 schema-v5 shared Wiki 路径，保持不变。
- `obsidian-wiki`：解析当前项目的 Obsidian Source bindings，并提供 Source/status、受绑定限制的 Note/Card 搜索读取、一跳 typed neighbor，以及统一 proposal/apply 工具。

`obsidian-wiki` 只从宿主确定的项目根下 `.shared-adapter/settings.json` 读取 bindings：Claude Code 使用 `CLAUDE_PROJECT_DIR`，Codex 使用受控 MCP request 的 Git workspace metadata，直接 CLI 可使用进程 cwd。工具不接受 Vault、Source 或 root 路径参数，因此调用方不能扩大到未绑定内容；多个 Codex workspace 同时声明 settings 时按歧义 fail-closed。

## Candidate Journal 边界

`grill-with-docs`、specification、tickets、implementation、review 与 debugging 阶段发现的 Wiki Note / Skill Card 候选，只能经 journal 追加，不能写 Obsidian。Skill Card 候选必须由已验证 pack 产生，并携带 provider/name/version/contract hash/roles/triggers；初始 `discoveryState` 恒为 `pending`。journal 每次追加前完整 replay，并对损坏、截断、重复 identity、未知引用和非法状态转换 fail-closed。

review 后 `update-wiki` 先 validate/fold，以最终 review + 已验证 code/tests、final spec/ticket、原 candidate 的顺序对 pending/deferred 候选做语义审查；语义相同的 claims 先合并成一个 `capture` replacement 并显式 supersede，再只写一次。Obsidian outcome 可保存严格的 `writeReceipt`：proposal 暂停是 `proposed+deferred`，恢复后可用另一条 deferred 事件刷新漂移后的 proposal；bridge apply 成功是 `applied+kept`，且必须与最新 proposal 的 repository/binding/Note/path/hash 身份完全一致。Skill Card 的 receipt 还必须携带 write result 返回的完整 `skillRegistration`，并与 staged candidate 逐字段一致；没有匹配 applied receipt 的 Card 不能进入 `kept`。journal 是本地、不可提交的恢复 receipt，保留而不删除；它不包含权威 Note body、token 或授权 secret，也不是绕过 Source policy、write bridge 或后续 PR publishing 的写通道。

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

### Atomic Skill Card

每个 executable pack 对应唯一一个 `type: guide` atomic Note；同一 provider/name 出现第二张 active Card 时 read/search/graph fail-closed，write 也拒绝创建或改写出重复身份。除普通 Note 属性外，Card 必须完整声明 `skill_provider: claude-code-project`、`skill_name`、`skill_version`、`skill_contract_hash`、非空 `skill_roles` 与 `skill_triggers`；缺任一项、类型不是 guide、pack 缺失、version/hash 漂移都会 fail-closed。pack 的 `SKILL.md` 必须带同一 `major.minor.patch` version。contract hash 使用 `grill-adapter.skill-pack-contract/v1\0` domain prefix，把 pack 内文件按 POSIX 相对路径的 UTF-8 bytes 升序排列，再依次纳入相对路径与文件内容 SHA-256；任何 symlink 都拒绝。Python staging 与 TypeScript MCP 用共享 fixture 锁定同一结果。

## 只读检索

`obsidian_wiki_search`、`obsidian_wiki_read_note`、`obsidian_wiki_read_notes` 与 `obsidian_wiki_graph_neighbors` 只操作当前项目可读 binding 下的 atomic Note。每次 Obsidian CLI 调用都带 resolver 得到的 Vault selector；调用者只能提供搜索语句、Vault 相对 Note 路径或 `wiki_id`，不能指定 Vault、Source 或 root。

- 搜索结果会机械排除 `_meta/`、未绑定路径、非 active/visible Note；Skill Card 还要求 Source 已明确同步到 remote base，并排除本地 provider/name/version/contract hash 不可用者。`syncBeforeResearch: false` 或 stale-read 降级都不能让 Card 变为 discoverable。通过者返回 `discoveryState: discoverable` 与完整 Card 身份。
- 批量读取经两轮 Obsidian CLI 重读，返回每条 Note 的 canonical `contentHash` 及整批稳定 `snapshotHash`；读取期间内容、路径或 ID 改变，以及重复 `wiki_id`，都会 fail-closed。
- typed neighbor 查询仅解析请求 Note 的 `depends_on`、`see_also`、`supersedes`、`contradicts` 一跳目标，去重且不递归跟随 target 的边；source/target 若是 Card，同样先通过 remote-base、pack availability 与唯一性门。

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

1. `obsidian_wiki_propose_note_change` 接受已绑定 `sourceId`、Vault 相对 `.md` 路径、完整 atomic Note 内容、`create|update` 和 expected hash（create 为 `null`），完成 schema、stable ID、typed links、root、effective policy 与 Shared neutrality 校验；Skill Card 还复核当前项目 pack identity。返回 structured diff，但不写。
2. agent 向用户展示 diff。effective policy 为 `confirm` 时必须获得明确授权；`deny` 永远不能被 `authorized: true` 绕过。
3. `obsidian_wiki_apply_note_change` 把同一输入交给 bridge。bridge 再独立校验 Bearer token、项目 binding + Source manifest effective policy、identity/typed links、允许 root、`_meta` 禁写与 Shared neutrality，并以每 Note 独占写锁串行 bridge 请求。create 使用 no-replace 原子 link；update 通过随包 Python helper 调用宿主的原生 atomic exchange（macOS `renamex_np(RENAME_SWAP)`、Linux `renameat2(RENAME_EXCHANGE)`、Windows `ReplaceFileW`），交换后校验被换出的旧目标 hash。若外部编辑抢先，bridge 原子交换回滚并返回 409，保留外部内容。
4. bridge 随后返回 `wikiId`、path、content hash，MCP 客户端还会核对 post-write identity 与 proposal 是否完全匹配。成功只表示工作树中的 staged knowledge state；合并、base 同步与正式 runtime 可见性由后续 Git PR publishing 流程负责。

JSON CLI 同样暴露 `propose-note-change` / `apply-note-change`，请求从 stdin 读取；它们仍从当前项目 binding 解析 Source，不能接受任意 Vault/root 覆盖。

## GitHub draft-PR 发布

`update-wiki` 在所有 outcome 落入 journal 后再次 fold。只有 `status: kept` 且 `writeReceipt.state: applied` 的 Obsidian receipt 能进入发布 allowlist；`proposed`、`deferred`、无 receipt 的 kept candidate 都不会发布。agent 先按 `repositoryRef` 展示 Source/path/operation/after-hash，并取得这一次 commit/push/draft-PR scope 的明确确认，然后运行：

```bash
python3 <plugin-root>/scripts/wiki_candidate_journal.py fold \
  --journal .adapter/context/<feature-slug>.wiki-candidates.jsonl \
  --feature-slug <feature-slug> \
| node <plugin-root>/mcp/obsidian-wiki/dist/index.js publish
```

publisher 每仓依次验证当前 binding digest、`publishing.mode: git-pr`、remote identity、base branch 与 remote/base 同步、Source containment、wiki ID、before/after hash，以及 worktree changed paths 与 receipts 完全相等；拿到 repository lock 后会再次核对 Note hash 与精确 path scope。它创建 `.grill-adapter-wiki.publish.lock` 阻止 formal read，在 run 专属 branch 上只 add allowlist paths、commit/push、创建 draft PR，并在所有仓库拿到 URL 后回填 peer PR 列表。成功或普通外部失败都会切回 clean base 后移除 lock；若 base 恢复本身失败则保留 lock 并 fail-closed。publisher 不 merge、approve、force-push、reset、stash、clean 或删 branch。

本地 `.adapter/context/<feature-slug>.wiki-publish.json` 是恢复 receipt，不提交。commit 前失败时，manifest 的 `stagedTree` 只保存已验证 Git tree 的 object ID（不保存 Note body），publisher 清理 base index/worktree；重跑时从该 tree 恢复同一 allowlist。已有 local commit、remote branch 或 GitHub PR 会按 content hash/commit/path/URL 重新核验并复用；base 上若出现新的 Capture 改动则 fail-closed，必须另行处理。PR 分支内容不是 runtime truth；只有人工 merge 后，配置的 base worktree 完成同步并重新通过 binding/Note 校验，formal research 才能读取。

## 诊断与失败模式

运行：

```bash
./manage.sh doctor /path/to/project
```

该命令会显示 legacy shared-wiki binding、active provider 和采用状态，并调用 `obsidian-wiki` bundle 校验 Source bindings。`wiki.provider: obsidian` 时，bundle 缺失、status 非法或 `healthy: false` 都让 doctor 非零退出；legacy provider 不会被强制要求配置 Obsidian。采用状态含：无 legacy root 的 `obsidian-native`、保留迁移证据但正式路径只走 Obsidian 的 `shadow-validation`、verify + 显式 cutover 后的 `cutover-complete`。任何状态都没有 legacy runtime fallback。也可以直接运行：

```bash
CLAUDE_PROJECT_DIR=/path/to/project \
node mcp/obsidian-wiki/dist/index.js status
```

以下条件均为 fail-closed 错误：缺少项目配置、缺少 registry entry、重复 Source/root、多个 project Source、缺失或不匹配 manifest、路径逃逸或 Source root 的符号链接逃逸、Obsidian CLI 未安装或无法列出 Vault selector、非法/不完整的 bridge 配置、带凭据或不匹配的 repository remote、非 `baseBranch`、脏 worktree，以及未解决的 merge/rebase/cherry-pick 等 Git 操作。写路径还会拒绝 token 缺失/错误、`_meta`、未绑定 root、policy deny/未确认 confirm、stable ID 漂移/重复、typed link 失效、expected-hash 冲突及 Shared neutrality 命中。`obsidian_wiki_sources` 在任一 binding 错误时拒绝列出 Source；`obsidian_wiki_status` 返回结构化错误以及已验证的 Vault/repository/bridge 配置摘要以便修复配置，但不暴露 token。

每个成功 binding 有 canonical `bindingDigest`，由 vault reference、Source identity、role、root、publishing mode、repository reference、base branch、effective read/update/create policy 与 Source manifest 治理字段计算。schema-v6 sidecar 保存它、每个 Note 的 `wikiId`/path/`contentHash`/summary，以及批量读取的 `snapshotHash`，但不保存 Note body；这些字段为后续执行期检测换绑、策略和内容漂移提供身份快照。

正式读取默认会在 registry 的 `syncBeforeResearch` 未显式关闭时 fetch 并 `--ff-only` 对齐 `remote/baseBranch`；无法证明 freshness 时仅在 `allowStaleRead: true` 时可继续。repository 根的 `.grill-adapter-wiki.publish.lock` 存在时所有读取都会拒绝，以防发布分支切换期间让 Obsidian 索引暴露混合内容。
