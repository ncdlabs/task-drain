/**
 * tools.ts: shared Taskwarrior tool definitions.
 *
 * createTools(config) returns the 22 task lifecycle tool descriptors.
 * Both the OpenCode plugin (index.ts) and the MCP server (mcp-server.ts)
 * consume these -- the handler logic lives here exactly once.
 */

/**
 * opencode-tasks: TaskChampion/Taskwarrior tools for OpenCode.
 *
 * Exposes the shared-pool task lifecycle as namespaced tools (`task_sync`,
 * `task_add`, `task_claim`, ...) so any agent session can perform the
 * session duties from the global rules without shelling out to `task` by hand:
 * sync before/after operations, UUID-first references, claim -> work ->
 * review -> approve -> complete, and decision recording.
 *
 * Configuration (plugin options in opencode.json, or env):
 * - taskBin: task binary (default $TASK_BIN or /opt/homebrew/bin/task)
 * - taskrc: taskrc profile path (default $TASKRC or the shared ~/.taskrc pool)
 * - autoSync: sync before reads and around writes (default true,
 *   $TASK_AUTO_SYNC=0 disables)
 */

import {
  approveGuard,
  applyTagFilter,
  assertActionable,
  assertActor,
  assertUuid,
  buildModifyArgs,
  buildSetArgs,
  claimGuard,
  completeGuard,
  countTasks,
  doctor,
  exportTasks,
  formatAnnotation,
  generateSetupScript,
  getTask,
  hasTag,
  lastClaimActor,
  normalizeTags,
  parseListing,
  runTask,
  startGuard,
  sync,
} from "./task.mjs";

type Task = Record<string, any>;
type ExecContext = { signal?: AbortSignal };

function text(data: unknown) {
  return { content: JSON.stringify(data, null, 2) };
}

const PRIORITY_SCHEMA = { type: "string", enum: ["H", "M", "L"] } as const;
const STATUS_SCHEMA = {
  type: "string",
  enum: ["pending", "completed", "deleted", "waiting", "recurring", "all"],
  default: "pending",
} as const;
const UUID_SCHEMA = {
  type: "string",
  description:
    "Full task UUID. Numeric IDs are replica-local; resolve them to UUIDs first.",
} as const;
const ACTOR_SCHEMA = {
  type: "string",
  description: "Agent or human actor name recorded in annotations.",
} as const;
const TAG_LIST_SCHEMA = {
  type: "array",
  items: { type: "string" },
  description:
    "Tags. Underscore spellings (ready_for_review) are normalized to live-pool hyphenated tags.",
} as const;

function objectSchema(
  properties: Record<string, unknown>,
  required: string[] = [],
) {
  return {
    type: "object",
    properties,
    required,
    additionalProperties: false,
  };
}


export interface TaskConfig {
  bin: string;
  taskrc?: string;
  autoSync: boolean;
}

export interface ToolDef {
  name: string;
  description: string;
  /** JSON Schema for the tool input. */
  input: Record<string, any>;
  execute: (input: any, context: ExecContext) => Promise<{ content: string }>;
}

