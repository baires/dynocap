import path from "node:path";

function walk(node, fn, parent) {
  if (!node) return;
  if (node.type === "element") fn(node, parent);
  const nextParent = node.type === "element" ? node : parent;
  for (const child of node.children || []) walk(child, fn, nextParent);
}

function textOf(node) {
  if (!node) return "";
  if (node.type === "text") return node.value || "";
  return (node.children || []).map(textOf).join("");
}

function labelTables(tree) {
  walk(tree, (node) => {
    if (node.tagName !== "table") return;
    const rows = [];
    for (const section of node.children || []) {
      if (section.type !== "element") continue;
      const sectionRows =
        section.tagName === "tr"
          ? [section]
          : (section.children || []).filter((child) => child.tagName === "tr");
      const kind = section.tagName === "thead" ? "thead" : "tbody";
      for (const row of sectionRows) rows.push({ kind, row });
    }
    const head = rows.find((entry) => entry.kind === "thead");
    const labels = head
      ? (head.row.children || [])
          .filter((cell) => cell.tagName === "th" || cell.tagName === "td")
          .map((cell) => textOf(cell).replace(/\s+/g, " ").trim())
      : [];
    for (const { kind, row } of rows) {
      if (kind === "thead") continue;
      let index = 0;
      for (const cell of row.children || []) {
        if (cell.tagName !== "td") continue;
        if (labels[index]) {
          cell.properties ??= {};
          cell.properties["data-label"] = labels[index];
        }
        index += 1;
      }
    }
  });
}

function rewrite(href, sourcePath) {
  if (!href || /^(https?:|mailto:|#)/.test(href)) return href;
  const hashAt = href.indexOf("#");
  const hash = hashAt >= 0 ? href.slice(hashAt) : "";
  let clean = (hashAt >= 0 ? href.slice(0, hashAt) : href).replace(
    /\.mdx?$/,
    ""
  );
  if (!clean) return href;
  if (/^\/(tutorials|how-to|reference|explanation)(\/|$)/.test(clean))
    return `/docs${clean}${hash}`;
  if (clean.startsWith("/") || !sourcePath) return href;
  const abs = path.resolve(path.dirname(sourcePath), clean);
  const docsRoot = path.resolve(process.cwd(), "../docs");
  const rel = path.relative(docsRoot, abs);
  if (rel.startsWith("..") || path.isAbsolute(rel)) return href;
  return `/docs/${rel.split(path.sep).join("/")}${hash}`;
}

const LANGUAGES = {
  sh: "Shell",
  bash: "Shell",
  shell: "Shell",
  zsh: "Shell",
  ts: "TypeScript",
  typescript: "TypeScript",
  js: "JavaScript",
  javascript: "JavaScript",
  json: "JSON",
  jsonc: "JSON",
  go: "Go",
  swift: "Swift",
  python: "Python",
  py: "Python",
  yaml: "YAML",
  toml: "TOML",
  text: "Text",
  plaintext: "Text",
};

const el = (tagName, properties, children = []) => ({
  type: "element",
  tagName,
  properties,
  children,
});

// Wrap each heading's content in a link to its own id, so any section can be shared.
function linkHeadings(tree) {
  walk(tree, (node) => {
    if (!/^h[2-4]$/.test(node.tagName) || !node.properties?.id) return;
    node.children = [
      el(
        "a",
        { className: ["heading-link"], href: `#${node.properties.id}` },
        node.children
      ),
    ];
  });
}

const ENTITIES = {
  amp: "&",
  lt: "<",
  gt: ">",
  quot: '"',
  "#39": "'",
  "#x27": "'",
};

// Shiki hands rehype each code block as raw HTML, so read the text back out of the markup.
function codeText(html) {
  return html
    .replace(/<\/span><span class="line">/g, "\n")
    .replace(/<[^>]+>/g, "")
    .replace(/&(amp|lt|gt|quot|#39|#x27);/g, (_, name) => ENTITIES[name])
    .replace(/\n$/, "");
}

// Give each code block a label and a copy button. The button reuses the site's data-copy handler.
function frameCode(parent) {
  const children = parent.children || [];
  for (let index = 0; index < children.length; index += 1) {
    const node = children[index];
    if (node.type === "element" && !["figure", "pre"].includes(node.tagName))
      frameCode(node);
    const isPre = node.type === "element" && node.tagName === "pre";
    const isRawPre = node.type === "raw" && /^\s*<pre/.test(node.value);
    if (!isPre && !isRawPre) continue;
    const language = isPre
      ? String(node.properties?.dataLanguage ?? "")
      : (node.value.match(/data-language="([^"]+)"/)?.[1] ?? "");
    const label = LANGUAGES[language] ?? "";
    children[index] = el("figure", { className: ["code-frame"] }, [
      el("figcaption", {}, [
        el("span", {}, [{ type: "text", value: label }]),
        el(
          "button",
          {
            type: "button",
            className: ["code-copy"],
            dataCopy: isPre
              ? textOf(node).replace(/\n$/, "")
              : codeText(node.value),
            ariaLabel: label ? `Copy ${label} code` : "Copy code",
          },
          [
            el("span", { ariaLive: "polite" }, [
              { type: "text", value: "Copy" },
            ]),
          ]
        ),
      ]),
      node,
    ]);
  }
}

// Wide reference tables scroll inside their own frame instead of widening the page.
function scrollTables(parent) {
  const children = parent.children || [];
  for (let index = 0; index < children.length; index += 1) {
    const node = children[index];
    if (node.type !== "element") continue;
    if (node.tagName === "table") {
      children[index] = el(
        "div",
        {
          className: ["table-scroll"],
          tabIndex: 0,
          role: "region",
          ariaLabel: "Table",
        },
        [node]
      );
    } else if (!["figure", "pre"].includes(node.tagName)) scrollTables(node);
  }
}

export function rehypeDocs() {
  return (tree, file) => {
    let seenH1 = false;
    walk(tree, (node, parent) => {
      if (node.tagName === "h1" && !seenH1) {
        seenH1 = true;
        node.properties ??= {};
        node.properties.id = "content";
        node.properties.tabindex = "-1";
      }
      if (node.tagName === "th") {
        node.properties ??= {};
        if (!node.properties.scope) node.properties.scope = "col";
      }
      if (node.tagName === "a" && typeof node.properties?.href === "string") {
        node.properties.href = rewrite(node.properties.href, file.path || "");
      }
    });
    labelTables(tree);
    linkHeadings(tree);
    frameCode(tree);
    scrollTables(tree);
  };
}
