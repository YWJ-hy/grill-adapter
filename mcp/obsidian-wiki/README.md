# @grill-adapter/obsidian-wiki

The package provides the Obsidian Wiki MCP server shipped by grill-adapter and a
local runtime CLI for maintaining the machine configuration and write bridge.

## Install

```bash
npm install --global @grill-adapter/obsidian-wiki
obsidian-wiki init
```

`init` creates a commented JSONC template at
`~/.config/grill-adapter/obsidian-wiki.example.jsonc` and a non-overwriting active
configuration at `~/.config/grill-adapter/obsidian-wiki.jsonc`.

## Commands

```bash
obsidian-wiki config path
obsidian-wiki config set-location /path/to/obsidian-wiki.jsonc
obsidian-wiki config validate
obsidian-wiki doctor
obsidian-wiki bridge start
obsidian-wiki bridge status
```

The MCP server uses the same configuration. Configuration discovery order is:

1. `--config <path>`
2. `OBSIDIAN_WIKI_CONFIG`
3. the location pointer written by `config set-location`
4. `~/.config/grill-adapter/obsidian-wiki.jsonc`
5. the legacy `OBSIDIAN_WIKI_REGISTRY` path and JSON filename

The bridge remains a separate loopback HTTP process. `bridge start` reads its
Vault root, allowed Source roots, project allowlist, host, and port from the
same configuration file. The bearer token remains in the environment variable
named by `bridge.tokenEnv`.

## Publishing

From this directory:

```bash
npm install
npm test
npm publish
```

The package requires Node.js 20 or newer.
