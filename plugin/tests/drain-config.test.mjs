import { describe, it, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import {
  loadSchema,
  resolveDrainConfig,
  parseYamlSubset,
  hostMatch,
} from "../src/drain-config.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const FIX = join(here, "..", "..", "tests", "config-fixtures");
const SCHEMA = join(here, "..", "src", "config-schema.json");
const LIB_SCHEMA = join(here, "..", "..", "lib", "config-schema.json");

function read(p) {
  return readFileSync(p, "utf8");
}

describe("schema sync", () => {
  it("plugin copy matches the canonical lib schema", () => {
    assert.equal(read(SCHEMA), read(LIB_SCHEMA));
  });
});

describe("shared fixtures (parity with shell resolver)", () => {
  it("missing file resolves to defaults", () => {
    const r = resolveDrainConfig({
      configPath: join(tmpdir(), "drain-missing-" + Date.now() + ".yaml"),
      schema: loadSchema(SCHEMA),
    });
    assert.equal(r.values["worker.agent"], "opencode");
    assert.equal(r.values["sync.retries"], 3);
    assert.equal(r.configPresent, false);
  });

  it("minimal valid config: yaml provenance", () => {
    const r = resolveDrainConfig({ configPath: join(FIX, "minimal.yaml"), schema: loadSchema(SCHEMA) });
    assert.equal(r.values["worker.primary_host"], "llama");
    assert.equal(r.sources["worker.primary_host"], "yaml");
    assert.equal(r.sources["sync.retries"], "default");
  });

  it("full valid config resolves every setting", () => {
    const r = resolveDrainConfig({ configPath: join(FIX, "full.yaml"), schema: loadSchema(SCHEMA) });
    assert.equal(r.values["worker.agent"], "claude");
    assert.equal(r.values["worker.model"], "test-model-1");
    assert.equal(r.values["worker.skip_permissions"], true);
    assert.equal(r.values["supervisor.min_workers"], 2);
    assert.equal(r.values["supervisor.max_workers"], 6);
    assert.equal(r.values["sync.retries"], 5);
    assert.equal(r.values["locks.grace_seconds"], 5);
    assert.equal(r.values["history.limit"], 50);
    assert.equal(r.values["display.verbose"], true);
    assert.equal(r.values["logging.level"], "debug");
    assert.equal(r.values["paths.task_bin"], "/bin/echo");
    assert.equal(r.values["task.auto_sync"], false);
  });

  it("unknown keys are rejected", () => {
    assert.throws(() => resolveDrainConfig({ configPath: join(FIX, "invalid-unknown.yaml"), schema: loadSchema(SCHEMA) }), /unknown config key/);
  });

  it("wrong types are rejected", () => {
    assert.throws(() => resolveDrainConfig({ configPath: join(FIX, "invalid-type.yaml"), schema: loadSchema(SCHEMA) }), /sync\.retries/);
  });

  it("out-of-range integers are rejected", () => {
    assert.throws(() => resolveDrainConfig({ configPath: join(FIX, "invalid-range.yaml"), schema: loadSchema(SCHEMA) }), /out of range/);
  });

  it("invalid booleans are rejected", () => {
    assert.throws(() => resolveDrainConfig({ configPath: join(FIX, "invalid-bool.yaml"), schema: loadSchema(SCHEMA) }), /invalid boolean/);
  });

  it("malformed YAML fails closed", () => {
    assert.throws(() => resolveDrainConfig({ configPath: join(FIX, "malformed.yaml"), schema: loadSchema(SCHEMA) }));
  });

  it("precedence: yaml < environment < cli with provenance", () => {
    const schema = loadSchema(SCHEMA);
    let r = resolveDrainConfig({ configPath: join(FIX, "full.yaml"), schema, environ: { ...process.env, DRAIN_SYNC_RETRIES: "7" } });
    assert.equal(r.values["sync.retries"], 7);
    assert.equal(r.sources["sync.retries"], "environment");
    r = resolveDrainConfig({ configPath: join(FIX, "full.yaml"), schema, environ: { ...process.env, DRAIN_SYNC_RETRIES: "7" }, cli: { "sync.retries": "9" } });
    assert.equal(r.values["sync.retries"], 9);
    assert.equal(r.sources["sync.retries"], "cli");
  });

  it("empty env values fall through to yaml", () => {
    const schema = loadSchema(SCHEMA);
    const r = resolveDrainConfig({ configPath: join(FIX, "full.yaml"), schema, environ: { ...process.env, DRAIN_SYNC_RETRIES: "" } });
    assert.equal(r.values["sync.retries"], 5);
  });

  it("conflicting env aliases are detected", () => {
    const schema = loadSchema(SCHEMA);
    assert.throws(
      () => resolveDrainConfig({ configPath: join(FIX, "minimal.yaml"), schema, environ: { ...process.env, TASK: "/bin/a", TASK_BIN: "/bin/b" } }),
      /conflicting environment aliases/,
    );
  });

  it("host matching handles short/FQDN without false equivalence", () => {
    assert.equal(hostMatch("llama", "llama"), true);
    assert.equal(hostMatch("llama", "llama.example.com"), true);
    assert.equal(hostMatch("llama.example.com", "llama"), true);
    assert.equal(hostMatch("llama", "llama2"), false);
    assert.equal(hostMatch("llama", "llamax.example.com"), false);
  });

  it("boolean parsing is strict and consistent", () => {
    const schema = loadSchema(SCHEMA);
    for (const good of ["1", "true", "yes", "on", "0", "false", "no", "off"]) {
      const r = resolveDrainConfig({ configPath: join(FIX, "minimal.yaml"), schema, environ: { ...process.env, DRAIN_AUTONOMOUS: good } });
      assert.equal(typeof r.values["worker.autonomous"], "boolean");
    }
    assert.throws(() => resolveDrainConfig({ configPath: join(FIX, "minimal.yaml"), schema, environ: { ...process.env, DRAIN_AUTONOMOUS: "perhaps" } }), /invalid boolean/);
  });

  it("min/max cross-field validation", () => {
    const schema = loadSchema(SCHEMA);
    assert.throws(
      () => resolveDrainConfig({ configPath: join(FIX, "minimal.yaml"), schema, cli: { "supervisor.min_workers": "8", "supervisor.max_workers": "2" } }),
      /cannot exceed/,
    );
  });

  it("yaml subset parser rejects tabs, sequences, anchors", () => {
    assert.throws(() => parseYamlSubset("worker:\n\tallow_home: true\n", "t"), /tabs/);
    assert.throws(() => parseYamlSubset("worker:\n  - a\n", "t"), /sequences/);
    assert.throws(() => parseYamlSubset("a: &x 1\n", "t"), /anchors/);
  });
});
