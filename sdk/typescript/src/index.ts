import { SandboxError } from "./lib/errors.ts";
import { boot, destroy, exec, list, type SandboxInfo } from "./lib/daemon.ts";
import { resolveHome } from "./lib/paths.ts";

export { SandboxError } from "./lib/errors.ts";
export type { SandboxErrorKind } from "./lib/errors.ts";
export type { SandboxInfo } from "./lib/daemon.ts";

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
  cpus?: number;
  memoryMB?: number;
  ttlSeconds?: number;
  bootTimeoutSeconds?: number;
};

export type ExecOptions = {
  cwd?: string;
  env?: Record<string, string>;
  timeoutSeconds?: number;
  /** Raw guest bytes for this chunk. A character may be split across chunks. */
  onStdout?: (chunk: Uint8Array) => void;
  onStderr?: (chunk: Uint8Array) => void;
};

export type ExecResult = {
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
    const home = resolveHome(options.home);
    const status = await boot(home, {
      name: options.name,
      cpus: options.cpus ?? 1,
      memoryMB: options.memoryMB ?? 1024,
      bootTimeoutSeconds: options.bootTimeoutSeconds ?? 60,
      ttlSeconds: options.ttlSeconds,
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
        argv: commandArgv(command),
        env: envEntries(options.env ?? {}),
        cwd: options.cwd ?? "",
        timeoutSeconds: options.timeoutSeconds ?? 60,
      },
      options
    );
    const exitCode = outcome.signal > 0 ? 128 + outcome.signal : outcome.code;
    return {
      stdout: text.decode(outcome.stdout),
      stderr: text.decode(outcome.stderr),
      exitCode,
    };
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
