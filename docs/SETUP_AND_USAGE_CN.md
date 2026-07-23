# grill-adapter 安装与使用（从零开始）

面向**从未装过 grill** 的用户。跟着走一遍：装 Claude Code/Codex → 装 grill → 装 grill-adapter → 端到端跑一次。装过 grill 的人可直接看 `../QUICKSTART_CN.md`。

## 0. 前置

- **Claude Code 或 Codex**（CLI / app）。已登录可用。
- **Python 3.9+**（`python3 --version`）。
- **Node.js ≥ 20**（`node --version`）——供 bundled Wiki MCP servers 运行；plugin 里已带打包好的 bundle，**不需要你构建**。

## 1. 装 grill（mattpocock/skills）

grill 是一个**只读、随版本更新的托管 plugin bundle**（你订阅它，不 fork），提供 `/grill-with-docs → /to-spec → /to-tickets → /implement → /code-review`（外加 `/diagnosing-bugs`）。在 Claude Code 里：

```
/plugin marketplace add mattpocock/skills
/plugin install mattpocock-skills@mattpocock
/setup-matt-pocock-skills
```

`/setup-matt-pocock-skills` 会问 issue tracker（GitHub / Linear / local）、ticket 标签、docs 保存位置——按你的项目回答即可。

备选（命令行）：`npx skills@latest add mattpocock/skills`。

> 落地前以 grill 官方 README 为准；命令名可能随版本微调。grill 升级不影响 grill-adapter——这正是「零 skill patch」设计的意义。

## 2. 装 grill-adapter

grill-adapter 同时提供 Claude Code 与 Codex plugin。装它分两步：先装 plugin，再给项目写约定块。

### 2.1 装 plugin（Claude Code 里）

```
/plugin marketplace add YWJ-hy/grill-adapter
/plugin install grill-adapter@grill-adapter
```

或命令行（在你的项目目录下）：

```bash
claude plugin install grill-adapter@grill-adapter --scope project
```

Codex：

```bash
codex plugin marketplace add YWJ-hy/grill-adapter
codex plugin add grill-adapter@grill-adapter
```

plugin 一启用，13 个 skill、1 个 agent、3 个 hook 和两个 MCP server（legacy `shared-wiki`、Source-binding `obsidian-wiki`）**一起注册、自动生效**——不往 `~/.claude/skills`、`~/.claude/agents` 拷文件，也不往你项目的 `.claude/settings.json` 里并 hook 片段。

**关于 `--scope`**：skills / agents / hooks / MCP **共用 plugin 的 scope**，plugin 自带的 MCP 无法单独设 scope。想要 shared-wiki MCP 只在**这个项目**里起，就用 `--scope project`；想跨项目共用，用 `--scope user`。

shared-wiki MCP 装好即自动启动（工具名带 `mcp__plugin_grill-adapter_shared-wiki__` 前缀），**不需要再手工注册**。要不要真连上一个跨 repo 共享 wiki，取决于你项目里的**绑定声明**（见下）：server 启动读 `CLAUDE_PROJECT_DIR`，从该项目的 `.shared-adapter/settings.json` 的 `wiki.sharedMcp` 自配置；没声明的项目自动 fail-closed，属正常。

### 2.2 给项目写约定块

plugin 唯一管不到的是项目持久指令文件——Claude Code 用 `CLAUDE.md`，Codex 用 `AGENTS.md`。用仓库里的 `manage.sh` 写：

```bash
git clone https://github.com/YWJ-hy/grill-adapter.git
cd grill-adapter
./manage.sh install /path/to/your/project --host grill --runtime claude
# Codex: --runtime codex；双端: --runtime both
```

它只做这一件事：把 grill 约定块（marker 包裹）写进 `<project>/CLAUDE.md`。块里**只点名 skill、不含任何安装路径**——路径由 skill 自己持有，plugin 升级换目录也不会失效。

校验：

```bash
./manage.sh verify /path/to/your/project --host grill --runtime codex
./manage.sh status /path/to/your/project --runtime codex
```

## 3. 配置 Obsidian Wiki runtime

新项目按 `OBSIDIAN_WIKI_CN.md` 创建/选择一个 Obsidian Source，提交 `_meta/wiki-source.md`，在项目 `.shared-adapter/settings.json` 声明 `wiki.provider: obsidian` 与 bindings，并在机器本地 registry 解析 `vaultRef` / `repositoryRef`。配置完成后运行：

```bash
./manage.sh doctor /path/to/your/project
```

