#!/usr/bin/env node
// Requires an entitled CLI, prepared runtime, and a dedicated DYNOCAP_HOME.
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { Task, Sandbox } from "../sdk/typescript/dist/index.js";

const home = process.env.DYNOCAP_HOME;
assert(home, "use a dedicated DYNOCAP_HOME with a prepared runtime");
const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const binary = path.join(repo, ".build/release/dynocap");
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), "dynocap-task-smoke-"));
const project = path.join(scratch, "project");
fs.mkdirSync(project);
fs.writeFileSync(path.join(project, "before.txt"), "before\n");
fs.writeFileSync(path.join(project, "delete.txt"), "delete\n");
fs.writeFileSync(path.join(project, ".gitignore"), "ignored.log\n");
const options = { home, projectPath: project };
const pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
try {
  execFileSync(binary, ["ps"], { env: process.env });
  const before = await Sandbox.list({ home });
  await assert.rejects(
    Task.start({ ...options, runtimes: [{ name: "node", version: "24" }] }),
    /unsupported|unprepared/
  );
  assert.deepEqual(await Sandbox.list({ home }), before);
  const task = await Task.start(options);
  await assert.rejects(Task.start(options), /one task/);
  assert.equal(
    (
      await task.exec(
        "! touch /usr/dynocap-should-be-readonly && ! mount -o remount,rw /"
      )
    ).exitCode,
    0
  );
  const upload = path.join(scratch, "upload");
  fs.mkdirSync(upload);
  const payload = Buffer.alloc(900000);
  for (let i = 0; i < payload.length; i++) payload[i] = i % 256;
  fs.writeFileSync(path.join(upload, "payload"), payload, { mode: 0o755 });
  const sandbox = await Sandbox.connect(task.id, { home });
  await sandbox.upload(upload, "/work/transferred", { requireOffline: true });
  const downloaded = path.join(scratch, "download");
  await sandbox.download("/work/transferred", downloaded, {
    requireOffline: true,
  });
  assert.deepEqual(fs.readFileSync(path.join(downloaded, "payload")), payload);
  assert.equal(
    fs.statSync(path.join(downloaded, "payload")).mode & 0o777,
    0o755
  );
  assert.equal(
    (
      await task.exec(
        "printf 'after\\n' > before.txt; rm delete.txt; printf '\\000\\377' > binary; printf ignored > ignored.log; chmod +x before.txt; truncate -s 300M too-large"
      )
    ).exitCode,
    0
  );
  await assert.rejects(task.finish(), /limit|exceeds|failed/);
  assert.equal((await task.exec("rm too-large")).exitCode, 0);
  const result = await task.finish();
  assert.equal(result.phase, "completed");
  const changes = JSON.parse(
    fs.readFileSync(path.join(result.resultDirectory, "changes.json"))
  );
  assert(changes.some((c) => c.path === "delete.txt" && c.kind === "deleted"));
  assert(changes.some((c) => c.path === "before.txt" && c.mode === 0o755));
  assert(!changes.some((c) => c.path === "ignored.log"));
  assert.deepEqual(
    fs.readFileSync(path.join(result.resultDirectory, "files/binary")),
    Buffer.from([0, 255])
  );
  assert.equal((await task.finish()).resultDirectory, result.resultDirectory);
  assert(!fs.existsSync(path.join(home, "tasks", task.id, "workspace.ext4")));
  console.log(
    "PASS: runtime read-only, binary transfer/modes, admission, export failure/retry, review and idempotent finish"
  );
  const expired = await Task.start({ ...options, ttlSeconds: 3 });
  await expired.exec("echo retained-before-expiry");
  await pause(4000);
  assert(
    !fs.existsSync(path.join(home, "tasks", expired.id, "workspace.ext4"))
  );
  const interrupted = JSON.parse(
    fs.readFileSync(path.join(home, "tasks", expired.id, "task.json"))
  );
  assert.equal(interrupted.phase, "interrupted");
  await assert.rejects(expired.finish(), /interrupted/);
  console.log(
    "PASS: TTL retains interrupted record and logs, removes workspace"
  );
  const noisy = await Task.start(options);
  await assert.rejects(noisy.exec("head -c 34000000 /dev/zero"), /limit/);
  for (
    let i = 0;
    i < 20 && (await Sandbox.list({ home })).some((s) => s.name === noisy.id);
    i++
  )
    await pause(100);
  assert(!fs.existsSync(path.join(home, "tasks", noisy.id, "workspace.ext4")));
  assert(
    fs.statSync(path.join(home, "tasks", noisy.id, "0.stdout")).size <=
      32 * 1024 * 1024
  );
  console.log("PASS: log quota stops task and preserves bounded logs");
  const restarted = await Task.start(options);
  await restarted.exec("echo before-restart");
  const identity = JSON.parse(fs.readFileSync(path.join(home, "daemon.json")));
  process.kill(identity.pid, "SIGKILL");
  await pause(300);
  execFileSync(binary, ["ps"], { env: process.env });
  const recovered = JSON.parse(
    fs.readFileSync(path.join(home, "tasks", restarted.id, "task.json"))
  );
  assert.equal(recovered.phase, "interrupted");
  assert(
    !fs.existsSync(path.join(home, "tasks", restarted.id, "workspace.ext4"))
  );
  assert(fs.existsSync(path.join(home, "tasks", restarted.id, "0.stdout")));
  assert(fs.existsSync(path.join(result.resultDirectory, "manifest.json")));
  console.log(
    "PASS: daemon restart reaps workspace and preserves logs and published result"
  );
} finally {
  for (const record of await Sandbox.list({ home }))
    await (await Sandbox.connect(record.name, { home })).destroy();
  fs.rmSync(scratch, { recursive: true, force: true });
}
