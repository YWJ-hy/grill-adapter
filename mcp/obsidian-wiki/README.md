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
configuration at `~/.config/grill-adapter/obsidian-wiki.jsonc`. The active
configuration starts empty so an orchestration skill can populate it without
leaving example paths active.

## Commands

```bash
obsidian-wiki config path
obsidian-wiki config set-location /path/to/obsidian-wiki.jsonc
printf '%s' '<vault-json>' | obsidian-wiki config upsert-vault
printf '%s' '<repository-json>' | obsidian-wiki config upsert-repository
obsidian-wiki config validate
obsidian-wiki doctor
obsidian-wiki bridge start
obsidian-wiki bridge status
obsidian-wiki bridge stop
obsidian-wiki bridge restart
```

The MCP server uses the same configuration. Configuration discovery order is:

1. `--config <path>`
2. `OBSIDIAN_WIKI_CONFIG`
3. the location pointer written by `config set-location`
4. `~/.config/grill-adapter/obsidian-wiki.jsonc`
5. the legacy `OBSIDIAN_WIKI_REGISTRY` path and JSON filename

## Bounded retrieval

`obsidian_wiki_search` accepts `limit` (1-50) and an opaque `cursor`. Results
are ordered by stable bound Source path and include `page.limit`,
`page.scannedCount`, `page.returnedCount`, `page.truncated`, and, when more
candidates remain, `page.nextCursor`. A cursor is bound to the original query,
Source, path prefix, publish mode, and binding identities; malformed or
integrity-invalid cursors and cursors reused for another scope are rejected.

`obsidian_wiki_catalog` uses the same `limit`/`cursor` response contract while
retaining `offset`/`nextOffset` for existing callers. Catalog pages are built
from active, agent-visible atomic Note frontmatter in the validated bound Git
revision. They never call Obsidian full-body reads and deliberately omit
`content` and `contentHash`. Selected Notes must still be passed to
`obsidian_wiki_read_notes` or `obsidian_wiki_read_notes_by_wiki_ids`; those
stable batch operations reread full Markdown and return authoritative content
and snapshot hashes.

The bridge remains a separate loopback HTTP process. `bridge start` reads its
Vault root, allowed Source roots, project allowlist, host, and port from the
same configuration file. The bearer token remains in the environment variable
named by `bridge.tokenEnv`.

`bridge start` starts a detached background bridge, waits for its health endpoint,
and then exits the terminal. `bridge stop` sends an authenticated loopback
shutdown request and waits for the health endpoint to go offline. `bridge restart`
performs the same stop, then starts a detached background bridge and waits for it
to become healthy. Use `serve-write-bridge` when a foreground process is needed
for an external supervisor.

`upsert-vault` and `upsert-repository` are idempotent and preserve unrelated
registry entries. If an existing entry differs, they fail unless `--replace` is
passed explicitly after the caller obtains authorization. JSON is supplied on
stdin so callers do not need to edit the machine config file.

## Publishing

From this directory:

```bash
npm install
npm test
npm publish
```

The package requires Node.js 20 or newer.