export function createTools(config: TaskConfig): ToolDef[] {

    const maybeSyncBefore = async (context: ExecContext) => {
      if (config.autoSync) await sync(config, { signal: context.signal });
    };
    const maybeSyncAfter = async (context: ExecContext) => {
      if (config.autoSync) await sync(config, { signal: context.signal });
    };
    const readOne = async (uuid: string, context: ExecContext) => {
      await maybeSyncBefore(context);
      return (await getTask(config, uuid, {
        signal: context.signal,
      })) as Task;
    };
    const mutate = async <T>(
      fn: () => Promise<T>,
      context: ExecContext,
    ): Promise<T> => {
      await maybeSyncBefore(context);
      const result = await fn();
      await maybeSyncAfter(context);
      return result;
    };

    
  const tools: ToolDef[] = [];

      

      tools.push({
        name: "sync",
        description:
          "Synchronize the local replica with the TaskChampion sync server. Runs automatically around other tools unless autoSync is disabled.",
        input: objectSchema({}),
        execute: async (_input: any, context: any) =>
          text(await sync(config, { signal: context.signal })),
      });

      tools.push({
        name: "add",
        description:
          "Create a task. Check for duplicates with task_list (project filter) before creating.",
        input: objectSchema(
          {
            description: { type: "string", description: "Task title." },
            project: { type: "string" },
            priority: PRIORITY_SCHEMA,
            due: { type: "string", description: 'Due date, e.g. "tomorrow", "2026-10-15".' },
            scheduled: { type: "string" },
            wait: { type: "string" },
            until: { type: "string" },
            recur: { type: "string", description: 'Recurrence, e.g. "weekly".' },
            tags: TAG_LIST_SCHEMA,
            depends: {
              type: "array",
              items: UUID_SCHEMA,
              description: "Blocking task UUIDs.",
            },
            annotations: {
              type: "array",
              items: { type: "string" },
              description: "Initial notes, recorded as structured annotations.",
            },
            actor: ACTOR_SCHEMA,
          },
          ["description"],
        ),
        execute: async (input: any, context: any) =>
          text(
            await mutate(async () => {
              const actor = input.actor ?? "opencode";
              assertActor(actor);
              const setArgs = buildSetArgs(input);
              const output = await runTask(
                config,
                ["rc.verbose=new-uuid", "add", input.description, ...setArgs],
                { signal: context.signal },
              );
              const uuid = output.match(
                /[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}/i,
              )?.[0];
              if (!uuid) {
                throw new Error(
                  `Could not resolve created task UUID from: ${output}`,
                );
              }
              for (const note of input.annotations ?? []) {
                await runTask(
                  config,
                  [uuid, "annotate", formatAnnotation(actor, "note", note)],
                  { signal: context.signal },
                );
              }
              return await getTask(config, uuid, {
                signal: context.signal,
              });
            }, context),
          ),
      });

      tools.push({
        name: "list",
        description:
          "List tasks with structured filters. Hyphenated tags are filtered client-side for correctness.",
        input: objectSchema({
          status: STATUS_SCHEMA,
          project: { type: "string" },
          tags: { ...TAG_LIST_SCHEMA, description: "Only tasks carrying all these tags." },
          exclude_tags: {
            type: "array",
            items: { type: "string" },
            description: "Exclude tasks carrying any of these tags.",
          },
          limit: {
            type: "number",
            description: "Max tasks returned (default 50, max 500).",
          },
        }),
        execute: async (input: any, context: any) => {
          await maybeSyncBefore(context);
          const status = input.status ?? "pending";
          const filterArgs: string[] = [];
          const statusFilter: Record<string, string> = {
            pending: "status:pending",
            completed: "status:completed",
            deleted: "status:deleted",
            waiting: "status:waiting",
            recurring: "status:recurring",
            all: "status:pending,completed,deleted,waiting,recurring",
          };
          const filter = statusFilter[status];
          if (!filter) {
            throw new Error(`Unsupported status filter: ${status}`);
          }
          filterArgs.push(filter);
          if (input.project) filterArgs.push(`project:${input.project}`);
          const limit = Math.min(Math.max(input.limit ?? 50, 1), 500);
          let tasks = (await exportTasks(config, filterArgs, {
            signal: context.signal,
          })) as Task[];
          tasks = applyTagFilter(tasks, input.tags ?? [], input.exclude_tags ?? []);
          const sliced = tasks.slice(0, limit);
          return text({ tasks: sliced, count: sliced.length, total_matching: tasks.length });
        },
      });

      tools.push({
        name: "get",
        description: "Get one task by full UUID, including annotations and tags.",
        input: objectSchema({ uuid: UUID_SCHEMA }, ["uuid"]),
        execute: async (input: any, context: any) =>
          text({ task: await readOne(input.uuid, context) }),
      });

      tools.push({
        name: "modify",
        description:
          "Modify description, project, priority, dates, or tags of one task by UUID. Custom UDAs are refused (shared pool defines none).",
        input: objectSchema(
          {
            uuid: UUID_SCHEMA,
            description: { type: "string" },
            project: { type: "string" },
            priority: PRIORITY_SCHEMA,
            due: { type: "string" },
            scheduled: { type: "string" },
            wait: { type: "string" },
            until: { type: "string" },
            recur: { type: "string" },
            add_tags: TAG_LIST_SCHEMA,
            remove_tags: TAG_LIST_SCHEMA,
            note: {
              type: "string",
              description: "Optional note recorded as an annotation.",
            },
            actor: ACTOR_SCHEMA,
          },
          ["uuid"],
        ),
        execute: async (input: any, context: any) =>
          text(
            await mutate(async () => {
              assertUuid(input.uuid);
              const args = buildModifyArgs(input);
              if (args.length === 0 && !input.note) {
                throw new Error("Nothing to modify: pass a field, tag change, or note.");
              }
              if (args.length > 0) {
                await runTask(config, [input.uuid, "modify", ...args], {
                  signal: context.signal,
                });
              }
              if (input.note) {
                const actor = input.actor ?? "opencode";
                await runTask(
                  config,
                  [input.uuid, "annotate", formatAnnotation(actor, "note", input.note)],
                  { signal: context.signal },
                );
              }
              return await getTask(config, input.uuid, {
                signal: context.signal,
              });
            }, context),
          ),
      });

      tools.push({
        name: "annotate",
        description: "Add a structured [actor] action: detail annotation to a task.",
        input: objectSchema(
          {
            uuid: UUID_SCHEMA,
            actor: ACTOR_SCHEMA,
            action: { type: "string" },
            detail: { type: "string" },
          },
          ["uuid", "actor", "action", "detail"],
        ),
        execute: async (input: any, context: any) =>
          text(
            await mutate(async () => {
              assertUuid(input.uuid);
              await runTask(
                config,
                [
                  input.uuid,
                  "annotate",
                  formatAnnotation(input.actor, input.action, input.detail),
                ],
                { signal: context.signal },
              );
              return await getTask(config, input.uuid, {
                signal: context.signal,
              });
            }, context),
          ),
      });

      tools.push({
        name: "add_dependency",
        description: "Record that one task is blocked by another (depends).",
        input: objectSchema({ uuid: UUID_SCHEMA, depends_on: UUID_SCHEMA }, [
          "uuid",
          "depends_on",
        ]),
        execute: async (input: any, context: any) =>
          text(
            await mutate(async () => {
              assertUuid(input.uuid);
              assertUuid(input.depends_on);
              await runTask(
                config,
                [input.uuid, "modify", `depends:${input.depends_on}`],
                { signal: context.signal },
              );
              return await getTask(config, input.uuid, {
                signal: context.signal,
              });
            }, context),
          ),
      });

      tools.push({
        name: "claim",
        description:
          "Claim a task for an actor before starting work. Fails if in review or already claimed by someone else (unless force).",
        input: objectSchema(
          {
            uuid: UUID_SCHEMA,
            actor: ACTOR_SCHEMA,
            force: { type: "boolean", description: "Steal an existing claim." },
          },
          ["uuid", "actor"],
        ),
        execute: async (input: any, context: any) =>
          text(
            await mutate(async () => {
              assertUuid(input.uuid);
              assertActor(input.actor);
              const task = (await getTask(config, input.uuid, {
                signal: context.signal,
              })) as Task;
              claimGuard(task, input.actor, { force: input.force === true });
              await runTask(config, [input.uuid, "modify", "+claimed"], {
                signal: context.signal,
              });
              await runTask(
                config,
                [input.uuid, "annotate", formatAnnotation(input.actor, "claimed", "claimed for implementation")],
                { signal: context.signal },
              );
              return await getTask(config, input.uuid, {
                signal: context.signal,
              });
            }, context),
          ),
      });

      tools.push({
        name: "release",
        description: "Release a claimed task so it can be reassigned.",
        input: objectSchema(
          {
            uuid: UUID_SCHEMA,
            actor: ACTOR_SCHEMA,
            reason: { type: "string" },
          },
          ["uuid", "actor"],
        ),
        execute: async (input: any, context: any) =>
          text(
            await mutate(async () => {
              assertUuid(input.uuid);
              const task = (await getTask(config, input.uuid, {
                signal: context.signal,
              })) as Task;
              assertActionable(task);
              if (task.start) {
                await runTask(config, [input.uuid, "stop"], {
                  signal: context.signal,
                });
              }
              await runTask(config, [input.uuid, "modify", "-claimed"], {
                signal: context.signal,
              });
              await runTask(
                config,
                [
                  input.uuid,
                  "annotate",
                  formatAnnotation(input.actor, "released", input.reason ?? "released for reassignment"),
                ],
                { signal: context.signal },
              );
              return await getTask(config, input.uuid, {
                signal: context.signal,
              });
            }, context),
          ),
      });

      tools.push({
        name: "start",
        description: "Mark a claimed task as actively being worked (task start).",
        input: objectSchema(
          {
            uuid: UUID_SCHEMA,
            actor: ACTOR_SCHEMA,
            force: { type: "boolean" },
          },
          ["uuid", "actor"],
        ),
        execute: async (input: any, context: any) =>
          text(
            await mutate(async () => {
              assertUuid(input.uuid);
              const task = (await getTask(config, input.uuid, {
                signal: context.signal,
              })) as Task;
              startGuard(task, { force: input.force === true });
              await runTask(config, [input.uuid, "start"], {
                signal: context.signal,
              });
              await runTask(
                config,
                [input.uuid, "annotate", formatAnnotation(input.actor, "started", "implementation underway")],
                { signal: context.signal },
              );
              return await getTask(config, input.uuid, {
                signal: context.signal,
              });
            }, context),
          ),
      });

      tools.push({
        name: "stop",
        description: "Stop active work on a task without completing it.",
        input: objectSchema(
          {
            uuid: UUID_SCHEMA,
            actor: ACTOR_SCHEMA,
            note: { type: "string" },
            force: { type: "boolean" },
          },
          ["uuid", "actor"],
        ),
        execute: async (input: any, context: any) =>
          text(
            await mutate(async () => {
              assertUuid(input.uuid);
              const task = (await getTask(config, input.uuid, {
                signal: context.signal,
              })) as Task;
              assertActionable(task, { force: input.force === true });
              if (!task.start && input.force !== true) {
                throw new Error("Task is not started; nothing to stop.");
              }
              if (task.start) {
                await runTask(config, [input.uuid, "stop"], {
                  signal: context.signal,
                });
              }
              await runTask(
                config,
                [input.uuid, "annotate", formatAnnotation(input.actor, "stopped", input.note ?? "work paused")],
                { signal: context.signal },
              );
              return await getTask(config, input.uuid, {
                signal: context.signal,
              });
            }, context),
          ),
      });

      tools.push({
        name: "submit_for_review",
        description:
          "Move a worked task to ready-for-review with evidence. Does not complete it.",
        input: objectSchema(
          {
            uuid: UUID_SCHEMA,
            actor: ACTOR_SCHEMA,
            evidence: { type: "string" },
            reviewer: { type: "string", description: "Recorded in the annotation (no reviewer UDA on the shared pool)." },
          },
          ["uuid", "actor", "evidence"],
        ),
        execute: async (input: any, context: any) =>
          text(
            await mutate(async () => {
              assertUuid(input.uuid);
              const evidence = input.reviewer
                ? `${input.evidence} (reviewer: ${input.reviewer})`
                : input.evidence;
              const task = (await getTask(config, input.uuid, {
                signal: context.signal,
              })) as Task;
              assertActionable(task);
              if (task.start) {
                await runTask(config, [input.uuid, "stop"], {
                  signal: context.signal,
                });
              }
              await runTask(
                config,
                [input.uuid, "modify", "-claimed", "+ready-for-review"],
                { signal: context.signal },
              );
              await runTask(
                config,
                [input.uuid, "annotate", formatAnnotation(input.actor, "submitted-for-review", evidence)],
                { signal: context.signal },
              );
              return await getTask(config, input.uuid, {
                signal: context.signal,
              });
            }, context),
          ),
      });

      tools.push({
        name: "approve",
        description: "Approve a task that is ready for review.",
        input: objectSchema(
          {
            uuid: UUID_SCHEMA,
            actor: ACTOR_SCHEMA,
            note: { type: "string" },
            force: { type: "boolean" },
          },
          ["uuid", "actor"],
        ),
        execute: async (input: any, context: any) =>
          text(
            await mutate(async () => {
              assertUuid(input.uuid);
              const task = (await getTask(config, input.uuid, {
                signal: context.signal,
              })) as Task;
              approveGuard(task, { force: input.force === true });
              await runTask(
                config,
                [input.uuid, "modify", "-ready-for-review", "-review", "+approved"],
                { signal: context.signal },
              );
              await runTask(
                config,
                [input.uuid, "annotate", formatAnnotation(input.actor, "approved", input.note ?? "review passed")],
                { signal: context.signal },
              );
              return await getTask(config, input.uuid, {
                signal: context.signal,
              });
            }, context),
          ),
      });

      tools.push({
        name: "complete",
        description:
          "Complete a task (task done). Requires +approved or +ready-for-review unless force is set.",
        input: objectSchema(
          {
            uuid: UUID_SCHEMA,
            actor: ACTOR_SCHEMA,
            note: { type: "string" },
            force: {
              type: "boolean",
              description: "Complete without the approval guard.",
            },
          },
          ["uuid", "actor"],
        ),
        execute: async (input: any, context: any) =>
          text(
            await mutate(async () => {
              assertUuid(input.uuid);
              const task = (await getTask(config, input.uuid, {
                signal: context.signal,
              })) as Task;
              completeGuard(task, { force: input.force === true });
              await runTask(
                config,
                [input.uuid, "annotate", formatAnnotation(input.actor, "completed", input.note ?? "work complete")],
                { signal: context.signal },
              );
              await runTask(config, [input.uuid, "done"], {
                signal: context.signal,
              });
              return { uuid: input.uuid, status: "completed" };
            }, context),
          ),
      });

      tools.push({
        name: "agent_queue",
        description:
          "Pending actionable tasks for one actor (claimed by or annotated by them, not yet in review).",
        input: objectSchema({
          actor: ACTOR_SCHEMA,
          limit: { type: "number", description: "Max tasks (default 50, max 500)." },
        }),
        execute: async (input: any, context: any) => {
          await maybeSyncBefore(context);
          assertActor(input.actor);
          const limit = Math.min(Math.max(input.limit ?? 50, 1), 500);
          const tasks = (await exportTasks(config, ["status:pending"], {
            signal: context.signal,
          })) as Task[];
          const mine = tasks.filter((t) => {
            if (hasTag(t, "ready-for-review") || hasTag(t, "review") || hasTag(t, "approved")) {
              return false;
            }
            if (lastClaimActor(t) === input.actor) return true;
            const notes = Array.isArray(t.annotations) ? t.annotations : [];
            return notes.some((a: any) =>
              String(a?.description ?? "").startsWith(`[${input.actor}]`),
            );
          });
          const sliced = mine.slice(0, limit);
          return text({ tasks: sliced, count: sliced.length, total_matching: mine.length });
        },
      });

      tools.push({
        name: "review_queue",
        description: "Pending tasks waiting for review (ready-for-review).",
        input: objectSchema({
          limit: { type: "number", description: "Max tasks (default 50, max 500)." },
        }),
        execute: async (input: any, context: any) => {
          await maybeSyncBefore(context);
          const limit = Math.min(Math.max(input.limit ?? 50, 1), 500);
          const tasks = (await exportTasks(config, ["status:pending"], {
            signal: context.signal,
          })) as Task[];
          const queued = applyTagFilter(tasks, ["ready-for-review"]);
          const sliced = queued.slice(0, limit);
          return text({ tasks: sliced, count: sliced.length, total_matching: queued.length });
        },
      });

      tools.push({
        name: "blocked_tasks",
        description: "Pending blocked tasks.",
        input: objectSchema({
          limit: { type: "number", description: "Max tasks (default 50, max 500)." },
        }),
        execute: async (input: any, context: any) => {
          await maybeSyncBefore(context);
          const limit = Math.min(Math.max(input.limit ?? 50, 1), 500);
          const tasks = (await exportTasks(config, ["status:pending"], {
            signal: context.signal,
          })) as Task[];
          const blocked = applyTagFilter(tasks, ["blocked"]);
          const sliced = blocked.slice(0, limit);
          return text({ tasks: sliced, count: sliced.length, total_matching: blocked.length });
        },
      });

      tools.push({
        name: "record_decision",
        description:
          "Record a decision as a task annotation, or as a new open +decision task titled DECISION: ....",
        input: objectSchema({
          actor: ACTOR_SCHEMA,
          decision: { type: "string", description: "The decision text." },
          taskUuid: {
            ...UUID_SCHEMA,
            description: "Annotate this existing task. Omit to create a +decision task instead.",
          },
          title: {
            type: "string",
            description: "Required when taskUuid is omitted: short decision title.",
          },
          project: { type: "string" },
          tags: TAG_LIST_SCHEMA,
        }),
        execute: async (input: any, context: any) =>
          text(
            await mutate(async () => {
              assertActor(input.actor ?? "opencode");
              const actor = input.actor ?? "opencode";
              if (typeof input.decision !== "string" || input.decision.trim().length === 0) {
                throw new Error("decision must be a non-empty string");
              }
              if (input.taskUuid) {
                assertUuid(input.taskUuid);
                await runTask(
                  config,
                  [input.taskUuid, "annotate", formatAnnotation(actor, "decision", input.decision)],
                  { signal: context.signal },
                );
                return await getTask(config, input.taskUuid, {
                  signal: context.signal,
                });
              }
              if (!input.title) {
                throw new Error("Provide taskUuid to annotate, or title (+project) to create a +decision task.");
              }
              const tags = normalizeTags([...(input.tags ?? []), "decision"]);
              const setArgs = buildSetArgs({ project: input.project, tags });
              const output = await runTask(
                config,
                ["rc.verbose=new-uuid", "add", `DECISION: ${input.title}`, ...setArgs],
                { signal: context.signal },
              );
              const uuid = output.match(
                /[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}/i,
              )?.[0];
              if (!uuid) {
                throw new Error(`Could not resolve created decision UUID from: ${output}`);
              }
              await runTask(
                config,
                [uuid, "annotate", formatAnnotation(actor, "decision", input.decision)],
                { signal: context.signal },
              );
              return await getTask(config, uuid, { signal: context.signal });
            }, context),
          ),
      });

      tools.push({
        name: "overview",
        description:
          "Board overview: pending/blocked/review/claimed counts plus project and tag listings. Good session-start call.",
        input: objectSchema({}),
        execute: async (_input: any, context: any) => {
          await maybeSyncBefore(context);
          const [projectsOut, tagsOut, pending, pendingTasks] = await Promise.all([
            runTask(config, ["projects"], { signal: context.signal }),
            runTask(config, ["tags"], { signal: context.signal }),
            countTasks(config, ["status:pending"], { signal: context.signal }),
            exportTasks(config, ["status:pending"], { signal: context.signal }),
          ]);
          // Tag counts are filtered client-side: hyphenated tags (e.g.
          // +ready-for-review) mis-parse in CLI filter expressions, so
          // `task count +ready-for-review` over-counts.
          const tasks = pendingTasks as Task[];
          return text({
            pending,
            blocked: applyTagFilter(tasks, ["blocked"]).length,
            ready_for_review: applyTagFilter(tasks, ["ready-for-review"]).length,
            claimed: applyTagFilter(tasks, ["claimed"]).length,
            projects: parseListing(projectsOut),
            tags: parseListing(tagsOut),
          });
        },
      });

      tools.push({
        name: "doctor",
        description:
          "Check task binary, TaskChampion sync, and show platform-specific install instructions if missing.",
        input: objectSchema({}),
        execute: async (_input: any, context: any) =>
          text(await doctor(config)),
      });

      tools.push({
        name: "setup",
        description:
          "Generate a platform-specific shell script to install taskwarrior (TaskChampion sync is built into 3.x). Use write:true to save directly to a file.",
        input: objectSchema({
          includeSyncService: {
            type: "boolean",
            default: true,
            description: "Deprecated (kept for compatibility): TaskChampion sync is built into taskwarrior 3.x, no service to start.",
          },
          includeVerify: {
            type: "boolean",
            default: true,
            description: "Include verification steps (version checks, test sync).",
          },
          write: {
            type: "boolean",
            default: false,
            description: "Write the script to a file instead of returning it. File defaults to ./install-taskwarrior.sh.",
          },
          outputPath: {
            type: "string",
            description: "Custom output path when write is true (relative to cwd).",
          },
        }),
        execute: async (input: any, context: any) => {
          const script = generateSetupScript({
            includeSyncService: input.includeSyncService ?? true,
            includeVerify: input.includeVerify ?? true,
          });
          if (input.write) {
            const fs = await import("node:fs/promises");
            const path = await import("node:path");
            const outPath = input.outputPath
              ? path.resolve(input.outputPath)
              : path.resolve("install-taskwarrior.sh");
            await fs.writeFile(outPath, script, { mode: 0o755 });
            return text({ ok: true, path: outPath, message: `Script written to ${outPath} (executable)` });
          }
          return text({ script, filename: "install-taskwarrior.sh" });
        },
      });

      tools.push({
        name: "auto",
        description:
          "Automated workflow: sync, find/claim/start next task, or create+claim+start a new task from description. Returns the active task.",
        input: objectSchema({
          actor: ACTOR_SCHEMA,
          description: {
            type: "string",
            description: "If provided, create a new task with this description instead of picking from queue.",
          },
          project: { type: "string" },
          priority: PRIORITY_SCHEMA,
          tags: TAG_LIST_SCHEMA,
          force: { type: "boolean", description: "Force claim/start even if guards would block." },
        }),
        execute: async (input: any, context: any) => {
          const actor = input.actor ?? "opencode";
          assertActor(actor);

          await maybeSyncBefore(context);

          // If description provided, create new task
          if (input.description) {
            const task = await mutate(async () => {
              const setArgs = buildSetArgs({
                project: input.project,
                priority: input.priority,
                tags: input.tags,
              });
              const output = await runTask(
                config,
                ["rc.verbose=new-uuid", "add", input.description, ...setArgs],
                { signal: context.signal },
              );
              const uuid = output.match(
                /[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}/i,
              )?.[0];
              if (!uuid) throw new Error(`Could not resolve created task UUID from: ${output}`);
              await runTask(config, [uuid, "modify", "+claimed"], { signal: context.signal });
              await runTask(
                config,
                [uuid, "annotate", formatAnnotation(actor, "claimed", "auto-claimed for implementation")],
                { signal: context.signal },
              );
              await runTask(config, [uuid, "start"], { signal: context.signal });
              await runTask(
                config,
                [uuid, "annotate", formatAnnotation(actor, "started", "auto-started implementation")],
                { signal: context.signal },
              );
              return await getTask(config, uuid, { signal: context.signal });
            }, context);
            return text({ task, action: "created_and_started" });
          }

          // Otherwise, pick from agent queue
          const queue = (await exportTasks(config, ["status:pending"], {
            signal: context.signal,
          })) as Task[];
          const mine = queue.filter((t) => {
            if (hasTag(t, "ready-for-review") || hasTag(t, "review") || hasTag(t, "approved")) return false;
            if (lastClaimActor(t) === actor) return true;
            const notes = Array.isArray(t.annotations) ? t.annotations : [];
            return notes.some((a: any) => String(a?.description ?? "").startsWith(`[${actor}]`));
          });

          let target = mine[0];

          // If nothing claimed, find first unclaimed actionable task
          if (!target) {
            const unclaimed = queue.filter((t) => {
              if (hasTag(t, "ready-for-review") || hasTag(t, "review") || hasTag(t, "approved")) return false;
              if (hasTag(t, "blocked")) return false;
              if (hasTag(t, "claimed")) return false;
              return t.status === "pending";
            });
            target = unclaimed[0];
          }

          if (!target) {
            return text({ task: null, action: "none_found", message: "No actionable tasks in queue." });
          }

          const uuid = target.uuid;
          const task = await mutate(async () => {
            // Claim if not already claimed
            if (!hasTag(target, "claimed")) {
              await runTask(config, [uuid, "modify", "+claimed"], { signal: context.signal });
              await runTask(
                config,
                [uuid, "annotate", formatAnnotation(actor, "claimed", "auto-claimed from queue")],
                { signal: context.signal },
              );
            }
            // Start if not already started
            if (!target.start || input.force) {
              await runTask(config, [uuid, "start"], { signal: context.signal });
              await runTask(
                config,
                [uuid, "annotate", formatAnnotation(actor, "started", "auto-started implementation")],
                { signal: context.signal },
              );
            }
            return await getTask(config, uuid, { signal: context.signal });
          }, context);

          return text({ task, action: hasTag(target, "claimed") ? "started" : "claimed_and_started" });
        },
      });

  return tools;
}