新项目必须显示 `obsidian-native` + healthy 后才进入正式 research。已有 legacy Wiki 的项目会显示 `shadow-validation`；正式 Disclose/Carry/Bind/Capture 已只走 Obsidian，旧目录只用于 migration evidence，不作 fallback。迁移按 plan → 确认 → 专用 PR branch → CAS apply/draft PR → 人工 merge/base sync → immutable-plan/source/binding verify → 单独确认 cutover；只有 plan 覆盖的旧目录成为 mechanically enforced read-only archive，不自动删除。`bootstrap-wiki` 是 legacy-only，active Obsidian provider 会拒绝重新播种；其他 legacy 维护 skill 在 cutover 前仅用于迁移准备，cutover 后由 archive gate 机械拒绝写入。

## 4. 端到端走一遍

打开 Claude Code，进入你的项目（`CLAUDE.md` 里已有 grill 约定块），按需求跑：

| 步 | 命令 | grill-adapter 触点 | 产物 |
|---|---|---|---|
| 1 质询/发现 | `/grill-with-docs` | Disclose：约定提示 `/grill-adapter:wiki-research`（brainstorm） | spec 草稿 |
| 2 定 spec | `/to-spec` | source-truth Verify：`/grill-adapter:source-truth-check`（spec-pre） | spec |
| 3 拆 ticket | `/to-tickets` | Disclose+Carry：`/grill-adapter:wiki-research`（plan）→ scaffold sidecar → 由真实 ticket 建 roster → `--finalize` | `.adapter/context/<feature-slug>.{wiki-context,ticket-roster}.json` |
| 4 实现 | `/implement` | Readiness+Bind：首次修改前 `/grill-adapter:wiki-readiness`；`ready` 才按 task materialize；`source-truth-lint` hook | 稳定 task/receipt + 可用时的硬约束全文 |
| 5 评审后 | `/code-review` → `/grill-adapter:update-wiki` | Capture：最终证据 reconcile → proposal/apply → 确认 scope 后按 repository 发布 resumable draft PR | applied receipt + `.wiki-publish.json` + draft PR |
| 6 调试（如需） | `/diagnosing-bugs` → `/grill-adapter:break-loop` | debug Disclose + 复盘→Capture | 修复 + 复盘候选 |

每一步的命令和约定都写在项目 `CLAUDE.md` 或 `AGENTS.md` 的 grill 约定块里。想看完整流程叙述见 `USER_FLOW_CN.md`。

## 5. 常见问题

- **我没用 grill，用裸 Claude Code/Codex 行吗？** 行。`./manage.sh install /path/to/project --host plain --runtime <runtime>`，然后在对应时刻自己调同样的 skill。
- **会改我的 grill 吗？** 不会。grill-adapter 零 skill patch。skill / agent / hook / MCP 全在 plugin 里自成一体；落到你仓库里的改动只有 `<project>/CLAUDE.md` 的那个约定块。
- **Obsidian Wiki 不健康？** 跑 `./manage.sh doctor <project>`；依次修复 settings、machine registry、Vault selector、Source manifest、repository remote/base/clean 状态与 bridge 配置。active Obsidian provider 的 doctor 非零退出，release-check 也会失败。
- **MCP 只想在某一个项目里起？** 那就用 `--scope project` 装 plugin。plugin 自带的 MCP 不能单独设 scope，它跟着 plugin 的 scope 走。
- **`/grill-adapter:wiki-materialize` 报 drift / 换绑？** 这是 fail-closed 设计：schema-v6 sidecar 的 binding digest、stable Note/Card identity、content hash、base sync 或 pack contract 与当前正式 Source 不一致。回规划期重新 research/scaffold/finalize，不能转读 legacy Wiki 绕过。
- **怎么卸载？** 两步对应两步安装。
  1. **停用 plugin**：把 `grill-adapter@grill-adapter` 从项目 `.claude/settings.json` 的 `enabledPlugins` 删掉即可。注意 `claude plugin uninstall` 对 **project scope 会直接拒绝**（原话：「enabled at project scope (.claude/settings.json, shared with your team)」）——它不肯替你改一份团队共享的提交物。只想自己关掉、不动团队设置：`claude plugin disable grill-adapter@grill-adapter --scope local`。装在 `--scope user` 时 `claude plugin uninstall grill-adapter@grill-adapter` 才直接生效。
  2. **剥约定块**：`./manage.sh uninstall /path/to/your/project`（marker 包裹，干净移除，不动 `CLAUDE.md` 其余内容）。
- **升级 grill-adapter？** `/plugin update grill-adapter@grill-adapter` 升 plugin。约定块若有变，`git pull` 后重跑 `./manage.sh install`（幂等：整块替换）。

## 6. 验证你的安装

```bash
claude --plugin-dir "$PWD" plugin details grill-adapter   # 不安装即加载：应报 13 skills / 1 agent / 3 hooks / 2 MCP servers
./manage.sh self-test                # 跑全套 smoke/regression（别传仓库根，见 DEVELOPMENT_CN.md）
./manage.sh release-check <project>  # 发布前总门（plugin 加载 + 沙盒接线 + verify + 全套 + doctor，非破坏）
```
