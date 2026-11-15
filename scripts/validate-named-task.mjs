#!/usr/bin/env node
// Owns a private daemon. Prepare its runtime first, then stop that daemon before
// invoking this harness. Never point DYNOCAP_HOME at your everyday daemon.
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { createHash } from "node:crypto";
import {
  Task,
  Sandbox,
  listManaged,
  removeManaged,
} from "../sdk/typescript/dist/index.js";
import { dynocapDiff, dynocapLs } from "../sdk/mcp/dist/tools.js";

const home = process.env.DYNOCAP_HOME;
const reportArgument = process.argv[2];
if (!home || !reportArgument)
  throw Error(
    "DYNOCAP_HOME=PRIVATE_HOME node scripts/validate-named-task.mjs REPORT.json"
  );
const binary = path.resolve(
  process.env.DYNOCAP_BIN ?? ".build/release/dynocap"
);
const reportPath = path.resolve(reportArgument);
assert(
  !fs.existsSync(path.join(home, "daemon.sock")),
  "stop the private validation daemon first"
);
fs.mkdirSync(path.dirname(reportPath), { recursive: true });
const revision = "d6de9f4b36f175b11586f89339689c1fe3c88805";
const lockfileHash =
  "de16b9dbcde39f75b41e7f5acc9a3a44af7a62ebc0ad077ecc51c5936843c129";
