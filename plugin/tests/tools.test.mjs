/**
 * Unit tests for tools.ts — the 22 task lifecycle tool handlers.
 *
 * Uses a fake task binary (see helpers/fake-task.mjs) to control
 * responses and verify command sequences without a real TaskChampion
 * sync server.
 */
import { describe, it, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import { createTools } from "../dist/tools.js";
import { createFakeTask } from "./helpers/fake-task.mjs";

const UUID_A = "27594f5a-7c89-4d88-8b08-f33b7ef33b6e";
const UUID_B = "675eb484-efe2-4e3f-9929-ff257db7c9c0";

let fake;
let tools;
let ctx;

function tool(name) {
  const t = tools.find((t) => t.name === name);
  assert.ok(t, `tool not found: ${name}`);
  return t;
}

function jsonResponse(data) {
  return { stdout: JSON.stringify(data) + "\n" };
}

function ndjsonResponse(tasks) {
  return { stdout: tasks.map((t) => JSON.stringify(t)).join("\n") + "\n" };
}

beforeEach(() => {
  fake = createFakeTask();
  tools = createTools(fake.config);
  ctx = {};
});

afterEach(() => {
  fake.cleanup();
});

describe("createTools", () => {
  it("returns 22 tools with valid structure", () => {
    assert.equal(tools.length, 22);
    for (const t of tools) {
      assert.equal(typeof t.name, "string", `tool name: ${t.name}`);
      assert.ok(t.name.length > 0, "tool name not empty");
      assert.equal(typeof t.description, "string", `tool description: ${t.name}`);
      assert.ok(t.description.length > 0, "tool description not empty");
      assert.equal(typeof t.input, "object", `tool input: ${t.name}`);
      assert.equal(typeof t.execute, "function", `tool execute: ${t.name}`);
    }
  });

  it("has all expected tool names", () => {
    const expected = [
      "sync", "add", "list", "get", "modify", "annotate",
      "add_dependency", "claim", "release", "start", "stop",
      "submit_for_review", "approve", "complete", "agent_queue",
      "review_queue", "blocked_tasks", "record_decision", "overview",
      "doctor", "setup", "auto",
    ];
    const actual = tools.map((t) => t.name).sort();
    assert.deepEqual(actual, expected.sort());
  });
});

describe("sync tool", () => {
  it("calls sync and returns result", async () => {
    fake.setResponses([
      { match: "sync", stdout: "Sync complete\n" },
    ]);
    const result = JSON.parse((await tool("sync").execute({}, ctx)).content);
    assert.equal(result.output, "Sync complete");
  });

  it("propagates sync failure", async () => {
    fake.setResponses([
      { match: "sync", stderr: "connection refused\n", exit: 1 },
    ]);
    await assert.rejects(
      () => tool("sync").execute({}, ctx),
      /sync failed/,
    );
  });
});

describe("add tool", () => {
  it("creates a task and returns it", async () => {
    fake.setResponses([
      { match: "add", stdout: `Created task ${UUID_A}.\n` },
      { match: "export", stdout: JSON.stringify({ uuid: UUID_A, status: "pending" }) + "\n" },
    ]);
    const result = JSON.parse((await tool("add").execute({ description: "test task" }, ctx)).content);
    assert.equal(result.uuid, UUID_A);
  });

  it("includes annotations when provided", async () => {
    fake.setResponses([
      { match: "add", stdout: `Created task ${UUID_A}.\n` },
      { match: "annotate", stdout: "Annotation added.\n" },
      { match: "export", stdout: JSON.stringify({ uuid: UUID_A, status: "pending" }) + "\n" },
    ]);
    await tool("add").execute({ description: "test", annotations: ["note one"] }, ctx);
    const calls = fake.getCalls();
    const annotateCalls = calls.filter((c) => c[1] === "annotate");
    assert.equal(annotateCalls.length, 1);
    assert.ok(annotateCalls[0][2].includes("note one"));
  });

  it("rejects empty description", async () => {
    // The add tool passes description to the binary; with an empty string
    // the binary returns no UUID, so the tool fails on UUID resolution.
    await assert.rejects(
      () => tool("add").execute({ description: "" }, ctx),
      /Could not resolve created task UUID/,
    );
  });
});

describe("list tool", () => {
  it("returns tasks with count", async () => {
    const taskData = { uuid: UUID_A, status: "pending", description: "test" };
    fake.setResponses([
      { match: "export", stdout: JSON.stringify(taskData) + "\n" },
    ]);
    const result = JSON.parse((await tool("list").execute({}, ctx)).content);
    assert.equal(result.count, 1);
    assert.equal(result.total_matching, 1);
    assert.equal(result.tasks.length, 1);
  });

  it("clamps limit to 1..500", async () => {
    fake.setResponses([
      { match: "export", stdout: "" },
    ]);
    const result = JSON.parse((await tool("list").execute({ limit: 9999 }, ctx)).content);
    assert.equal(result.count, 0);
  });

  it("filters tags client-side", async () => {
    const tasks = [
      { uuid: UUID_A, status: "pending", tags: ["bug"] },
      { uuid: UUID_B, status: "pending", tags: ["feature"] },
    ];
    fake.setResponses([
      { match: "export", stdout: tasks.map((t) => JSON.stringify(t)).join("\n") + "\n" },
    ]);
    const result = JSON.parse((await tool("list").execute({ tags: ["bug"] }, ctx)).content);
    assert.equal(result.count, 1);
    assert.equal(result.tasks[0].uuid, UUID_A);
  });

  it("excludes tags", async () => {
    const tasks = [
      { uuid: UUID_A, status: "pending", tags: ["bug"] },
      { uuid: UUID_B, status: "pending", tags: ["feature"] },
    ];
    fake.setResponses([
      { match: "export", stdout: tasks.map((t) => JSON.stringify(t)).join("\n") + "\n" },
    ]);
    const result = JSON.parse((await tool("list").execute({ exclude_tags: ["bug"] }, ctx)).content);
    assert.equal(result.count, 1);
    assert.equal(result.tasks[0].uuid, UUID_B);
  });

  it("rejects unsupported status", async () => {
    await assert.rejects(
      () => tool("list").execute({ status: "bogus" }, ctx),
      /Unsupported status/,
    );
  });

  it("supports status=all", async () => {
    fake.setResponses([
      { match: "export", stdout: "" },
    ]);
    const result = JSON.parse((await tool("list").execute({ status: "all" }, ctx)).content);
    assert.equal(result.count, 0);
  });
});

describe("get tool", () => {
  it("fetches a task by UUID", async () => {
    const taskData = { uuid: UUID_A, status: "pending", description: "test" };
    fake.setResponses([
      { match: "export", stdout: JSON.stringify(taskData) + "\n" },
    ]);
    const result = JSON.parse((await tool("get").execute({ uuid: UUID_A }, ctx)).content);
    assert.equal(result.task.uuid, UUID_A);
  });

  it("rejects invalid UUID", async () => {
    await assert.rejects(
      () => tool("get").execute({ uuid: "123" }, ctx),
      /full UUID/,
    );
  });
});

describe("modify tool", () => {
  it("modifies description and tags", async () => {
    fake.setResponses([
      { match: "modify", stdout: "Modified.\n" },
      { match: "export", stdout: JSON.stringify({ uuid: UUID_A, status: "pending" }) + "\n" },
    ]);
    await tool("modify").execute({ uuid: UUID_A, description: "new desc", add_tags: ["approved"] }, ctx);
    const calls = fake.getCalls();
    const modifyCalls = calls.filter((c) => c[1] === "modify");
    assert.equal(modifyCalls.length, 1);
    assert.ok(modifyCalls[0].includes("new desc"));
    assert.ok(modifyCalls[0].includes("+approved"));
  });

  it("rejects empty modification", async () => {
    await assert.rejects(
      () => tool("modify").execute({ uuid: UUID_A }, ctx),
      /Nothing to modify/,
    );
  });

  it("adds a note as annotation", async () => {
    fake.setResponses([
      { match: "annotate", stdout: "Annotation added.\n" },
      { match: "export", stdout: JSON.stringify({ uuid: UUID_A, status: "pending" }) + "\n" },
    ]);
    await tool("modify").execute({ uuid: UUID_A, note: "a note" }, ctx);
    const calls = fake.getCalls();
    const annotateCalls = calls.filter((c) => c[1] === "annotate");
    assert.equal(annotateCalls.length, 1);
    assert.ok(annotateCalls[0][2].includes("a note"));
  });
});

describe("annotate tool", () => {
  it("adds a structured annotation", async () => {
    fake.setResponses([
      { match: "annotate", stdout: "Annotation added.\n" },
      { match: "export", stdout: JSON.stringify({ uuid: UUID_A, status: "pending" }) + "\n" },
    ]);
    await tool("annotate").execute({ uuid: UUID_A, actor: "opencode", action: "note", detail: "hello" }, ctx);
    const calls = fake.getCalls();
    const annotateCalls = calls.filter((c) => c[1] === "annotate");
    assert.equal(annotateCalls.length, 1);
    assert.ok(annotateCalls[0][2].includes("[opencode] note: hello"));
  });
});

describe("claim tool", () => {
  it("claims a pending task", async () => {
    const taskData = { uuid: UUID_A, status: "pending", tags: [] };
    fake.setResponses([
      { match: "export", stdout: JSON.stringify(taskData) + "\n" },
      { match: "modify", stdout: "Modified.\n" },
      { match: "annotate", stdout: "Annotation added.\n" },
    ]);
    const result = JSON.parse((await tool("claim").execute({ uuid: UUID_A, actor: "opencode" }, ctx)).content);
    assert.equal(result.uuid, UUID_A);
    const calls = fake.getCalls();
    const modifyCalls = calls.filter((c) => c[1] === "modify");
    assert.ok(modifyCalls[0].includes("+claimed"));
  });

  it("blocks claim on review-stage tasks", async () => {
    const taskData = { uuid: UUID_A, status: "pending", tags: ["ready-for-review"] };
    fake.setResponses([
      { match: "export", stdout: JSON.stringify(taskData) + "\n" },
    ]);
    await assert.rejects(
      () => tool("claim").execute({ uuid: UUID_A, actor: "opencode" }, ctx),
      /already in review/,
    );
  });

  it("blocks double-claim by different actor", async () => {
    const taskData = {
      uuid: UUID_A, status: "pending", tags: ["claimed"],
      annotations: [{ description: "[alice] claimed: mine" }],
    };
    fake.setResponses([
      { match: "export", stdout: JSON.stringify(taskData) + "\n" },
    ]);
    await assert.rejects(
      () => tool("claim").execute({ uuid: UUID_A, actor: "bob" }, ctx),
      /already claimed by alice/,
    );
  });

  it("allows force re-claim", async () => {
    const taskData = {
      uuid: UUID_A, status: "pending", tags: ["claimed"],
      annotations: [{ description: "[alice] claimed: mine" }],
    };
    fake.setResponses([
      { match: "export", stdout: JSON.stringify(taskData) + "\n" },
      { match: "modify", stdout: "Modified.\n" },
      { match: "annotate", stdout: "Annotation added.\n" },
    ]);
    await tool("claim").execute({ uuid: UUID_A, actor: "bob", force: true }, ctx);
  });
});

describe("release tool", () => {
  it("releases a claimed task", async () => {
    const taskData = { uuid: UUID_A, status: "pending", tags: ["claimed"] };
    fake.setResponses([
      { match: "export", stdout: JSON.stringify(taskData) + "\n" },
      { match: "modify", stdout: "Modified.\n" },
      { match: "annotate", stdout: "Annotation added.\n" },
    ]);
    const result = JSON.parse((await tool("release").execute({ uuid: UUID_A, actor: "opencode" }, ctx)).content);
    assert.equal(result.uuid, UUID_A);
    const calls = fake.getCalls();
    const modifyCalls = calls.filter((c) => c[1] === "modify");
    assert.ok(modifyCalls[0].includes("-claimed"));
  });

  it("stops the task before releasing if started", async () => {
    const taskData = { uuid: UUID_A, status: "pending", tags: ["claimed"], start: "20261007T100000Z" };
    fake.setResponses([
      { match: "export", stdout: JSON.stringify(taskData) + "\n" },
      { match: "stop", stdout: "Stopped.\n" },
      { match: "modify", stdout: "Modified.\n" },
      { match: "annotate", stdout: "Annotation added.\n" },
    ]);
    await tool("release").execute({ uuid: UUID_A, actor: "opencode" }, ctx);
    const calls = fake.getCalls();
    const stopCalls = calls.filter((c) => c[1] === "stop");
    assert.equal(stopCalls.length, 1);
    const modifyCalls = calls.filter((c) => c[1] === "modify");
    assert.ok(modifyCalls[0].includes("-claimed"));
  });
});

describe("start tool", () => {
  it("starts a claimed task", async () => {
    const taskData = { uuid: UUID_A, status: "pending", tags: ["claimed"] };
    fake.setResponses([
      { match: "export", stdout: JSON.stringify(taskData) + "\n" },
      { match: "start", stdout: "Started.\n" },
      { match: "annotate", stdout: "Annotation added.\n" },
    ]);
    const result = JSON.parse((await tool("start").execute({ uuid: UUID_A, actor: "opencode" }, ctx)).content);
    assert.equal(result.uuid, UUID_A);
    const calls = fake.getCalls();
    const startCalls = calls.filter((c) => c[1] === "start");
    assert.equal(startCalls.length, 1);
  });

  it("blocks already-started tasks", async () => {
    const taskData = { uuid: UUID_A, status: "pending", tags: ["claimed"], start: "20261007T100000Z" };
    fake.setResponses([
      { match: "export", stdout: JSON.stringify(taskData) + "\n" },
    ]);
    await assert.rejects(
      () => tool("start").execute({ uuid: UUID_A, actor: "opencode" }, ctx),
      /already started/,
    );
  });
});

describe("stop tool", () => {
  it("stops a started task", async () => {
    const taskData = { uuid: UUID_A, status: "pending", start: "20261007T100000Z" };
    fake.setResponses([
      { match: "export", stdout: JSON.stringify(taskData) + "\n" },
      { match: "stop", stdout: "Stopped.\n" },
      { match: "annotate", stdout: "Annotation added.\n" },
    ]);
    await tool("stop").execute({ uuid: UUID_A, actor: "opencode" }, ctx);
    const calls = fake.getCalls();
    const stopCalls = calls.filter((c) => c[1] === "stop");
    assert.equal(stopCalls.length, 1);
  });

  it("errors when task is not started", async () => {
    const taskData = { uuid: UUID_A, status: "pending" };
    fake.setResponses([
      { match: "export", stdout: JSON.stringify(taskData) + "\n" },
    ]);
    await assert.rejects(
      () => tool("stop").execute({ uuid: UUID_A, actor: "opencode" }, ctx),
      /not started/,
    );
  });
});

describe("submit_for_review tool", () => {
  it("submits a claimed task for review", async () => {
    const taskData = { uuid: UUID_A, status: "pending", tags: ["claimed"] };
    fake.setResponses([
      { match: "export", stdout: JSON.stringify(taskData) + "\n" },
      { match: "modify", stdout: "Modified.\n" },
      { match: "annotate", stdout: "Annotation added.\n" },
    ]);
    const result = JSON.parse((await tool("submit_for_review").execute(
      { uuid: UUID_A, actor: "opencode", evidence: "tests pass" }, ctx,
    )).content);
    assert.equal(result.uuid, UUID_A);
    const calls = fake.getCalls();
    const modifyCalls = calls.filter((c) => c[1] === "modify");
    assert.ok(modifyCalls[0].includes("-claimed"));
    assert.ok(modifyCalls[0].includes("+ready-for-review"));
  });

  it("stops the task before submitting if started", async () => {
    const taskData = { uuid: UUID_A, status: "pending", tags: ["claimed"], start: "20261007T100000Z" };
    fake.setResponses([
      { match: "export", stdout: JSON.stringify(taskData) + "\n" },
      { match: "stop", stdout: "Stopped.\n" },
      { match: "modify", stdout: "Modified.\n" },
      { match: "annotate", stdout: "Annotation added.\n" },
    ]);
    await tool("submit_for_review").execute(
      { uuid: UUID_A, actor: "opencode", evidence: "done" }, ctx,
    );
    const calls = fake.getCalls();
    const stopCalls = calls.filter((c) => c[1] === "stop");
    assert.equal(stopCalls.length, 1);
  });
});

describe("approve tool", () => {
  it("approves a task in review", async () => {
    const taskData = { uuid: UUID_A, status: "pending", tags: ["ready-for-review"] };
    fake.setResponses([
      { match: "export", stdout: JSON.stringify(taskData) + "\n" },
      { match: "modify", stdout: "Modified.\n" },
      { match: "annotate", stdout: "Annotation added.\n" },
    ]);
    const result = JSON.parse((await tool("approve").execute(
      { uuid: UUID_A, actor: "opencode" }, ctx,
    )).content);
    assert.equal(result.uuid, UUID_A);
    const calls = fake.getCalls();
    const modifyCalls = calls.filter((c) => c[1] === "modify");
    assert.ok(modifyCalls[0].includes("-ready-for-review"));
    assert.ok(modifyCalls[0].includes("+approved"));
  });

  it("blocks approval of non-review tasks", async () => {
    const taskData = { uuid: UUID_A, status: "pending", tags: [] };
    fake.setResponses([
      { match: "export", stdout: JSON.stringify(taskData) + "\n" },
    ]);
    await assert.rejects(
      () => tool("approve").execute({ uuid: UUID_A, actor: "opencode" }, ctx),
      /ready-for-review/,
    );
  });
});

describe("complete tool", () => {
  it("completes an approved task", async () => {
    const taskData = { uuid: UUID_A, status: "pending", tags: ["approved"] };
    fake.setResponses([
      { match: "export", once: true, stdout: JSON.stringify(taskData) + "\n" },
      { match: "export", stdout: JSON.stringify({...taskData, status:"completed"}) + "\n" },
      { match: "annotate", stdout: "Annotation added.\n" },
      { match: "done", stdout: "Completed.\n" },
    ]);
    const result = JSON.parse((await tool("complete").execute(
      { uuid: UUID_A, actor: "opencode" }, ctx,
    )).content);
    assert.equal(result.uuid, UUID_A);
    const calls = fake.getCalls();
    const annotateCalls = calls.filter((c) => c[1] === "annotate");
    const doneCalls = calls.filter((c) => c[1] === "done");
    assert.equal(annotateCalls.length, 1);
    assert.equal(doneCalls.length, 1);
    // Annotate must come before done
    assert.ok(calls.findIndex((c) => c[1] === "annotate") < calls.findIndex((c) => c[1] === "done"));
  });

  it("blocks completion without approval", async () => {
    const taskData = { uuid: UUID_A, status: "pending", tags: [] };
    fake.setResponses([
      { match: "export", stdout: JSON.stringify(taskData) + "\n" },
    ]);
    await assert.rejects(
      () => tool("complete").execute({ uuid: UUID_A, actor: "opencode" }, ctx),
      /requires \+approved/,
    );
  });
});

describe("agent_queue tool", () => {
  it("returns tasks for the specified actor", async () => {
    const tasks = [
      { uuid: UUID_A, status: "pending", tags:["claimed"], annotations: [{ description: "[opencode] claimed: mine" }] },
      { uuid: UUID_B, status: "pending", annotations: [{ description: "[other] claimed: theirs" }] },
    ];
    fake.setResponses([
      { match: "export", stdout: tasks.map((t) => JSON.stringify(t)).join("\n") + "\n" },
    ]);
    const result = JSON.parse((await tool("agent_queue").execute({ actor: "opencode" }, ctx)).content);
    assert.equal(result.count, 1);
    assert.equal(result.tasks[0].uuid, UUID_A);
  });

  it("excludes review and approved tasks", async () => {
    const tasks = [
      { uuid: UUID_A, status: "pending", tags: ["ready-for-review"] },
      { uuid: UUID_B, status: "pending", tags: [] },
    ];
    fake.setResponses([
      { match: "export", stdout: tasks.map((t) => JSON.stringify(t)).join("\n") + "\n" },
    ]);
    const result = JSON.parse((await tool("agent_queue").execute({ actor: "opencode" }, ctx)).content);
    assert.equal(result.count, 0);
  });

  it("clamps limit", async () => {
    fake.setResponses([
      { match: "export", stdout: "" },
    ]);
    const result = JSON.parse((await tool("agent_queue").execute({ actor: "opencode", limit: 9999 }, ctx)).content);
    assert.equal(result.count, 0);
  });
});

describe("review_queue tool", () => {
  it("returns tasks ready for review", async () => {
    const tasks = [
      { uuid: UUID_A, status: "pending", tags: ["ready-for-review"] },
      { uuid: UUID_B, status: "pending", tags: [] },
    ];
    fake.setResponses([
      { match: "export", stdout: tasks.map((t) => JSON.stringify(t)).join("\n") + "\n" },
    ]);
    const result = JSON.parse((await tool("review_queue").execute({}, ctx)).content);
    assert.equal(result.count, 1);
    assert.equal(result.tasks[0].uuid, UUID_A);
  });
});

describe("blocked_tasks tool", () => {
  it("returns blocked tasks", async () => {
    const tasks = [
      { uuid: UUID_A, status: "pending", tags: ["blocked"] },
    ];
    fake.setResponses([
      { match: "export", stdout: tasks.map((t) => JSON.stringify(t)).join("\n") + "\n" },
    ]);
    const result = JSON.parse((await tool("blocked_tasks").execute({}, ctx)).content);
    assert.equal(result.count, 1);
    assert.equal(result.tasks[0].uuid, UUID_A);
  });
});

describe("record_decision tool", () => {
  it("annotates an existing task", async () => {
    fake.setResponses([
      { match: "annotate", stdout: "Annotation added.\n" },
      { match: "export", stdout: JSON.stringify({ uuid: UUID_A, status: "pending" }) + "\n" },
    ]);
    const result = JSON.parse((await tool("record_decision").execute(
      { actor: "opencode", decision: "use PostgreSQL", taskUuid: UUID_A }, ctx,
    )).content);
    assert.equal(result.uuid, UUID_A);
    const calls = fake.getCalls();
    const annotateCalls = calls.filter((c) => c[1] === "annotate");
    assert.equal(annotateCalls.length, 1);
    assert.ok(annotateCalls[0][2].includes("use PostgreSQL"));
  });

  it("creates a decision task when no taskUuid", async () => {
    fake.setResponses([
      { match: "add", stdout: `Created task ${UUID_B}.\n` },
      { match: "annotate", stdout: "Annotation added.\n" },
      { match: "export", stdout: JSON.stringify({ uuid: UUID_B, status: "pending" }) + "\n" },
    ]);
    const result = JSON.parse((await tool("record_decision").execute(
      { actor: "opencode", decision: "use PostgreSQL", title: "Database choice" }, ctx,
    )).content);
    assert.equal(result.uuid, UUID_B);
    const calls = fake.getCalls();
    const addCalls = calls.filter((c) => c[1] === "add");
    assert.equal(addCalls.length, 1);
    assert.ok(addCalls[0].includes("DECISION: Database choice"));
  });

  it("requires title when no taskUuid", async () => {
    await assert.rejects(
      () => tool("record_decision").execute({ actor: "opencode", decision: "text" }, ctx),
      /title/,
    );
  });
});

describe("overview tool", () => {
  it("returns board overview with counts", async () => {
    const tasks = [
      { uuid: UUID_A, status: "pending", tags: ["blocked"] },
      { uuid: UUID_B, status: "pending", tags: ["ready-for-review"] },
    ];
    fake.setResponses([
      { match: "projects", stdout: "projA\nprojB\n" },
      { match: "tags", stdout: "bug\nfeature\n" },
      { match: "count", stdout: "2\n" },
      { match: "export", stdout: tasks.map((t) => JSON.stringify(t)).join("\n") + "\n" },
    ]);
    const result = JSON.parse((await tool("overview").execute({}, ctx)).content);
    assert.equal(result.pending, 2);
    assert.equal(result.blocked, 1);
    assert.equal(result.ready_for_review, 1);
    assert.deepEqual(result.projects, ["projA", "projB"]);
    assert.deepEqual(result.tags, ["bug", "feature"]);
  });
});

describe("doctor tool", () => {
    it("returns doctor summary when all checks pass", async () => {
    fake.setResponses([
      { match: "--version", stdout: "Task 3.5.0\n" },
      { match: "sync", stdout: "Sync complete\n" },
    ]);
    const result = JSON.parse((await tool("doctor").execute({}, ctx)).content);
    assert.equal(result.task_binary.ok, true);
    assert.equal(result.taskchampion_sync.ok, true);
    assert.equal(result.summary, "All checks passed ✓");
  });

  it("returns issues when sync fails", async () => {
    fake.setResponses([
      { match: "--version", stdout: "Task 3.5.0\n" },
      { match: "sync", stderr: "connection refused\n", exit: 1 },
    ]);
    const result = JSON.parse((await tool("doctor").execute({}, ctx)).content);
    assert.equal(result.task_binary.ok, true);
    assert.equal(result.taskchampion_sync.ok, false);
    assert.ok(result.summary.includes("Issues"));
  });
});

describe("setup tool", () => {
  it("returns a setup script", async () => {
    const result = JSON.parse((await tool("setup").execute({}, ctx)).content);
    assert.ok(result.script.includes("#!/usr/bin/env bash"));
    assert.ok(result.script.includes("task"));
    assert.equal(result.filename, "install-taskwarrior.sh");
  });

  it("can write the script to a file", async () => {
    const { mkdtempSync, readFileSync, existsSync, rmSync } = await import("node:fs");
    const { tmpdir } = await import("node:os");
    const { join } = await import("node:path");
    const dir = mkdtempSync(join(tmpdir(), "setup-test-"));
    const prevCwd = process.cwd();
    process.chdir(dir);
    try {
      const result = JSON.parse((await tool("setup").execute({ write: true }, ctx)).content);
      assert.equal(result.ok, true);
      assert.ok(existsSync(result.path));
      const content = readFileSync(result.path, "utf8");
      assert.ok(content.includes("#!/usr/bin/env bash"));
    } finally {
      process.chdir(prevCwd);
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("rejects outputPath outside cwd", async () => {
    await assert.rejects(
      () => tool("setup").execute({ write: true, outputPath: "/etc/evil.sh" }, ctx),
      /within the current directory/,
    );
  });
});

describe("auto tool", () => {
  it("creates and starts a task from description", async () => {
    fake.setResponses([
      { match: "add", stdout: `Created task ${UUID_A}.\n` },
      { match: "modify", stdout: "Modified.\n" },
      { match: "annotate", stdout: "Annotation added.\n" },
      { match: "start", stdout: "Started.\n" },
      { match: "export", stdout: JSON.stringify({ uuid: UUID_A, status: "pending" }) + "\n" },
    ]);
    const result = JSON.parse((await tool("auto").execute(
      { actor: "opencode", description: "new task" }, ctx,
    )).content);
    assert.equal(result.action, "created_and_started");
    assert.equal(result.task.uuid, UUID_A);
  });

  it("picks an unclaimed task from the queue", async () => {
    const tasks = [
      { uuid: UUID_A, status: "pending", tags: [] },
    ];
    fake.setResponses([
      { match: "export", stdout: tasks.map((t) => JSON.stringify(t)).join("\n") + "\n" },
      { match: "modify", stdout: "Modified.\n" },
      { match: "annotate", stdout: "Annotation added.\n" },
      { match: "start", stdout: "Started.\n" },
    ]);
    const result = JSON.parse((await tool("auto").execute({ actor: "opencode" }, ctx)).content);
    assert.equal(result.action, "claimed_and_started");
    assert.equal(result.task.uuid, UUID_A);
  });

  it("returns none_found when queue is empty", async () => {
    fake.setResponses([
      { match: "export", stdout: "" },
    ]);
    const result = JSON.parse((await tool("auto").execute({ actor: "opencode" }, ctx)).content);
    assert.equal(result.action, "none_found");
    assert.equal(result.task, null);
  });

  it("prefers tasks already claimed by the actor", async () => {
    const tasks = [
      { uuid: UUID_A, status: "pending", tags: [] },
      { uuid: UUID_B, status: "pending", tags: ["claimed"], annotations: [{ description: "[opencode] claimed: mine" }] },
    ];
    // Return all tasks for queue export, but only the specific task for getTask
    fake.setResponses([
      { match: "rc.json.array=off " + UUID_A, stdout: JSON.stringify(tasks[0]) + "\n" },
      { match: "rc.json.array=off " + UUID_B, stdout: JSON.stringify(tasks[1]) + "\n" },
      { match: "rc.json.array=off +PENDING", stdout: tasks.map((t) => JSON.stringify(t)).join("\n") + "\n" },
      { match: "rc.json.array=off", stdout: "" },
      { match: "modify", stdout: "Modified.\n" },
      { match: "annotate", stdout: "Annotation added.\n" },
      { match: "start", stdout: "Started.\n" },
    ]);
    const result = JSON.parse((await tool("auto").execute({ actor: "opencode" }, ctx)).content);
    assert.equal(result.action, "started");
    assert.equal(result.task.uuid, UUID_B);
  });
});

describe("sync behavior", () => {
  it("syncs before and after mutations when autoSync is true", async () => {
    const syncConfig = { ...fake.config, autoSync: true };
    const syncTools = createTools(syncConfig);
    const claimTool = syncTools.find((t) => t.name === "claim");
    const taskData = { uuid: UUID_A, status: "pending", tags: [] };
    fake.setResponses([
      { match: "export", stdout: JSON.stringify(taskData) + "\n" },
      { match: "modify", stdout: "Modified.\n" },
      { match: "annotate", stdout: "Annotation added.\n" },
    ]);
    await claimTool.execute({ uuid: UUID_A, actor: "opencode" }, ctx);
    const calls = fake.getCalls();
    const syncCalls = calls.filter((c) => c[0] === "sync");
    // At least 2 syncs: before getTask, before mutate, after mutate
    assert.ok(syncCalls.length >= 2, `expected >=2 syncs, got ${syncCalls.length}`);
  });

  it("does not sync when autoSync is false", async () => {
    // fake.config has autoSync: false
    const taskData = { uuid: UUID_A, status: "pending", tags: [] };
    fake.setResponses([
      { match: "export", stdout: JSON.stringify(taskData) + "\n" },
      { match: "modify", stdout: "Modified.\n" },
      { match: "annotate", stdout: "Annotation added.\n" },
    ]);
    await tool("claim").execute({ uuid: UUID_A, actor: "opencode" }, ctx);
    const calls = fake.getCalls();
    const syncCalls = calls.filter((c) => c[0] === "sync");
    assert.equal(syncCalls.length, 0);
  });

  it("mutate throws when sync fails after local mutation", async () => {
    const syncConfig = { ...fake.config, autoSync: true };
    const syncTools = createTools(syncConfig);
    const claimTool = syncTools.find((t) => t.name === "claim");
    const taskData = { uuid: UUID_A, status: "pending", tags: [] };
    fake.setResponses([
      // First sync (before mutate) succeeds
      { match: "sync", stdout: "Sync complete\n", once: true },
      // export for getTask inside mutate
      { match: "export", stdout: JSON.stringify(taskData) + "\n" },
      // Local mutation succeeds
      { match: "modify", stdout: "Modified.\n" },
      { match: "annotate", stdout: "Annotation added.\n" },
      // Second sync (after mutate) fails
      { match: "sync", stderr: "connection refused\n", exit: 1 },
    ]);
    await assert.rejects(
      () => claimTool.execute({ uuid: UUID_A, actor: "opencode" }, ctx),
      /Local mutation applied but sync failed/,
    );
  });
});
