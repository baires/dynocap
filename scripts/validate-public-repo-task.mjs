#!/usr/bin/env node
// Public HTTPS clone inside a prepared Node task. Requires explicit NAT.
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { Task } from "../sdk/typescript/dist/index.js";

const repositoryUrl = "https://github.com/octocat/Hello-World.git";
const [reportArgument] = process.argv.slice(2);
if (!reportArgument || !process.env.MICROVM_HOME) {
  throw new Error(
    "MICROVM_HOME=PRIVATE_HOME node scripts/validate-public-repo-task.mjs REPORT.json"
  );
}
const reportPath = path.resolve(reportArgument);
fs.mkdirSync(path.dirname(reportPath), { recursive: true });

const task = await Task.start({
  repositoryUrl,
  ref: "master",
  runtimes: [{ name: "node", version: "24" }],
  network: "nat",
});
const head = await task.exec(["git", "rev-parse", "HEAD"]);
const revision = head.stdout.trim();
assert.equal(head.exitCode, 0);
assert.equal(revision, task.sourceRevision);
assert.match(revision, /^[0-9a-f]{40}$/);
const history = await task.exec(["test", "-d", "/workspace/.git"]);
assert.equal(history.exitCode, 0);
const result = await task.finish();
assert.equal(result.sourceRevision, revision);

function assertNoGit(directory) {
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    assert.notEqual(entry.name, ".git");
    if (entry.isDirectory()) assertNoGit(path.join(directory, entry.name));
  }
}
assertNoGit(result.resultDirectory);

const report = {
  repositoryUrl,
  sourceRevision: revision,
  resultDirectory: result.resultDirectory,
};
fs.writeFileSync(reportPath, JSON.stringify(report, null, 2));
console.log(JSON.stringify(report));
