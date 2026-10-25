import { describe, it, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import {
  UUID_RE,
  TAG_CANONICAL,
  applyTagFilter,
  approveGuard,
  assertActionable,
  assertActor,
  assertUuid,
  buildModifyArgs,
  buildSetArgs,
  claimGuard,
  checkSync,
  checkTaskBinary,
  completeGuard,
  countTasks,
  doctor,
  exportTasks,
  formatAnnotation,
  generateSetupScript,
  getInstallInstructions,
  getTask,
  hasTag,
  isDrainClaimed,
  lastClaimActor,
  normalizeTag,
  normalizeTags,
  parseListing,
  resolveConfig,
  runTask,
  startGuard,
  sync,
} from "../src/task.mjs";
import { createFakeTask } from "./helpers/fake-task.mjs";

const UUID_A = "27594f5a-7c89-4d88-8b08-f33b7ef33b6e";
const UUID_B = "675eb484-efe2-4e3f-9929-ff257db7c9c0";

function task(overrides = {}) {
  return { uuid: UUID_A, status: "pending", tags: [], ...overrides };
}

describe("resolveConfig", () => {
  it("defaults to the shared-pool task binary with no taskrc", () => {
    const config = resolveConfig({});
    // Homebrew path when it exists (macOS); otherwise `task` on PATH.
    assert.ok(
      ["/opt/homebrew/bin/task", "task"].includes(config.bin),
      `unexpected default bin: ${config.bin}`,
    );
    assert.equal(config.taskrc, undefined);
    assert.equal(config.autoSync, true);
  });

  it("prefers explicit options over environment", () => {
    const config = resolveConfig({ taskBin: "/custom/task", taskrc: "/custom/rc" });
    assert.equal(config.bin, "/custom/task");
    assert.equal(config.taskrc, "/custom/rc");
  });

  it("honors TASK_AUTO_SYNC=0", () => {
    const prev = process.env.TASK_AUTO_SYNC;
    process.env.TASK_AUTO_SYNC = "0";
    try {
      assert.equal(resolveConfig({}).autoSync, false);
    } finally {
      if (prev === undefined) delete process.env.TASK_AUTO_SYNC;
      else process.env.TASK_AUTO_SYNC = prev;
    }
  });
});

describe("assertUuid", () => {
  it("accepts full UUIDs", () => {
    assertUuid(UUID_A);
    assert.ok(UUID_RE.test(UUID_B));
  });

  it("rejects short numeric IDs (replica-local)", () => {
    assert.throws(() => assertUuid("381"), /full UUID/);
    assert.throws(() => assertUuid(""), /full UUID/);
    assert.throws(() => assertUuid(undefined), /full UUID/);
  });
});

describe("tags", () => {
  it("normalizes underscore-safe lifecycle tags to live-pool hyphens", () => {
    assert.equal(normalizeTag("ready_for_review"), "ready-for-review");
    assert.equal(normalizeTag("agent_created"), "agent-created");
    assert.equal(normalizeTag("human_review"), "human-review");
    for (const [, canonical] of TAG_CANONICAL) {
      assert.equal(normalizeTag(canonical), canonical);
    }
  });

  it("passes through unknown well-formed tags", () => {
    assert.equal(normalizeTag("drain-failed"), "drain-failed");
    assert.deepEqual(normalizeTags(["bug", "ready_for_review"]), [
      "bug",
      "ready-for-review",
    ]);
  });

  it("rejects malformed tags", () => {
    assert.throws(() => normalizeTag("has space"), /Invalid tag/);
    assert.throws(() => normalizeTag("semi;colon"), /Invalid tag/);
    assert.throws(() => normalizeTags("bug"), /must be an array/);
  });

  it("hasTag matches across underscore/hyphen spellings", () => {
    const t = task({ tags: ["ready-for-review"] });
    assert.equal(hasTag(t, "ready_for_review"), true);
    assert.equal(hasTag(t, "ready-for-review"), true);
    assert.equal(hasTag(t, "approved"), false);
  });

  it("assertActor requires a bounded non-empty actor", () => {
    assertActor("opencode");
    assert.throws(() => assertActor(""), /actor/);
    assert.throws(() => assertActor("x".repeat(81)), /actor/);
  });
});

describe("formatAnnotation", () => {
  it("produces the structured audit form", () => {
    assert.equal(
      formatAnnotation("opencode", "claimed", "starting work"),
      "[opencode] claimed: starting work",
    );
  });

  it("rejects empty action/detail", () => {
    assert.throws(() => formatAnnotation("a", "", "d"), /action/);
    assert.throws(() => formatAnnotation("a", "act", "  "), /detail/);
  });
});

describe("applyTagFilter", () => {
  const tasks = [
    task({ uuid: UUID_A, tags: ["ready-for-review", "documentation"] }),
    task({ uuid: UUID_B, tags: ["bug"] }),
  ];

  it("filters hyphenated tags client-side", () => {
    const out = applyTagFilter(tasks, ["ready-for-review"]);
    assert.equal(out.length, 1);
    assert.equal(out[0].uuid, UUID_A);
  });

  it("accepts underscore spelling for hyphenated tags", () => {
    assert.equal(applyTagFilter(tasks, ["ready_for_review"]).length, 1);
  });

  it("supports exclusion", () => {
    assert.equal(applyTagFilter(tasks, [], ["bug"]).length, 1);
  });
});

describe("lastClaimActor", () => {
  it("returns the most recent claim annotation actor", () => {
    const t = task({
      annotations: [
        { description: "[alice] claimed: first" },
        { description: "unrelated note" },
        { description: "[bob] claimed: second" },
      ],
    });
    assert.equal(lastClaimActor(t), "bob");
  });

  it("returns undefined when nothing claimed", () => {
    assert.equal(lastClaimActor(task()), undefined);
  });
});

describe("guards", () => {
  it("claimGuard blocks review-stage tasks", () => {
    assert.throws(
      () => claimGuard(task({ tags: ["ready-for-review"] }), "opencode"),
      /already in review/,
    );
    assert.throws(
      () => claimGuard(task({ tags: ["review"] }), "opencode"),
      /already in review/,
    );
  });

  it("claimGuard blocks double-claims and names the holder", () => {
    const t = task({
      tags: ["claimed"],
      annotations: [{ description: "[alice] claimed: mine" }],
    });
    assert.throws(() => claimGuard(t, "bob"), /already claimed by alice/);
    claimGuard(t, "bob", { force: true });
    claimGuard(task({ tags: ["claimed"] }), "bob", { force: true });
  });

  it("claimGuard allows fresh tasks", () => {
    claimGuard(task(), "opencode");
  });

  it("claimGuard rejects drain-claimed takeover without explicit override", () => {
    const t = task({ tags: ["drain-claimed"] });
    assert.ok(isDrainClaimed(t));
    assert.throws(() => claimGuard(t, "bob"), /already in review/);
    assert.throws(() => claimGuard(t, "bob", { force: true }), /overrideDrainClaim/);
    assert.throws(
      () => claimGuard(t, "bob", { force: true, overrideDrainClaim: true }),
      /overrideReason/,
    );
    claimGuard(t, "admin", { force: true, overrideDrainClaim: true, overrideReason: "host retired" });
    claimGuard(t, "admin", { overrideDrainClaim: true, overrideReason: "host retired" });
  });

  it("startGuard rejects active drain claims without explicit override", () => {
    const t = task({ tags: ["drain-claimed"], start: "20261007T100000Z" });
    assert.throws(() => startGuard(t), /already started/);
    assert.throws(() => startGuard(t, { force: true }), /overrideDrainClaim/);
    startGuard(t, { force: true, overrideDrainClaim: true, overrideReason: "recovery" });
  });

  it("startGuard blocks already-started tasks", () => {
    assert.throws(
      () => startGuard(task({ start: "20261007T100000Z" })),
      /already started/,
    );
    startGuard(task({ start: "20261007T100000Z" }), { force: true });
    startGuard(task());
  });

  it("completeGuard requires approval", () => {
    assert.throws(() => completeGuard(task()), /requires \+approved/);
    completeGuard(task({ tags: ["approved"] }));
    assert.throws(() => completeGuard(task({ tags: ["ready-for-review"] })), /requires \+approved/);
    completeGuard(task(), { force: true });
  });

  it("approveGuard requires the review stage", () => {
    assert.throws(() => approveGuard(task()), /ready-for-review/);
    approveGuard(task({ tags: ["ready_for_review"] }));
    approveGuard(task(), { force: true });
  });
});

describe("assertActionable", () => {
  it("requires pending status for lifecycle transitions", () => {
    assertActionable(task());
    for (const status of ["completed", "deleted", "waiting"]) {
      assert.throws(
        () => assertActionable(task({ status })),
        /not pending/,
      );
    }
    assertActionable(task({ status: "completed" }), { force: true });
  });

  it("claimGuard blocks completed tasks", () => {
    assert.throws(
      () => claimGuard(task({ status: "completed" }), "opencode"),
      /not pending/,
    );
  });
});

describe("arg builders", () => {
  it("buildSetArgs maps structured fields to CLI mods", () => {
    assert.deepEqual(
      buildSetArgs({
        project: "ncdlabs",
        priority: "H",
        due: "tomorrow",
        tags: ["ready_for_review"],
        depends: [UUID_B],
      }),
      [
        "project:ncdlabs",
        "priority:H",
        "due:tomorrow",
        "+ready-for-review",
        `depends:${UUID_B}`,
      ],
    );
  });

  it("buildModifyArgs supports description and tag add/remove", () => {
    assert.deepEqual(
      buildModifyArgs({
        description: "new text",
        add_tags: ["approved"],
        remove_tags: ["ready_for_review"],
      }),
      ["new text", "+approved", "-ready-for-review"],
    );
  });

  it("rejects bad priority, bad dependency UUIDs, and UDAs", () => {
    assert.throws(() => buildSetArgs({ priority: "urgent" }), /priority/);
    assert.throws(() => buildSetArgs({ depends: ["381"] }), /full UUID/);
    assert.throws(() => buildSetArgs({ udas: { owner: "Lou" } }), /not defined/);
    assert.throws(() => buildSetArgs({ project: "" }), /project/);
    assert.throws(() => buildSetArgs({ due: "  " }), /due/);
  });
});

describe("parseListing", () => {
  it("splits project/tag listings and drops empty lines", () => {
    assert.deepEqual(parseListing("ncdlabs\nsol-foundation\n\n"), [
      "ncdlabs",
      "sol-foundation",
    ]);
    assert.deepEqual(parseListing(""), []);
  });
});

describe("runTask", () => {
  let fake;
  beforeEach(() => { fake = createFakeTask(); });
  afterEach(() => { fake.cleanup(); });

  it("returns trimmed stdout on success", async () => {
    fake.setResponses([{ match: "sync", stdout: "  Sync complete  \n" }]);
    const result = await runTask(fake.config, ["sync"]);
    assert.equal(result, "Sync complete");
  });

  it("rejects with stderr context on failure", async () => {
    fake.setResponses([{ match: "sync", stderr: "connection refused\n", exit: 1 }]);
    await assert.rejects(
      () => runTask(fake.config, ["sync"]),
      /connection refused/,
    );
  });

  it("reports operation failure without echoing arguments", async () => {
    fake.setResponses([{ match: "sync", stderr: "boom\n", exit: 1 }]);
    await assert.rejects(
      () => runTask(fake.config, ["sync"]),
      /Taskwarrior operation failed/,
    );
  });
});

describe("sync", () => {
  let fake;
  beforeEach(() => { fake = createFakeTask(); });
  afterEach(() => { fake.cleanup(); });

  it("returns ok with output on success", async () => {
    fake.setResponses([{ match: "sync", stdout: "Sync complete\n" }]);
    const result = await sync(fake.config);
    assert.equal(result.ok, true);
    assert.equal(result.output, "Sync complete");
  });

  it("wraps failure with stop-don't-retry message", async () => {
    fake.setResponses([{ match: "sync", stderr: "connection refused\n", exit: 1 }]);
    await assert.rejects(
      () => sync(fake.config),
      /report and stop, do not retry/,
    );
  });
});

describe("exportTasks", () => {
  let fake;
  beforeEach(() => { fake = createFakeTask(); });
  afterEach(() => { fake.cleanup(); });

  it("returns empty array for empty output", async () => {
    fake.setResponses([{ match: "export", stdout: "" }]);
    const result = await exportTasks(fake.config, ["status:pending"]);
    assert.deepEqual(result, []);
  });

  it("parses NDJSON lines into task objects", async () => {
    const t1 = { uuid: UUID_A, status: "pending" };
    const t2 = { uuid: UUID_B, status: "pending" };
    fake.setResponses([
      { match: "export", stdout: JSON.stringify(t1) + "\n" + JSON.stringify(t2) + "\n" },
    ]);
    const result = await exportTasks(fake.config, ["status:pending"]);
    assert.equal(result.length, 2);
    assert.equal(result[0].uuid, UUID_A);
    assert.equal(result[1].uuid, UUID_B);
  });

  it("skips blank lines", async () => {
    const t1 = { uuid: UUID_A, status: "pending" };
    fake.setResponses([
      { match: "export", stdout: "\n" + JSON.stringify(t1) + "\n\n" },
    ]);
    const result = await exportTasks(fake.config, []);
    assert.equal(result.length, 1);
  });

  it("throws on malformed JSON line", async () => {
    fake.setResponses([
      { match: "export", stdout: "not json\n" },
    ]);
    await assert.rejects(
      () => exportTasks(fake.config, []),
      /Failed to parse/,
    );
  });
});

describe("getTask", () => {
  let fake;
  beforeEach(() => { fake = createFakeTask(); });
  afterEach(() => { fake.cleanup(); });

  it("returns the single matching task", async () => {
    const t = { uuid: UUID_A, status: "pending" };
    fake.setResponses([{ match: "export", stdout: JSON.stringify(t) + "\n" }]);
    const result = await getTask(fake.config, UUID_A);
    assert.equal(result.uuid, UUID_A);
  });

  it("throws when zero tasks match", async () => {
    fake.setResponses([{ match: "export", stdout: "" }]);
    await assert.rejects(
      () => getTask(fake.config, UUID_A),
      /Expected one task/,
    );
  });

  it("throws when multiple tasks match", async () => {
    const t1 = { uuid: UUID_A, status: "pending" };
    const t2 = { uuid: UUID_A, status: "pending" };
    fake.setResponses([
      { match: "export", stdout: JSON.stringify(t1) + "\n" + JSON.stringify(t2) + "\n" },
    ]);
    await assert.rejects(
      () => getTask(fake.config, UUID_A),
      /Expected one task/,
    );
  });
});

describe("countTasks", () => {
  let fake;
  beforeEach(() => { fake = createFakeTask(); });
  afterEach(() => { fake.cleanup(); });

  it("returns the parsed count", async () => {
    fake.setResponses([{ match: "count", stdout: "42\n" }]);
    const result = await countTasks(fake.config, ["status:pending"]);
    assert.equal(result, 42);
  });

  it("throws on non-numeric output", async () => {
    fake.setResponses([{ match: "count", stdout: "unknown\n" }]);
    await assert.rejects(
      () => countTasks(fake.config, []),
      /Failed to parse/,
    );
  });
});

describe("checkTaskBinary and checkSync", () => {
  let fake;
  beforeEach(() => { fake = createFakeTask(); });
  afterEach(() => { fake.cleanup(); });

  it("checkTaskBinary returns ok with version", async () => {
    fake.setResponses([{ match: "--version", stdout: "Task 3.5.0\n" }]);
    const result = await checkTaskBinary(fake.config);
    assert.equal(result.ok, true);
    assert.equal(result.version, "Task 3.5.0");
  });

  it("checkTaskBinary returns error when binary missing", async () => {
    fake.setResponses([{ match: "--version", stderr: "not found\n", exit: 127 }]);
    const result = await checkTaskBinary(fake.config);
    assert.equal(result.ok, false);
    assert.ok(result.error);
  });

  it("checkSync returns ok on success", async () => {
    fake.setResponses([{ match: "sync", stdout: "Sync complete\n" }]);
    const result = await checkSync(fake.config);
    assert.equal(result.ok, true);
  });

  it("checkSync returns error on failure", async () => {
    fake.setResponses([{ match: "sync", stderr: "fail\n", exit: 1 }]);
    const result = await checkSync(fake.config);
    assert.equal(result.ok, false);
    assert.ok(result.error);
  });
});

describe("doctor", () => {
  let fake;
  beforeEach(() => { fake = createFakeTask(); });
  afterEach(() => { fake.cleanup(); });

  it("returns all-pass summary when both checks succeed", async () => {
    fake.setResponses([
      { match: "--version", stdout: "Task 3.5.0\n" },
      { match: "sync", stdout: "Sync complete\n" },
    ]);
    const result = await doctor(fake.config);
    assert.equal(result.summary, "All checks passed ✓");
  });

  it("returns issues summary when sync fails", async () => {
    fake.setResponses([
      { match: "--version", stdout: "Task 3.5.0\n" },
      { match: "sync", stderr: "fail\n", exit: 1 },
    ]);
    const result = await doctor(fake.config);
    assert.ok(result.summary.includes("Issues"));
  });
});

describe("getInstallInstructions", () => {
  it("returns platform and arch info", () => {
    const info = getInstallInstructions();
    assert.ok(info.platform);
    assert.ok(info.arch);
    assert.ok(Array.isArray(info.instructions));
    assert.ok(info.instructions.length > 0);
  });

  it("includes a command in each instruction", () => {
    const info = getInstallInstructions();
    for (const instr of info.instructions) {
      assert.ok(instr.command, `instruction missing command: ${instr.manager}`);
      assert.ok(instr.manager, "instruction missing manager");
    }
  });
});

describe("generateSetupScript", () => {
  it("generates a bash script with task install command", () => {
    const script = generateSetupScript({ includeVerify: true });
    assert.ok(script.includes("#!/usr/bin/env bash"));
    assert.ok(script.includes("task"));
  });

  it("includes verify section when includeVerify is true", () => {
    const script = generateSetupScript({ includeVerify: true });
    assert.ok(script.includes("# Verify installation"));
    assert.ok(script.includes("task --version"));
    assert.ok(script.includes("task sync"));
  });

  it("omits verify section when includeVerify is false", () => {
    const script = generateSetupScript({ includeVerify: false });
    assert.ok(!script.includes("# Verify installation"));
    assert.ok(!script.includes("task --version"));
  });
});

describe("edge cases", () => {
  it("normalizeTag rejects non-string input", () => {
    assert.throws(() => normalizeTag(123), /Invalid tag/);
    assert.throws(() => normalizeTag(null), /Invalid tag/);
    assert.throws(() => normalizeTag(undefined), /Invalid tag/);
  });

  it("hasTag works on tasks with no tags field", () => {
    assert.equal(hasTag({}, "claimed"), false);
    assert.equal(hasTag({ tags: undefined }, "claimed"), false);
  });

  it("applyTagFilter handles both include and exclude", () => {
    const tasks = [
      { uuid: UUID_A, tags: ["bug", "ready-for-review"] },
      { uuid: UUID_B, tags: ["bug"] },
    ];
    const result = applyTagFilter(tasks, ["bug"], ["ready-for-review"]);
    assert.equal(result.length, 1);
    assert.equal(result[0].uuid, UUID_B);
  });

  it("applyTagFilter returns all tasks when no filters given", () => {
    const tasks = [
      { uuid: UUID_A, tags: ["bug"] },
      { uuid: UUID_B, tags: ["feature"] },
    ];
    assert.equal(applyTagFilter(tasks).length, 2);
  });

  it("lastClaimActor handles non-array annotations", () => {
    assert.equal(lastClaimActor({ annotations: "not-array" }), undefined);
    assert.equal(lastClaimActor({ annotations: null }), undefined);
    assert.equal(lastClaimActor({}), undefined);
  });

  it("assertActionable handles missing status field", () => {
    assert.throws(() => assertActionable({}), /not pending/);
    assert.throws(() => assertActionable({ status: null }), /not pending/);
  });

  it("buildSetArgs handles recur field", () => {
    const args = buildSetArgs({ recur: "weekly" });
    assert.ok(args.includes("recur:weekly"));
  });

  it("buildSetArgs handles depends as scalar string", () => {
    const args = buildSetArgs({ depends: UUID_B });
    assert.ok(args.includes(`depends:${UUID_B}`));
  });

  it("buildModifyArgs with no changes returns empty array", () => {
    assert.deepEqual(buildModifyArgs({}), []);
  });

  it("formatAnnotation accepts actor at exactly 80 chars", () => {
    const actor80 = "x".repeat(80);
    assert.doesNotThrow(() => formatAnnotation(actor80, "a", "d"));
  });
});
