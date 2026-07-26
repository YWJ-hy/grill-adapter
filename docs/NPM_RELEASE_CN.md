# npm 发布与本地升级

根级 `grill-adapter` npm 包承载完整 plugin payload 和统一 `grill-adapter` CLI。`@grill-adapter/obsidian-wiki` 是唯一独立 MCP 包；根包不会把它的源码或 `node_modules` 打进 tarball，只携带已经构建好的 `dist/index.js`。

## 发布前

在仓库根目录确认 Node.js 20+、Python 3.9+ 和 npm 可用：

```bash
npm run pack:dry
npm run test:package
```

`prepack` 会检查 `.claude-plugin/plugin.json`、`.codex-plugin/plugin.json`、`manifest.json` 与根 `package.json` 的版本一致，并检查插件 skills、hooks、contracts、脚本和 Obsidian MCP bundle 都在包内。

## 版本

根 `package.json` 是唯一版本入口。使用 npm 的 semver 命令：

```bash
npm version patch
npm version minor
npm version major
```

`version` lifecycle 会同步三个插件/manifest 元数据并把它们加入本次版本提交。不要只手改某一个 `plugin.json`。发布前 `npm run pack:dry` 会再次拒绝版本漂移。

## 发布到 npm 官方

首次发布需要 npm 官方账号和一次登录：

```bash
npm login
npm publish --access public
```

本地手工发布后续版本：

```bash
npm version patch
npm publish
```

发布前可用 `npm view grill-adapter version` 查看 registry 上的当前版本。发布命令不会自动启用 Claude Code 或 Codex plugin，也不会修改业务项目。

日常合并不需要执行这些命令；启用下方的 Trusted Publishing 后，`main` 分支的包
payload 变更会由 GitHub Actions 自动递增版本并发布。

## 自动发布与 Trusted Publishing

仓库提供 `.github/workflows/npm-publish.yml`。合并到 `main` 后，workflow 会比较本次
提交涉及的文件：只要 npm 包 payload 发生变化，就自动构建、验收、递增 patch 版本、
提交版本变更并通过 GitHub Actions OIDC Trusted Publishing 发布。不会因为测试文件或
workflow 自身变化发布 npm 包。

workflow 使用 provenance，不保存 npm token，也不要求在 runner 上输入 OTP。并发发布
会串行化，自动生成的版本提交带有 `[skip ci]`，不会形成重复触发。

也保留了 Actions 手动触发入口 `publish_current`，用于发布当前已经写入
`package.json` 的版本，不会再次递增版本。

首次启用前，为两个已存在的包分别建立 npm trusted publisher，workflow 文件名和仓库
必须完全匹配：

```bash
npm trust github grill-adapter \
  --repo YWJ-hy/grill-adapter \
  --file npm-publish.yml \
  --allow-publish

npm trust github @grill-adapter/obsidian-wiki \
  --repo YWJ-hy/grill-adapter \
  --file npm-publish.yml \
  --allow-publish
```

配置完成后，把 workflow 推送到 GitHub。之后不需要手动创建 Release：每次合并
相关代码到 `main` 都会自动发布。workflow 会先运行 Obsidian runtime 和根包验收，
再按自动递增后的版本发布 `@grill-adapter/obsidian-wiki` 与 `grill-adapter`。

## 让宿主使用 npm 包

npm 包本身也是一个本地 plugin marketplace source。首次使用 npm 版本时，把全局安装目录加入宿主：

Claude Code：

```bash
claude plugin marketplace add "$(grill-adapter package-root)"
claude plugin install grill-adapter@grill-adapter --scope user
```

Codex：

```bash
codex plugin marketplace add "$(grill-adapter package-root)"
codex plugin add grill-adapter@grill-adapter
```

这一步只需在每台机器上做一次。它让宿主读取 npm 包内的 `.claude-plugin` / `.codex-plugin`、skills、hooks 和 MCP bundle，而不是 GitHub checkout。

## 本地安装与更新

发布后，在任意业务项目外部安装 CLI：

```bash
npm install --global grill-adapter
grill-adapter --version
```

升级到最新版本：

```bash
npm update --global grill-adapter
```

升级到指定版本：

```bash
npm install --global grill-adapter@0.3.0
```

`npm update` 只替换本机 npm 包；要让已运行的宿主重新加载新版本，还要刷新本地 marketplace 并执行 plugin update/add：

Claude Code：

```bash
claude plugin marketplace update grill-adapter
claude plugin update grill-adapter@grill-adapter
```

Codex：

```bash
codex plugin add grill-adapter@grill-adapter
```

Codex 的本地 marketplace 不需要 Git fetch，重新 `plugin add` 会从当前 `package-root` 重新安装；Claude 的 `marketplace update` 后再 `plugin update`。宿主 plugin 的缓存仍由宿主管理，npm 更新不会自动改写它。

也可以不做全局安装：

```bash
npx grill-adapter@latest --version
npx grill-adapter@latest install /path/to/project --runtime codex
```

安装 CLI 后，在业务项目目录直接运行：

```bash
cd /path/to/project
grill-adapter install --runtime codex --host grill
grill-adapter doctor
```

项目路径省略时，`install`、`uninstall`、`verify`、`status`、`doctor` 默认使用当前目录。npm 包只负责分发和执行；plugin 激活仍按宿主自己的命令完成，项目约定块则由上述 CLI 写入。
