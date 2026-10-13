# Development and validation

Start with [architecture](architecture.md) for the source map and workflow
boundaries. Shell workers and the plugin are independent; validate both when
changing shared lifecycle assumptions. Durable work belongs in the team's
Taskwarrior pool; record stable technical decisions in `DECISIONS.md`.

## Local checks

Use Node.js 22+ with `--experimental-strip-types` support, npm, Bash, Bats,
and jq. The package runtime engine remains Node.js >=20, but the current
unit-test command imports TypeScript through Node's type-stripping flag.
From the repository root:

```bash
(cd plugin && npm ci)
(cd plugin && npm run typecheck && npm test && npm run build)
bats tests/task-drain.bats
bash -n drain task-drain.sh install.sh lib/display.sh lib/worker-detect.sh
git diff --check
```

`npm ci` invokes the `prepare` build. `npm run build` uses TypeScript to
produce `plugin/dist/`, including the JavaScript helper module. Generated
output and `node_modules/` are ignored. There is no configured lint script;
`bash -n` checks syntax, not runtime correctness.

## Test boundaries

- `plugin/tests/task.test.mjs`: validation, argument construction, guards,
  subprocess helpers, and setup/diagnostic behavior.
- `plugin/tests/tools.test.mjs`: shared tool handlers with a fake Taskwarrior
  executable under `plugin/tests/helpers/`. `npm test` runs both suites.
- `tests/task-drain.bats`: shell functions using a mock task command and
  fixture directories. It extracts definitions from the worker rather than
  running a real agent queue. Do not run two copies simultaneously: fixture
  names under `tests/` are shared and removed by teardown.
- `plugin/tests/integration.test.mjs`: real Taskwarrior commands and sync,
  including helper guards and manually reproduced lifecycle transitions.
  This is not an end-to-end agent or MCP transport test.

The current `.github/workflows/tests.yml` workflow runs JS and Bats jobs on pushes to branches other than main/master.
Check the workflow triggers when changing CI. Local
passing checks do not establish that remote CI or live agent execution passed.

## Live integration tests

Use a dedicated empty Taskwarrior profile with a separate data directory and
a **separate scratch pool identity**, not the team's production pool. Configure
and verify sync for that profile before running the suite:

```bash
TASKRC=/absolute/path/to/scratch.taskrc \
TASK_BIN=/absolute/path/to/task \
npm --prefix plugin run test:integration
```

The suite explicitly calls sync even if `TASK_AUTO_SYNC=0`; that variable
is not a safety barrier here. It creates real tasks tagged `plugin-test` and
attempts to delete them at teardown. Failed runs may leave tasks behind, and
teardown does not perform a final sync. Inspect the scratch profile and sync
cleanup afterward. `npm run test:all` includes this live suite.

## Changing behavior

For a tool change, update `plugin/src/tools.ts` and/or `task.mjs`, exercise the
shared handler, and confirm the exported schema and response documentation.
For worker changes, cover selection, claim failure, result handling, and
stop behavior with fake commands before a deliberate scratch-pool smoke run.
Never source the worker file unguarded: its bottom-level dispatch starts a
worker by default.

When altering CLI flags or configuration, update the Markdown reference,
embedded `drain help`/`drain docs`, installer output, and tests together.
Use [troubleshooting](troubleshooting.md) and the [review issue register](documentation-review.md)
to distinguish intended behavior from documented implementation limitations.
