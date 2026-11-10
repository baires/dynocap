#!/usr/bin/env node
// Run against a deliberately selected checkout; online installation requires explicit NAT.
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { Task, Sandbox } from "../sdk/typescript/dist/index.js";

const revision = "d6de9f4b36f175b11586f89339689c1fe3c88805";
const lockfileHash =
  "de16b9dbcde39f75b41e7f5acc9a3a44af7a62ebc0ad077ecc51c5936843c129";
const [projectArgument, reportArgument] = process.argv.slice(2);
if (!projectArgument || !reportArgument || !process.env.MICROVM_HOME) {
  throw new Error(
    "MICROVM_HOME=PRIVATE_HOME node scripts/validate-node-task.mjs CHECKOUT REPORT.json"
  );
}
const projectPath = path.resolve(projectArgument);
const reportPath = path.resolve(reportArgument);
const hash = (bytes) => createHash("sha256").update(bytes).digest("hex");
assert.equal(
  execFileSync("git", ["-C", projectPath, "rev-parse", "HEAD"], {
    encoding: "utf8",
  }).trim(),
  revision
);
assert.equal(
  hash(fs.readFileSync(path.join(projectPath, "package-lock.json"))),
  lockfileHash
);
const sourceFile = path.join(projectPath, "helpers/time.ts");
const sourceHash = hash(fs.readFileSync(sourceFile));
fs.mkdirSync(path.dirname(reportPath), { recursive: true });
const marks = [];
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
let task, result, failure;
const checks = [];
try {
  task = await timed("start", () =>
    Task.start({ projectPath, network: "nat", ttlSeconds: 600 })
  );
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
assert.equal(
  hash(fs.readFileSync(sourceFile)),
  sourceHash,
  "source checkout changed"
);
assert(
  !(await Sandbox.list()).some((s) => s.name === task?.id),
  "sandbox still exists"
);
const report = {
  revision,
  lockfileHash,
  startedAt,
  totalMs,
  budgetMs: 180000,
  withinBudget: totalMs <= 180000,
  result,
  marks,
  checks,
  failure,
};
fs.writeFileSync(reportPath, JSON.stringify(report, null, 2) + "\n");
console.log(`total: ${(totalMs / 1000).toFixed(2)} seconds; ${reportPath}`);
if (failure || totalMs > 180000 || result?.phase !== "completed")
  process.exitCode = 1;
