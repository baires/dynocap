import assert from "node:assert/strict";
import test from "node:test";
import { fileURLToPath } from "node:url";

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";

import { Sandbox } from "@microvm/sdk";

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

test("NAT creation requires an explicit MCP host policy", async () => {
  const daemon = await fakeDaemon();
  try {
    const denied = await microvmRun(
      { name: "denied", network: "nat" },
      { home: daemon.home }
    );
    assert.equal(denied.isError, true);
    assert.match(denied.content[0].text, /MICROVM_MCP_ALLOW_NAT=1/);
    assert.equal(daemon.runs.length, 0);
    const allowed = await microvmRun(
      { name: "allowed", network: "nat" },
      { home: daemon.home, allowNat: true }
    );
    assert.equal(allowed.isError, undefined);
    assert.equal(daemon.runs[0]?.network, "nat");
  } finally {
    await daemon.close();
  }
});

test("MCP cannot exec existing NAT or unknown sandboxes without host permission", async () => {
  for (const recordedNetwork of ["nat", "unknown"] as const) {
    const daemon = await fakeDaemon({ recordedNetwork });
    const home = { home: daemon.home };
    try {
      await Sandbox.create({ ...home, name: "existing" });
      const denied = await microvmExec(
        { name: "existing", command: "true" },
        home
      );
      assert.equal(denied.isError, true);
      assert.match(denied.content[0].text, /offline sandbox/);
      assert.equal(daemon.execs.length, 0);
      const allowed = await microvmExec(
        { name: "existing", command: "true" },
        { ...home, allowNat: true }
      );
      assert.equal(allowed.isError, undefined);
      assert.equal((await microvmPs(home)).isError, undefined);
      assert.equal((await microvmDestroy("existing", home)).isError, undefined);
    } finally {
      await daemon.close();
    }
  }
});

test("daemon offline requirement protects MCP exec if networking changes after listing", async () => {
  const daemon = await fakeDaemon({ execNetwork: "nat" });
  const home = { home: daemon.home };
  try {
    await microvmRun({ name: "replaced" }, home);
    const denied = await microvmExec(
      { name: "replaced", command: "true" },
      home
    );
    assert.equal(denied.isError, true);
    assert.match(denied.content[0].text, /offline sandbox/);
    assert.equal(daemon.execs.length, 0);
  } finally {
    await daemon.close();
  }
});

test("MCP server snapshots host policy and validates TTL and networking schemas", async () => {
  const daemon = await fakeDaemon();
  const host = { home: daemon.home, allowNat: false };
  const server = createServer(host);
  host.allowNat = true;
  const [clientTransport, serverTransport] =
    InMemoryTransport.createLinkedPair();
  const client = new Client({ name: "test", version: "0.0.0" });
  await Promise.all([
    server.connect(serverTransport),
    client.connect(clientTransport),
  ]);
  try {
    const denied = await client.callTool({
      name: "microvm_run",
      arguments: { name: "denied", network: "nat" },
    });
    assert.equal(denied.isError, true);
    for (const input of [
      { ttlSeconds: 86401 },
      { ttlSeconds: 0 },
      { ttlSeconds: 1.5 },
      { network: "public" },
    ]) {
      const result = await client.callTool({
        name: "microvm_run",
        arguments: { name: "bad", ...input },
      });
      assert.equal(result.isError, true);
    }
    assert.equal(daemon.runs.length, 0);
    const offline = await client.callTool({
      name: "microvm_run",
      arguments: { name: "offline", ttlSeconds: null },
    });
    assert.equal(offline.isError, undefined);
    assert.equal(daemon.runs[0]?.network, "none");
    assert.equal(daemon.runs[0]?.ttlSeconds, 1800);
  } finally {
    await client.close();
    await daemon.close();
  }
});

test("stdio entrypoint only enables NAT for the literal host environment value 1", async () => {
  for (const value of [undefined, "0", "true", "1"]) {
    const daemon = await fakeDaemon();
    const transport = new StdioClientTransport({
      command: process.execPath,
      args: [fileURLToPath(new URL("../dist/bin.js", import.meta.url))],
      env: {
        MICROVM_HOME: daemon.home,
        ...(value === undefined ? {} : { MICROVM_MCP_ALLOW_NAT: value }),
      },
    });
    const client = new Client({ name: "test", version: "0.0.0" });
    try {
      await client.connect(transport);
      const result = await client.callTool({
        name: "microvm_run",
        arguments: { name: "nat", network: "nat" },
      });
      assert.equal(result.isError === true, value !== "1");
      assert.equal(daemon.runs.length, value === "1" ? 1 : 0);
    } finally {
      await client.close();
      await daemon.close();
    }
  }
});
