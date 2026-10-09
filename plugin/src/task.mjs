/**
 * Core TaskChampion/Taskwarrior helpers for the opencode-tasks plugin.
 *
 * Targets the shared sync pool via the bare `task` binary (default ~/.taskrc),
 * per the global OpenCode agent rules: sync before ANY operation and after
 * EVERY mutation, UUID-first references.
 *
 * Live-pool reality (verified 2026-10-07):
 * - No custom UDAs are defined on the shared pool. UDA-style writes such as
 *   `task <uuid> modify assigned_agent:X` are silently reinterpreted as
 *   description text, so this module refuses UDA writes by default.
 * - Lifecycle is tracked with tags + annotations (hyphenated, e.g.
 *   `ready-for-review`, `agent-created`). Hyphenated tags misbehave in CLI
 *   filter expressions, so tag filtering is done client-side after `export`.
 *
 * Plain JavaScript (no dependencies) so it can be unit-tested directly with
 * `node --test` and imported from the TypeScript plugin entrypoint.
 */

import { execFile } from "node:child_process";
import { existsSync } from "node:fs";

export const DEFAULT_TASK_BIN = "/opt/homebrew/bin/task";
export const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export const TAG_RE = /^[A-Za-z0-9_-]+$/;
export const PRIORITIES = new Set(["H", "M", "L"]);

/**
 * Underscore-safe spellings (used by the Phase 6 MCP policy wrapper) mapped
 * to the hyphenated canonical tags stored in the live shared pool.
 */
export const TAG_CANONICAL = new Map([
  ["ready_for_review", "ready-for-review"],
  ["agent_created", "agent-created"],
  ["agent_owned", "agent-owned"],
  ["human_review", "human-review"],
  ["technical_debt", "technical-debt"],
  ["in_review", "in-review"],
  ["phase6_validation", "phase6-validation"],
]);

/** Homebrew path when it exists (macOS); otherwise `task` resolved from PATH. */
function defaultTaskBin() {
  return existsSync(DEFAULT_TASK_BIN) ? DEFAULT_TASK_BIN : "task";
}

/** Resolve the task binary / taskrc from plugin options, env, then defaults. */
export function resolveConfig(options = {}) {
  const bin =
    options.taskBin || process.env.TASK_BIN || defaultTaskBin();
  const taskrc = options.taskrc || process.env.TASKRC || undefined;
  let autoSync = true;
  if (options.autoSync !== undefined) autoSync = Boolean(options.autoSync);
  else if (process.env.TASK_AUTO_SYNC === "0") autoSync = false;
  return { bin, taskrc, autoSync };
}

function taskEnv(config) {
  if (!config.taskrc) return undefined;
  return { ...process.env, TASKRC: config.taskrc };
}

/** Run the task binary and return trimmed stdout. Rejects with stderr context. */
export function runTask(config, args, { signal } = {}) {
  return new Promise((resolve, reject) => {
    execFile(
      config.bin,
      args,
      { encoding: "utf8", env: taskEnv(config), signal },
      (error, stdout, stderr) => {
        if (error) {
          const detail = (stderr || error.message || "").trim();
          reject(
            new Error(`task ${args.join(" ")} failed: ${detail}`),
          );
          return;
        }
        resolve((stdout || "").trim());
      },
    );
  });
}

/**
 * Sync with the TaskChampion server.
 * Per agent rules a sync failure must stop the operation, not retry in a loop.
 */
export async function sync(config, { signal } = {}) {
  try {
    const output = await runTask(config, ["sync"], { signal });
    return { ok: true, output };
  } catch (error) {
    throw new Error(
      `TaskChampion sync failed; report and stop, do not retry in a loop: ${error.message}`,
    );
  }
}

/**
 * Export tasks as parsed JSON. filterArgs are CLI-safe filters only.
 * Uses rc.json.array=off for NDJSON output — faster to parse for large lists.
 */
export async function exportTasks(config, filterArgs = [], { signal } = {}) {
  const output = await runTask(config, ["rc.json.array=off", ...filterArgs, "export"], { signal });
  if (!output) return [];
  const tasks = [];
  for (const line of output.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    try {
      tasks.push(JSON.parse(trimmed));
    } catch {
      throw new Error(`Failed to parse 'task export' NDJSON line: ${trimmed.slice(0, 120)}`);
    }
  }
  return tasks;
}

