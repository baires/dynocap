#!/usr/bin/env node
// Public URL run of the pinned shouldideploy commit. The task uses filtered egress.
// One later NAT task checks that NAT can still reach a name the filter denies.
// Runtime preparation, image download, and the Swift build stay outside this
// process and outside totalMs.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { Task, Sandbox } from "../sdk/typescript/dist/index.js";

const repositoryUrl = "https://github.com/baires/shouldideploy.git";
const revision = "d6de9f4b36f175b11586f89339689c1fe3c88805";
const expectedLockfileHash =
  "de16b9dbcde39f75b41e7f5acc9a3a44af7a62ebc0ad077ecc51c5936843c129";
const checkout = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  ".."
);
const [reportArgument] = process.argv.slice(2);
if (!reportArgument || !process.env.MICROVM_HOME) {
  throw new Error(
    "MICROVM_HOME=PRIVATE_HOME node scripts/validate-public-node-task.mjs REPORT.json\nREPORT.json and MICROVM_HOME must be outside this checkout or under validation/"
  );
}
const reportPath = path.resolve(reportArgument);
const homePath = path.resolve(process.env.MICROVM_HOME);
for (const target of [reportPath, homePath]) {
  if (!allowedSidePath(target)) {
    throw new Error(
      `${target} must be outside this checkout or under validation/`
    );
  }
}

function allowedSidePath(target) {
  const relative = path.relative(checkout, path.resolve(target));
  const outside =
    relative === ".." ||
    relative.startsWith(`..${path.sep}`) ||
    path.isAbsolute(relative);
  return (
    outside ||
    relative === "validation" ||
    relative.startsWith(`validation${path.sep}`)
  );
}

function checkoutSnapshot() {
  const head = execFileSync("git", ["-C", checkout, "rev-parse", "HEAD"], {
    encoding: "utf8",
  });
  const status = execFileSync(
    "git",
    ["-C", checkout, "status", "--porcelain=v1", "--untracked-files=all"],
    { encoding: "utf8" }
  );
  return `${head}${status}`;
}

function assertNoGit(directory) {
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    assert.notEqual(entry.name, ".git");
    if (entry.isDirectory()) assertNoGit(path.join(directory, entry.name));
  }
}

const sourceSnapshot = checkoutSnapshot();
const denyScript =
  "const net = require('net');\nconst targets = [['169.254.169.254', 80], ['10.1.2.3', 443], ['192.168.1.1', 443]];\nlet left = targets.length;\nconst opened = [];\nfor (const [host, port] of targets) {\n  const socket = net.connect({ host, port });\n  const finish = (open) => {\n    socket.destroy();\n    if (open) opened.push(host + ':' + port);\n    if (--left === 0) {\n      if (opened.length) { console.error(opened.join(',')); process.exit(1); }\n      process.exit(0);\n    }\n  };\n  socket.setTimeout(3000);\n  socket.once('connect', () => finish(true));\n  socket.once('timeout', () => finish(false));\n  socket.once('error', () => finish(false));\n}\n";
const nxScript =
  "require('dns').lookup('example.com', (error) => process.exit(error ? 0 : 1));";
const natScript =
  "const net = require('net');\nconst socket = net.connect(443, 'example.com');\nsocket.setTimeout(8000);\nsocket.once('connect', () => { socket.end(); process.exit(0); });\nsocket.once('timeout', () => process.exit(2));\nsocket.once('error', (error) => { console.error(error.message); process.exit(3); });\n";
