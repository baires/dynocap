#!/usr/bin/env node
// Decide the next DynoCap version from pull request titles merged after the
// commit that set DynoCapInfo.version. With --apply, write that version into
// Sources/DynoCapCore/Support.swift. Merging the result does not publish.

import { execFileSync } from "node:child_process";
import fs from "node:fs";
import {
  highestBump,
  nextVersion,
  replaceVersion,
  titlesSince,
} from "./conventional.mjs";

const VERSION_FILE = "Sources/DynoCapCore/Support.swift";

function git(args) {
  return execFileSync("git", args, { encoding: "utf8" }).trim();
}

function mergedPulls() {
  const output = execFileSync(
    "gh",
    [
      "pr",
      "list",
      "--state",
      "merged",
      "--base",
      "main",
      "--limit",
      "200",
      "--json",
      "title,mergedAt,headRefName",
    ],
    { encoding: "utf8" }
  );
  return JSON.parse(output);
}

export function planFromPulls(version, versionCommittedAt, pulls) {
  const titles = titlesSince(pulls, Date.parse(versionCommittedAt));
  const bump = highestBump(titles);
  const versionNext = nextVersion(version, bump);
  return { open: versionNext !== version, version: versionNext, bump, titles };
}

function readVersion(source) {
  const match = /public static let version = "([^"]+)"/.exec(source);
  if (!match) throw new Error("DynoCapInfo.version not found");
  return match[1];
}

function main() {
  const source = fs.readFileSync(VERSION_FILE, "utf8");
  const version = readVersion(source);
  const committedAt = git([
    "log",
    "-1",
    "--format=%cI",
    "-S",
    `public static let version = "${version}"`,
    "--",
    VERSION_FILE,
  ]);
  if (!committedAt)
    throw new Error(`no commit sets DynoCapInfo.version ${version}`);
  const plan = planFromPulls(version, committedAt, mergedPulls());
  if (plan.open && process.argv.includes("--apply")) {
    fs.writeFileSync(VERSION_FILE, replaceVersion(source, plan.version));
  }
  const lines = [
    `open=${plan.open}`,
    `version=${plan.version}`,
    `bump=${plan.bump}`,
  ];
  if (process.env.GITHUB_OUTPUT)
    fs.appendFileSync(process.env.GITHUB_OUTPUT, lines.join("\n") + "\n");
  console.log(
    plan.open
      ? `next version ${plan.version} (${plan.bump})`
      : `version stays ${version}`
  );
}

if (process.argv[1] && process.argv[1].endsWith("plan-version.mjs")) main();
