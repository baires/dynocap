import assert from "node:assert/strict";
import test from "node:test";
import { fileURLToPath } from "node:url";

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";

import { Sandbox } from "@dynocap/sdk";

import { createServer } from "../src/index.ts";
import {
  dynocapDestroy,
  dynocapExec,
  dynocapPs,
  dynocapRun,
} from "../src/tools.ts";
import { fakeDaemon } from "../../typescript/tests/daemon.ts";

test("the server exposes sandbox and task tools", async () => {
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
      "dynocap_destroy",
      "dynocap_diff",
      "dynocap_exec",
      "dynocap_ls",
      "dynocap_ps",
      "dynocap_rm",
      "dynocap_run",
      "dynocap_task_exec",
      "dynocap_task_finish",
      "dynocap_task_start",
    ]);
    const exec = listed.tools.find((tool) => tool.name === "dynocap_exec");
    assert.match(exec?.description ?? "", /not a cloud sandbox/i);
  } finally {
    await client.close();
  }
});

test("mcp tools boot, exec, list, and destroy through the sandbox client", async () => {
  const daemon = await fakeDaemon();
  const home = { home: daemon.home };
  try {
    const created = await dynocapRun(
      { name: "demo", cpus: 2, memoryMB: 256, ttlSeconds: 30 },
      home
    );
    assert.equal(created.isError, undefined);
    assert.equal(created.content[0].text, "running demo");

    const exec = await dynocapExec(
      { name: "demo", command: "uname -a", cwd: "/workspace" },
      home
    );
    assert.equal(exec.content[0].text, "exit 0\nsh -c uname -a\n");
    assert.equal(daemon.execs[0]?.timeoutSeconds, 30);
    assert.equal(daemon.execs[0]?.cwd, "/workspace");

    const listed = await dynocapPs(home);
    assert.match(listed.content[0].text, /"name": "demo"/);
    assert.equal(listed.content[0].text.includes("daemonToken"), false);

    const removed = await dynocapDestroy("demo", home);
    assert.equal(removed.content[0].text, "destroyed demo");
    const after = await dynocapPs(home);
    assert.equal(after.content[0].text, "[]");
  } finally {
    await daemon.close();
  }
});

