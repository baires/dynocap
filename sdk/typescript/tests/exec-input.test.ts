import assert from "node:assert/strict";
import test from "node:test";

import { Sandbox, SandboxError } from "../src/index.ts";

import { fakeDaemon } from "./daemon.ts";

test("piped stdin requires exec stream v1 and reaches the guest", async () => {
  const missing = await fakeDaemon({ execStreamVersion: null });
  try {
    const sandbox = await Sandbox.create({
      name: "demo",
      cpus: 1,
      memoryMB: 256,
      home: missing.home,
    });
    await assert.rejects(
      sandbox.exec(["cat"], { stdin: Buffer.from("hello") }),
      (error: unknown) => {
        assert.ok(error instanceof SandboxError);
        assert.match(error.message, /exec stream v1/);
        return true;
      }
    );
  } finally {
    await missing.close();
  }

  const daemon = await fakeDaemon();
  try {
    const sandbox = await Sandbox.create({
      name: "demo",
      cpus: 1,
      memoryMB: 256,
      home: daemon.home,
    });
    const payload = Buffer.concat([
      Buffer.alloc(40_000, 0x61),
      Buffer.from("\n"),
    ]);
    const result = await sandbox.exec(["cat"], { stdin: payload });
    assert.equal(result.exitCode, 0);
    assert.equal(Buffer.from(result.stdout).equals(payload), true);
    assert.equal(result.stderr, "");
    assert.equal(daemon.execs[0]?.cwd, "");
  } finally {
    await daemon.close();
  }
});

test("terminal execs need execTerminalVersion and return one transcript", async () => {
  const old = await fakeDaemon({ execTerminalVersion: null });
  try {
    const sandbox = await Sandbox.create({
      name: "demo",
      cpus: 1,
      memoryMB: 256,
      home: old.home,
    });
    await assert.rejects(
      sandbox.exec(["sh"], { terminal: { rows: 24, cols: 80 } }),
      (error: unknown) => {
        assert.ok(error instanceof SandboxError);
        assert.match(error.message, /cannot allocate guest terminals/);
        return true;
      }
    );
    assert.equal(old.execs.length, 0, "nothing is sent to an older daemon");
  } finally {
    await old.close();
  }

  const daemon = await fakeDaemon();
  try {
    const sandbox = await Sandbox.create({
      name: "demo",
      cpus: 1,
      memoryMB: 256,
      home: daemon.home,
    });
    for (const terminal of [
      { rows: 0, cols: 80 },
      { rows: 24, cols: 1.5 },
      { rows: 70_000, cols: 80 },
    ]) {
      await assert.rejects(sandbox.exec(["sh"], { terminal }), /1 to 65535/);
    }
    const result = await sandbox.exec(["sh"], {
      terminal: { rows: 33, cols: 101 },
      stdin: Buffer.from("ls\r"),
    });
    assert.equal(result.exitCode, 0);
    assert.equal(result.stdout, "ls\r\ntty: ls\r\n");
    assert.equal(result.stderr, "");
    assert.deepEqual(daemon.execs.at(-1)?.terminal, { rows: 33, cols: 101 });
    assert.equal(daemon.execs.at(-1)?.input, "interactive");

    // No stdin still streams: the CLI-side EOF is harmless on a terminal.
    const quiet = await sandbox.exec("true", {
      terminal: { rows: 24, cols: 80 },
    });
    assert.equal(quiet.stdout, "tty: \r\n");
    const plain = await sandbox.exec(["uname"]);
    assert.equal(daemon.execs.at(-1)?.terminal, undefined);
    assert.equal(plain.stdout, "uname\n");
  } finally {
    await daemon.close();
  }
});
