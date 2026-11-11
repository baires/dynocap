import { SandboxError } from "./lib/errors.ts";
import { boot, destroy, exec, list, type SandboxInfo } from "./lib/daemon.ts";
import { transfer } from "./lib/tasks.ts";
export { Task, listManaged, removeManaged } from "./task.ts";
export type {
  TaskOptions,
  TaskInfo,
  RuntimeSelection,
  TaskAccessOptions,
  TaskPreview,
  ManagedEntry,
} from "./task.ts";
import { resolveHome } from "./lib/paths.ts";

export { SandboxError } from "./lib/errors.ts";
export type { SandboxErrorKind } from "./lib/errors.ts";
export type { SandboxInfo, NetworkMode } from "./lib/daemon.ts";

/** Phases the daemon records today. A newer daemon may report another phase string. */
export const SANDBOX_PHASES = [
  "booting",
  "running",
  "stopping",
  "stopped",
  "failed",
] as const;

export type KnownPhase = (typeof SANDBOX_PHASES)[number];

export type ClientOptions = {
  /** Daemon home. Defaults to `MICROVM_HOME`, then `~/.microvm`. */
  home?: string;
};

export type CreateOptions = ClientOptions & {
  name: string;
  network?: "none" | "nat" | "filtered";
  cpus?: number;
  memoryMB?: number;
  ttlSeconds?: number | null;
  bootTimeoutSeconds?: number;
};

export type ExecOptions = {
  /** Bound captured output per stream; callbacks still receive all bytes. */
  maxOutputBytes?: number;
  /** Require daemon-enforced offline networking, including for existing sandboxes. */
  requireOffline?: boolean;
  /** Permit an existing filtered sandbox. Omitted by direct SDK callers. */
  permitFiltered?: boolean;
  cwd?: string;
  env?: Record<string, string>;
  timeoutSeconds?: number;
  /** Streamed to the guest, then closed. Requires an exec stream v1 daemon. */
  stdin?: Uint8Array;
  /** Raw guest bytes for this chunk. A character may be split across chunks. */
  onStdout?: (chunk: Uint8Array) => void;
  onStderr?: (chunk: Uint8Array) => void;
};

export type ExecResult = {
  outputTruncated?: boolean;
  stdout: string;
  stderr: string;
  /** Guest status. A signal is `128 + signal`. */
  exitCode: number;
};

const text = new TextDecoder();

/**
 * A named Linux sandbox owned by the per-user daemon.
 *
 * The daemon must already be listening for this home. `create` resolves when
 * the sandbox is running. `connect` returns a handle for a recorded sandbox.
 * A string command runs as `sh -c`. An exec deadline throws {@link SandboxError}
 * kind `timeout` with exit code 124. A missing sandbox is kind `not_found`.
 * Any other daemon failure is kind `daemon`.
 */
export class Sandbox {
  readonly name: string;
  readonly #home: string;

  private constructor(name: string, home: string) {
    this.name = name;
    this.#home = home;
  }

  static async create(options: CreateOptions): Promise<Sandbox> {
    const ttlSeconds = options.ttlSeconds ?? 1800;
    if (!Number.isInteger(ttlSeconds) || ttlSeconds < 1 || ttlSeconds > 86400)
      throw new SandboxError(
        "daemon",
        "ttlSeconds must be an integer between 1 and 86400 (default 1800)"
      );
    const network = options.network ?? "none";
    if (network !== "none" && network !== "nat" && network !== "filtered")
      throw new SandboxError(
        "daemon",
        "network must be none, nat, or filtered"
      );
    const home = resolveHome(options.home);
    const status = await boot(home, {
      name: options.name,
      cpus: options.cpus ?? 1,
      memoryMB: options.memoryMB ?? 1024,
      bootTimeoutSeconds: options.bootTimeoutSeconds ?? 60,
      ttlSeconds,
      network,
    });
    if (status.phase !== "running") {
      throw new SandboxError(
        "daemon",
        `sandbox ${status.name} is ${status.phase}`
      );
    }
    return new Sandbox(status.name, home);
  }

  static async connect(
    name: string,
    options?: ClientOptions
  ): Promise<Sandbox> {
    const home = resolveHome(options?.home);
    const found = (await Sandbox.list(options)).find(
      (sandbox) => sandbox.name === name
    );
    if (!found) throw new SandboxError("not_found", `no sandbox named ${name}`);
    return new Sandbox(name, home);
  }

  static async list(options?: ClientOptions): Promise<SandboxInfo[]> {
    return list(resolveHome(options?.home));
  }

  async exec(
    command: string | readonly string[],
    options: ExecOptions = {}
  ): Promise<ExecResult> {
    const outcome = await exec(
      this.#home,
      {
        name: this.name,
        requireOffline: options.requireOffline,
        ...(options.permitFiltered === undefined
          ? {}
          : { permitFiltered: options.permitFiltered }),
        argv: commandArgv(command),
        env: envEntries(options.env ?? {}),
        cwd: options.cwd ?? "",
        timeoutSeconds: options.timeoutSeconds ?? 60,
        ...(options.stdin === undefined ? {} : { input: "pipe" as const }),
      },
      options,
      options.stdin
    );
    const exitCode = outcome.signal > 0 ? 128 + outcome.signal : outcome.code;
    return {
      ...(outcome.truncated ? { outputTruncated: true } : {}),
      stdout: text.decode(outcome.stdout),
      stderr: text.decode(outcome.stderr),
      exitCode,
    };
  }

  async upload(
    localPath: string,
    guestPath: string,
    options: { requireOffline?: boolean } = {}
  ): Promise<void> {
    await transfer(this.#home, {
      name: this.name,
      direction: "upload",
      localPath,
      guestPath,
      ...options,
    });
  }

  async download(
    guestPath: string,
    localPath: string,
    options: { requireOffline?: boolean } = {}
  ): Promise<void> {
    await transfer(this.#home, {
      name: this.name,
      direction: "download",
      localPath,
      guestPath,
      ...options,
    });
  }

  async destroy(): Promise<void> {
    await destroy(this.#home, this.name);
  }
}

function commandArgv(command: string | readonly string[]): string[] {
  if (typeof command === "string") {
    if (command.length === 0)
      throw new SandboxError("daemon", "exec requires a command");
    return ["sh", "-c", command];
  }
  if (command.length === 0 || command[0]!.length === 0) {
    throw new SandboxError("daemon", "exec requires a command");
  }
  return [...command];
}

function envEntries(env: Record<string, string>): string[] {
  return Object.entries(env).map(([key, value]) => {
    if (key.length === 0 || key.includes("=")) {
      throw new SandboxError("daemon", `env expects KEY=VAL, got ${key}`);
    }
    return `${key}=${value}`;
  });
}