const marks = [];
let daemon, task, result, failure, totalMs, restartFiles, startupCancelled;
function command(args) {
  return new Promise((resolve, reject) => {
    const child = spawn(binary, ["--home", home, ...args]);
    let stdout = "",
      stderr = "";
    child.stdout.on("data", (chunk) => (stdout += chunk));
    child.stderr.on("data", (chunk) => (stderr += chunk));
    child.once("error", reject);
    child.once("close", (exitCode, signal) =>
      resolve({ stdout, stderr, exitCode, signal })
    );
  });
}
async function run(label, args) {
  const start = performance.now();
  const outcome = await command(args);
  marks.push({ label, ms: performance.now() - start, ...outcome });
  console.log(
    `${label}: ${Math.round(marks.at(-1).ms)} ms, exit ${outcome.exitCode}`
  );
  assert.equal(outcome.exitCode, 0, `${label}: ${outcome.stderr}`);
  return outcome.stdout;
}
async function startDaemon() {
  const fd = fs.openSync(
    path.join(path.dirname(reportPath), "named-daemon.log"),
    "a"
  );
  daemon = spawn(binary, ["--home", home, "daemon"], {
    stdio: ["ignore", fd, fd],
  });
  fs.closeSync(fd);
  const deadline = Date.now() + 15000;
  while (Date.now() < deadline) {
    if (daemon.exitCode !== null)
      throw Error("private daemon exited during startup");
    try {
      await Task.list({ home });
      return;
    } catch {
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
  }
  throw Error("private daemon did not become ready");
}
async function stopDaemon() {
  if (!daemon || daemon.exitCode !== null || daemon.signalCode !== null) return;
  const exited = once(daemon, "exit");
  daemon.kill("SIGTERM");
  await exited;
}
function fingerprints(directory) {
  return Object.fromEntries(
    fs
      .readdirSync(directory, { recursive: true, withFileTypes: true })
      .filter((entry) => entry.isFile())
      .map((entry) => {
        const file = path.join(entry.parentPath, entry.name);
        return [
          path.relative(directory, file),
          createHash("sha256").update(fs.readFileSync(file)).digest("hex"),
        ];
      })
  );
}
try {
  await startDaemon();
  const started = performance.now();
  const created = JSON.parse(
    await run("clone", [
      "clone",
      "https://github.com/baires/shouldideploy.git",
      "interview",
      "--network",
      "filtered",
      "--ref",
      revision,
      "--ttl",
      "600",
    ])
  );
  task = await Task.open("interview", { home, permitFiltered: true });
  assert.equal(task.id, created.id);
  assert.equal(created.sourceRevision, revision);
  const entries = JSON.parse(await run("ls", ["ls", "--json"]));
  assert.equal(entries.length, 1);
  assert.equal(entries[0].name, "interview");
  assert.equal(entries[0].kind, "task");
  assert(entries[0].expiresAtUnix <= Date.now() / 1000 + 601);
  assert.equal((await Task.list({ home }))[0].id, task.id);
  assert.equal((await listManaged({ home }))[0].id, task.id);
  assert.match((await dynocapLs({ home })).content[0].text, /interview/);
  await run("npm ci", [
    "exec",
    "interview",
    "--timeout",
    "120",
    "--env",
    "CI=1",
    "--env",
    "TZ=UTC",
    "--",
    "npm",
    "ci",
  ]);
  const tests = (label) =>
    run(label, [
      "exec",
      "interview",
      "--timeout",
      "30",
      "--env",
      "CI=1",
      "--env",
      "TZ=UTC",
      "--",
      "npm",
      "test",
      "--",
      "--runInBand",
    ]);
  await tests("jest before");
  const edit = `const fs=require('fs');const p='/workspace/helpers/time.ts';const s=fs.readFileSync(p,'utf8');const n="    this.customDate = new Date(customDate + 'T00:00:00Z')\\n";if(s.split(n).length!==2)throw Error('constructor mismatch');fs.writeFileSync(p,s.replace(n,''));`;
  await run("edit", ["exec", "interview", "--", "node", "-e", edit]);
  await tests("jest after");
  const patch = await run("diff", ["diff", "interview"]);
  assert.match(patch, /^diff --git a\/helpers\/time.ts b\/helpers\/time.ts$/m);
  assert.match(patch, /^-    this.customDate = new Date/m);
  const preview = await task.diff();
  assert.equal(fs.readFileSync(preview.patchPath, "utf8"), patch);
  assert.equal((await dynocapDiff("interview", { home })).isError, true);
  const mcpPreview = await dynocapDiff("interview", {
    home,
    allowFiltered: true,
  });
  assert.equal(mcpPreview.isError, undefined);
  assert.match(mcpPreview.content[0].text, /patchPath/);
  const lock = await task.exec([
    "node",
    "-e",
    "const fs=require('fs');process.stdout.write(require('crypto').createHash('sha256').update(fs.readFileSync('package-lock.json')).digest('hex'))",
  ]);
  assert.equal(lock.exitCode, 0);
  assert.equal(lock.stdout, lockfileHash);
  result = JSON.parse(await run("finish", ["finish", "interview"]));
  assert.equal(result.phase, "completed");
  assert.equal(
    fs.readFileSync(path.join(result.resultDirectory, "changes.patch"), "utf8"),
    patch
  );
  assert.deepEqual(
    JSON.parse(
      fs.readFileSync(path.join(result.resultDirectory, "changes.json"))
    ).map((c) => c.path),
    ["helpers/time.ts"]
  );
  assert.equal(fs.existsSync(preview.directory), false);
  const before = fingerprints(result.resultDirectory);
  await run("rm", ["rm", "interview"]);
  totalMs = performance.now() - started;
  assert(totalMs <= 180000, `acceptance exceeded 180 seconds: ${totalMs}`);
  assert.deepEqual(await Sandbox.list({ home }), []);
  await assert.rejects(Task.open("interview", { home }));
  assert.deepEqual(fingerprints(result.resultDirectory), before);
  const retained = path.join(
    path.dirname(reportPath),
    path.basename(reportPath, ".json") + "-result"
  );
  fs.cpSync(result.resultDirectory, retained, {
    recursive: true,
    errorOnExist: true,
    force: false,
  });
  result.retainedCopy = retained;
  await stopDaemon();
  await startDaemon();
  assert.equal(
    (await Task.connect(task.id, { home }).finish()).resultDirectory,
    result.resultDirectory
  );
  assert.deepEqual(fingerprints(result.resultDirectory), before);
  restartFiles = Object.keys(before).length;
  const empty = fs.mkdtempSync(
    path.join(path.dirname(reportPath), "named-empty-")
  );
  const replacement = JSON.parse(
    await run("reuse name", ["clone", empty, "interview", "--ttl", "120"])
  );
  assert.notEqual(replacement.id, task.id);
  assert.equal((await task.diff()).directory, result.resultDirectory); // Pinned old handle.
  await task.remove({ purge: true });
  assert.equal(fs.existsSync(result.resultDirectory), false);
  assert.equal((await Task.open("interview", { home })).id, replacement.id);
  const replacementTask = await Task.open("interview", { home });
  const waiting = replacementTask.exec("sleep 30");
  const cancelled = assert.rejects(waiting);
  await new Promise((resolve) => setTimeout(resolve, 100));
  await run("remove replacement", ["rm", "interview", "--purge"]);
  await cancelled;
  assert.deepEqual(await listManaged({ home }), []);
  const pending = Task.start({
    home,
    projectPath: empty,
    name: "boot-cancel",
    ttlSeconds: 120,
  }).then(
    (value) => ({ value }),
    (error) => ({ error })
  );
  const deadline = Date.now() + 15000;
  let observedStarting = false;
  while (Date.now() < deadline && !observedStarting) {
    for (const directory of fs.readdirSync(path.join(home, "tasks"))) {
      try {
        const record = JSON.parse(
          fs.readFileSync(
            path.join(home, "tasks", directory, "task.json"),
            "utf8"
          )
        );
        if (record.name === "boot-cancel" && record.phase === "starting")
          observedStarting = true;
      } catch {
        /* A record can be published between polls. */
      }
    }
    if (!observedStarting)
      await new Promise((resolve) => setTimeout(resolve, 5));
  }
  assert(observedStarting, "did not observe the startup cancellation window");
  await removeManaged("boot-cancel", { home, purge: true });
  const cancelledStart = await pending;
  assert(
    "error" in cancelledStart,
    "removed task unexpectedly finished booting"
  );
  assert.deepEqual(await listManaged({ home }), []);
  assert.deepEqual(await Sandbox.list({ home }), []);
  startupCancelled = true;
} catch (error) {
  failure = String(error?.stack ?? error);
  if (task && !result) {
    try {
      result = await task.finish();
    } catch {
      /* Keep the original failure. */
    }
  }
} finally {
  await stopDaemon();
  fs.writeFileSync(
    reportPath,
    JSON.stringify(
      {
        revision,
        lockfileHash,
        totalMs,
        budgetMs: 180000,
        withinBudget: totalMs <= 180000,
        restartFiles,
        startupCancelled,
        result,
        marks,
        failure,
      },
      null,
      2
    ) + "\n"
  );
}
console.log(
  `total: ${totalMs === undefined ? "incomplete" : (totalMs / 1000).toFixed(2)} s; ${reportPath}`
);
if (failure) {
  console.error(failure);
  process.exitCode = 1;
}
