import assert from "node:assert/strict";
import test from "node:test";
import { Task, Sandbox } from "../src/index.ts";
import { fakeDaemon } from "./daemon.ts";

test("task defaults, bounded capture, finish and opaque runtime selection", async () => {
  const daemon = await fakeDaemon();
  try {
    const runtimes = [{ name: "node", version: "22" }];
    const task = await Task.start({
      home: daemon.home,
      projectPath: ".",
      runtimes,
      requireOffline: true,
    });
    assert.deepEqual(daemon.runs[0]?.runtimes, runtimes);
    assert.equal(daemon.runs[0]?.requireOffline, true);
    let streamed = 0;
    const result = await task.exec("big", {
      onStdout: (chunk) => (streamed += chunk.length),
    });
    assert.equal(result.stdout.length, 32768);
    assert.equal(streamed, 200000);
    assert.equal(result.outputTruncated, true);
    assert.equal(daemon.execs[0]?.cwd, "/workspace");
    assert.equal(daemon.execs[0]?.timeoutSeconds, 300);
    const finished = await task.finish();
    assert.equal(finished.resultDirectory, "/result");
    assert.equal(daemon.runs.at(-1)?.requireOffline, true);
  } finally {
    await daemon.close();
  }
});
test("older daemons reject task creation before sending start", async () => {
  const daemon = await fakeDaemon({ taskVersion: null });
  try {
    await assert.rejects(
      Task.start({ home: daemon.home, projectPath: "." }),
      /lacks taskVersion/
    );
    assert.equal(daemon.runs.length, 0);
  } finally {
    await daemon.close();
  }
});
test("directory transfer uses the same client and offline requirement", async () => {
  const daemon = await fakeDaemon();
  try {
    const sandbox = await Sandbox.create({ home: daemon.home, name: "files" });
    await sandbox.upload(".", "/workspace", { requireOffline: true });
    await sandbox.download("/workspace", "./output", { requireOffline: true });
    assert.equal(daemon.runs.at(-2)?.direction, "upload");
    assert.equal(daemon.runs.at(-1)?.direction, "download");
    assert.equal(daemon.runs.at(-1)?.requireOffline, true);
  } finally {
    await daemon.close();
  }
});
