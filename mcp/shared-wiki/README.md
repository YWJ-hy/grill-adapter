# Shared Wiki MCP

把这个目录复制到本机任意位置，配置 shared-wiki Git 仓库后，就可以作为 MCP server 启动。server 会读取 indexed shared wiki 页面，也可以把 wiki 修改通过 branch + commit + GitHub PR 的方式提交。

GitHub 仓库是 shared wiki 的事实源。这个 MCP server 不会 merge PR，也不会判断某条知识是否应该进入 shared wiki；这些语义判断必须先由调用它的 agent 或 `update-wiki` skill 完成。

## 安装

```bash
npm install
npm run build
```

build 后用 `dist/index.js` 作为 MCP server 入口。

## 注册（一份通用注册，注册一次）

把下面这份**不含 repo 信息**的注册加到 Claude Code 的 user 级 MCP 配置即可（可用 `../../manage.sh shared-wiki-registration` 直接生成带正确绝对路径的版本）：

```json
{
  "mcpServers": {
    "shared-wiki": {
      "command": "node",
      "args": ["/absolute/path/to/shared-wiki-mcp/dist/index.js"]
    }
  }
}
```

server 启动时读取 Claude Code 注入的 `CLAUDE_PROJECT_DIR`，再从该项目的 `.shared-superpowers/settings.json` 的 `wiki.sharedMcp` 块自我配置。因此**一份注册服务所有项目**，不同项目可指向不同 shared wiki。**不要**在注册里加 `SHARED_WIKI_MCP_*` 环境变量——它们会覆盖每项目设置，把所有项目都钉到同一个 repo。

## 每个项目绑定 shared wiki

在使用 shared wiki 的项目里写 `.shared-superpowers/settings.json`（见 `examples/project-shared-superpowers-settings.example.json`）：

```json
{
  "wiki": {
    "sharedMcp": {
      "repoUrl": "https://github.com/YWJ-hy/shared-wiki.git",
      "baseBranch": "master",
      "remote": "origin",
      "wikiRoot": ".",
      "displayRoot": ".shared-superpowers/wiki",
      "draftPr": true
    }
  }
}
```

没有声明 `wiki.sharedMcp` 的项目拿不到 MCP shared wiki（**fail-closed**：server 起不来 / `shared_wiki_status` unhealthy，`wiki-researcher` 当它不可用并回退本地 `.shared-superpowers/wiki/` 或继续）。`cacheDir` 是机器本地项，不要放进项目配置（用 `SHARED_WIKI_MCP_CACHE_DIR` 或默认值）。

## 两个 settings.json 的辖域（勿混淆）

- **消费项目的** `.shared-superpowers/settings.json` → `wiki.sharedMcp`：本项目连哪个 shared wiki（这个 server 启动时读它）。
- **shared wiki 仓库内的** `.shared-superpowers/settings.json` → `wiki.updateAuthorization` / `wiki.sharedNeutrality`：该 shared wiki 自身的写入治理（server 从 clone 出的仓库读，见“写入策略”）。在消费项目里写治理键不会作用于远端 shared wiki。

## 可选：全局 / 测试覆盖

仍支持旧的 env 路径用于测试或单一全局 wiki：`SHARED_WIKI_MCP_CONFIG`（指向一个 `shared-wiki-mcp.config.json`，见 `examples/shared-wiki-mcp.config.example.json`）或单独的 `SHARED_WIKI_MCP_REPO_URL` 等环境变量。优先级：单独 env var > `SHARED_WIKI_MCP_CONFIG` 文件 > 项目 `wiki.sharedMcp` > 默认值。

## 工具列表

