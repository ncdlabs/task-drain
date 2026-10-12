/**
 * Fake task binary for unit testing tools.ts and task.mjs.
 *
 * Creates an executable Node.js script that responds to task commands
 * based on a control file. All invocations are logged to a file for
 * asserting on call sequences.
 *
 * Control file format (JSON):
 *   { "responses": [ { "match": "pattern", "stdout": "...", "stderr": "...", "exit": 0 } ] }
 *
 * The fake binary matches responses by checking if the joined args include
 * the `match` string. First match wins.
 */
import {
  mkdtempSync,
  writeFileSync,
  chmodSync,
  readFileSync,
  rmSync,
  existsSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const FAKE_BINARY_SOURCE = `#!/usr/bin/env node
const fs = require('fs');
const logFile = process.env.MOCK_TASK_LOG;
const controlFile = process.env.MOCK_TASK_CONTROL;
const args = process.argv.slice(2);
if (logFile) fs.appendFileSync(logFile, JSON.stringify(args) + '\\n');
let control = { responses: [] };
if (controlFile && fs.existsSync(controlFile)) {
  control = JSON.parse(fs.readFileSync(controlFile, 'utf8'));
}
const key = args.join(' ');
for (const resp of control.responses || []) {
  if (key.includes(resp.match)) {
    if (resp.stdout) process.stdout.write(resp.stdout);
    if (resp.stderr) process.stderr.write(resp.stderr);
    process.exit(resp.exit || 0);
  }
}
process.exit(0);
`;

export function createFakeTask() {
  const dir = mkdtempSync(join(tmpdir(), "fake-task-"));
  const bin = join(dir, "task");
  writeFileSync(bin, FAKE_BINARY_SOURCE);
  chmodSync(bin, 0o755);

  const controlPath = join(dir, "control.json");
  const logPath = join(dir, "calls.log");

  const prevControl = process.env.MOCK_TASK_CONTROL;
  const prevLog = process.env.MOCK_TASK_LOG;

  process.env.MOCK_TASK_CONTROL = controlPath;
  process.env.MOCK_TASK_LOG = logPath;

  const fake = {
    dir,
    bin,
    controlPath,
    logPath,
    config: { bin, autoSync: false },

    setResponses(responses) {
      writeFileSync(controlPath, JSON.stringify({ responses }));
    },

    getCalls() {
      if (!existsSync(logPath)) return [];
      return readFileSync(logPath, "utf8")
        .trim()
        .split("\n")
        .filter(Boolean)
        .map((line) => JSON.parse(line));
    },

    clearCalls() {
      writeFileSync(logPath, "");
    },

    cleanup() {
      if (prevControl === undefined) delete process.env.MOCK_TASK_CONTROL;
      else process.env.MOCK_TASK_CONTROL = prevControl;
      if (prevLog === undefined) delete process.env.MOCK_TASK_LOG;
      else process.env.MOCK_TASK_LOG = prevLog;
      rmSync(dir, { recursive: true, force: true });
    },
  };

  fake.setResponses([]);

  return fake;
}
