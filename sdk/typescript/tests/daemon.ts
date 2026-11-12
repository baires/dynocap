import fs from "node:fs";
import net from "node:net";
import path from "node:path";
import { fileURLToPath } from "node:url";

const MAX_FRAME = 1 << 20;

export type FakeExec = {
  argv: string[];
  env: string[];
  cwd: string;
  timeoutSeconds: number;
  input?: string;
  terminal?: { rows: number; cols: number };
};

type Recorded = {
  network?: string;
  name: string;
  phase: string;
  cpus: number;
  memoryMB: number;
  daemonToken: string;
  createdAtUnix: number;
  ttlSeconds: number | null;
  message: string | null;
};

export type FakeDaemon = {
  home: string;
  execs: FakeExec[];
  runs: Record<string, unknown>[];
  close: () => Promise<void>;
};

/** Speaks the daemon control frames on `home/daemon.sock`. */
export async function fakeDaemon(
  behavior: Partial<FakeBehavior> = {}
): Promise<FakeDaemon> {
  const scratch = path.resolve(
    path.dirname(fileURLToPath(import.meta.url)),
    "..",
    ".tmp"
  );
  fs.mkdirSync(scratch, { recursive: true });
  const home = fs.mkdtempSync(path.join(scratch, "home-"));
  const socketPath = path.join(home, "daemon.sock");
  const sandboxes = new Map<string, Recorded>();
  const execs: FakeExec[] = [];
  const runs: Record<string, unknown>[] = [];
  const openExecs = new Map<net.Socket, Buffer[]>();
  const server = net.createServer((socket) => {
    const reader = new FrameReader();
    socket.on("data", (chunk: Buffer) => {
      let bodies: Buffer[];
      try {
        bodies = reader.push(chunk);
      } catch (error) {
        writeFrame(
          socket,
          20,
          Buffer.from(error instanceof Error ? error.message : String(error))
        );
        return;
      }
      for (const body of bodies)
        handle(socket, body, sandboxes, execs, runs, behavior, home, openExecs);
    });
  });
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(socketPath, () => resolve());
  });
  return {
    home,
    execs,
    runs,
    close: () =>
      new Promise((resolve) => {
        server.close(() => {
          fs.rmSync(home, { recursive: true, force: true });
          resolve();
        });
      }),
  };
}

type FakeBehavior = {
  execError: string;
  policyVersion: number | null;
  taskVersion: number | null;
  taskManagementVersion: number | null;
  execStreamVersion: number | null;
  execTerminalVersion: number | null;
  resolveID: string;
  execNetwork: "none" | "nat";
  recordedNetwork: "none" | "nat" | "unknown";
  onRun: (name: string) => "running" | "error";
};

