import { describe, it } from "node:test";
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
  completeGuard,
  formatAnnotation,
  hasTag,
  lastClaimActor,
  normalizeTag,
  normalizeTags,
  parseListing,
  resolveConfig,
  startGuard,
} from "../src/task.mjs";

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

  it("startGuard blocks already-started tasks", () => {
    assert.throws(
      () => startGuard(task({ start: "20261007T100000Z" })),
      /already started/,
    );
    startGuard(task({ start: "20261007T100000Z" }), { force: true });
    startGuard(task());
  });

  it("completeGuard requires approval or review stage", () => {
    assert.throws(() => completeGuard(task()), /requires \+approved/);
    completeGuard(task({ tags: ["approved"] }));
    completeGuard(task({ tags: ["ready-for-review"] }));
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
