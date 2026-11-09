import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import * as z from "zod";

import {
  microvmDestroy,
  microvmExec,
  microvmPs,
  microvmRun,
  toolDescriptions,
  type ExecInput,
  type RunInput,
} from "./tools.ts";

export {
  microvmDestroy,
  microvmExec,
  microvmPs,
  microvmRun,
  toolDescriptions,
} from "./tools.ts";
export type { ExecInput, RunInput, ToolResult } from "./tools.ts";

/** MCP server over the sandbox client. Tools call the client; they do not speak the daemon socket. */
export function createServer(): McpServer {
  const server = new McpServer({ name: "microvm", version: "0.1.0" });

  server.registerTool(
    "microvm_run",
    {
      description: toolDescriptions.microvm_run,
      inputSchema: {
        name: z.string().describe("Sandbox name"),
        cpus: z.number().int().positive().optional(),
        memoryMB: z.number().int().positive().optional(),
        ttlSeconds: z.number().int().positive().optional(),
        bootTimeoutSeconds: z.number().int().positive().optional(),
      },
    },
    async (input) => microvmRun(input as RunInput)
  );

  server.registerTool(
    "microvm_exec",
    {
      description: toolDescriptions.microvm_exec,
      inputSchema: {
        name: z.string().describe("Sandbox name"),
        command: z.string().describe("Shell command, run with sh -c"),
        cwd: z.string().optional(),
        env: z.record(z.string(), z.string()).optional(),
        timeoutSeconds: z.number().int().positive().optional(),
      },
    },
    async (input) => microvmExec(input as ExecInput)
  );

  server.registerTool(
    "microvm_ps",
    {
      description: toolDescriptions.microvm_ps,
      inputSchema: {},
    },
    async () => microvmPs()
  );

  server.registerTool(
    "microvm_destroy",
    {
      description: toolDescriptions.microvm_destroy,
      inputSchema: {
        name: z.string().describe("Sandbox name"),
      },
    },
    async ({ name }) => microvmDestroy(name)
  );

  return server;
}
