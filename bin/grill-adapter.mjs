#!/usr/bin/env node

import { existsSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const PACKAGE_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const VERSION = JSON.parse(readFileSync(join(PACKAGE_ROOT, "package.json"), "utf8")).version;
const PROJECT_COMMANDS = new Set(["install", "uninstall", "verify", "status", "doctor"]);

function usage(code = 0) {
  const stream = code === 0 ? process.stdout : process.stderr;
  stream.write(`grill-adapter ${VERSION}

Use from a target project directory:
  grill-adapter install [project] [--host grill|plain] [--runtime claude|codex|both]
  grill-adapter uninstall [project] [--runtime claude|codex|both]
  grill-adapter verify [project] [--host grill|plain] [--runtime claude|codex|both]
  grill-adapter status [project] [--runtime claude|codex|both]
  grill-adapter doctor [project]
  grill-adapter init-wiki <project> [analysis-hint]
  grill-adapter bootstrap-wiki <project> [--template name] [--wiki-root project|shared]
  grill-adapter export-wiki-skills <wiki-repo> [--no-graph-ci]

Package maintenance:
  grill-adapter version
  grill-adapter package-root
  grill-adapter validate-package

The package carries the plugin payload. Host plugin activation remains a separate
Claude Code/Codex operation, while the commands above wire the target project.
`);
  process.exit(code);
}

function validatePackage() {
  const required = [
    ".claude-plugin/plugin.json",
    ".codex-plugin/plugin.json",
    ".mcp.json",
    "hooks/hooks.json",
    "manifest.json",
    "skills",
    "agents",
    "hooks",
    "scripts",
    "lib",
    "contracts",
    "host-adapters",
    "mcp/obsidian-wiki/dist/index.js",
  ];
  const missing = required.filter((relative) => !existsSync(join(PACKAGE_ROOT, relative)));
  if (missing.length > 0) {
    throw new Error(`package is missing required runtime files:\n- ${missing.join("\n- ")}`);
  }
  const metadata = [
    ".claude-plugin/plugin.json",
    ".codex-plugin/plugin.json",
    "manifest.json",
  ];
  const drift = metadata.filter((relative) => {
    const value = JSON.parse(readFileSync(join(PACKAGE_ROOT, relative), "utf8"));
    return value.version !== VERSION;
  });
  if (drift.length > 0) {
    throw new Error(`package version ${VERSION} does not match:\n- ${drift.join("\n- ")}`);
  }
  process.stdout.write(`package OK: grill-adapter@${VERSION}\n`);
}

function addDefaultProject(command, args) {
  if (!PROJECT_COMMANDS.has(command)) return args;
  if (args.length === 0 || args[0].startsWith("-")) {
    return [process.cwd(), ...args];
  }
  return args;
}

function runManage(command, args) {
  const forwarded = addDefaultProject(command, args);
  const env = { ...process.env, GRILL_ADAPTER_PACKAGE_ROOT: PACKAGE_ROOT };
  const result = process.platform === "win32"
    ? spawnSync(
        "powershell.exe",
        [
          "-NoProfile",
          "-ExecutionPolicy",
          "Bypass",
          "-File",
          join(PACKAGE_ROOT, "manage.ps1"),
          command,
          ...forwarded,
        ],
        { cwd: process.cwd(), env, stdio: "inherit" },
      )
    : spawnSync("bash", [join(PACKAGE_ROOT, "manage.sh"), command, ...forwarded], {
        cwd: process.cwd(),
        env,
        stdio: "inherit",
      });
  if (result.error) throw result.error;
  process.exit(result.status ?? 1);
}

const [command, ...args] = process.argv.slice(2);
try {
  if (!command || command === "help" || command === "--help" || command === "-h") {
    usage(0);
  } else if (command === "version" || command === "--version" || command === "-v") {
    process.stdout.write(`${VERSION}\n`);
  } else if (command === "package-root") {
    process.stdout.write(`${PACKAGE_ROOT}\n`);
  } else if (command === "validate-package") {
    validatePackage();
  } else if (command === "self-test" || command === "release-check") {
    throw new Error(`${command} is a source-repository command; run it from a grill-adapter checkout`);
  } else {
    runManage(command, args);
  }
} catch (error) {
  process.stderr.write(`grill-adapter: ${error instanceof Error ? error.message : String(error)}\n`);
  process.exit(1);
}