function handle(
  socket: net.Socket,
  body: Buffer,
  sandboxes: Map<string, Recorded>,
  execs: FakeExec[],
  runs: Record<string, unknown>[],
  behavior: Partial<FakeBehavior>,
  home: string,
  openExecs: Map<net.Socket, Buffer[]>
) {
  if (body.length === 0) return;
  const type = body[0]!;
  const payload = body.subarray(1);
  const json = () =>
    JSON.parse(payload.toString("utf8")) as Record<string, unknown>;
  try {
    switch (type) {
      case 6:
        writeFrame(
          socket,
          16,
          Buffer.from(
            JSON.stringify({
              ok: true,
              taskVersion:
                behavior.taskVersion === null
                  ? undefined
                  : (behavior.taskVersion ?? 1),
              transferVersion: 1,
              taskManagementVersion:
                behavior.taskManagementVersion === null
                  ? undefined
                  : (behavior.taskManagementVersion ?? 1),
              ...(behavior.policyVersion === null
                ? {}
                : { isolationPolicyVersion: behavior.policyVersion ?? 1 }),
              ...(behavior.execStreamVersion === null
                ? {}
                : { execStreamVersion: behavior.execStreamVersion ?? 1 }),
              ...(behavior.execTerminalVersion === null
                ? {}
                : { execTerminalVersion: behavior.execTerminalVersion ?? 1 }),
            })
          )
        );
        return;
      case 7: {
        const request = json();
        runs.push(request);
        const id =
          request.op === "resolve"
            ? (behavior.resolveID ?? "task-fake")
            : "task-fake";
        const info = {
          id,
          name: request.name ?? "interview",
          phase: "running",
          runtimeDigest: "digest",
          createdAtUnix: 1,
          expiresAtUnix: 100,
        };
        if (
          ["list", "entries", "resolve", "remove", "diff"].includes(
            String(request.op)
          )
        ) {
          const preview = path.join(home, "preview");
          const value =
            request.op === "list"
              ? [info]
              : request.op === "entries"
                ? [{ ...info, kind: "task", runtime: "node:22" }]
                : request.op === "remove"
                  ? {}
                  : request.op === "diff"
                    ? {
                        directory: preview,
                        patchPath: path.join(preview, "changes.patch"),
                        reviewPath: path.join(preview, "review.txt"),
                        changesPath: path.join(preview, "changes.json"),
                      }
                    : info;
          writeFrame(socket, 16, Buffer.from(JSON.stringify(value)));
          return;
        }
        if (request.op === "start")
          sandboxes.set(id, {
            name: id,
            phase: "running",
            network: String(request.network ?? "none"),
            cpus: 2,
            memoryMB: 2048,
            daemonToken: "token",
            createdAtUnix: 1,
            ttlSeconds: 1800,
            message: null,
          });
        else sandboxes.delete(id);
        writeFrame(
          socket,
          16,
          Buffer.from(
            JSON.stringify({
              id,
              name: request.name,
              phase: request.op === "start" ? "running" : "completed",
              runtimeDigest: "digest",
              createdAtUnix: 1,
              expiresAtUnix: 100,
              resultDirectory: request.op === "finish" ? "/result" : undefined,
            })
          )
        );
        return;
      }
      case 8:
        runs.push(json());
        writeFrame(socket, 16, Buffer.from(JSON.stringify({ ok: true })));
        return;
      case 1: {
        const request = json();
        runs.push(request);
        const name = String(request.name);
        if (behavior.onRun?.(name) === "error") {
          writeFrame(
            socket,
            20,
            Buffer.from(`boot timed out waiting for ${name}`)
          );
          return;
        }
        sandboxes.set(name, {
          network:
            behavior.recordedNetwork === "unknown"
              ? undefined
              : (behavior.recordedNetwork ?? String(request.network ?? "none")),
          name,
          phase: "running",
          cpus: Number(request.cpus),
          memoryMB: Number(request.memoryMB),
          daemonToken: "secret-token",
          createdAtUnix: 1_700_000_000,
          ttlSeconds:
            request.ttlSeconds == null ? 1800 : Number(request.ttlSeconds),
          message: null,
        });
        writeFrame(
          socket,
          16,
          Buffer.from(JSON.stringify({ name, phase: "running" }))
        );
        return;
      }
      case 2: {
        const request = json();
        const name = String(request.name);
        const recorded = sandboxes.get(name);
        if (!recorded) {
          writeFrame(socket, 20, Buffer.from(`no VM named ${name}`));
          return;
        }
        if (behavior.execError !== undefined) {
          writeFrame(socket, 20, Buffer.from(behavior.execError));
          return;
        }
        const network = behavior.execNetwork ?? recorded.network;
        if (network === "filtered" && request.permitFiltered !== true) {
          writeFrame(
            socket,
            20,
            Buffer.from("filtered networking is disabled")
          );
          return;
        }
        if (
          request.requireOffline &&
          network !== "none" &&
          network !== "filtered"
        ) {
          writeFrame(
            socket,
            20,
            Buffer.from("exec requires an offline sandbox")
          );
          return;
        }
        const argv = request.argv as string[];
        const command =
          argv[0] === "sh" && argv[1] === "-c" ? String(argv[2] ?? "") : "";
        execs.push({
          argv,
          env: request.env as string[],
          cwd: String(request.cwd ?? ""),
          timeoutSeconds: Number(request.timeoutSeconds),
          ...(request.input === undefined
            ? {}
            : { input: String(request.input) }),
          ...(request.terminal === undefined
            ? {}
            : { terminal: request.terminal as { rows: number; cols: number } }),
        });
        if (request.input === "pipe" || request.input === "interactive") {
          openExecs.set(socket, []);
          if (request.terminal) terminals.add(socket);
          return;
        }
        if (argv[0] === "sleep" || command.startsWith("sleep")) {
          writeFrame(
            socket,
            20,
            Buffer.from(`timed out after ${request.timeoutSeconds}s`)
          );
          return;
        }
        if (argv[0] === "big" || command === "big") {
          writeFrame(socket, 17, Buffer.alloc(200_000, 0x78));
          writeFrame(socket, 19, exitFrame(0, 0));
          return;
        }
        const out = Buffer.from(`${argv.join(" ")}\n`);
        writeFrame(socket, 17, out.subarray(0, 2));
        writeFrame(socket, 17, out.subarray(2));
        if (argv[0] === "noisy") {
          writeFrame(socket, 18, Buffer.from("warn\n"));
        }
        if (argv[0] === "kill") {
          writeFrame(socket, 19, exitFrame(0, 9));
          return;
        }
        writeFrame(socket, 19, exitFrame(argv[0] === "false" ? 1 : 0, 0));
        return;
      }
      case 3: {
        writeFrame(
          socket,
          16,
          Buffer.from(JSON.stringify({ vms: [...sandboxes.values()] }))
        );
        return;
      }
      case 4: {
        const name = String(json().name);
        if (!sandboxes.has(name)) {
          writeFrame(socket, 20, Buffer.from(`no VM named ${name}`));
          return;
        }
        sandboxes.delete(name);
        writeFrame(socket, 16, Buffer.from(JSON.stringify({ ok: true })));
        return;
      }
      case 21: {
        const chunks = openExecs.get(socket);
        if (!chunks) {
          writeFrame(
            socket,
            20,
            Buffer.from("stdin frame without a streaming exec")
          );
          return;
        }
        chunks.push(Buffer.from(payload));
        return;
      }
      case 22: {
        const chunks = openExecs.get(socket);
        if (!chunks) {
          writeFrame(
            socket,
            20,
            Buffer.from("stdin EOF without a streaming exec")
          );
          return;
        }
        openExecs.delete(socket);
        if (terminals.delete(socket)) {
          // Like a guest terminal: echo with CR LF, then the program's output, all on stdout.
          const typed = Buffer.concat(chunks).toString("utf8");
          const echo = typed.replace(/\r/g, "\r\n");
          writeFrame(
            socket,
            17,
            Buffer.from(`${echo}tty: ${typed.trim()}\r\n`)
          );
          writeFrame(socket, 19, exitFrame(0, 0));
          return;
        }
        writeFrame(socket, 17, Buffer.concat(chunks));
        writeFrame(socket, 19, exitFrame(0, 0));
        return;
      }
      default:
        writeFrame(socket, 20, Buffer.from(`unknown control type ${type}`));
    }
  } catch (error) {
    writeFrame(
      socket,
      20,
      Buffer.from(error instanceof Error ? error.message : String(error))
    );
  }
}

