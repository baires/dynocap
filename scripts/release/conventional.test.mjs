import assert from "node:assert/strict";
import test from "node:test";
import {
  bumpFromTitle,
  highestBump,
  nextVersion,
  replaceVersion,
  titlesSince,
  validatePrTitle,
} from "./conventional.mjs";

test("accepts conventional titles and rejects a trailing period", () => {
  assert.equal(validatePrTitle("fix: restore the guest image").valid, true);
  assert.equal(validatePrTitle("feat(cli): add doctor json").valid, true);
  assert.equal(validatePrTitle("feat!: drop the old flag").valid, true);
  assert.equal(validatePrTitle("chore: release v0.2.0").valid, true);
  assert.equal(validatePrTitle("Fix: nope").valid, false);
  assert.equal(validatePrTitle("fix: ends here.").valid, false);
  assert.equal(validatePrTitle("wip add a thing").valid, false);
});

test("fix is a patch, feat is a minor, and a bang is major", () => {
  assert.equal(bumpFromTitle("fix: close the fd"), "patch");
  assert.equal(bumpFromTitle("feat: add filtered egress"), "minor");
  assert.equal(bumpFromTitle("fix!: rename the flag"), "major");
  assert.equal(
    bumpFromTitle("feat(runtime)!: change the wire protocol"),
    "major"
  );
  assert.equal(bumpFromTitle("docs: correct the install line"), "none");
  assert.equal(bumpFromTitle("chore: release v0.2.0"), "none");
  assert.equal(bumpFromTitle("not a title"), "none");
});

test("the highest bump among merged titles wins", () => {
  assert.equal(highestBump(["fix: a", "docs: b", "fix: c"]), "patch");
  assert.equal(highestBump(["fix: a", "feat: b"]), "minor");
  assert.equal(highestBump(["feat: a", "fix!: b"]), "major");
  assert.equal(highestBump(["chore: tidy"]), "none");
});

test("next version resets the lower numbers", () => {
  assert.equal(nextVersion("0.1.0", "patch"), "0.1.1");
  assert.equal(nextVersion("0.1.4", "minor"), "0.2.0");
  assert.equal(nextVersion("0.2.3", "major"), "1.0.0");
  assert.equal(nextVersion("0.1.0", "none"), "0.1.0");
});

test("version replacement touches only DynoCapInfo.version", () => {
  const source =
    'public static let version = "0.1.0"\npublic static let protocolVersion: UInt32 = 1\n';
  assert.equal(
    replaceVersion(source, "0.2.0"),
    'public static let version = "0.2.0"\npublic static let protocolVersion: UInt32 = 1\n'
  );
});

test("titles since the version commit skip the release pull request", () => {
  const pulls = [
    {
      title: "fix: old",
      mergedAt: "2026-11-01T00:00:00Z",
      headRefName: "fix-old",
    },
    {
      title: "feat: new flag",
      mergedAt: "2026-11-20T00:00:00Z",
      headRefName: "feat-flag",
    },
    {
      title: "chore: release v0.2.0",
      mergedAt: "2026-11-21T00:00:00Z",
      headRefName: "release/next",
    },
    {
      title: "docs: readme",
      mergedAt: "2026-11-22T00:00:00Z",
      headRefName: "docs",
    },
  ];
  assert.deepEqual(titlesSince(pulls, Date.parse("2026-11-15T00:00:00Z")), [
    "feat: new flag",
    "docs: readme",
  ]);
});
