import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const ROOT = path.resolve(process.cwd(), "../docs");
const DIRS = ["tutorials", "how-to", "reference", "explanation"];
// Rendered HTML also depends on the Markdown pipeline, so a change there must re-render every page.
const PIPELINE = ["rehype-docs.mjs", "shiki-theme.mjs"]
  .map((name) => fs.readFileSync(new URL(name, import.meta.url), "utf8"))
  .join("\n");

function files() {
  const found = [];
  for (const dir of DIRS) {
    const base = path.join(ROOT, dir);
    if (!fs.existsSync(base)) continue;
    const walk = (current) => {
      for (const entry of fs.readdirSync(current, { withFileTypes: true })) {
        const full = path.join(current, entry.name);
        if (entry.isDirectory()) walk(full);
        else if (/\.mdx?$/.test(entry.name)) found.push(full);
      }
    };
    walk(base);
  }
  return found;
}

function frontmatter(raw) {
  if (!raw.startsWith("---")) return { data: {}, body: raw };
  const end = raw.indexOf("\n---", 3);
  if (end < 0) return { data: {}, body: raw };
  const data = {};
  for (const line of raw.slice(3, end).split("\n")) {
    const match = line.match(/^([A-Za-z0-9_]+):\s*(.*)$/);
    if (!match) continue;
    let value = match[2].trim();
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }
    data[match[1]] = value;
  }
  return { data, body: raw.slice(end + 4).replace(/^\r?\n/, "") };
}

function plainMath(body) {
  return body.replace(/\$\$([\s\S]*?)\$\$/g, (_, expr) => {
    const plain = expr
      .replace(/\\text\{([^}]*)\}/g, "$1")
      .replace(/\\[a-zA-Z]+/g, "")
      .replace(/\s+/g, " ")
      .trim();
    return `\n\n${plain}\n\n`;
  });
}

async function loadFile(file, context) {
  const raw = fs.readFileSync(file, "utf8");
  const id = path
    .relative(ROOT, file)
    .replace(/\.mdx?$/, "")
    .split(path.sep)
    .join("/");
  const parsed = frontmatter(raw);
  const body = plainMath(parsed.body);
  const data = await context.parseData({
    id,
    data: parsed.data,
    filePath: file,
  });
  const rendered = await context.renderMarkdown(body, {
    fileURL: pathToFileURL(file),
  });
  context.store.set({
    id,
    data,
    body,
    filePath: path.relative(process.cwd(), file),
    rendered,
    digest: context.generateDigest(raw + PIPELINE),
  });
}

export function docsLoader() {
  return {
    name: "microvm-docs",
    async load(context) {
      const current = new Set();
      for (const file of files()) {
        await loadFile(file, context);
        current.add(
          path
            .relative(ROOT, file)
            .replace(/\.mdx?$/, "")
            .split(path.sep)
            .join("/")
        );
      }
      for (const id of context.store.keys()) {
        if (!current.has(id)) context.store.delete(id);
      }
      context.watcher?.add(ROOT);
    },
  };
}
