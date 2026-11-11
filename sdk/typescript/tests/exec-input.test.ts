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
