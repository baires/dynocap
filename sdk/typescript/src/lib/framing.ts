export const MAX_FRAME = 1 << 20;

export const ControlType = {
  run: 1,
  exec: 2,
  ps: 3,
  destroy: 4,
  ping: 6,
  task: 7,
  transfer: 8,
  result: 16,
  stdout: 17,
  stderr: 18,
  exit: 19,
  error: 20,
  stdin: 21,
  stdinEOF: 22,
  signal: 23,
} as const;

export type Inbound =
  | { kind: "result"; json: unknown }
  | { kind: "stdout"; data: Uint8Array }
  | { kind: "stderr"; data: Uint8Array }
  | { kind: "exit"; code: number; signal: number }
  | { kind: "error"; message: string };

export function encodeFrame(type: number, payload: Uint8Array): Buffer {
  const length = 1 + payload.length;
  if (length <= 0 || length > MAX_FRAME) {
    throw new Error("control frame exceeds limit");
  }
  const out = Buffer.alloc(4 + length);
  out.writeUInt32BE(length, 0);
  out[4] = type;
  Buffer.from(payload).copy(out, 5);
  return out;
}

export function encodeJSON(type: number, value: unknown): Buffer {
  return encodeFrame(type, Buffer.from(JSON.stringify(value)));
}

export class FrameReader {
  #buf = Buffer.alloc(0) as Buffer<ArrayBufferLike>;

  push(chunk: Buffer): Buffer[] {
    this.#buf =
      this.#buf.length === 0 ? chunk : Buffer.concat([this.#buf, chunk]);
    const bodies: Buffer[] = [];
    while (this.#buf.length >= 4) {
      const length = this.#buf.readUInt32BE(0);
      if (length <= 0 || length > MAX_FRAME) {
        throw new Error("control frame exceeds limit");
      }
      if (this.#buf.length < 4 + length) break;
      bodies.push(this.#buf.subarray(4, 4 + length));
      this.#buf = this.#buf.subarray(4 + length);
    }
    return bodies;
  }
}

export function decodeBody(body: Buffer): Inbound {
  if (body.length === 0) throw new Error("bad control frame");
  const type = body[0];
  const payload = body.subarray(1);
  switch (type) {
    case ControlType.result:
      return {
        kind: "result",
        json:
          payload.length === 0 ? null : JSON.parse(payload.toString("utf8")),
      };
    case ControlType.stdout:
      return { kind: "stdout", data: Uint8Array.from(payload) };
    case ControlType.stderr:
      return { kind: "stderr", data: Uint8Array.from(payload) };
    case ControlType.exit: {
      if (payload.length !== 8) throw new Error("bad exit frame");
      return {
        kind: "exit",
        code: payload.readInt32BE(0),
        signal: payload.readInt32BE(4),
      };
    }
    case ControlType.error:
      return { kind: "error", message: payload.toString("utf8") };
    default:
      throw new Error(`unknown control type ${type}`);
  }
}
