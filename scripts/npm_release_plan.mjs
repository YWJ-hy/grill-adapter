#!/usr/bin/env node

import { execFileSync } from "node:child_process";

const [, , base, head, ...flags] = process.argv;
const force = flags.includes("--force");

if (!head) {
  throw new Error("usage: npm_release_plan.mjs <base> <head> [--force]");
}

const changedFiles = base && !/^0+$/.test(base)
  ? execFileSync("git", ["diff", "--name-only", base, head], { encoding: "utf8" })
      .split("\n")
      .map((file) => file.trim())
      .filter(Boolean)
  : execFileSync("git", ["diff-tree", "--root", "--no-commit-id", "--name-only", "-r", head], {
      encoding: "utf8",
    })
      .split("\n")
      .map((file) => file.trim())
      .filter(Boolean);

const rootIgnored = (file) =>
  file.startsWith(".github/") ||
  file.startsWith("tests/") ||
  file.startsWith("docs/") ||
  file.startsWith("mcp/obsidian-wiki/tests/") ||
  file === "AGENTS.md" ||
  file === "README.md" ||
  file === "QUICKSTART_CN.md" ||
  file === "scripts/npm_release_plan.mjs";

const rootChanged =
  force ||
  changedFiles.some((file) => !rootIgnored(file) && file !== "mcp/obsidian-wiki/README.md");
const obsidianChanged =
  force ||
  changedFiles.some(
    (file) =>
      file.startsWith("mcp/obsidian-wiki/src/") ||
      file.startsWith("mcp/obsidian-wiki/dist/") ||
      file.startsWith("mcp/obsidian-wiki/scripts/") ||
      file === "mcp/obsidian-wiki/package.json" ||
      file === "mcp/obsidian-wiki/package-lock.json" ||
      file === "mcp/obsidian-wiki/README.md",
  );
const release = rootChanged || obsidianChanged;

console.log(`release=${release}`);
console.log(`root=${rootChanged}`);
console.log(`obsidian=${obsidianChanged}`);
console.log(`changedFiles=${changedFiles.length}`);