const terminals = new WeakSet<net.Socket>();

function exitFrame(code: number, signal: number): Buffer {
  const payload = Buffer.alloc(8);
  payload.writeInt32BE(code, 0);
  payload.writeInt32BE(signal, 4);
  return payload;
}

function writeFrame(socket: net.Socket, type: number, payload: Buffer) {
  const length = 1 + payload.length;
  if (length > MAX_FRAME) throw new Error("frame too large");
  const out = Buffer.alloc(4 + length);
  out.writeUInt32BE(length, 0);
  out[4] = type;
  payload.copy(out, 5);
  socket.write(out);
}

class FrameReader {
  #buf = Buffer.alloc(0);

  push(chunk: Buffer): Buffer[] {
    this.#buf =
      this.#buf.length === 0 ? chunk : Buffer.concat([this.#buf, chunk]);
    const bodies: Buffer[] = [];
    while (this.#buf.length >= 4) {
      const length = this.#buf.readUInt32BE(0);
      if (length <= 0 || length > MAX_FRAME)
        throw new Error("control frame exceeds limit");
      if (this.#buf.length < 4 + length) break;
      bodies.push(this.#buf.subarray(4, 4 + length));
      this.#buf = this.#buf.subarray(4 + length);
    }
    return bodies;
  }
}
