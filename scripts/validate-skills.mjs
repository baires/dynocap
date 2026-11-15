#!/usr/bin/env node
// Checks each skills/*/SKILL.md against the Agent Skills specification
// (https://agentskills.io/specification) without network or dependencies.
import fs from "node:fs";
import path from "node:path";

const root = path.resolve(process.argv[2] ?? "skills");
const allowed = new Set([
  "name",
  "description",
  "license",
  "compatibility",
  "metadata",
  "allowed-tools",
]);

function parseFrontmatter(text) {
  const match = /^---\n([\s\S]*?)\n---\n/.exec(text);
  if (!match) throw new Error("missing --- frontmatter at the top of the file");
  const fields = {};
  const lines = match[1].split("\n");
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (line.trim() === "" || line.trimStart().startsWith("#")) continue;
    const field = /^([A-Za-z0-9_-]+):(?:\s+(.*))?$/.exec(line);
    if (!field) throw new Error(`unrecognized frontmatter line: ${line}`);
    const [, key, raw = ""] = field;
    const block = [];
    while (i + 1 < lines.length && /^\s+\S/.test(lines[i + 1]))
      block.push(lines[++i].trim());
    if (/^[>|]-?$/.test(raw)) {
      fields[key] = block.join(raw.startsWith(">") ? " " : "\n");
    } else if (raw === "" && block.length > 0) {
      fields[key] = Object.fromEntries(
        block.map((entry) => {
          const pair = /^([^:]+):\s*(.*)$/.exec(entry);
          if (!pair)
            throw new Error(`${key}: expected "key: value", got ${entry}`);
          return [pair[1].trim(), unquote(pair[2])];
        })
      );
    } else {
      fields[key] = unquote(raw);
    }
  }
  return { fields, body: text.slice(match[0].length) };
}

function unquote(value) {
  return value.replace(/^(["'])(.*)\1$/, "$2");
}

function validate(dir) {
  const errors = [];
  const file = path.join(dir, "SKILL.md");
  const text = fs.readFileSync(file, "utf8");
  const { fields, body } = parseFrontmatter(text);
  for (const key of Object.keys(fields))
    if (!allowed.has(key)) errors.push(`unknown frontmatter field "${key}"`);

  const name = fields.name ?? "";
  if (!/^[a-z0-9]+(-[a-z0-9]+)*$/.test(name) || name.length > 64)
    errors.push(
      "name must be 1-64 lowercase letters, digits, and single hyphens, not starting or ending with a hyphen"
    );
  if (name !== path.basename(dir))
    errors.push(
      `name "${name}" must match its directory "${path.basename(dir)}"`
    );

  const description = fields.description ?? "";
  if (
    typeof description !== "string" ||
    description.trim() === "" ||
    description.length > 1024
  )
    errors.push("description must be 1-1024 characters");
  if (fields.compatibility !== undefined && fields.compatibility.length > 500)
    errors.push("compatibility must be at most 500 characters");
  if (fields.metadata !== undefined && typeof fields.metadata !== "object")
    errors.push("metadata must map string keys to string values");

  const lines = text.split("\n").length;
  if (lines > 500)
    errors.push(`SKILL.md has ${lines} lines; keep it under 500`);

  for (const [, target] of body.matchAll(/\]\(([^)\s]+)\)/g)) {
    if (/^[a-z]+:|^#|^\//.test(target)) continue;
    if (!fs.existsSync(path.join(dir, target.split("#")[0])))
      errors.push(`broken relative link: ${target}`);
  }
  return errors;
}

const dirs = fs
  .readdirSync(root, { withFileTypes: true })
  .filter((entry) => entry.isDirectory())
  .map((entry) => path.join(root, entry.name));
let failed = false;
for (const dir of dirs) {
  let errors;
  try {
    errors = validate(dir);
  } catch (error) {
    errors = [error.message];
  }
  for (const error of errors)
    console.error(`${path.relative(process.cwd(), dir)}: ${error}`);
  failed ||= errors.length > 0;
}
if (dirs.length === 0) {
  console.error(`no skills found in ${root}`);
  failed = true;
}
process.exit(failed ? 1 : 0);
