import path from "node:path";
import {
  Sandbox,
  type ClientOptions,
  type ExecOptions,
  type ExecResult,
} from "./index.ts";
import { resolveHome } from "./lib/paths.ts";
import { taskOperation } from "./lib/tasks.ts";
import { SandboxError } from "./lib/errors.ts";

export type RuntimeSelection = { name: string; version: string };
export type TaskOptions = ClientOptions & {
  projectPath: string;
  runtimes?: RuntimeSelection[];
  network?: "none" | "nat";
  ttlSeconds?: number;
  cpus?: number;
  memoryMB?: number;
  requireOffline?: boolean;
};
export type TaskInfo = {
  id: string;
  phase: string;
  runtimeDigest: string;
  createdAtUnix: number;
  expiresAtUnix: number;
  resultDirectory?: string;
  timingsMS?: Record<string, number>;
};
function taskInfo(value: unknown): TaskInfo {
  if (
    !value ||
    typeof value !== "object" ||
    typeof Reflect.get(value, "id") !== "string" ||
    typeof Reflect.get(value, "phase") !== "string" ||
    typeof Reflect.get(value, "runtimeDigest") !== "string" ||
    typeof Reflect.get(value, "expiresAtUnix") !== "number"
  ) {
    throw new SandboxError("daemon", "invalid task response");
  }
  return value as TaskInfo;
}
export class Task {
  readonly id: string;
  readonly #home: string;
  readonly #requireOffline: boolean;
  private constructor(info: TaskInfo, home: string, requireOffline: boolean) {
    this.id = info.id;
    this.#home = home;
    this.#requireOffline = requireOffline;
  }
  static async start(options: TaskOptions): Promise<Task> {
    const home = resolveHome(options.home);
    const info = taskInfo(
      await taskOperation(home, {
        ...options,
        projectPath: path.resolve(options.projectPath),
        op: "start",
      })
    );
    return new Task(info, home, options.requireOffline === true);
  }
  static connect(
    id: string,
    options: ClientOptions & { requireOffline?: boolean } = {}
  ): Task {
    if (!/^task-[a-z0-9-]+$/.test(id))
      throw new SandboxError("daemon", "invalid task id");
    return new Task(
      {
        id,
        phase: "unknown",
        runtimeDigest: "",
        createdAtUnix: 0,
        expiresAtUnix: 0,
      },
      resolveHome(options.home),
      options.requireOffline === true
    );
  }
  async exec(
    command: string | readonly string[],
    options: ExecOptions = {}
  ): Promise<ExecResult & { logDirectory: string }> {
    const sandbox = await Sandbox.connect(this.id, { home: this.#home });
    const result = await sandbox.exec(command, {
      ...options,
      cwd: options.cwd ?? "/workspace",
      timeoutSeconds: options.timeoutSeconds ?? 300,
      maxOutputBytes: options.maxOutputBytes ?? 32 * 1024,
      requireOffline: this.#requireOffline || options.requireOffline,
    });
    return { ...result, logDirectory: path.join(this.#home, "tasks", this.id) };
  }
  async finish(): Promise<TaskInfo> {
    return taskInfo(
      await taskOperation(this.#home, {
        op: "finish",
        id: this.id,
        requireOffline: this.#requireOffline,
      })
    );
  }
}
