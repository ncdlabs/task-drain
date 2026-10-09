#!/usr/bin/env node
/**
 * taskwarrior-mcp: Model Context Protocol server for Taskwarrior/TaskChampion.
 *
 * Exposes the same 22 task lifecycle tools as the opencode-tasks OpenCode
 * plugin (see ./tools.js) over MCP stdio, so Claude Code, Cursor, OpenCode,
 * and Codex can all share one task pool without shelling out to `task`.
 *
 * Configuration via environment:
 * - TASK_BIN: task binary (default /opt/homebrew/bin/task, falls back to PATH)
 * - TASKRC: taskrc profile path
 * - TASK_AUTO_SYNC=0: disable automatic sync around tool calls
 *
 * Run:  npx taskwarrior-mcp
 *   or: node dist/mcp-server.js
 */

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { resolveConfig } from "./task.mjs";
import { createTools } from "./tools.js";

const INSTRUCTIONS = `Taskwarrior shared-pool lifecycle. Follow these rules on every task you touch:

1. SYNC FIRST. The tools sync automatically before reads and around writes (unless TASK_AUTO_SYNC=0). If a sync fails, stop -- never work offline.
2. CLAIM BEFORE YOU START. Call task_claim on a task before doing any work on it, then task_start when active work begins. task_auto does sync -> find -> claim -> start in one call.
3. ANNOTATE AS YOU GO. Record progress, blockers, and decisions with task_annotate. Reference tasks by full UUID, never short numeric IDs (they are replica-local).
4. COMPLETE ONLY WHEN VERIFIED. Call task_complete after the build/tests/acceptance criteria pass. Never mark complete on partial work. Use task_submit_for_review when human review should come first.
5. IF YOU CAN'T FINISH, RELEASE IT. Call task_stop and task_release with the blocker annotated. Never leave tasks claimed that you are not actively working.
6. CHECK DUPLICATES. Search with task_list before creating tasks with task_add.
7. DECISIONS BELONG TO THE OWNER. Design, security, product, and public-facing decisions are never yours to make -- annotate what is needed and release the task. Durable decisions go in the repo's docs/DECISIONS.md, not in tasks.`;

const server = new Server(
  { name: "taskwarrior-mcp", version: "0.1.0" },
  { capabilities: { tools: {} }, instructions: INSTRUCTIONS },
);

const config = resolveConfig({});
const tools = createTools(config);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: tools.map((t) => ({
    name: `task_${t.name}`,
    description: t.description,
    inputSchema: t.input,
  })),
}));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;
  const tool = tools.find((t) => `task_${t.name}` === name);
  if (!tool) {
    throw new Error(`Unknown tool: ${name}`);
  }
  const result = await tool.execute(args ?? {}, {});
  // Tool handlers return { content: <JSON string> }; surface it as MCP text.
  return { content: [{ type: "text", text: result.content }] };
});

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
}

main().catch((err) => {
  console.error("taskwarrior-mcp failed:", err);
  // Report to webhook if configured
  const webhook = process.env.DRAIN_ERROR_WEBHOOK;
  if (webhook) {
    const payload = JSON.stringify({
      text: `taskwarrior-mcp failed: ${err?.message ?? String(err)}`,
    });
    fetch(webhook, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: payload,
    }).catch(() => {});
  }
  process.exit(1);
});
