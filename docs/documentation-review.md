# Engineering documentation review

This register distinguishes corrected documentation from implementation
limitations. Entries marked **documented limitation** remain in code; this
review does not claim to remediate them. Evidence refers to the owning source
file and function, so findings remain navigable as line numbers change.

Scope: root README and all documentation under `docs/`, checked against shell
entry points, installer, plugin helpers/handlers, and tests. The review was
reassessed after commits `994463d` and `9c62e07`, including the expanded tests
and CI configuration. No live agent queue, installer, or destructive uninstall
procedure was executed to validate documentation.

## Findings

| # | Issue and engineering consequence | Evidence | Resolution |
|---|---|---|---|
| 1 | Different client IDs per machine create separate pools instead of sharing tasks. | [Official sync manual](https://taskwarrior.org/docs/man/task-sync.5/) | Corrected installation: same pool identity/secret, separate local replicas. |
| 2 | Missing encryption secret was described as allowing plaintext sync. | Official sync manual; `install.sh` warning | Corrected docs; misleading installer warning remains. |
| 3 | Uninstall deleted `taskchampion-data` before the backup warning. | Previous uninstall sequence; installer data mount | Reordered uninstall to stop, preserve data, then remove deliberately. |
| 4 | Permission bypass was presented as applying to every harness. | `task-drain.sh`: flag array and `run_one` | Corrected: OpenCode only. |
| 5 | `OPENCODE_RUN_FLAGS` was advertised as an environment override but is reassigned unconditionally. | `task-drain.sh`: top-level array assignment | Documented as an internal array. |
| 6 | `noauto` was described as an unconditional exclusion; autonomous mode requires `auto` without excluding `noauto`. | `drain_elig_filter`, retry snapshot construction | Corrected filter tables and withholding instructions; documented limitation. |
| 7 | Environment-only autonomous mode was said to launch an autoscaler. | `drain`: `cmd_start` checks the CLI-local flag | Corrected distinction between flag and environment. |
| 8 | Verification and PR workflow were described as shell-enforced guarantees. | `build_prompt`, `run_one` | Corrected: prompt instructions; success checks only task status. |
| 9 | Claims are not atomic, so duplicate execution remains possible. | `pick_task`, `claim_task` | Documented limitation; no exactly-once guarantee. |
| 10 | Stale release was described as detecting worker death. It checks active age globally, including live workers and other projects. | `reclaim_stale` | Documented limitation and timeout interaction. |
| 11 | One retry per run was overstated: snapshots are per worker and rechecks omit some original eligibility conditions. | `run_worker`, `pick_retry_task` | Corrected scope of retry guarantee. |
| 12 | Plugin lifecycle tags do not isolate tasks from shell workers; checkouts are also shared without worktree/locking isolation. | Worker filter and `repo_for_project`; plugin claim/review handlers | Added coexistence and concurrency guidance. |
| 13 | Plugin completion does not require separate approval; `ready-for-review` suffices. | `task.mjs`: `completeGuard` | Explicitly documented; not a human approval barrier. |
| 14 | Completed tasks are not universally immutable and force behavior differs by operation. Same-actor claims also fail; in-review claims fail even with force. | `tools.ts`; `claimGuard`, `assertActionable` | Corrected guard descriptions. |
| 15 | Plugin blocked/auto queues were described too broadly: stored `blocked` tag differs from dependency blocking; auto selection ignores worker tags, urgency sorting, and project input. | `tools.ts`: `blocked_tasks`, `auto`, `agent_queue` | Documented exact selection behavior. |
| 16 | Both scripts were said to resolve symlinks; only `drain` does. Copying scripts alone omits `lib/`. | Script initialization | Corrected manual installation and direct invocation. |
| 17 | TASKRC was said to affect only sudo; ordinary Taskwarrior commands inherit it too. | Exported process environment; plugin `taskEnv` | Corrected configuration and profile guidance. |
| 18 | Project merge does not guarantee moving all tasks: it skips some sources, suppresses modification errors, reports a pre-count, and references uninitialized TASK. | `drain`: `cmd_projects_merge` | Documented limitations, explicit TASK, and verification requirement. |
| 19 | PR discovery is not complete or cross-forge: only GitHub, directory `.git`, `Task <uuid>` body pattern, gh default limits; failures may look empty. | `drain_list_prs` | Corrected command scope and diagnosis. |
| 20 | Engineering onboarding lacked source map, execution boundaries, test instructions, and recovery procedures. | Original README/docs coverage | Added architecture, development, and troubleshooting guides. |
| 21 | Installer success was treated as setup verification despite warnings and container-only checks. | `install.sh` | Documented side effects and independent verification. |
| 22 | Installer URL override and setting detection are unreliable (`task show` parsed with awk; differing URL preserved). | `install.sh` sync setup | Documented limitation; configure profile first. |
| 23 | Installer prints singular `plugin`, while this adapter targets OpenCode v2 `plugins`. | `install.sh`, `plugin/src/index.ts`; [v2 guide](https://opencode.ai/v2/docs/build/plugins/) | Corrected docs; installer output remains stale. |
| 24 | PATH is replaced, so interactive-shell binary availability does not imply worker availability. | Both script headers | Added fixed PATH and explicit binary guidance. |
| 25 | Timeout portability omitted that only `gtimeout` is detected; ordinary Linux `timeout` is ignored. | `run_one` | Documented limitation. |
| 26 | `drain stop` returns early without workers, leaving a supervisor untouched; TERM does not ensure all descendants stop or cleanup sync succeeds. | `cmd_stop`, `cmd_kill`, `on_signal` | Corrected stop semantics and recovery guidance. |
| 27 | Autoscale equals-form arguments do not shift and can loop indefinitely. | `cmd_autoscale` | Documented limitation; use spaced `--min N --max N`. |
| 28 | Existing supervisor settings persist; exported PROJECT_FILTER can survive `all`; autoscale does not clear STOP; process counting is not project-isolated. | `cmd_start`, `cmd_autoscale`, `autoscale_supervisor` | Added launch/configuration caveats. |
| 29 | History display limits cannot restore pruned records, and concurrent pruning is unlocked. | `history_record`, `cmd_history` | Documented retention and audit limitations. |
| 30 | `unfail` changes immediately, filters out some failed tasks, and does not sync. | `cmd_unfail` | Corrected reference with exact filter and sync steps. |
| 31 | Sudo fallback does not guarantee ownership; task-only sudoers permission may not cover `sudo env`. Historical platform observations were overgeneralized. | `task_sync`; historical decision record | Qualified incident record and added operational guidance. |
| 32 | Offline/transaction guarantees were overstated: worker ignores some sync errors; plugin failures can follow successful local writes. | `run_one`, `run_worker`, `autoscale_supervisor`; plugin `mutate` | Documented failure semantics and duplicate-creation risk. |
| 33 | Plugin setup was described as needing no server; it only generates a client script. File writes can overwrite and containment is lexical, not symlink-resolved. | `tools.ts`: `setup` | Corrected tool reference; documented limitations. |
| 34 | Integration test coverage and fixed test count were overstated/outdated. Live suite reproduces many operations rather than invoking handlers/transport. | Plugin test files | Corrected test boundaries and scratch-pool requirements. |
| 35 | Runtime Node minimum is insufficient for current tests' type-stripping flag. | `plugin/package.json`, CI | Development instructions use Node 22+ with flag support; runtime remains >=20. |
| 36 | Bats test for exhausted retry snapshot fails on expected function exit status before its assertion. | `tests/task-drain.bats`: `pick_retry_task skips non-pending tasks` | Reported validation defect; test source unchanged by documentation review. |
| 37 | Webhook described as generally Slack/Discord-compatible and all errors logged; code sends a `text` payload on selected paths only. | `report_error`, MCP startup catch | Corrected configuration; no promise of every-failure notification. |
| 38 | Project listing was called effective mapping; it lists sources. Subprojects require exact mappings, paths are not shell-parsed, missing dirs fall back to HOME. | `cmd_projects`, `repo_for_project`, `run_one` | Corrected mapping reference. |
| 39 | No-telemetry wording omitted task/context transmission through agents, sync, PR lookup, and optional webhook. | Agent invocation and network call sites | Added explicit data-flow description. |
| 40 | Prerequisites misstated Codex as OpenCode, omitted plugin Node minimum and forge auth, claimed no hosted service, and implied workers themselves check Taskwarrior version. | Installer checks and package manifest | Corrected prerequisites and removed unsupported service-availability claim. |
| 41 | Direct mode reference omitted `pr-list`; state inventory omitted autoscale log and optional server data. | Worker dispatch and installer | Completed CLI/state reference. |
| 42 | `task_record_decision` optional actor/default and behavior were unclear; it does not write repository decision records. | `tools.ts`: `record_decision` | Corrected API and durable-decision guidance. |
| 43 | Future scheduled dates were conflated with waiting, and dashboards could show a different mode from running workers. | Queue filter; dashboard environment | Explained waiting/scheduled distinction and mode-matched inspection. |

## Validation

- JavaScript tests: 119 passed, 0 failed.
- TypeScript typecheck: passed.
- Plugin build: passed.
- Bats: 88 passed, 1 failed (issue 36).
- Shell syntax and whitespace checks: passed at review time.
- All 40 relative links/heading anchors across 12 documents resolve; README is 162 lines.
- Live integration tests, installer execution, agent runs, and uninstall were
  not run against the shared pool. Documentation review does not establish
  live deployment readiness.

Remaining implementation limitations are described above for engineering
assessment; they are not new feature commitments or a replacement for the
project's Taskwarrior work queue.
