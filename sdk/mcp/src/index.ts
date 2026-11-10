import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import * as z from "zod";

import {
  microvmLs,
  microvmRm,
  microvmDiff,
  microvmTaskStart,
  microvmTaskExec,
  microvmTaskFinish,
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
  microvmLs,
  microvmRm,
  microvmDiff,
  microvmTaskStart,
  microvmTaskExec,
  microvmTaskFinish,
  microvmDestroy,
  microvmExec,
  microvmPs,
  microvmRun,
  toolDescriptions,
} from "./tools.ts";
export type { ExecInput, RunInput, ToolResult, ToolOptions } from "./tools.ts";

/** MCP server over the sandbox client. Tools call the client; they do not speak the daemon socket. */
export function createServer(options: ToolOptions = {}): McpServer {
  const host = {
    ...options,
    allowNat: options.allowNat === true,
    allowFiltered: options.allowFiltered === true,
  };
  const server = new McpServer({ name: "microvm", version: "0.1.0" });

  server.registerTool(
    "microvm_run",
    {
      description: toolDescriptions.microvm_run,
      inputSchema: {
        network: z
          .enum(["none", "nat", "filtered"])
          .optional()
          .describe(
            "Defaults to none. nat is unrestricted and requires host permission. filtered allows registry.npmjs.org and the task Git host and requires its own host permission."
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

  server.registerTool(
    "microvm_task_start",
    {
      description:
        "Start a Node task from a local directory or a repository URL. A URL is cloned in the guest and requires nat or filtered. A token or SSH key is held for that guest fetch and is not imported. An ssh URL requires nat. Results require finish before TTL.",
      inputSchema: {
        name: z.string().optional(),
        projectPath: z.string().optional(),
        repositoryUrl: z.string().optional(),
        ref: z.string().optional(),
        gitToken: z
          .string()
          .optional()
          .describe(
            "HTTPS token. Held in daemon memory for the guest fetch and not returned or imported."
          ),
        sshKeyPath: z.string().optional(),
        runtimes: z
          .array(z.object({ name: z.string(), version: z.string() }))
          .optional(),
        network: z.enum(["none", "nat", "filtered"]).optional(),
        ttlSeconds: z.number().int().min(1).max(86400).optional(),
        cpus: z.number().int().positive().optional(),
        memoryMB: z.number().int().min(128).optional(),
      },
    },
    async (input) => microvmTaskStart(input, host)
  );
  server.registerTool(
    "microvm_task_exec",
    {
      description:
        "Run a task command with a 300-second default deadline. Returns bounded output and a host log directory.",
      inputSchema: {
        name: z.string(),
        command: z.string(),
        cwd: z.string().optional(),
        env: z.record(z.string(), z.string()).optional(),
        timeoutSeconds: z.number().int().min(1).max(86400).optional(),
      },
    },
    async (input) => microvmTaskExec(input, host)
  );
  server.registerTool(
    "microvm_task_finish",
    {
      description:
        "Export reviewable changes and logs to the host, then destroy the sandbox. Returns result path and expiry.",
      inputSchema: { id: z.string() },
    },
    async (input) => microvmTaskFinish(input.id, host)
  );
  server.registerTool(
    "microvm_ls",
    {
      description:
        "List project tasks and raw sandboxes without duplicate task rows. Includes retained results and expiry.",
      inputSchema: {},
    },
    async () => microvmLs(host)
  );
  server.registerTool(
    "microvm_diff",
    {
      description:
        "Capture verified changes against the imported baseline without destroying an idle task. Returns bounded patch text and host file references.",
      inputSchema: { name: z.string() },
    },
    async (input) => microvmDiff(input.name, host)
  );
  server.registerTool(
    "microvm_rm",
    {
      description:
        "Remove a sandbox or task and release its name. Published results remain unless purge is explicitly true. Unexported edits are discarded.",
      inputSchema: { name: z.string(), purge: z.boolean().optional() },
    },
    async (input) => microvmRm(input.name, input.purge === true, host)
  );
  return server;
}
