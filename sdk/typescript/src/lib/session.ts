import net from "node:net";

import { SandboxError, classifyDaemonMessage } from "./errors.ts";
import { FrameReader, decodeBody, type Inbound } from "./framing.ts";

export type ExecHandlers = {
  maxOutputBytes?: number;
  onStdout?: (chunk: Uint8Array) => void;
  onStderr?: (chunk: Uint8Array) => void;
};

export type ExecStream = {
  code: number;
  signal: number;
  truncated: boolean;
  stdout: Uint8Array;
  stderr: Uint8Array;
};

export async function roundTrip(
  socketPath: string,
  frame: Buffer
): Promise<unknown> {
  const message = await withSocket(socketPath, async (socket) => {
    const incoming = new Incoming(socket);
    await writeFrame(socket, frame);
    const next = await incoming.next();
    if (!next) throw new SandboxError("daemon", "daemon closed the connection");
    return next;
  });
  if (message.kind === "error")
    throw classifyDaemonMessage(message.message, false);
  if (message.kind !== "result") {
    throw new SandboxError("daemon", "unexpected daemon reply");
  }
  return message.json;
}

export async function execStream(
  socketPath: string,
  frame: Buffer,
  handlers: ExecHandlers
): Promise<ExecStream> {
  return withSocket(socketPath, async (socket) => {
    const incoming = new Incoming(socket);
    await writeFrame(socket, frame);
    const stdout: Buffer[] = [];
    const stderr: Buffer[] = [];
    let stdoutBytes = 0,
      stderrBytes = 0;
    const limit = handlers.maxOutputBytes ?? Infinity;
    for (;;) {
      const message = await incoming.next();
      if (!message) break;
      switch (message.kind) {
        case "stdout":
          if (stdoutBytes < limit)
            stdout.push(
              Buffer.from(message.data).subarray(0, limit - stdoutBytes)
            );
          stdoutBytes += message.data.length;
          handlers.onStdout?.(message.data);
          break;
        case "stderr":
          if (stderrBytes < limit)
            stderr.push(
              Buffer.from(message.data).subarray(0, limit - stderrBytes)
            );
          stderrBytes += message.data.length;
          handlers.onStderr?.(message.data);
          break;
        case "exit":
          return {
            truncated: stdoutBytes > limit || stderrBytes > limit,
            code: message.code,
            signal: message.signal,
            stdout: concat(stdout),
            stderr: concat(stderr),
          };
        case "error":
          throw classifyDaemonMessage(message.message, true);
        default:
          throw new SandboxError("daemon", "unexpected exec reply");
      }
    }
    throw new SandboxError("daemon", "daemon closed the exec stream");
  });
}

async function withSocket<T>(
  socketPath: string,
  use: (socket: net.Socket) => Promise<T>
): Promise<T> {
  const socket = await connect(socketPath);
  try {
    return await use(socket);
  } finally {
    socket.end();
  }
}

function connect(socketPath: string): Promise<net.Socket> {
  return new Promise((resolve, reject) => {
    const socket = net.connect(socketPath);
    const fail = (error: NodeJS.ErrnoException) => {
      socket.destroy();
      if (error.code === "ENOENT" || error.code === "ECONNREFUSED") {
        reject(
          new SandboxError("daemon", `daemon is not listening at ${socketPath}`)
        );
        return;
      }
      reject(new SandboxError("daemon", error.message));
    };
    socket.once("error", fail);
    socket.once("connect", () => {
      socket.removeListener("error", fail);
      resolve(socket);
    });
  });
}

function writeFrame(socket: net.Socket, frame: Buffer): Promise<void> {
  return new Promise((resolve, reject) => {
    socket.write(frame, (error) => {
      if (error) reject(new SandboxError("daemon", error.message));
      else resolve();
    });
  });
}

class Incoming {
  #reader = new FrameReader();
  #pending: Inbound[] = [];
  #ended = false;
  #failure: Error | undefined;
  #wake: (() => void) | undefined;

  constructor(socket: net.Socket) {
    socket.on("data", (chunk: Buffer) => {
      try {
        for (const body of this.#reader.push(chunk))
          this.#pending.push(decodeBody(body));
      } catch (error) {
        this.#failure = asDaemonError(error);
      }
      this.#poke();
    });
    socket.on("error", (error: Error) => {
      this.#failure = new SandboxError("daemon", error.message);
      this.#poke();
    });
    socket.on("end", () => {
      this.#ended = true;
      this.#poke();
    });
  }

  async next(): Promise<Inbound | undefined> {
    while (true) {
      if (this.#pending.length > 0) return this.#pending.shift();
      if (this.#failure) throw this.#failure;
      if (this.#ended) return undefined;
      await new Promise<void>((resolve) => {
        this.#wake = resolve;
      });
    }
  }

  #poke() {
    const notify = this.#wake;
    this.#wake = undefined;
    notify?.();
  }
}

function concat(parts: Buffer[]): Uint8Array {
  return Uint8Array.from(Buffer.concat(parts));
}

function asDaemonError(error: unknown): SandboxError {
  if (error instanceof SandboxError) return error;
  const message = error instanceof Error ? error.message : String(error);
  return new SandboxError("daemon", message);
}
