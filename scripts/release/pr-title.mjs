#!/usr/bin/env node
import { validatePrTitle } from "./conventional.mjs";

const title = process.argv[2] || process.env.PR_TITLE || "";
const result = validatePrTitle(title);
if (result.valid) {
  console.log("PR title is valid");
  process.exit(0);
}
console.error(`Invalid PR title: ${result.reason}`);
console.error(`Title: "${title}"`);
process.exit(1);
