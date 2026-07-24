# grill-adapter 快速上手（5 分钟）

面向**已经装好 grill**（mattpocock/skills）并在用 Claude Code 或 Codex 的人。没装过 grill 请看 `docs/SETUP_AND_USAGE_CN.md`。

## 1. 装 grill-adapter

grill-adapter 同时支持 Claude Code 和 Codex plugin。两步：

**① 装 plugin**（在你的项目目录下）：

```bash
claude plugin marketplace add YWJ-hy/grill-adapter
claude plugin install grill-adapter@grill-adapter --scope project
```

Codex：

```bash
codex plugin marketplace add YWJ-hy/grill-adapter
codex plugin add grill-adapter@grill-adapter
```

13 个 skill、3 个 hook 事件、两个 MCP **一起注册、自动生效**。Claude 直接注册 1 个 agent；Codex 由入口 skill 派生同角色 sub-agent。MCP 装好即自动启动，无需手工注册。

**② 给项目写约定块**（plugin 唯一管不到的东西）：

```bash
npm install --global grill-adapter
grill-adapter install /path/to/your/project --host grill --runtime claude
# Codex 改用 --runtime codex；双端项目用 --runtime both
```

只把 grill 约定块写进你项目的 `CLAUDE.md`/`AGENTS.md`（marker 包裹，只点名 skill、不含安装路径）。**不改 grill 一行。**

Windows 如果 `bash` 指向没有 `/bin/bash` 的 WSL shim，请改用仓库提供的 PowerShell 入口：

```powershell
.\manage.ps1 install <project-root> --host grill --runtime both
.\manage.ps1 self-test
```

它会自动选择 Git Bash；也可以通过 `GRILL_ADAPTER_BASH` 指定 `bash.exe`。

## 2. 配置 Obsidian Wiki Source

按 `docs/OBSIDIAN_WIKI_CN.md` 配置项目 `.shared-adapter/settings.json` 的 `wiki.provider: obsidian` / bindings、机器本地 registry，以及 Source 的 `_meta/wiki-source.md`。然后运行：

```bash
grill-adapter doctor /path/to/your/project
```

新项目应显示 `adoptionState: obsidian-native` 和 `Obsidian runtime healthy: yes`。已有 `.adapter/wiki/` / `.shared-adapter/wiki/` 的项目显示 `shadow-validation`：正式路径只读 Obsidian，legacy roots 原样保留用于 `/grill-adapter:migrate-wiki` 的 plan/verify，不能充当 runtime fallback。`bootstrap-wiki` 只保留给尚未设置 Obsidian provider 的 legacy 项目。

## 3. 跑一遍 grill → implement → update-wiki

在对应运行时里对你的项目（Claude 用 `/skill`，Codex 用 `$plugin:skill`）：

1. `/grill-with-docs`：描述需求。约定会在质询期自动提示调 `/grill-adapter:wiki-research` 披露相关 wiki。
2. `/to-tickets`：规划期 `/grill-adapter:wiki-research`（plan）正式选 bound atomic Notes/Skill Cards → 生成 schema-v6 `.adapter/context/<feature-slug>.wiki-context.json` sidecar；ticket 发布后由真实 ticket 建 roster，再 `--finalize` 盖指纹。
3. `/implement`：首次代码修改前跑 `/grill-adapter:wiki-readiness`。formal ticket 复用已有 context；direct issue/manual 建单任务 roster 并按需 late Carry；`ready` 才 materialize，`no-relevant`/`disabled` 直接继续，`broken` 由用户选择停止或无 Wiki 继续。改到 source-of-truth 保护路径时 `source-truth-lint` hook 会提醒。
4. `/code-review`：启动 Standards/Spec 两个 review agent 前，`/grill-adapter:wiki-readiness` 复用 implement receipt 生成同一个 reviewer handoff；只有 `ready` 才按 reviewer 角色 materialize，其他状态或失败只给非阻塞 caveat，不补 research、不阻止评审。
5. 各阶段发现 durable 候选时跑 `/grill-adapter:candidate-journal` 追加到同一 feature journal；`/code-review` 后跑 `/grill-adapter:update-wiki`，先校验/折叠 journal，再记录 keep/skip/defer 并处理回写。

## 4. 验证

```bash
grill-adapter verify /path/to/your/project --host grill --runtime codex
./manage.sh self-test                          # 跑全套 smoke（可选）
```

## 常用命令速查

```
./manage.sh install|uninstall|verify|status <project> [--host grill|plain] [--runtime claude|codex|both]
./manage.sh bootstrap-wiki <project> [--template standard]  # legacy only
./manage.sh init-wiki <project> [hint]
./manage.sh export-wiki-skills <wiki-repo> [--no-graph-ci]
./manage.sh doctor <project>
./manage.sh self-test [project]
./manage.sh release-check <project>
```

要卸载：把 `grill-adapter@grill-adapter` 从项目 `.claude/settings.json` 的 `enabledPlugins` 里删掉（project scope 是提交进仓库、与团队共享的设置，`claude plugin uninstall` 会**拒绝**替你删；只想自己关掉用 `claude plugin disable grill-adapter@grill-adapter --scope local`），再 `./manage.sh uninstall /path/to/your/project` 剥项目约定块。