- `shared_wiki_status`：检查配置、clone 状态、base revision、策略、工具可用性和 wiki 校验摘要。
- `shared_wiki_tree`：返回基于 `index.md` 链接图的 shared wiki 树、当前 revision，以及 leaf page 的 companion section index metadata。
- `shared_wiki_read`：默认读取 root/directory `index.md` 和 leaf companion `xxx.index.md`，并返回 `displayPath`、`path` 和当前 revision；leaf `xxx.md` 整页读取默认禁用，只有显式 `allowLeafDocumentRead: true` 才允许用于人工审计。
- `shared_wiki_read_section`：读取 indexed leaf `xxx.md` 中一个 `<!-- wiki-section:... -->` section，可通过 `includeDocumentContext: true` 附带 companion index 中的 bounded document context。
- `shared_wiki_read_sections`：按输入顺序一次读取多个 selected sections，可跨多个 indexed leaf 文件；输入为 `{ sections: [{ path, section, includeDocumentContext? }], includeDocumentContext?, errorMode? }`，默认 `errorMode: "strict"`，任一 section/path/indexing 错误会整体失败。`errorMode: "partial"` 只用于人工诊断。返回一个 batch revision 和逐条 result revision；hard-constraint reread 应使用 strict + `includeDocumentContext: true`，不得把 batch 当成整页读取或 sibling section 读取。
- `shared_wiki_search`：在已 indexed 的 markdown 页面中做有界搜索并返回片段和当前 revision。
- `shared_wiki_validate_patch`：校验 unified diff，不 push、不创建 PR。
- `shared_wiki_create_patch_pr`：把已校验 patch 应用到新 branch，push 后创建 GitHub PR。

## CLI：`read-sections` / `graph-neighbors`（执行期硬约束 reread + depends-on 闭包）

同一个 `dist/index.js` 既是 stdio MCP server（无参启动），也提供两个 CLI 子命令：

```bash
# 取硬约束 section 全文（与 shared_wiki_read_sections 同形）
echo '{"sections":[{"path":"frontend/quality.md","section":"required-quality-patterns"}],"includeDocumentContext":true}' \
  | CLAUDE_PROJECT_DIR=/abs/path/to/consumer-project node /abs/path/to/shared-wiki-mcp/dist/index.js read-sections

# 取这些 page#section 节点的 1 跳邻居（与 shared_wiki_graph_neighbors 同形）
echo '{"nodes":["frontend/quality.md#required-quality-patterns"]}' \
  | CLAUDE_PROJECT_DIR=/abs/path/to/consumer-project node /abs/path/to/shared-wiki-mcp/dist/index.js graph-neighbors
```

两者都从 stdin 读一个 JSON 请求，复用 server 同一份 `loadConfig`（照常从 `CLAUDE_PROJECT_DIR` 的 `wiki.sharedMcp` 自我配置）与对应工具（`readSectionsTool` / `graphNeighborsTool`），把结果加上顶层 `repoUrl` 以一行 JSON 打到 stdout；`read-sections` 的 strict 错误以非零退出码 fail-closed。

这是给 adapter 执行层 `wiki_materialize_task.py` 用的：让一个普通编排脚本不经 MCP 协议也能走**同一份** shared-wiki 读取/图实现（保证 revision / index / marker / graph 语义一致）。`read-sections` 取 `source: github_mcp` 硬约束 reread 全文，并据返回的 `repoUrl`+`revision` 检测换绑/revision 漂移；`graph-neighbors` 让 materializer 对每个选中的 github_mcp 硬约束 section 沿 `depends-on` 边做 1 跳闭包（受 `indexed` 标志门控），把被依赖的 section 折进同一批 `read-sections` 一起 materialize——这与 renderer 对**本地** root 的 depends-on 闭包同形（共用 `wiki_common.depends_on_closure_targets`），只是远端图必须经此 CLI 取。`wiki_materialize_task.py` 会从本项目的 MCP 注册解析出 server 命令再附加对应子命令，因此无需单独再注册一份。

## 写入策略

server 会从 clone 后的仓库按以下顺序读取 wiki 策略：

1. `<repo>/<wikiRoot>/.shared-superpowers/settings.json`
2. `<repo>/.shared-superpowers/settings.json`
3. `<repo>/settings.json`
4. 默认值

策略格式：

```json
{
  "wiki": {
    "updateAuthorization": {
      "updateExistingPage": "skip",
      "createNewDocument": "ask"
    },
    "sharedNeutrality": {
      "blockedTerms": [],
      "blockedPatterns": []
    }
  }
}
```

`ask` 要求 MCP 调用方传入 `authorizedCreate` 或 `authorizedUpdate`。`refuse` 不能通过授权绕过。`sharedNeutrality` 中的词和正则只是机械防线；调用方在提交 patch 前仍然必须先把项目专属标识改写成中性、可迁移的表达。

## GitHub PR 要求

`shared_wiki_create_patch_pr` 需要：

- `git`
- GitHub CLI `gh`
- `gh auth status` 对目标仓库有效
- 有 push branch 和创建 PR 的权限

这个工具只创建 branch 和 PR，永远不会 merge。
