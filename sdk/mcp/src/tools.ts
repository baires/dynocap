import fs from "node:fs/promises";
import path from "node:path";
import {
  Task,
  listManaged,
  removeManaged,
  type TaskOptions,
  Sandbox,
  SandboxError,
  type ClientOptions,
} from "@microvm/sdk";

import { MCP_TERMINAL, cap, presentExec } from "./lib/policy.ts";

const local =
  "This is a local Linux sandbox on the user's Mac, through their microvm daemon. It is not a cloud sandbox.";

export type ToolResult = {
  isError?: boolean;
  content: [{ type: "text"; text: string }];
};

export type ToolOptions = ClientOptions & {
  allowNat?: boolean;
  allowFiltered?: boolean;
};

export type RunInput = {
  network?: "none" | "nat" | "filtered";
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
  /** Run on a 24x80 guest terminal. Output is one combined transcript. */
  terminal?: boolean;
};

export const toolDescriptions = {
  microvm_run: `${local} Boot a sandbox and return when it is running. Default network none. nat is unrestricted outbound access and requires MICROVM_MCP_ALLOW_NAT=1. filtered allows HTTPS only to registry.npmjs.org and the task Git host and requires MICROVM_MCP_ALLOW_FILTERED=1. Default lifetime 1800 seconds, maximum 86400.`,
  microvm_exec: `${local} Run a shell command inside a running sandbox. The command is sh -c. Default deadline is 30 seconds. Output is capped. Set terminal for programs that require a terminal: they run on a 24x80 guest terminal and output is one combined transcript, including control sequences.`,
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
    if (input.network === "filtered" && options?.allowFiltered !== true)
      throw new Error(
        "filtered networking is disabled by this MCP host; start the server with MICROVM_MCP_ALLOW_FILTERED=1 to permit it"
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
    const recorded = (await Sandbox.list(options)).find(
      (sandbox) => sandbox.name === input.name
    );
    assertExecutable(recorded?.network, options);
    const sandbox = await Sandbox.connect(input.name, options);
    const text = await presentExec(sandbox, input.command, {
      ...input,
      ...permits(options),
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

function permits(options?: ToolOptions): {
  requireOffline: boolean;
  permitFiltered: boolean;
} {
  return {
    requireOffline: options?.allowNat !== true,
    permitFiltered: options?.allowFiltered === true,
  };
}

function assertExecutable(
  network: "none" | "nat" | "filtered" | null | undefined,
  options?: ToolOptions
) {
  if (network === undefined) return;
  if (network === "filtered" && options?.allowFiltered !== true)
    throw new Error(
      "filtered networking is disabled by this MCP host; start the server with MICROVM_MCP_ALLOW_FILTERED=1 to permit it"
    );
  if (
    network !== "filtered" &&
    options?.allowNat !== true &&
    network !== "none"
  )
    throw new Error(
      "MCP exec requires an offline sandbox; networking is NAT or unknown"
    );
}

function ok(text: string): ToolResult {
  return { content: [{ type: "text", text }] };
}

async function guard(run: () => Promise<ToolResult>): Promise<ToolResult> {
  try {
    return await run();
  } catch (error) {
    if (error instanceof SandboxError) {
      const next = error.recovery ? `\nNext: ${error.recovery}` : "";
      return {
        isError: true,
        content: [
          { type: "text", text: `${error.kind}: ${error.message}${next}` },
        ],
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
    if (input.network === "filtered" && options?.allowFiltered !== true)
      throw new Error("filtered networking is disabled by this MCP host");
    const task = await Task.start({
      ...input,
      home: options?.home,
      ...permits(options),
    });
    const runtime = (task.runtimes ?? [])
      .map((item) => `${item.name}:${item.version}`)
      .join(", ");
    return ok(
      JSON.stringify({
        id: task.id,
        name: task.name,
        ...(runtime ? { runtime } : {}),
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
    const recorded = (await Sandbox.list(options)).find(
      (sandbox) => sandbox.name === input.name
    );
    assertExecutable(recorded?.network, options);
    const access = { home: options?.home, ...permits(options) };
    const task = input.name.startsWith("task-")
      ? Task.connect(input.name, access)
      : await Task.open(input.name, access);
    const { terminal, ...execOptions } = input;
    const result = await task.exec(input.command, {
      ...execOptions,
      ...(terminal ? { terminal: MCP_TERMINAL } : {}),
    });
    const output = terminal
      ? `terminal:\n${result.stdout}`
      : `${result.stdout}\nstderr:\n${result.stderr}`;
    return ok(
      cap(`exit ${result.exitCode}\nlogs: ${result.logDirectory}\n${output}`)
    );
  });
}
export async function microvmTaskFinish(
  id: string,
  options?: ToolOptions
): Promise<ToolResult> {
  return guard(async () => {
    const finished = await (
      id.startsWith("task-")
        ? Task.connect(id, { home: options?.home, ...permits(options) })
        : await Task.open(id, { home: options?.home, ...permits(options) })
    ).finish();
    const patch = finished.resultDirectory
      ? path.join(finished.resultDirectory, "changes.patch")
      : undefined;
    return ok(JSON.stringify({ ...finished, ...(patch ? { patch } : {}) }));
  });
}

export async function microvmLs(options?: ToolOptions): Promise<ToolResult> {
  return guard(async () =>
    ok(cap(JSON.stringify(await listManaged(options), null, 2)))
  );
}
export async function microvmRm(
  target: string,
  purge: boolean,
  options?: ToolOptions,
  force = false
): Promise<ToolResult> {
  return guard(async () => {
    await removeManaged(target, { home: options?.home, purge, force });
    return ok(`removed ${target}`);
  });
}
export async function microvmDiff(
  target: string,
  options?: ToolOptions
): Promise<ToolResult> {
  return guard(async () => {
    const task = await Task.open(target, {
      home: options?.home,
      ...permits(options),
    });
    const preview = await task.diff();
    const file = await fs.open(preview.patchPath, "r");
    try {
      const buffer = Buffer.alloc(64 * 1024);
      const { bytesRead } = await file.read(buffer, 0, buffer.length, 0);
      return ok(
        cap(
          `${JSON.stringify(preview)}\n${buffer.subarray(0, bytesRead).toString("utf8")}`
        )
      );
    } finally {
      await file.close();
    }
  });
}
