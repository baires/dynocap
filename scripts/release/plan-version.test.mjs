import assert from "node:assert/strict";
import test from "node:test";
import { planFromPulls } from "./plan-version.mjs";

const after = "2026-11-15T00:00:00Z";

test("a fix merged after the version commit opens a patch", () => {
  const plan = planFromPulls("0.1.0", after, [
    {
      title: "fix: close the fd",
      mergedAt: "2026-11-16T00:00:00Z",
      headRefName: "fd",
    },
  ]);
  assert.deepEqual(plan, {
    open: true,
    version: "0.1.1",
    bump: "patch",
    titles: ["fix: close the fd"],
  });
});

test("a feature outranks a fix, and a bang outranks both", () => {
  const pulls = [
    { title: "fix: a", mergedAt: "2026-11-16T00:00:00Z", headRefName: "a" },
    { title: "feat: b", mergedAt: "2026-11-17T00:00:00Z", headRefName: "b" },
  ];
  assert.equal(planFromPulls("0.1.0", after, pulls).version, "0.2.0");
  pulls.push({
    title: "feat!: c",
    mergedAt: "2026-11-18T00:00:00Z",
    headRefName: "c",
  });
  assert.equal(planFromPulls("0.1.0", after, pulls).version, "1.0.0");
});

test("docs and the release pull request do not open another bump", () => {
  const plan = planFromPulls("0.2.0", after, [
    {
      title: "docs: install",
      mergedAt: "2026-11-16T00:00:00Z",
      headRefName: "docs",
    },
    {
      title: "chore: release v0.2.0",
      mergedAt: "2026-11-17T00:00:00Z",
      headRefName: "release/next",
    },
  ]);
  assert.equal(plan.open, false);
  assert.equal(plan.version, "0.2.0");
});
