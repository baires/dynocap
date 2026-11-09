export type SandboxErrorKind = "daemon" | "timeout" | "not_found";

export class SandboxError extends Error {
  readonly kind: SandboxErrorKind;
  readonly exitCode: number;

  constructor(kind: SandboxErrorKind, message: string, exitCode = 1) {
    super(message);
    this.name = "SandboxError";
    this.kind = kind;
    this.exitCode = exitCode;
  }
}

/** Maps a daemon error frame onto the caller's error kinds. */
export function classifyDaemonMessage(
  message: string,
  exec: boolean
): SandboxError {
  if (message.includes("no VM named")) {
    return new SandboxError("not_found", message, 1);
  }
  if (message.includes("timed out")) {
    return new SandboxError("timeout", message, exec ? 124 : 1);
  }
  return new SandboxError("daemon", message, 1);
}
