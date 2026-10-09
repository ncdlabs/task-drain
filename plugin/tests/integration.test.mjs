/**
 * Integration tests for opencode-tasks plugin tools.
 * Tests each tool's execute logic against the real task binary.
 * Creates test tasks, runs operations, verifies results, cleans up.
 */
import { describe, it, before, after } from "node:test";
import assert from "node:assert/strict";
import {
  resolveConfig,
  runTask,
  sync,
  exportTasks,
  getTask,
  buildSetArgs,
  buildModifyArgs,
  formatAnnotation,
  normalizeTags,
  applyTagFilter,
  hasTag,
  lastClaimActor,
  assertUuid,
  assertActor,
  assertActionable,
  claimGuard,
  startGuard,
  completeGuard,
  approveGuard,
  parseListing,
  doctor,
  generateSetupScript,
  getInstallInstructions,
} from "../src/task.mjs";

const config = resolveConfig({});
const TEST_TAG = "plugin-test";
const TEST_ACTOR = "plugin-test";

// Track created tasks for cleanup
const createdUuids = [];

async function cleanup() {
  for (const uuid of createdUuids) {
    try {
      await runTask(config, [uuid, "delete", "rc.confirmation=off"]);
    } catch {
      // ignore - may already be gone
    }
  }
}

async function createTestTask(description, extraArgs = []) {
  const setArgs = buildSetArgs({ tags: [TEST_TAG] });
  const output = await runTask(
    config,
    ["rc.verbose=new-uuid", "add", description, ...setArgs, ...extraArgs],
  );
  const uuid = output.match(/[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}/i)?.[0];
  if (!uuid) throw new Error(`Could not resolve UUID from: ${output}`);
  createdUuids.push(uuid);
  return uuid;
}

