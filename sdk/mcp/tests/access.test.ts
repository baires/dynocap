import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import { admitProjectPath, admitRepositoryUrl } from "../src/lib/access.ts";
import { dynocapTaskStart } from "../src/tools.ts";

test("project paths stay inside the configured roots", async () => {
  const root = await fs.realpath(
    await fs.mkdtemp(path.join(os.tmpdir(), "dynocap-roots-"))
  );
  const outside = await fs.realpath(
    await fs.mkdtemp(path.join(os.tmpdir(), "dynocap-outside-"))
  );
  try {
    await fs.mkdir(path.join(root, "app"));
    await fs.symlink(outside, path.join(root, "escape"));
    assert.equal(
      await admitProjectPath(path.join(root, "app"), { roots: [root] }),
      path.join(root, "app")
    );
    await assert.rejects(
      admitProjectPath(outside, { roots: [root] }),
      /outside the MCP project roots/
    );
    await assert.rejects(
      admitProjectPath(path.join(root, "escape"), { roots: [root] }),
      /outside the MCP project roots/,
      "a symlink inside a root does not reach outside it"
    );
  } finally {
    await fs.rm(root, { recursive: true, force: true });
    await fs.rm(outside, { recursive: true, force: true });
  }
});

test("the home directory and its dot directories are never importable", async () => {
  const home = os.homedir();
  const policy = { roots: [path.dirname(home)] };
  await assert.rejects(admitProjectPath(home, policy), /home directory/);
  await assert.rejects(
    admitProjectPath(path.dirname(home), policy),
    /home directory/
  );
  const ssh = path.join(home, ".ssh");
  if (await fs.stat(ssh).catch(() => undefined))
    await assert.rejects(admitProjectPath(ssh, policy), /dot directory/);
  const project = await fs.realpath(
    await fs.mkdtemp(path.join(os.tmpdir(), "dynocap-project-"))
  );
  try {
    await assert.rejects(
      admitProjectPath(project, { roots: [home] }),
      /no project roots/,
      "a root at the home directory is dropped"
    );
  } finally {
    await fs.rm(project, { recursive: true, force: true });
  }
});

test("repository hosts and ssh keys need the server's permission", async () => {
  admitRepositoryUrl("https://github.com/acme/app.git", {});
  admitRepositoryUrl("git@gitlab.com:acme/app.git", {});
  assert.throws(
    () => admitRepositoryUrl("https://attacker.example/x.git", {}),
    /not allowed by this MCP server/
  );
  admitRepositoryUrl("https://git.acme.internal/x.git", {
    gitHosts: ["git.acme.internal"],
  });
  const keyed = await dynocapTaskStart(
    {
      repositoryUrl: "git@github.com:acme/app.git",
      sshKeyPath: path.join(os.homedir(), ".aws", "credentials"),
      network: "nat",
    },
    { allowNat: true }
  );
  assert.equal(keyed.isError, true);
  assert.match(keyed.content[0].text, /DYNOCAP_MCP_ALLOW_SSH_KEY/);
  const home = await dynocapTaskStart({ projectPath: os.homedir() }, {});
  assert.equal(home.isError, true);
  assert.match(home.content[0].text, /home directory/);
});
