/**
 * opencode-tasks: TaskChampion/Taskwarrior tools for OpenCode.
 *
 * Thin OpenCode plugin wrapper around the shared tool definitions in
 * ./tools.js. The same tools are exposed over MCP by ./mcp-server.js.
 */

import { Plugin } from "@opencode/plugin";
import { resolveConfig } from "./task.mjs";
import { createTools } from "./tools.js";

const NS = { namespace: "task", codemode: true } as const;

export default Plugin.define({
  id: "opencode-tasks",
  async setup(ctx) {
    const config = resolveConfig(ctx.options ?? {});
    const tools = createTools(config);
    await ctx.tool.transform((editor) => {
      editor.namespace({
        name: "task",
        description:
          "TaskChampion/Taskwarrior shared-pool lifecycle: sync, list, claim, review, complete, decisions.",
      });
      for (const tool of tools) {
        editor.add({
          name: tool.name,
          description: tool.description,
          input: tool.input,
          execute: tool.execute,
          options: { ...NS },
        });
      }
    });
  },
});
