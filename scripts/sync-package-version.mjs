#!/usr/bin/env node

import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const packagePath = join(root, "package.json");
const version = JSON.parse(readFileSync(packagePath, "utf8")).version;
const metadataPaths = [
  ".claude-plugin/plugin.json",
  ".codex-plugin/plugin.json",
  "manifest.json",
];
const checkOnly = process.argv.includes("--check");
const drift = [];

for (const relative of metadataPaths) {
  const file = join(root, relative);
  const value = JSON.parse(readFileSync(file, "utf8"));
  if (value.version === version) continue;
  drift.push(`${relative}: ${value.version} != ${version}`);
  if (!checkOnly) {
    value.version = version;
    writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`, "utf8");
  }
}

if (drift.length > 0 && checkOnly) {
  process.stderr.write(`package version metadata drift:\n- ${drift.join("\n- ")}\n`);
  process.exit(1);
}

if (!checkOnly) {
  process.stdout.write(`synced plugin metadata to ${version}\n`);
}
