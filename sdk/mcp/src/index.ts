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
  type ToolOptions,
} from "./tools.ts";

export {
  microvmDestroy,
  microvmExec,
  microvmPs,
  microvmRun,
  toolDescriptions,
} from "./tools.ts";
export type { ExecInput, RunInput, ToolResult, ToolOptions } from "./tools.ts";

/** MCP server over the sandbox client. Tools call the client; they do not speak the daemon socket. */
export function createServer(options: ToolOptions = {}): McpServer {
  const host = { ...options, allowNat: options.allowNat === true };
  const server = new McpServer({ name: "microvm", version: "0.1.0" });

  server.registerTool(
    "microvm_run",
    {
      description: toolDescriptions.microvm_run,
      inputSchema: {
        network: z
          .enum(["none", "nat"])
          .optional()
          .describe(
            "Defaults to none; nat enables unrestricted outbound access and requires host permission"
          ),
        name: z.string().describe("Sandbox name"),
        cpus: z.number().int().positive().optional(),
        memoryMB: z.number().int().positive().optional(),
        ttlSeconds: z.number().int().min(1).max(86400).nullish(),
        bootTimeoutSeconds: z.number().int().positive().optional(),
      },
    },
    async (input) => microvmRun(input as RunInput, host)
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
    async (input) => microvmExec(input as ExecInput, host)
  );

  server.registerTool(
    "microvm_ps",
    {
      description: toolDescriptions.microvm_ps,
      inputSchema: {},
    },
    async () => microvmPs(host)
  );

  server.registerTool(
    "microvm_destroy",
    {
      description: toolDescriptions.microvm_destroy,
      inputSchema: {
        name: z.string().describe("Sandbox name"),
      },
    },
    async ({ name }) => microvmDestroy(name, host)
  );

  return server;
}