/** Fetch exactly one task by full UUID. */
export async function getTask(config, uuid, { signal } = {}) {
  assertUuid(uuid);
  const tasks = await exportTasks(config, [uuid], { signal });
  if (tasks.length !== 1) {
    throw new Error(`Expected one task for UUID ${uuid}, found ${tasks.length}`);
  }
  return tasks[0];
}

/** Count tasks matching CLI-safe filters. Much faster than export for counts. */
export async function countTasks(config, filterArgs = [], { signal } = {}) {
  const output = await runTask(config, [...filterArgs, "count"], { signal });
  const n = parseInt(output.trim(), 10);
  if (Number.isNaN(n)) {
    throw new Error(`Failed to parse 'task count' output: ${output}`);
  }
  return n;
}

export function assertUuid(uuid) {
  if (typeof uuid !== "string" || !UUID_RE.test(uuid)) {
    throw new Error(
      `Task operations require a full UUID (got ${JSON.stringify(uuid)}). Resolve short IDs to UUIDs first; numeric IDs are replica-local.`,
    );
  }
}

export function assertActor(actor) {
  if (typeof actor !== "string" || actor.length < 1 || actor.length > 80) {
    throw new Error("actor must be a non-empty string (max 80 chars)");
  }
}

/** Normalize underscore-safe lifecycle spellings to live-pool hyphenated tags. */
export function normalizeTag(tag) {
  if (typeof tag !== "string" || !TAG_RE.test(tag)) {
    throw new Error(
      `Invalid tag ${JSON.stringify(tag)}: use letters, digits, '-' or '_' only`,
    );
  }
  return TAG_CANONICAL.get(tag) ?? tag;
}

export function normalizeTags(tags = []) {
  if (!Array.isArray(tags)) throw new Error("tags must be an array");
  return tags.map(normalizeTag);
}

/** Structured audit annotation: `[actor] action: detail`. */
export function formatAnnotation(actor, action, detail) {
  assertActor(actor);
  if (typeof action !== "string" || action.trim().length === 0) {
    throw new Error("annotation action must be a non-empty string");
  }
  if (typeof detail !== "string" || detail.trim().length === 0) {
    throw new Error("annotation detail must be a non-empty string");
  }
  return `[${actor}] ${action}: ${detail}`;
}

/** Stored tags normalized to canonical form (defensive: accepts either spelling). */
function canonicalTags(task) {
  const tags = Array.isArray(task.tags) ? task.tags : [];
  return tags.map((t) => {
    try {
      return normalizeTag(t);
    } catch {
      return t;
    }
  });
}

export function hasTag(task, tag) {
  const canonical = normalizeTag(tag);
  return canonicalTags(task).includes(canonical);
}

/**
 * Client-side tag filtering. Required because hyphenated tags (e.g.
 * `+ready-for-review`) are mis-parsed in CLI filter expressions: the CLI
 * returned 262 tasks where only 44 actually carried the tag.
 */
export function applyTagFilter(tasks, includeTags = [], excludeTags = []) {
  const include = normalizeTags(includeTags);
  const exclude = normalizeTags(excludeTags);
  return tasks.filter((task) => {
    const tags = canonicalTags(task);
    if (!include.every((t) => tags.includes(t))) return false;
    if (exclude.some((t) => tags.includes(t))) return false;
    return true;
  });
}

/** Find the actor of the most recent `[actor] claimed:` annotation, if any. */
export function lastClaimActor(task) {
  const annotations = Array.isArray(task.annotations)
    ? task.annotations
    : [];
  for (let i = annotations.length - 1; i >= 0; i--) {
    const match = /^\[(.+?)\]\s+claimed:/.exec(
      annotations[i]?.description || "",
    );
    if (match) return match[1];
  }
  return undefined;
}

function tagsOf(task) {
  return canonicalTags(task);
}

/** Lifecycle transitions only make sense on pending tasks. */
export function assertActionable(task, { force = false } = {}) {
  if (!force && task.status !== "pending") {
    throw new Error(
      `Task status is ${JSON.stringify(task.status)}, not pending; lifecycle transitions require a pending task (or retry with force:true)`,
    );
  }
}

