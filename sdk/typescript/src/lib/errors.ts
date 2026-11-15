export type SandboxErrorKind = "daemon" | "timeout" | "not_found";

export class SandboxError extends Error {
  readonly kind: SandboxErrorKind;
  readonly exitCode: number;
  readonly recovery?: string;

  constructor(
    kind: SandboxErrorKind,
    message: string,
    exitCode = 1,
    recovery?: string
  ) {
    super(message);
    this.name = "SandboxError";
    this.kind = kind;
    this.exitCode = exitCode;
    this.recovery = recovery;
  }
}

/** Maps a daemon error frame onto the caller's error kinds. */
export function classifyDaemonMessage(
  message: string,
  exec: boolean
): SandboxError {
  const prefix = "dynocap-error-v1:";
  if (message.startsWith(prefix)) {
    try {
      const failure: unknown = JSON.parse(message.slice(prefix.length));
      if (
        typeof failure === "object" &&
        failure !== null &&
        "code" in failure &&
        "message" in failure &&
        typeof failure.message === "string"
      ) {
        const kind =
          failure.code === "not_found"
            ? "not_found"
            : failure.code === "command_timeout"
              ? "timeout"
              : "daemon";
        const recovery =
          "recovery" in failure && typeof failure.recovery === "string"
            ? failure.recovery
            : undefined;
        return new SandboxError(
          kind,
          failure.message,
          kind === "timeout" && exec ? 124 : 1,
          recovery
        );
      }
    } catch {
      // Malformed envelopes are ordinary daemon failures, never timeout guesses.
    }
    return new SandboxError("daemon", "invalid daemon error response");
  }
  // Legacy daemon compatibility stays confined to the SDK. The CLI does not guess.
  if (message.includes("no VM named")) {
    return new SandboxError("not_found", message, 1);
  }
  if (message.includes("timed out")) {
    return new SandboxError("timeout", message, exec ? 124 : 1);
  }
  return new SandboxError("daemon", message, 1);
}
