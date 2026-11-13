import assert from "node:assert/strict";
import test from "node:test";
import { Task, Sandbox, listManaged, removeManaged } from "../src/index.ts";
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
    assert.deepEqual(task.runtimes, runtimes);
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
test("repository start accepts one source and keeps the token out of the task", async () => {
  const daemon = await fakeDaemon();
  try {
    await assert.rejects(
      Task.start({
        home: daemon.home,
        projectPath: ".",
        repositoryUrl: "https://github.com/org/repo.git",
      }),
      /projectPath or a repositoryUrl/
    );
    assert.equal(daemon.runs.length, 0);
    const task = await Task.start({
      home: daemon.home,
      repositoryUrl: "https://github.com/org/private.git",
      gitToken: "secret-token",
      ref: "main",
    });
    assert.equal(
      daemon.runs[0]?.repositoryUrl,
      "https://github.com/org/private.git"
    );
    assert.equal(daemon.runs[0]?.gitToken, "secret-token");
    assert.equal(daemon.runs[0]?.ref, "main");
    assert.equal(Object.hasOwn(daemon.runs[0] ?? {}, "projectPath"), false);
    assert.equal(task.sourceRevision, undefined);
    assert.equal(JSON.stringify(task).includes("secret-token"), false);
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

test("named task handles stay pinned after alias reuse and expose management operations", async () => {
  const behavior = { resolveID: "task-original" };
  const daemon = await fakeDaemon(behavior);
  try {
    const task = await Task.start({
      home: daemon.home,
      projectPath: ".",
      name: "interview",
    });
    assert.equal(task.name, "interview");
    assert.equal(daemon.runs[0]?.name, "interview");
    const opened = await Task.open("interview", {
      home: daemon.home,
      requireOffline: true,
      permitFiltered: false,
    });
    assert.equal(opened.id, "task-original");
    behavior.resolveID = "task-replacement";
    const preview = await opened.diff();
    assert.match(preview.patchPath, /changes.patch$/);
    assert.equal(daemon.runs.at(-1)?.id, "task-original");
    assert.equal(daemon.runs.at(-1)?.requireOffline, true);
    assert.equal(daemon.runs.at(-1)?.permitFiltered, false);
    await opened.remove();
    assert.equal(daemon.runs.at(-1)?.id, "task-original");
    assert.equal(daemon.runs.at(-1)?.purge, false);
    assert.equal(daemon.runs.at(-1)?.force, false);
    await opened.remove({ force: true, purge: false });
    assert.equal(daemon.runs.at(-1)?.force, true);
    assert.equal(daemon.runs.at(-1)?.purge, false);
    await removeManaged("interview", { home: daemon.home, purge: true });
    assert.equal(daemon.runs.at(-1)?.purge, true);
    assert.equal(daemon.runs.at(-1)?.force, false);
    assert.equal((await Task.list({ home: daemon.home })).length, 1);
    assert.equal((await listManaged({ home: daemon.home }))[0]?.kind, "task");
  } finally {
    await daemon.close();
  }
});
test("management and named starts fail clearly before sending operations to old daemons", async () => {
  const daemon = await fakeDaemon({ taskManagementVersion: null });
  try {
    const options = { home: daemon.home };
    await assert.rejects(
      Task.open("interview", options),
      /taskManagementVersion/
    );
    await assert.rejects(Task.list(options), /taskManagementVersion/);
    await assert.rejects(
      Task.start({ ...options, projectPath: ".", name: "interview" }),
      /taskManagementVersion/
    );
    await assert.rejects(
      Task.connect("task-old", options).diff(),
      /taskManagementVersion/
    );
    await assert.rejects(
      removeManaged("raw", options),
      /taskManagementVersion/
    );
    assert.equal(daemon.runs.length, 0);
    await Task.start({ ...options, projectPath: "." }); // Existing unnamed task interface still works.
  } finally {
    await daemon.close();
  }
});