test("a missing sandbox and an exec deadline stay tool errors", async () => {
  const daemon = await fakeDaemon();
  const home = { home: daemon.home };
  try {
    await dynocapRun({ name: "demo" }, home);
    const missing = await dynocapExec({ name: "other", command: "true" }, home);
    assert.equal(missing.isError, true);
    assert.match(missing.content[0].text, /^not_found:/);

    const timed = await dynocapExec(
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
    await dynocapRun({ name: "demo" }, { home: daemon.home });
    const exec = await dynocapExec(
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
    const denied = await dynocapRun(
      { name: "denied", network: "nat" },
      { home: daemon.home }
    );
    assert.equal(denied.isError, true);
    assert.match(denied.content[0].text, /DYNOCAP_MCP_ALLOW_NAT=1/);
    assert.equal(daemon.runs.length, 0);
    const allowed = await dynocapRun(
      { name: "allowed", network: "nat" },
      { home: daemon.home, allowNat: true }
    );
    assert.equal(allowed.isError, undefined);
    assert.equal(daemon.runs[0]?.network, "nat");
  } finally {
    await daemon.close();
  }
});

test("filtered creation requires its own MCP host policy", async () => {
  const daemon = await fakeDaemon();
  try {
    const denied = await dynocapRun(
      { name: "denied", network: "filtered" },
      { home: daemon.home, allowNat: true }
    );
    assert.equal(denied.isError, true);
    assert.match(denied.content[0].text, /DYNOCAP_MCP_ALLOW_FILTERED=1/);
    assert.equal(daemon.runs.length, 0);
    const natStillDenied = await dynocapRun(
      { name: "nat", network: "nat" },
      { home: daemon.home, allowFiltered: true }
    );
    assert.equal(natStillDenied.isError, true);
    assert.match(natStillDenied.content[0].text, /DYNOCAP_MCP_ALLOW_NAT=1/);
    const allowed = await dynocapRun(
      { name: "allowed", network: "filtered" },
      { home: daemon.home, allowFiltered: true }
    );
    assert.equal(allowed.isError, undefined);
    assert.equal(daemon.runs[0]?.network, "filtered");
    assert.equal(daemon.runs[0]?.permitFiltered, undefined);
  } finally {
    await daemon.close();
  }
});

test("filtered exec permission does not follow NAT permission", async () => {
  const daemon = await fakeDaemon({ recordedNetwork: "filtered" });
  const home = { home: daemon.home };
  try {
    await Sandbox.create({ ...home, name: "existing", network: "filtered" });
    const deniedByNat = await dynocapExec(
      { name: "existing", command: "true" },
      { ...home, allowNat: true }
    );
    assert.equal(deniedByNat.isError, true);
    assert.match(deniedByNat.content[0].text, /DYNOCAP_MCP_ALLOW_FILTERED=1/);
    assert.equal(daemon.execs.length, 0);
    const deniedByFiltered = await dynocapExec(
      { name: "existing", command: "true" },
      { ...home, allowFiltered: true, allowNat: false }
    );
    assert.equal(deniedByFiltered.isError, undefined);
    const nat = await fakeDaemon({ recordedNetwork: "nat" });
    try {
      await Sandbox.create({ home: nat.home, name: "natbox", network: "nat" });
      const natDenied = await dynocapExec(
        { name: "natbox", command: "true" },
        { home: nat.home, allowFiltered: true }
      );
      assert.equal(natDenied.isError, true);
      assert.match(natDenied.content[0].text, /offline sandbox/);
      assert.equal(nat.execs.length, 0);
    } finally {
      await nat.close();
    }
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
      const denied = await dynocapExec(
        { name: "existing", command: "true" },
        home
      );
      assert.equal(denied.isError, true);
      assert.match(denied.content[0].text, /offline sandbox/);
      assert.equal(daemon.execs.length, 0);
      const allowed = await dynocapExec(
        { name: "existing", command: "true" },
        { ...home, allowNat: true }
      );
      assert.equal(allowed.isError, undefined);
      assert.equal((await dynocapPs(home)).isError, undefined);
      assert.equal((await dynocapDestroy("existing", home)).isError, undefined);
    } finally {
      await daemon.close();
    }
  }
});

test("daemon offline requirement protects MCP exec if networking changes after listing", async () => {
  const daemon = await fakeDaemon({ execNetwork: "nat" });
  const home = { home: daemon.home };
  try {
    await dynocapRun({ name: "replaced" }, home);
    const denied = await dynocapExec(
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
      name: "dynocap_run",
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
        name: "dynocap_run",
        arguments: { name: "bad", ...input },
      });
      assert.equal(result.isError, true);
    }
    assert.equal(daemon.runs.length, 0);
    const offline = await client.callTool({
      name: "dynocap_run",
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
        DYNOCAP_HOME: daemon.home,
        ...(value === undefined ? {} : { DYNOCAP_MCP_ALLOW_NAT: value }),
      },
    });
    const client = new Client({ name: "test", version: "0.0.0" });
    try {
      await client.connect(transport);
      const result = await client.callTool({
        name: "dynocap_run",
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

test("stdio entrypoint only enables filtered networking for the literal value 1", async () => {
  for (const value of [undefined, "0", "true", "1"]) {
    const daemon = await fakeDaemon();
    const transport = new StdioClientTransport({
      command: process.execPath,
      args: [fileURLToPath(new URL("../dist/bin.js", import.meta.url))],
      env: {
        DYNOCAP_HOME: daemon.home,
        DYNOCAP_MCP_ALLOW_NAT: "1",
        ...(value === undefined ? {} : { DYNOCAP_MCP_ALLOW_FILTERED: value }),
      },
    });
    const client = new Client({ name: "test", version: "0.0.0" });
    try {
      await client.connect(transport);
      const result = await client.callTool({
        name: "dynocap_run",
        arguments: { name: "filtered", network: "filtered" },
      });
      assert.equal(result.isError === true, value !== "1");
      assert.equal(daemon.runs.length, value === "1" ? 1 : 0);
    } finally {
      await client.close();
      await daemon.close();
    }
  }
});

test("task start keeps the daemon recovery command", async () => {
  const { dynocapTaskStart } = await import("../src/tools.ts");
  const daemon = await fakeDaemon({
    taskError:
      "dynocap-error-v1:" +
      JSON.stringify({
        code: "operation_failed",
        message: "runtime node:22 is not prepared yet",
        exitCode: 1,
        recovery:
          "Run dynocap doctor --fix --runtime node:22 with the same --home, then retry.",
      }),
  });
  try {
    const started = await dynocapTaskStart(
      {
        projectPath: ".",
        runtimes: [{ name: "node", version: "22" }],
      },
      { home: daemon.home }
    );
    assert.equal(started.isError, true);
    assert.match(
      started.content[0].text,
      /runtime node:22 is not prepared yet/
    );
    assert.match(
      started.content[0].text,
      /Next: Run dynocap doctor --fix --runtime node:22/
    );
  } finally {
    await daemon.close();
  }
});

test("task start reports the runtime the daemon selected", async () => {
  const { dynocapTaskStart } = await import("../src/tools.ts");
  const daemon = await fakeDaemon();
  try {
    const started = await dynocapTaskStart(
      {
        projectPath: ".",
        runtimes: [{ name: "python", version: "3.14" }],
      },
      { home: daemon.home }
    );
    assert.equal(started.isError, undefined);
    assert.match(started.content[0].text, /"runtime":"python:3.14"/);
  } finally {
    await daemon.close();
  }
});

test("task tools preserve MCP NAT permission and return retained result references", async () => {
  const { dynocapTaskStart, dynocapTaskExec, dynocapTaskFinish } =
    await import("../src/tools.ts");
  const daemon = await fakeDaemon();
  const options = { home: daemon.home };
  try {
    assert.equal(
      (await dynocapTaskStart({ projectPath: ".", network: "nat" }, options))
        .isError,
      true
    );
    assert.match(
      (
        await dynocapTaskStart(
          { projectPath: ".", network: "filtered" },
          options
        )
      ).content[0].text,
      /DYNOCAP_MCP_ALLOW_FILTERED=1|filtered networking is disabled/
    );
    const filtered = await dynocapTaskStart(
      { projectPath: ".", network: "filtered" },
      { ...options, allowFiltered: true }
    );
    assert.equal(filtered.isError, undefined);
    assert.equal(daemon.runs.at(-1)?.network, "filtered");
    assert.equal(daemon.runs.at(-1)?.permitFiltered, true);
    assert.equal(daemon.runs.at(-1)?.requireOffline, true);
    assert.equal(daemon.runs.length, 1);
    assert.equal(
      (await dynocapTaskStart({ projectPath: "." }, options)).isError,
      undefined
    );
    const privateStart = await dynocapTaskStart(
      {
        repositoryUrl: "https://github.com/org/private.git",
        gitToken: "secret-token",
      },
      options
    );
    assert.equal(privateStart.isError, undefined);
    assert.equal(privateStart.content[0].text.includes("secret-token"), false);
    assert.equal(daemon.runs.at(-1)?.gitToken, "secret-token");
    const result = await dynocapTaskExec(
      { name: "task-fake", command: "big" },
      options
    );
    assert.match(result.content[0].text, /logs:/);
    assert(Buffer.byteLength(result.content[0].text) <= 65536);
    const terminal = await dynocapTaskExec(
      { name: "task-fake", command: "vi", terminal: true },
      options
    );
    assert.match(
      terminal.content[0].text,
      /^exit 0\nlogs: .+\nterminal:\ntty: \r\n$/
    );
    assert.equal(terminal.content[0].text.includes("stderr:"), false);
    assert.deepEqual(daemon.execs.at(-1)?.terminal, { rows: 24, cols: 80 });
    assert.equal(daemon.execs.at(-1)?.cwd, "/workspace");
    const finished = await dynocapTaskFinish("task-fake", options);
    assert.equal(finished.isError, undefined);
    assert.match(finished.content[0].text, /"resultDirectory":"\/result"/);
    assert.match(finished.content[0].text, /"patch":"\/result\/changes.patch"/);
    assert.equal(daemon.runs.at(-1)?.requireOffline, true);
  } finally {
    await daemon.close();
  }
});

test("named management tools return bounded previews, host paths, and explicit policy", async () => {
  const fs = await import("node:fs");
  const path = await import("node:path");
  const { dynocapTaskStart, dynocapDiff, dynocapLs, dynocapRm } =
    await import("../src/tools.ts");
  const daemon = await fakeDaemon();
  const options = { home: daemon.home, allowFiltered: true };
  try {
    const created = await dynocapTaskStart(
      { name: "interview", projectPath: ".", network: "filtered" },
      options
    );
    assert.match(created.content[0].text, /interview/);
    const directory = path.join(daemon.home, "preview");
    fs.mkdirSync(directory);
    fs.writeFileSync(path.join(directory, "changes.patch"), "é".repeat(100000));
    const preview = await dynocapDiff("interview", options);
    assert.equal(preview.isError, undefined);
    assert.match(preview.content[0].text, /patchPath/);
    assert.match(preview.content[0].text, /output truncated/);
    assert(Buffer.byteLength(preview.content[0].text) <= 64 * 1024);
    assert.equal(daemon.runs.at(-1)?.op, "diff");
    assert.equal(daemon.runs.at(-1)?.requireOffline, true);
    assert.equal(daemon.runs.at(-1)?.permitFiltered, true);
    assert.match((await dynocapLs(options)).content[0].text, /"kind": "task"/);
    await dynocapRm("interview", false, options);
    assert.equal(daemon.runs.at(-1)?.purge, false);
    assert.equal(daemon.runs.at(-1)?.force, false);
    await dynocapRm("interview", false, options, true);
    assert.equal(daemon.runs.at(-1)?.force, true);
    assert.equal(daemon.runs.at(-1)?.purge, false);
    await dynocapRm("task-fake", true, options);
    assert.equal(daemon.runs.at(-1)?.purge, true);
    assert.equal(daemon.runs.at(-1)?.force, false);
  } finally {
    await daemon.close();
  }
});

test("terminal exec returns one labeled transcript at a fixed size", async () => {
  const daemon = await fakeDaemon();
  const home = { home: daemon.home };
  try {
    await dynocapRun({ name: "demo", cpus: 1, memoryMB: 256 }, home);
    const result = await dynocapExec(
      { name: "demo", command: "top -b -n 1", terminal: true },
      home
    );
    assert.equal(result.isError, undefined);
    assert.equal(result.content[0].text, "exit 0\nterminal:\ntty: \r\n");
    assert.deepEqual(daemon.execs.at(-1)?.terminal, { rows: 24, cols: 80 });
    await dynocapExec({ name: "demo", command: "true" }, home);
    assert.equal(daemon.execs.at(-1)?.terminal, undefined);
  } finally {
    await daemon.close();
  }
  const old = await fakeDaemon({ execTerminalVersion: null });
  try {
    await dynocapRun(
      { name: "demo", cpus: 1, memoryMB: 256 },
      { home: old.home }
    );
    const refused = await dynocapExec(
      { name: "demo", command: "top", terminal: true },
      { home: old.home }
    );
    assert.equal(refused.isError, true);
    assert.match(refused.content[0].text, /cannot allocate guest terminals/);
  } finally {
    await old.close();
  }
});
