import { Sandbox, SandboxError, type ClientOptions } from "@microvm/sdk";

import { presentExec } from "./lib/policy.ts";

const local =
  "This is a local Linux sandbox on the user's Mac, through their microvm daemon. It is not a cloud sandbox.";

export type ToolResult = {
  isError?: boolean;
  content: [{ type: "text"; text: string }];
};

export type RunInput = {
  name: string;
  cpus?: number;
  memoryMB?: number;
  ttlSeconds?: number;
  bootTimeoutSeconds?: number;
};

export type ExecInput = {
  name: string;
  command: string;
  cwd?: string;
  env?: Record<string, string>;
  timeoutSeconds?: number;
};

export const toolDescriptions = {
  microvm_run: `${local} Boot a sandbox and return when it is running.`,
  microvm_exec: `${local} Run a shell command inside a running sandbox. The command is sh -c. Default deadline is 30 seconds. Output is capped.`,
  microvm_ps: `${local} List sandboxes and their phases.`,
  microvm_destroy: `${local} Destroy a sandbox and delete its record.`,
} as const;

export async function microvmRun(
  input: RunInput,
  options?: ClientOptions
): Promise<ToolResult> {
  return guard(async () => {
    const sandbox = await Sandbox.create({ ...input, home: options?.home });
    return ok(`running ${sandbox.name}`);
  });
}

export async function microvmExec(
  input: ExecInput,
  options?: ClientOptions
): Promise<ToolResult> {
  return guard(async () => {
    const sandbox = await Sandbox.connect(input.name, options);
    const text = await presentExec(sandbox, input.command, input);
    return ok(text);
  });
}

export async function microvmPs(options?: ClientOptions): Promise<ToolResult> {
  return guard(async () => {
    const sandboxes = await Sandbox.list(options);
    return ok(JSON.stringify(sandboxes, null, 2));
  });
}

export async function microvmDestroy(
  name: string,
  options?: ClientOptions
): Promise<ToolResult> {
  return guard(async () => {
    const sandbox = await Sandbox.connect(name, options);
    await sandbox.destroy();
    return ok(`destroyed ${name}`);
  });
}

function ok(text: string): ToolResult {
  return { content: [{ type: "text", text }] };
}

async function guard(run: () => Promise<ToolResult>): Promise<ToolResult> {
  try {
    return await run();
  } catch (error) {
    if (error instanceof SandboxError) {
      return {
        isError: true,
        content: [{ type: "text", text: `${error.kind}: ${error.message}` }],
      };
    }
    const message = error instanceof Error ? error.message : String(error);
    return {
      isError: true,
      content: [{ type: "text", text: `daemon: ${message}` }],
    };
  }
}
