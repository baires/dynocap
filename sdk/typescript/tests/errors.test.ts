import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";
import { Sandbox, SandboxError } from "../src/index.ts";
import { fakeDaemon } from "./daemon.ts";

function typedError(code: string, message: string, exitCode = 1): string {
  return (
    "microvm-error-v1:" +
    JSON.stringify({ code, message, exitCode, recovery: "Retry." })
  );
}

async function expectError(
  message: string,
  kind: string,
  code: number,
  text?: string
) {
  const daemon = await fakeDaemon({ execError: message });
  try {
    const sandbox = await Sandbox.create({ name: "demo", home: daemon.home });
    await assert.rejects(sandbox.exec(["true"]), (error: unknown) => {
      assert.ok(error instanceof SandboxError);
      assert.equal(error.kind, kind);
      assert.equal(error.exitCode, code);
      if (text !== undefined) assert.equal(error.message, text);
      return true;
    });
  } finally {
    await daemon.close();
  }
}

test("typed daemon errors keep the recovery command", async () => {
  const { classifyDaemonMessage } = await import("../src/lib/errors.ts");
  const error = classifyDaemonMessage(
    "microvm-error-v1:" +
      JSON.stringify({
        code: "operation_failed",
        message: "runtime node:22 is not prepared yet",
        exitCode: 1,
        recovery:
          "Run microvm doctor --fix --runtime node:22 with the same --home, then retry.",
      }),
    false
  );
  assert.equal(error.message, "runtime node:22 is not prepared yet");
  assert.match(error.recovery ?? "", /doctor --fix --runtime node:22/);
});

test("typed daemon errors classify independently of message wording", async () => {
  await expectError(
    typedError("command_timeout", "deadline reached", 124),
    "timeout",
    124,
    "deadline reached"
  );
  await expectError(
    typedError("operation_failed", "lookup timed out"),
    "daemon",
    1,
    "lookup timed out"
  );
  await expectError(
    typedError("not_found", "sandbox missing"),
    "not_found",
    1,
    "sandbox missing"
  );
});

test("invalid typed errors cannot claim a timeout status", async () => {
  for (const text of ["microvm-error-v1:{}", "microvm-error-v1:not JSON"]) {
    await expectError(text, "daemon", 1);
  }
});

test("shared host control error vectors retain typed codes through the public SDK", async () => {
  const vectors = JSON.parse(
    fs.readFileSync(
      new URL("../../../testdata/control-error-vectors.json", import.meta.url),
      "utf8"
    )
  );
  for (const vector of vectors) {
    const frame = Buffer.from(vector.hex, "hex");
    assert.equal(frame.readUInt32BE(0), frame.length - 4);
    assert.equal(frame[4], 20);
    const kind =
      vector.error.code === "not_found"
        ? "not_found"
        : vector.error.code === "command_timeout"
          ? "timeout"
          : "daemon";
    await expectError(
      frame.subarray(5).toString("utf8"),
      kind,
      vector.error.exitCode,
      vector.error.message
    );
  }
});
