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
  name?: string;
  projectPath?: string;
  repositoryUrl?: string;
  ref?: string;
  gitToken?: string;
  sshKeyPath?: string;
  runtimes?: RuntimeSelection[];
  network?: "none" | "nat" | "filtered";
  ttlSeconds?: number;
  cpus?: number;
  memoryMB?: number;
  requireOffline?: boolean;
  permitFiltered?: boolean;
};
export type TaskInfo = {
  name?: string;
  network?: "none" | "nat" | "filtered";
  id: string;
  phase: string;
  runtimeDigest: string;
  createdAtUnix: number;
  expiresAtUnix: number;
  resultDirectory?: string;
  sourceUrl?: string;
  sourceRevision?: string;
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
  readonly name?: string;
  readonly sourceUrl?: string;
  readonly sourceRevision?: string;
  readonly #home: string;
  readonly #requireOffline: boolean;
  readonly #permitFiltered: boolean | undefined;
  private constructor(
    info: TaskInfo,
    home: string,
    requireOffline: boolean,
    permitFiltered: boolean | undefined
  ) {
    this.id = info.id;
    this.name = info.name;
    this.sourceUrl = info.sourceUrl;
    this.sourceRevision = info.sourceRevision;
    this.#home = home;
    this.#requireOffline = requireOffline;
    this.#permitFiltered = permitFiltered;
  }
  static async start(options: TaskOptions): Promise<Task> {
    const hasPath = options.projectPath !== undefined;
    const hasURL = options.repositoryUrl !== undefined;
    if (hasPath === hasURL) {
      throw new SandboxError(
        "daemon",
        "task start requires a projectPath or a repositoryUrl"
      );
    }
    const home = resolveHome(options.home);
    const info = taskInfo(
      await taskOperation(home, {
        op: "start",
        name: options.name,
        runtimes: options.runtimes,
        network: options.network,
        ttlSeconds: options.ttlSeconds,
        cpus: options.cpus,
        memoryMB: options.memoryMB,
        requireOffline: options.requireOffline,
        ...(options.permitFiltered === undefined
          ? {}
          : { permitFiltered: options.permitFiltered }),
        ...(options.projectPath
          ? { projectPath: path.resolve(options.projectPath) }
          : {}),
        ...(options.repositoryUrl
          ? { repositoryUrl: options.repositoryUrl }
          : {}),
        ...(options.ref ? { ref: options.ref } : {}),
        ...(options.gitToken ? { gitToken: options.gitToken } : {}),
        ...(options.sshKeyPath ? { sshKeyPath: options.sshKeyPath } : {}),
      })
    );
    return new Task(
      info,
      home,
      options.requireOffline === true,
      options.permitFiltered
    );
  }
  static async list(options: ClientOptions = {}): Promise<TaskInfo[]> {
    const value = await taskOperation(resolveHome(options.home), {
      op: "list",
    });
    if (!Array.isArray(value))
      throw new SandboxError("daemon", "invalid task list");
    return value.map(taskInfo);
  }
  static async open(
    target: string,
    options: TaskAccessOptions = {}
  ): Promise<Task> {
    const home = resolveHome(options.home);
    const info = taskInfo(
      await taskOperation(home, { op: "resolve", id: target })
    );
    return new Task(
      info,
      home,
      options.requireOffline === true,
      options.permitFiltered
    );
  }
  async diff(): Promise<TaskPreview> {
    const value = await taskOperation(this.#home, {
      op: "diff",
      id: this.id,
      requireOffline: this.#requireOffline,
      permitFiltered: this.#permitFiltered,
    });
    if (
      !value ||
      typeof value !== "object" ||
      !["directory", "patchPath", "reviewPath", "changesPath"].every(
        (key) => typeof Reflect.get(value, key) === "string"
      )
    ) {
      throw new SandboxError("daemon", "invalid task preview");
    }
    return value as TaskPreview;
  }
  async remove(
    options: { purge?: boolean; force?: boolean } = {}
  ): Promise<void> {
    await removeManaged(this.id, { home: this.#home, ...options });
  }
  static connect(
    id: string,
    options: ClientOptions & {
      requireOffline?: boolean;
      permitFiltered?: boolean;
    } = {}
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
      options.requireOffline === true,
      options.permitFiltered
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
      ...(this.#permitFiltered === undefined
        ? {}
        : { permitFiltered: this.#permitFiltered }),
    });
    return { ...result, logDirectory: path.join(this.#home, "tasks", this.id) };
  }
  async finish(): Promise<TaskInfo> {
    return taskInfo(
      await taskOperation(this.#home, {
        op: "finish",
        id: this.id,
        requireOffline: this.#requireOffline,
        ...(this.#permitFiltered === undefined
          ? {}
          : { permitFiltered: this.#permitFiltered }),
      })
    );
  }
}

export type TaskAccessOptions = ClientOptions & {
  requireOffline?: boolean;
  permitFiltered?: boolean;
};
export type TaskPreview = {
  directory: string;
  patchPath: string;
  reviewPath: string;
  changesPath: string;
};
export type ManagedEntry = {
  id: string;
  name?: string;
  kind: "task" | "sandbox";
  phase: string;
  runtime: string;
  network?: "none" | "nat" | "filtered";
  expiresAtUnix?: number;
  resultDirectory?: string;
};
export async function listManaged(
  options: ClientOptions = {}
): Promise<ManagedEntry[]> {
  const value = await taskOperation(resolveHome(options.home), {
    op: "entries",
  });
  if (
    !Array.isArray(value) ||
    !value.every(
      (entry) =>
        entry &&
        typeof entry.id === "string" &&
        ["task", "sandbox"].includes(entry.kind) &&
        typeof entry.phase === "string"
    )
  ) {
    throw new SandboxError("daemon", "invalid managed list");
  }
  return value as ManagedEntry[];
}
export async function removeManaged(
  target: string,
  options: ClientOptions & { purge?: boolean; force?: boolean } = {}
): Promise<void> {
  await taskOperation(resolveHome(options.home), {
    op: "remove",
    id: target,
    purge: options.purge === true,
    force: options.force === true,
  });
}
