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
  };
}
