import assert from "node:assert/strict";
import test from "node:test";

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";

import { createServer } from "../src/index.ts";
import {
  microvmDestroy,
  microvmExec,
  microvmPs,
  microvmRun,
} from "../src/tools.ts";
import { fakeDaemon } from "../../typescript/tests/daemon.ts";

test("the server exposes the four sandbox tools", async () => {
  const [clientTransport, serverTransport] =
    InMemoryTransport.createLinkedPair();
  const server = createServer();
  const client = new Client({ name: "test", version: "0.0.0" });
  await Promise.all([
    server.connect(serverTransport),
    client.connect(clientTransport),
  ]);
  try {
    const listed = await client.listTools();
    const names = listed.tools.map((tool) => tool.name).sort();
    assert.deepEqual(names, [
      "microvm_destroy",
      "microvm_exec",
      "microvm_ps",
      "microvm_run",
    ]);
    const exec = listed.tools.find((tool) => tool.name === "microvm_exec");
    assert.match(exec?.description ?? "", /not a cloud sandbox/i);
  } finally {
    await client.close();
  }
});

test("mcp tools boot, exec, list, and destroy through the sandbox client", async () => {
  const daemon = await fakeDaemon();
  const home = { home: daemon.home };
  try {
    const created = await microvmRun(
      { name: "demo", cpus: 2, memoryMB: 256, ttlSeconds: 30 },
      home
    );
    assert.equal(created.isError, undefined);
    assert.equal(created.content[0].text, "running demo");

    const exec = await microvmExec(
      { name: "demo", command: "uname -a", cwd: "/workspace" },
      home
    );
    assert.equal(exec.content[0].text, "exit 0\nsh -c uname -a\n");
    assert.equal(daemon.execs[0]?.timeoutSeconds, 30);
    assert.equal(daemon.execs[0]?.cwd, "/workspace");

    const listed = await microvmPs(home);
    assert.match(listed.content[0].text, /"name": "demo"/);
    assert.equal(listed.content[0].text.includes("daemonToken"), false);

    const removed = await microvmDestroy("demo", home);
    assert.equal(removed.content[0].text, "destroyed demo");
    const after = await microvmPs(home);
    assert.equal(after.content[0].text, "[]");
  } finally {
    await daemon.close();
  }
});

test("a missing sandbox and an exec deadline stay tool errors", async () => {
  const daemon = await fakeDaemon();
  const home = { home: daemon.home };
  try {
    await microvmRun({ name: "demo" }, home);
    const missing = await microvmExec({ name: "other", command: "true" }, home);
    assert.equal(missing.isError, true);
    assert.match(missing.content[0].text, /^not_found:/);

    const timed = await microvmExec(
      { name: "demo", command: "sleep 5", timeoutSeconds: 1 },
      home
    );
    assert.equal(timed.isError, true);
    assert.match(timed.content[0].text, /^timeout:/);
  } finally {
    await daemon.close();
  }
});

test("captured exec output is capped", async () => {
  const daemon = await fakeDaemon();
  try {
    await microvmRun({ name: "demo" }, { home: daemon.home });
    const exec = await microvmExec(
      { name: "demo", command: "big" },
      { home: daemon.home }
    );
    assert.equal(exec.isError, undefined);
    assert.match(exec.content[0].text, /output truncated/);
    assert.ok(Buffer.byteLength(exec.content[0].text) < 70_000);
  } finally {
    await daemon.close();
  }
});
