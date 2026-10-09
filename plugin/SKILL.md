# Taskwarrior Workflow

You have Taskwarrior tools available (`task sync`, `task claim`, `task start`,
`task complete`, etc.). Follow these rules on every task you touch.

## The lifecycle (non-negotiable)

1. **Sync first.** Run `task sync` before reading the queue and after every
   mutation. If sync fails, stop — do not work offline.
2. **Claim before you start.** Run `task claim` on a task before doing any
   work on it. This marks it in-progress so no one else picks it up.
   Then `task start` when you begin active work.
3. **Annotate as you go.** Record progress, blockers, and decisions with
   `task annotate`. Future you (or another agent) should understand the
   state from the annotations alone.
4. **Complete when done — and only when done.** Run `task complete` after
   you have verified the work (build passes, tests pass, acceptance
   criteria met). Never mark complete on partial or unverified work.
5. **If you can't finish, release it.** Run `task stop` and `task release`
   with an annotation explaining the blocker. Do not leave tasks claimed
   that you are not actively working.

## Shortcuts

- `task auto` does sync → find → claim → start in one call. Use it when
  picking up the next available task.
- `task submit_for_review` moves a finished task to review instead of
  completing it directly, when human review is wanted first.

## Rules

- Reference tasks by UUID, never by short numeric ID (IDs differ per machine).
- Search for duplicates with `task list` before creating a task.
- Durable decisions go in the repo's `docs/DECISIONS.md`, not in tasks.
- Design, security, product, and public-facing decisions belong to the
  project owner — never make them yourself. Annotate what's needed and
  release the task.
