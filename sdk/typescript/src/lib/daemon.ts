import { SandboxError } from "./errors.ts";
import { ControlType, encodeFrame, encodeJSON } from "./framing.ts";
import { daemonSocket } from "./paths.ts";
import {
  execStream,
  roundTrip,
  type ExecHandlers,
  type ExecStream,
} from "./session.ts";

export type NetworkMode = "none" | "nat" | "filtered";

export type SandboxInfo = {
  network: NetworkMode | null;
  name: string;
  phase: string;
  cpus: number;
  memoryMB: number;
  createdAtUnix: number;
  ttlSeconds: number | null;
  message: string | null;
};

export type BootRequest = {
  network: NetworkMode;
  name: string;
  cpus: number;
  memoryMB: number;
  bootTimeoutSeconds: number;
  ttlSeconds?: number;
};

export type ExecBody = {
  requireOffline?: boolean;
  permitFiltered?: boolean;
  input?: "none" | "pipe" | "interactive";
  /** Run on a guest terminal of this size. Older daemons ignore it, so check first. */
  terminal?: { rows: number; cols: number };
  name: string;
  argv: string[];
  env: string[];
  cwd: string;
  timeoutSeconds: number;
};

export async function boot(
  home: string,
  request: BootRequest
): Promise<{ name: string; phase: string }> {
  await requirePolicy(home);
  const body: Record<string, unknown> = {
    network: request.network,
    name: request.name,
    cpus: request.cpus,
    memoryMB: request.memoryMB,
    bootTimeoutSeconds: request.bootTimeoutSeconds,
  };
  if (request.ttlSeconds !== undefined) body.ttlSeconds = request.ttlSeconds;
  const json = await roundTrip(
    daemonSocket(home),
    encodeJSON(ControlType.run, body)
  );
  return asStatus(json);
}

export async function list(home: string): Promise<SandboxInfo[]> {
  const json = await roundTrip(
    daemonSocket(home),
    encodeFrame(ControlType.ps, new Uint8Array())
  );
  return asList(json);
}

export async function exec(
  home: string,
  request: ExecBody,
  handlers: ExecHandlers,
  stdin?: Uint8Array
): Promise<ExecStream> {
  if (request.requireOffline) await requirePolicy(home);
  if (request.input === "pipe" || request.input === "interactive") {
    await requireExecStream(home);
  }
  if (request.terminal) await requireExecTerminal(home);
  return execStream(
    daemonSocket(home),
    encodeJSON(ControlType.exec, request),
    handlers,
    stdin
  );
}

export async function destroy(home: string, name: string): Promise<void> {
  await roundTrip(
    daemonSocket(home),
    encodeJSON(ControlType.destroy, { name })
  );
}

function asStatus(json: unknown): { name: string; phase: string } {
  if (!json || typeof json !== "object") {
    throw new SandboxError(
      "daemon",
      "daemon run reply was not a sandbox status"
    );
  }
  const record = json as { name?: unknown; phase?: unknown };
  if (typeof record.name !== "string" || typeof record.phase !== "string") {
    throw new SandboxError(
      "daemon",
      "daemon run reply was not a sandbox status"
    );
  }
  return { name: record.name, phase: record.phase };
}

function asList(json: unknown): SandboxInfo[] {
  if (
    !json ||
    typeof json !== "object" ||
    !Array.isArray((json as { vms?: unknown }).vms)
  ) {
    throw new SandboxError("daemon", "daemon ps reply was not a sandbox list");
  }
  return (json as { vms: unknown[] }).vms.map(asInfo);
}

function asInfo(value: unknown): SandboxInfo {
  if (!value || typeof value !== "object") {
    throw new SandboxError("daemon", "daemon ps reply had a bad sandbox");
  }
  const record = value as Record<string, unknown>;
  if (typeof record.name !== "string" || typeof record.phase !== "string") {
    throw new SandboxError("daemon", "daemon ps reply had a bad sandbox");
  }
  return {
    network:
      record.network === "none" ||
      record.network === "nat" ||
      record.network === "filtered"
        ? record.network
        : null,
    name: record.name,
    phase: record.phase,
    cpus: numberField(record.cpus, "cpus"),
    memoryMB: numberField(record.memoryMB, "memoryMB"),
    createdAtUnix: numberField(record.createdAtUnix, "createdAtUnix"),
    ttlSeconds:
      record.ttlSeconds == null
        ? null
        : numberField(record.ttlSeconds, "ttlSeconds"),
    message: record.message == null ? null : String(record.message),
  };
}

function numberField(value: unknown, name: string): number {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    throw new SandboxError("daemon", `daemon ps reply had a bad ${name}`);
  }
  return value;
}

async function requireExecStream(home: string): Promise<void> {
  const reply = await roundTrip(
    daemonSocket(home),
    encodeFrame(ControlType.ping, new Uint8Array())
  );
  if (
    !reply ||
    typeof reply !== "object" ||
    (reply as Record<string, unknown>).execStreamVersion !== 1
  ) {
    throw new SandboxError(
      "daemon",
      "daemon lacks exec stream v1; rebuild and restart it"
    );
  }
}

async function requireExecTerminal(home: string): Promise<void> {
  const reply = await roundTrip(
    daemonSocket(home),
    encodeFrame(ControlType.ping, new Uint8Array())
  );
  if (
    !reply ||
    typeof reply !== "object" ||
    (reply as Record<string, unknown>).execTerminalVersion !== 1
  ) {
    throw new SandboxError(
      "daemon",
      "daemon cannot allocate guest terminals; rebuild and restart it"
    );
  }
}

async function requirePolicy(home: string): Promise<void> {
  const reply = await roundTrip(
    daemonSocket(home),
    encodeFrame(ControlType.ping, new Uint8Array())
  );
  if (
    !reply ||
    typeof reply !== "object" ||
    (reply as Record<string, unknown>).ok !== true ||
    (reply as Record<string, unknown>).isolationPolicyVersion !== 1
  ) {
    throw new SandboxError(
      "daemon",
      "daemon lacks isolation policy v1; rebuild dynocap and manually restart the daemon before creating sandboxes"
    );
  }
}
