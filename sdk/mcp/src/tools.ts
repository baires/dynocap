import {
  Task,
  type TaskOptions,
  Sandbox,
  SandboxError,
  type ClientOptions,
} from "@microvm/sdk";

import { cap, presentExec } from "./lib/policy.ts";

const local =
  "This is a local Linux sandbox on the user's Mac, through their microvm daemon. It is not a cloud sandbox.";

export type ToolResult = {
  isError?: boolean;
  content: [{ type: "text"; text: string }];
};

export type ToolOptions = ClientOptions & { allowNat?: boolean };

export type RunInput = {
  network?: "none" | "nat";
  name: string;
  cpus?: number;
  memoryMB?: number;
  ttlSeconds?: number | null;
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
  microvm_run: `${local} Boot a sandbox and return when it is running. Default network none; nat is unrestricted outbound access and requires host permission. Default lifetime 1800 seconds, maximum 86400.`,
  microvm_exec: `${local} Run a shell command inside a running sandbox. The command is sh -c. Default deadline is 30 seconds. Output is capped.`,
  microvm_ps: `${local} List sandboxes and their phases.`,
  microvm_destroy: `${local} Destroy a sandbox and delete its record.`,
} as const;

export async function microvmRun(
  input: RunInput,
  options?: ToolOptions
): Promise<ToolResult> {
  return guard(async () => {
    if (input.network === "nat" && options?.allowNat !== true)
      throw new Error(
        "NAT is disabled by this MCP host; start the server with MICROVM_MCP_ALLOW_NAT=1 to permit it"
      );
    const sandbox = await Sandbox.create({ ...input, home: options?.home });
    return ok(`running ${sandbox.name}`);
  });
}

export async function microvmExec(
  input: ExecInput,
  options?: ToolOptions
): Promise<ToolResult> {
  return guard(async () => {
    const requireOffline = options?.allowNat !== true;
    const recorded = (await Sandbox.list(options)).find(
      (sandbox) => sandbox.name === input.name
    );
    if (recorded && requireOffline && recorded.network !== "none")
      throw new Error(
        "MCP exec requires an offline sandbox; networking is NAT or unknown"
      );
    const sandbox = await Sandbox.connect(input.name, options);
    const text = await presentExec(sandbox, input.command, {
      ...input,
      requireOffline,
    });
    return ok(text);
  });
}

export async function microvmPs(options?: ToolOptions): Promise<ToolResult> {
  return guard(async () => {
    const sandboxes = await Sandbox.list(options);
    return ok(JSON.stringify(sandboxes, null, 2));
  });
}

export async function microvmDestroy(
  name: string,
  options?: ToolOptions
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

export async function microvmTaskStart(
  input: Omit<TaskOptions, "home" | "requireOffline">,
  options?: ToolOptions
): Promise<ToolResult> {
  return guard(async () => {
    if (input.network === "nat" && options?.allowNat !== true)
      throw new Error("NAT is disabled by this MCP host");
    const task = await Task.start({
      ...input,
      home: options?.home,
      requireOffline: options?.allowNat !== true,
    });
    return ok(
      JSON.stringify({
        id: task.id,
        sourceUrl: task.sourceUrl,
        sourceRevision: task.sourceRevision,
      })
    );
  });
}
export async function microvmTaskExec(
  input: ExecInput,
  options?: ToolOptions
): Promise<ToolResult> {
  return guard(async () => {
    const task = Task.connect(input.name, {
      home: options?.home,
      requireOffline: options?.allowNat !== true,
    });
    const result = await task.exec(input.command, input);
    return ok(
      cap(
        `exit ${result.exitCode}\nlogs: ${result.logDirectory}\n${result.stdout}\nstderr:\n${result.stderr}`
      )
    );
  });
}
export async function microvmTaskFinish(
  id: string,
  options?: ToolOptions
): Promise<ToolResult> {
  return guard(async () =>
    ok(
      JSON.stringify(
        await Task.connect(id, {
          home: options?.home,
          requireOffline: options?.allowNat !== true,
        }).finish()
      )
    )
  );
}