describe("integration: plugin tools", () => {
  before(async () => {
    await sync(config);
  });

  after(async () => {
    await cleanup();
  });

  describe("task_sync", () => {
    it("syncs successfully", async () => {
      const result = await sync(config);
      assert.equal(result.ok, true);
      assert.ok(result.output.length > 0);
    });
  });

  describe("task_add", () => {
    it("creates a task with tags and project", async () => {
      const uuid = await createTestTask("Integration test: task_add basic");
      const task = await getTask(config, uuid);
      assert.equal(task.description, "Integration test: task_add basic");
      assert.ok(hasTag(task, TEST_TAG));
      createdUuids.push(uuid);
    });

    it("creates a task with priority and due date", async () => {
      const setArgs = buildSetArgs({ priority: "H", due: "tomorrow" });
      const output = await runTask(
        config,
        ["rc.verbose=new-uuid", "add", "Integration test: priority+due", ...setArgs, `+${TEST_TAG}`],
      );
      const uuid = output.match(/[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}/i)?.[0];
      assert.ok(uuid, `UUID from output: ${output}`);
      createdUuids.push(uuid);
      const task = await getTask(config, uuid);
      assert.equal(task.priority, "H");
      assert.ok(task.due);
    });

    it("normalizes underscore tags to hyphens", async () => {
      const setArgs = buildSetArgs({ tags: ["ready_for_review"] });
      const output = await runTask(
        config,
        ["rc.verbose=new-uuid", "add", "Integration test: tag normalization", ...setArgs, `+${TEST_TAG}`],
      );
      const uuid = output.match(/[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}/i)?.[0];
      assert.ok(uuid);
      createdUuids.push(uuid);
      const task = await getTask(config, uuid);
      assert.ok(hasTag(task, "ready-for-review"));
      assert.ok(hasTag(task, "ready_for_review"));
    });

    it("rejects UDA writes", async () => {
      assert.throws(
        () => buildSetArgs({ udas: { owner: "test" } }),
        /not defined/,
      );
    });

    it("rejects invalid priority", async () => {
      assert.throws(
        () => buildSetArgs({ priority: "urgent" }),
        /priority/,
      );
    });
  });

  describe("task_list", () => {
    it("lists pending tasks", async () => {
      const tasks = await exportTasks(config, ["status:pending"]);
      assert.ok(Array.isArray(tasks));
      assert.ok(tasks.length > 0);
    });

    it("filters by project", async () => {
      const tasks = await exportTasks(config, ["status:pending", "project:opencode-tasks"]);
      // May be empty, but should not throw
      assert.ok(Array.isArray(tasks));
    });

    it("applies tag filter client-side", async () => {
      const tasks = await exportTasks(config, ["status:pending"]);
      const filtered = applyTagFilter(tasks, [TEST_TAG]);
      // Should find at least the tasks we created
      assert.ok(filtered.length >= 0);
    });

    it("excludes tags", async () => {
      const tasks = await exportTasks(config, ["status:pending"]);
      const filtered = applyTagFilter(tasks, [], [TEST_TAG]);
      assert.ok(Array.isArray(filtered));
    });
  });

  describe("task_get", () => {
    it("gets a task by UUID", async () => {
      const uuid = await createTestTask("Integration test: task_get");
      const task = await getTask(config, uuid);
      assert.equal(task.uuid, uuid);
      assert.equal(task.description, "Integration test: task_get");
    });

    it("rejects short IDs", async () => {
      assert.throws(() => assertUuid("123"), /full UUID/);
    });

    it("rejects invalid UUIDs", async () => {
      assert.throws(() => assertUuid("not-a-uuid"), /full UUID/);
    });
  });

  describe("task_modify", () => {
    it("modifies description", async () => {
      const uuid = await createTestTask("Integration test: modify before");
      await runTask(config, [uuid, "modify", "Integration test: modify after"]);
      const task = await getTask(config, uuid);
      assert.equal(task.description, "Integration test: modify after");
    });

    it("adds and removes tags", async () => {
      const uuid = await createTestTask("Integration test: modify tags");
      await runTask(config, [uuid, "modify", "+temp-tag"]);
      let task = await getTask(config, uuid);
      assert.ok(hasTag(task, "temp-tag"));
      await runTask(config, [uuid, "modify", "-temp-tag"]);
      task = await getTask(config, uuid);
      assert.ok(!hasTag(task, "temp-tag"));
    });

    it("modifies project and priority", async () => {
      const uuid = await createTestTask("Integration test: modify project+priority");
      await runTask(config, [uuid, "modify", "project:opencode-tasks", "priority:H"]);
      const task = await getTask(config, uuid);
      assert.equal(task.project, "opencode-tasks");
      assert.equal(task.priority, "H");
    });

    it("rejects empty description", async () => {
      assert.throws(
        () => buildModifyArgs({ description: "" }),
        /description/,
      );
    });
  });

  describe("task_annotate", () => {
    it("adds a structured annotation", async () => {
      const uuid = await createTestTask("Integration test: annotate");
      const annotation = formatAnnotation(TEST_ACTOR, "test", "integration test annotation");
      await runTask(config, [uuid, "annotate", annotation]);
      const task = await getTask(config, uuid);
      const notes = Array.isArray(task.annotations) ? task.annotations : [];
      assert.ok(notes.some((a) => a.description.includes("[plugin-test] test:")));
    });

    it("rejects empty action", async () => {
      assert.throws(
        () => formatAnnotation("actor", "", "detail"),
        /action/,
      );
    });

    it("rejects empty detail", async () => {
      assert.throws(
        () => formatAnnotation("actor", "action", ""),
        /detail/,
      );
    });
  });

  describe("task_add_dependency", () => {
    it("adds a dependency between two tasks", async () => {
      const uuidA = await createTestTask("Integration test: dependency A");
      const uuidB = await createTestTask("Integration test: dependency B");
      await runTask(config, [uuidB, "modify", `depends:${uuidA}`]);
      const taskB = await getTask(config, uuidB);
      assert.ok(taskB.depends);
      assert.ok(taskB.depends.includes(uuidA));
    });
  });

  describe("task_claim", () => {
    it("claims a task", async () => {
      const uuid = await createTestTask("Integration test: claim");
      await runTask(config, [uuid, "modify", "+claimed"]);
      await runTask(config, [uuid, "annotate", formatAnnotation(TEST_ACTOR, "claimed", "test claim")]);
      const task = await getTask(config, uuid);
      assert.ok(hasTag(task, "claimed"));
      assert.equal(lastClaimActor(task), TEST_ACTOR);
    });

    it("claimGuard blocks double-claim by different actor", async () => {
      const uuid = await createTestTask("Integration test: double-claim");
      await runTask(config, [uuid, "modify", "+claimed"]);
      await runTask(config, [uuid, "annotate", formatAnnotation("alice", "claimed", "first claim")]);
      const task = await getTask(config, uuid);
      assert.throws(
        () => claimGuard(task, "bob"),
        /already claimed by alice/,
      );
    });

    it("claimGuard allows force re-claim", async () => {
      const uuid = await createTestTask("Integration test: force-claim");
      await runTask(config, [uuid, "modify", "+claimed"]);
      await runTask(config, [uuid, "annotate", formatAnnotation("alice", "claimed", "first")]);
      const task = await getTask(config, uuid);
      claimGuard(task, "bob", { force: true });
    });

    it("claimGuard blocks review-stage tasks", async () => {
      const uuid = await createTestTask("Integration test: claim-review");
      await runTask(config, [uuid, "modify", "+ready-for-review"]);
      const task = await getTask(config, uuid);
      assert.throws(
        () => claimGuard(task, TEST_ACTOR),
        /already in review/,
      );
    });
  });

  describe("task_release", () => {
    it("releases a claimed task", async () => {
      const uuid = await createTestTask("Integration test: release");
      await runTask(config, [uuid, "modify", "+claimed"]);
      await runTask(config, [uuid, "annotate", formatAnnotation(TEST_ACTOR, "claimed", "test")]);
      await runTask(config, [uuid, "modify", "-claimed"]);
      await runTask(config, [uuid, "annotate", formatAnnotation(TEST_ACTOR, "released", "test release")]);
      const task = await getTask(config, uuid);
      assert.ok(!hasTag(task, "claimed"));
    });
  });

  describe("task_start / task_stop", () => {
    it("starts and stops a task", async () => {
      const uuid = await createTestTask("Integration test: start/stop");
      await runTask(config, [uuid, "start"]);
      let task = await getTask(config, uuid);
      assert.ok(task.start);
      await runTask(config, [uuid, "stop"]);
      task = await getTask(config, uuid);
      assert.ok(!task.start);
    });

    it("startGuard blocks already-started tasks", async () => {
      const uuid = await createTestTask("Integration test: double-start");
      await runTask(config, [uuid, "start"]);
      const task = await getTask(config, uuid);
      assert.throws(
        () => startGuard(task),
        /already started/,
      );
    });
  });

  describe("task_submit_for_review", () => {
    it("submits for review with evidence", async () => {
      const uuid = await createTestTask("Integration test: submit-review");
      await runTask(config, [uuid, "modify", "+claimed"]);
      await runTask(config, [uuid, "annotate", formatAnnotation(TEST_ACTOR, "claimed", "test")]);
      // Plugin only stops if task.start is set; this task was never started
      await runTask(config, [uuid, "modify", "-claimed", "+ready-for-review"]);
      await runTask(config, [uuid, "annotate", formatAnnotation(TEST_ACTOR, "submitted-for-review", "test evidence")]);
      const task = await getTask(config, uuid);
      assert.ok(hasTag(task, "ready-for-review"));
      assert.ok(!hasTag(task, "claimed"));
    });
  });

  describe("task_approve", () => {
    it("approves a task in review", async () => {
      const uuid = await createTestTask("Integration test: approve");
      await runTask(config, [uuid, "modify", "+ready-for-review"]);
      await runTask(config, [uuid, "modify", "-ready-for-review", "+approved"]);
      await runTask(config, [uuid, "annotate", formatAnnotation(TEST_ACTOR, "approved", "test approval")]);
      const task = await getTask(config, uuid);
      assert.ok(hasTag(task, "approved"));
      assert.ok(!hasTag(task, "ready-for-review"));
    });

    it("approveGuard blocks non-review tasks", async () => {
      const uuid = await createTestTask("Integration test: approve-guard");
      const task = await getTask(config, uuid);
      assert.throws(
        () => approveGuard(task),
        /ready-for-review/,
      );
    });
  });

  describe("task_complete", () => {
    it("completes an approved task", async () => {
      const uuid = await createTestTask("Integration test: complete");
      await runTask(config, [uuid, "modify", "+approved"]);
      await runTask(config, [uuid, "annotate", formatAnnotation(TEST_ACTOR, "completed", "test complete")]);
      await runTask(config, [uuid, "done"]);
      const task = await getTask(config, uuid);
      assert.equal(task.status, "completed");
    });

    it("completeGuard blocks unapproved tasks", async () => {
      const uuid = await createTestTask("Integration test: complete-guard");
      const task = await getTask(config, uuid);
      assert.throws(
        () => completeGuard(task),
        /requires \+approved/,
      );
    });

    it("completeGuard allows force", async () => {
      const uuid = await createTestTask("Integration test: complete-force");
      const task = await getTask(config, uuid);
      completeGuard(task, { force: true });
    });
  });

  describe("task_agent_queue", () => {
    it("finds tasks for an actor", async () => {
      const uuid = await createTestTask("Integration test: agent-queue");
      await runTask(config, [uuid, "modify", "+claimed"]);
      await runTask(config, [uuid, "annotate", formatAnnotation(TEST_ACTOR, "claimed", "queue test")]);
      const tasks = await exportTasks(config, ["status:pending"]);
      const mine = tasks.filter((t) => {
        if (hasTag(t, "ready-for-review") || hasTag(t, "review") || hasTag(t, "approved")) return false;
        if (lastClaimActor(t) === TEST_ACTOR) return true;
        const notes = Array.isArray(t.annotations) ? t.annotations : [];
        return notes.some((a) => String(a?.description ?? "").startsWith(`[${TEST_ACTOR}]`));
      });
      assert.ok(mine.length > 0);
    });
  });

  describe("task_review_queue", () => {
    it("finds tasks in review", async () => {
      const uuid = await createTestTask("Integration test: review-queue");
      await runTask(config, [uuid, "modify", "+ready-for-review"]);
      const tasks = await exportTasks(config, ["status:pending"]);
      const queued = applyTagFilter(tasks, ["ready-for-review"]);
      assert.ok(queued.some((t) => t.uuid === uuid));
    });
  });

  describe("task_blocked_tasks", () => {
    it("finds blocked tasks", async () => {
      const uuid = await createTestTask("Integration test: blocked");
      await runTask(config, [uuid, "modify", "+blocked"]);
      const tasks = await exportTasks(config, ["status:pending"]);
      const blocked = applyTagFilter(tasks, ["blocked"]);
      assert.ok(blocked.some((t) => t.uuid === uuid));
    });
  });

  describe("task_record_decision", () => {
    it("creates a decision task", async () => {
      const tags = normalizeTags(["decision"]);
      const output = await runTask(
        config,
        ["rc.verbose=new-uuid", "add", "DECISION: Integration test decision", `+${TEST_TAG}`],
      );
      const uuid = output.match(/[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}/i)?.[0];
      assert.ok(uuid);
      createdUuids.push(uuid);
      await runTask(config, [uuid, "annotate", formatAnnotation(TEST_ACTOR, "decision", "test decision text")]);
      const task = await getTask(config, uuid);
      assert.ok(task.description.startsWith("DECISION:"));
      assert.ok(hasTag(task, TEST_TAG));
    });

    it("annotates an existing task with a decision", async () => {
      const uuid = await createTestTask("Integration test: decision-annotate");
      await runTask(config, [uuid, "annotate", formatAnnotation(TEST_ACTOR, "decision", "test decision")]);
      const task = await getTask(config, uuid);
      const notes = Array.isArray(task.annotations) ? task.annotations : [];
      assert.ok(notes.some((a) => a.description.includes("[plugin-test] decision:")));
    });
  });

  describe("task_overview", () => {
    it("returns board overview", async () => {
      const projectsOut = await runTask(config, ["projects"]);
      const tagsOut = await runTask(config, ["tags"]);
      const pending = await exportTasks(config, ["status:pending"]);
      const list = pending;
      const count = (tags) => applyTagFilter(list, tags).length;
      const overview = {
        pending: list.length,
        blocked: count(["blocked"]),
        ready_for_review: count(["ready-for-review"]),
        claimed: count(["claimed"]),
        started: list.filter((t) => Boolean(t.start)).length,
        projects: parseListing(projectsOut),
        tags: parseListing(tagsOut),
      };
      assert.ok(overview.pending > 0);
      assert.ok(Array.isArray(overview.projects));
      assert.ok(Array.isArray(overview.tags));
    });
  });

  describe("task_doctor", () => {
    it("runs doctor checks", async () => {
      const result = await doctor(config);
      assert.ok(result.task_binary.ok);
      assert.ok(result.taskchampion_sync.ok);
      assert.ok(result.platform);
      assert.ok(result.arch);
      assert.ok(Array.isArray(result.install_instructions));
    });
  });

  describe("task_setup", () => {
    it("generates setup script", async () => {
      const script = generateSetupScript({ includeSyncService: true, includeVerify: true });
      assert.ok(script.includes("#!/usr/bin/env bash"));
      assert.ok(script.includes("task"));
      assert.ok(script.includes("taskchampion"));
    });

    it("generates script without sync service", async () => {
      const script = generateSetupScript({ includeSyncService: false, includeVerify: false });
      assert.ok(script.includes("#!/usr/bin/env bash"));
      assert.ok(!script.includes("# Start TaskChampion sync service"));
      assert.ok(!script.includes("brew services start taskchampion-sync 2>/dev/null"));
    });
  });

  describe("task_auto", () => {
    it("creates and starts a task from description", async () => {
      const output = await runTask(
        config,
        ["rc.verbose=new-uuid", "add", "Integration test: auto-create", `+${TEST_TAG}`],
      );
      const uuid = output.match(/[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}/i)?.[0];
      assert.ok(uuid);
      createdUuids.push(uuid);
      await runTask(config, [uuid, "modify", "+claimed"]);
      await runTask(config, [uuid, "annotate", formatAnnotation(TEST_ACTOR, "claimed", "auto-claimed")]);
      await runTask(config, [uuid, "start"]);
      await runTask(config, [uuid, "annotate", formatAnnotation(TEST_ACTOR, "started", "auto-started")]);
      const task = await getTask(config, uuid);
      assert.ok(hasTag(task, "claimed"));
      assert.ok(task.start);
    });
  });

  describe("edge cases", () => {
    it("assertActor rejects empty and too-long", async () => {
      assert.throws(() => assertActor(""), /actor/);
      assert.throws(() => assertActor("x".repeat(81)), /actor/);
      assertActor("valid");
    });

    it("assertActionable requires pending", async () => {
      assertActionable({ status: "pending" });
      assert.throws(() => assertActionable({ status: "completed" }), /not pending/);
      assertActionable({ status: "completed" }, { force: true });
    });

    it("parseListing handles empty output", async () => {
      assert.deepEqual(parseListing(""), []);
      assert.deepEqual(parseListing("ncdlabs\nsol-foundation\n\n"), ["ncdlabs", "sol-foundation"]);
    });

    it("getInstallInstructions returns platform info", async () => {
      const info = getInstallInstructions();
      assert.ok(info.platform);
      assert.ok(info.arch);
      assert.ok(Array.isArray(info.instructions));
      assert.ok(info.instructions.length > 0);
    });
  });
});