/** Guard for claim_task. Throws on violation unless force is set. */
export function claimGuard(task, actor, { force = false } = {}) {
  assertActionable(task, { force });
  if (hasTag(task, "ready-for-review") || hasTag(task, "review")) {
    throw new Error("Task is already in review and cannot be claimed");
  }
  if (tagsOf(task).includes("claimed") && !force) {
    const holder = lastClaimActor(task);
    throw new Error(
      holder && holder !== actor
        ? `Task is already claimed by ${holder}; release it first or retry with force:true`
        : "Task is already claimed; release it first or retry with force:true",
    );
  }
}

/** Guard for start. Taskwarrior tracks active work via the `start` field. */
export function startGuard(task, { force = false } = {}) {
  assertActionable(task, { force });
  if (task.start && !force) {
    throw new Error("Task is already started; stop it first or retry with force:true");
  }
}

/** Guard for complete_task. */
export function completeGuard(task, { force = false } = {}) {
  assertActionable(task, { force });
  if (!force && !hasTag(task, "approved") && !hasTag(task, "ready-for-review")) {
    throw new Error(
      "Task completion requires +approved (use approve first) or +ready-for-review; or retry with force:true and a note",
    );
  }
}

/** Guard for approve. */
export function approveGuard(task, { force = false } = {}) {
  assertActionable(task, { force });
  if (!force && !hasTag(task, "ready-for-review")) {
    throw new Error(
      "Only tasks tagged ready-for-review can be approved; submit for review first or retry with force:true",
    );
  }
}

const MUTABLE_DATE_FIELDS = new Set([
  "due",
  "scheduled",
  "wait",
  "until",
  "recur",
]);

function assertDateField(name, value) {
  if (typeof value !== "string" || value.trim().length === 0) {
    throw new Error(`${name} must be a non-empty date string (e.g. "tomorrow", "2026-10-15")`);
  }
}

/**
 * Build `task add` modification args from structured input.
 * Rejects UDA-style fields: the shared pool defines no custom UDAs and the
 * CLI would silently rewrite the description instead of failing.
 */
export function buildSetArgs(input = {}) {
  const args = [];
  if (input.project !== undefined) {
    if (typeof input.project !== "string" || input.project.length === 0) {
      throw new Error("project must be a non-empty string");
    }
    args.push(`project:${input.project}`);
  }
  if (input.priority !== undefined) {
    if (!PRIORITIES.has(input.priority)) {
      throw new Error('priority must be one of "H", "M", "L"');
    }
    args.push(`priority:${input.priority}`);
  }
  for (const field of MUTABLE_DATE_FIELDS) {
    if (input[field] !== undefined) {
      assertDateField(field, input[field]);
      args.push(`${field}:${input[field]}`);
    }
  }
  for (const tag of normalizeTags(input.tags || [])) args.push(`+${tag}`);
  if (input.depends !== undefined) {
    const deps = Array.isArray(input.depends) ? input.depends : [input.depends];
    for (const dep of deps) {
      assertUuid(dep);
      args.push(`depends:${dep}`);
    }
  }
  if (input.udas !== undefined) {
    throw new Error(
      "Custom UDAs are not defined on the shared TaskChampion pool and CLI writes would corrupt the description. " +
        "Omit `udas`, or point the plugin at a profile that defines them (TASKRC) with allowUdas:true.",
    );
  }
  return args;
}

/** Build `task <uuid> modify` args from structured input. */
export function buildModifyArgs(input = {}) {
  const args = [];
  if (input.description !== undefined) {
    if (typeof input.description !== "string" || input.description.length === 0) {
      throw new Error("description must be a non-empty string");
    }
    args.push(input.description);
  }
  args.push(...buildSetArgs(input));
  for (const tag of normalizeTags(input.add_tags || [])) args.push(`+${tag}`);
  for (const tag of normalizeTags(input.remove_tags || [])) args.push(`-${tag}`);
  return args;
}

/** Parse `task projects` / `task tags` listings into string arrays. */
export function parseListing(output) {
  return output
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line.length > 0 && !/^No |^A configuration/i.test(line));
}

