import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";

import { Sandbox, SandboxError } from "../src/index.ts";

import { fakeDaemon } from "./daemon.ts";

test("create, exec, list, and destroy a sandbox", async () => {
  const daemon = await fakeDaemon();
  try {
    const sandbox = await Sandbox.create({
      name: "demo",
      cpus: 2,
      memoryMB: 512,
      ttlSeconds: 600,
      home: daemon.home,
    });
    assert.equal(sandbox.name, "demo");

    const chunks: string[] = [];
    const result = await sandbox.exec("uname -a", {
      cwd: "/tmp",
      env: { FOO: "bar" },
      onStdout: (chunk) => chunks.push(Buffer.from(chunk).toString("utf8")),
    });
    assert.equal(result.stdout, "sh -c uname -a\n");
    assert.equal(result.stderr, "");
    assert.equal(result.exitCode, 0);
    assert.deepEqual(chunks.join(""), result.stdout);
    assert.deepEqual(daemon.execs[0], {
      argv: ["sh", "-c", "uname -a"],
      env: ["FOO=bar"],
      cwd: "/tmp",
      timeoutSeconds: 60,
    });

    const listed = await Sandbox.list({ home: daemon.home });
    assert.deepEqual(listed, [
      {
        name: "demo",
        phase: "running",
        cpus: 2,
        memoryMB: 512,
        createdAtUnix: 1_700_000_000,
        ttlSeconds: 600,
        message: null,
      },
    ]);
    assert.equal(JSON.stringify(listed).includes("daemonToken"), false);

    const connected = await Sandbox.connect("demo", { home: daemon.home });
    const direct = await connected.exec(["false"]);
    assert.equal(direct.exitCode, 1);

    await sandbox.destroy();
    assert.deepEqual(await Sandbox.list({ home: daemon.home }), []);
  } finally {
    await daemon.close();
  }
});

test("a missing sandbox is not_found and an exec deadline is exit 124", async () => {
  const daemon = await fakeDaemon();
  try {
    const sandbox = await Sandbox.create({ name: "demo", home: daemon.home });
    await assert.rejects(
      Sandbox.connect("other", { home: daemon.home }),
      (error: unknown) => {
        assert.ok(error instanceof SandboxError);
        assert.equal(error.kind, "not_found");
        return true;
      }
    );
    await assert.rejects(
      sandbox.exec(["sleep", "30"], { timeoutSeconds: 1 }),
      (error: unknown) => {
        assert.ok(error instanceof SandboxError);
        assert.equal(error.kind, "timeout");
        assert.equal(error.exitCode, 124);
        assert.match(error.message, /timed out/);
        return true;
      }
    );
    const killed = await sandbox.exec(["kill"]);
    assert.equal(killed.exitCode, 137);
  } finally {
    await daemon.close();
  }
});

test("boot deadline stays a timeout with the daemon's exit code", async () => {
  const daemon = await fakeDaemon({ onRun: () => "error" });
  try {
    await assert.rejects(
      Sandbox.create({ name: "demo", home: daemon.home }),
      (error: unknown) => {
        assert.ok(error instanceof SandboxError);
        assert.equal(error.kind, "timeout");
        assert.equal(error.exitCode, 1);
        assert.match(error.message, /boot timed out/);
        return true;
      }
    );
  } finally {
    await daemon.close();
  }
});

test("a silent home is a daemon error", async () => {
  const home = fs.mkdtempSync(path.join("/tmp", "microvm-empty-"));
  try {
    await assert.rejects(Sandbox.list({ home }), (error: unknown) => {
      assert.ok(error instanceof SandboxError);
      assert.equal(error.kind, "daemon");
      assert.match(error.message, /not listening/);
      return true;
    });
  } finally {
    fs.rmSync(home, { recursive: true, force: true });
  }
});

test("callers cannot import the client implementation", () => {
  const testsDir = path.dirname(new URL(import.meta.url).pathname);
  const offenders: string[] = [];
  for (const file of fs.readdirSync(testsDir)) {
    if (!file.endsWith(".ts")) continue;
    const source = fs.readFileSync(path.join(testsDir, file), "utf8");
    for (const match of source.matchAll(/from\s+["']([^"']+)["']/g)) {
      const specifier = match[1] ?? "";
      if (specifier.includes("/lib/") || specifier.includes("src/lib"))
        offenders.push(file);
    }
  }
  assert.deepEqual(offenders, []);
});