fs.mkdirSync(path.dirname(reportPath), { recursive: true });
const marks = [];
const probes = [];
const startedAt = new Date().toISOString();
const started = performance.now();
async function timed(label, operation) {
  const start = performance.now();
  try {
    const result = await operation();
    marks.push({
      label,
      ms: performance.now() - start,
      exitCode: result?.exitCode,
    });
    console.log(
      `${label}: ${Math.round(marks.at(-1).ms)} ms${result?.exitCode === undefined ? "" : `, exit ${result.exitCode}`}`
    );
    return result;
  } catch (error) {
    marks.push({ label, ms: performance.now() - start, error: String(error) });
    throw error;
  }
}
async function probe(label, operation) {
  const start = performance.now();
  try {
    const result = await operation();
    const ms = performance.now() - start;
    probes.push({ label, ms, exitCode: result?.exitCode });
    console.log(
      `probe ${label}: ${Math.round(ms)} ms, exit ${result?.exitCode}`
    );
    return result;
  } catch (error) {
    probes.push({
      label,
      ms: performance.now() - start,
      error: String(error),
    });
    throw error;
  }
}
let task, result, failure, headRevision, measuredLockfileHash;
const checks = [];
try {
  task = await timed("start", () =>
    Task.start({
      repositoryUrl,
      ref: revision,
      runtimes: [{ name: "node", version: "24" }],
      network: "filtered",
      ttlSeconds: 600,
    })
  );
  const head = await probe("git rev-parse HEAD", () =>
    task.exec(["git", "rev-parse", "HEAD"])
  );
  assert.equal(head.exitCode, 0);
  headRevision = head.stdout.trim();
  assert.equal(headRevision, task.sourceRevision);
  assert.equal(headRevision, revision);
  const history = await probe("test -d /workspace/.git", () =>
    task.exec(["test", "-d", "/workspace/.git"])
  );
  assert.equal(history.exitCode, 0);
  const lock = await probe("package-lock.json", () =>
    task.exec([
      "node",
      "-e",
      "const fs=require('node:fs');const {createHash}=require('node:crypto');process.stdout.write(createHash('sha256').update(fs.readFileSync('/workspace/package-lock.json')).digest('hex'))",
    ])
  );
  assert.equal(lock.exitCode, 0);
  measuredLockfileHash = lock.stdout.trim();
  assert.equal(measuredLockfileHash, expectedLockfileHash);
  for (const label of ["npm ci", "jest before"]) {
    const command = label === "npm ci" ? "npm ci" : "npm test -- --runInBand";
    const check = await timed(label, () =>
      task.exec(command, { env: { CI: "1", TZ: "UTC" } })
    );
    checks.push({ label, ...check });
    assert.equal(
      check.exitCode,
      0,
      `${label} failed; see ${check.logDirectory}`
    );
    if (label === "npm ci") {
      const blocked = await timed("filtered deny", () =>
        task.exec(["node", "-e", denyScript])
      );
      assert.equal(blocked.exitCode, 0, blocked.stderr);
      const foreign = await timed("filtered nxdomain", () =>
        task.exec(["node", "-e", nxScript])
      );
      assert.equal(foreign.exitCode, 0, foreign.stderr);
    }
  }
  const edit = `const fs = require('node:fs'); const file = '/workspace/helpers/time.ts'; const source = fs.readFileSync(file,'utf8'); const needle = "    this.customDate = new Date(customDate + 'T00:00:00Z')\\n"; if (source.split(needle).length !== 2) throw Error('constructor mismatch'); fs.writeFileSync(file,source.replace(needle,''));`;
  const applied = await timed("edit", () => task.exec(["node", "-e", edit]));
  assert.equal(applied.exitCode, 0);
  const after = await timed("jest after", () =>
    task.exec("npm test -- --runInBand", { env: { CI: "1", TZ: "UTC" } })
  );
  checks.push({ label: "jest after", ...after });
  assert.equal(after.exitCode, 0);
} catch (error) {
  failure = String(error);
} finally {
  if (task) {
    try {
      result = await timed("finish", () => task.finish());
    } catch (error) {
      failure = `${failure ?? ""}\n${error}`;
    }
  }
}
const totalMs = performance.now() - started;
const findings = [];
try {
  if (result?.resultDirectory) {
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
    assertNoGit(result.resultDirectory);
    assertNoGit(retained);
  }
  if (!failure) {
    assert.equal(result?.phase, "completed");
    assert.equal(result?.sourceRevision, revision);
    assert.equal(typeof result?.resultDirectory, "string");
    const retained = result.retainedCopy;
    assert.equal(typeof retained, "string");
    assert(fs.existsSync(path.join(retained, "manifest.json")));
    const changes = JSON.parse(
      fs.readFileSync(path.join(retained, "changes.json"), "utf8")
    );
    assert.deepEqual(
      changes.map((change) => [change.path, change.kind]),
      [["helpers/time.ts", "modified"]]
    );
    const exported = fs.readFileSync(
      path.join(retained, "files/helpers/time.ts"),
      "utf8"
    );
    assert(
      !exported.includes(
        "    this.customDate = new Date(customDate + 'T00:00:00Z')"
      )
    );
    for (const command of JSON.parse(
      fs.readFileSync(path.join(retained, "manifest.json"), "utf8")
    ).commands)
      assert.equal(command.exitCode, 0);
  }
} catch (error) {
  findings.push(String(error));
}
try {
  assert.equal(checkoutSnapshot(), sourceSnapshot, "script checkout changed");
  const sandboxes = await Sandbox.list();
  const leftover = task?.id
    ? sandboxes.some((sandbox) => sandbox.name === task.id)
    : sandboxes.length > 0;
  assert.equal(leftover, false, "sandbox still exists");
} catch (error) {
  findings.push(String(error));
}
if (findings.length > 0)
  failure = [failure, ...findings].filter(Boolean).join("\n");
let natProbe;
try {
  const probeDir = fs.mkdtempSync(
    path.join(path.dirname(reportPath), "nat-probe-")
  );
  const natTask = await Task.start({
    projectPath: probeDir,
    network: "nat",
    ttlSeconds: 180,
    runtimes: [{ name: "node", version: "24" }],
  });
  try {
    natProbe = await natTask.exec(["node", "-e", natScript]);
    assert.equal(natProbe.exitCode, 0, natProbe.stderr || natProbe.stdout);
  } finally {
    await natTask.finish();
  }
} catch (error) {
  failure = [failure, `NAT regression: ${error}`].filter(Boolean).join("\n");
}
const report = {
  repositoryUrl,
  network: "filtered",
  natProbe: natProbe
    ? { exitCode: natProbe.exitCode, stderr: natProbe.stderr }
    : undefined,
  ref: revision,
  revision,
  ...(measuredLockfileHash === undefined
    ? {}
    : { lockfileHash: measuredLockfileHash }),
  headRevision,
  sourceRevision: result?.sourceRevision ?? task?.sourceRevision,
  startedAt,
  totalMs,
  budgetMs: 180000,
  withinBudget: totalMs <= 180000,
  result,
  marks,
  probes,
  checks,
  failure,
};
fs.writeFileSync(reportPath, JSON.stringify(report, null, 2) + "\n");
if (failure) console.error(failure);
console.log(`total: ${(totalMs / 1000).toFixed(2)} seconds; ${reportPath}`);
if (failure || totalMs > 180000 || result?.phase !== "completed")
  process.exitCode = 1;