/** Detect OS and return install instructions for taskwarrior.
 * TaskChampion sync is built into taskwarrior 3.x — there is no separate
 * taskchampion package or sync service to install. */
export function getInstallInstructions() {
  const platform = process.platform;
  const arch = process.arch;
  const isMac = platform === "darwin";
  const isLinux = platform === "linux";
  const isWin = platform === "win32";

  const instructions = [];

  if (isMac) {
    instructions.push({
      manager: "Homebrew",
      command: "brew install task",
      note: "TaskChampion sync is built into taskwarrior 3.x — no separate package or service.",
    });
    if (arch === "arm64") {
      instructions.push({
        manager: "MacPorts (alternative)",
        command: "sudo port install task",
      });
    }
  } else if (isLinux) {
    instructions.push({
      manager: "Debian/Ubuntu",
      command: "sudo apt update && sudo apt install taskwarrior",
    });
    instructions.push({
      manager: "Fedora/RHEL",
      command: "sudo dnf install task",
    });
    instructions.push({
      manager: "Arch/Manjaro",
      command: "sudo pacman -S task",
    });
    instructions.push({
      manager: "openSUSE",
      command: "sudo zypper install taskwarrior",
    });
    instructions.push({
      manager: "NixOS",
      command: "nix-env -iA nixos.taskwarrior",
    });
  } else if (isWin) {
    instructions.push({
      manager: "Scoop",
      command: "scoop install taskwarrior",
    });
    instructions.push({
      manager: "Chocolatey",
      command: "choco install taskwarrior",
    });
    instructions.push({
      manager: "Winget",
      command: "winget install Taskwarrior.Taskwarrior",
    });
  } else {
    instructions.push({
      manager: "Unknown platform",
      command: "See https://taskwarrior.org/download/",
    });
  }

  return { platform, arch, instructions };
}

/** Check if `task` binary exists and is executable. */
export async function checkTaskBinary(config) {
  try {
    const output = await runTask(config, ["--version"], {});
    return { ok: true, version: output.trim() };
  } catch (error) {
    return { ok: false, error: error.message };
  }
}

/** Check TaskChampion sync connectivity. */
export async function checkSync(config) {
  try {
    const result = await sync(config, {});
    return { ok: true, output: result.output };
  } catch (error) {
    return { ok: false, error: error.message };
  }
}

/** Full environment doctor check. */
export async function doctor(config) {
  const binary = await checkTaskBinary(config);
  const syncCheck = await checkSync(config);
  const install = getInstallInstructions();

  return {
    task_binary: binary,
    taskchampion_sync: syncCheck,
    platform: install.platform,
    arch: install.arch,
    install_instructions: install.instructions,
    summary: binary.ok && syncCheck.ok
      ? "All checks passed ✓"
      : "Issues detected — see details above",
  };
}

/** Generate a platform-specific shell script to install taskwarrior. */
export function generateSetupScript(options = {}) {
  // includeSyncService is accepted for compatibility but ignored: TaskChampion
  // sync is built into taskwarrior 3.x, there is no service to start.
  const { includeVerify = true } = options;
  const install = getInstallInstructions();
  const lines = [
    "#!/usr/bin/env bash",
    "# Generated by opencode-tasks plugin — taskwarrior setup",
    `# Platform: ${install.platform} (${install.arch})`,
    `# Date: ${new Date().toISOString()}`,
    "",
    "set -euo pipefail",
    "",
    "echo \"Installing taskwarrior...\"",
    "",
  ];

  // Use the first (preferred) instruction for the platform
  const primary = install.instructions[0];
  if (primary) {
    lines.push(`# ${primary.manager}`);
    lines.push(primary.command);
    if (primary.note) {
      lines.push(`# ${primary.note}`);
    }
    lines.push("");
  }

  if (includeVerify) {
    lines.push("# Verify installation");
    lines.push("task --version");
    lines.push("");
    lines.push("# Test sync (requires a configured taskrc with a sync server)");
    lines.push("task sync || echo \"Sync failed — check your taskrc configuration\"");
    lines.push("");
  }

  lines.push("echo \"Setup complete.\"");
  return lines.join("\n");
}
