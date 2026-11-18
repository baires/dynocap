import assert from "node:assert/strict";
import { readFileSync, existsSync } from "node:fs";
import { test } from "node:test";

const dist = new URL("../dist/", import.meta.url);
const read = (path) => readFileSync(new URL(path, dist), "utf8");
const locations = (xml) =>
  [...xml.matchAll(/<loc>([^<]+)<\/loc>/g)].map((match) => match[1]);
const urls = locations(read("sitemap-index.xml")).flatMap((url) =>
  locations(read(new URL(url).pathname.slice(1)))
);
const htmlPath = (pathname) =>
  `${pathname.replace(/^\//, "").replace(/\/$/, "")}${pathname === "/" ? "" : "/"}index.html`;
const pages = new Map(
  urls.map((url) => [
    new URL(url).pathname,
    read(htmlPath(new URL(url).pathname)),
  ])
);
const cluster = [
  "runtime-sandboxes",
  "nodejs-sandbox",
  "python-sandbox",
  "go-sandbox",
].map((slug) => `/docs/tutorials/${slug}`);
const worktreeComparison = "/dynocap-vs-git-worktrees";
const links = (html) =>
  [...html.matchAll(/<a\b[^>]*href="([^"]+)"/g)].map((match) => match[1]);

test("conventional sitemap URL redirects to the generated sitemap index", () => {
  assert.match(
    read("_redirects"),
    /^\/sitemap\.xml\s+\/sitemap-index\.xml\s+301\s*$/m
  );
  assert.ok(locations(read("sitemap-index.xml")).length > 0);
});

test("XML sitemap contains unique, indexable HTML URLs matching their canonicals", () => {
  assert.equal(new Set(urls).size, urls.length);
  const titles = new Set();
  const descriptions = new Set();
  for (const [path, html] of pages) {
    const canonical = html.match(
      /<link\b[^>]*rel="canonical"[^>]*href="([^"]+)"/
    );
    assert.ok(canonical, `${path}: missing canonical`);
    assert.equal(canonical[1], `https://dynocap.dev${path}`);
    assert.doesNotMatch(
      html,
      /<meta\b[^>]*name="robots"[^>]*content="[^"]*noindex/
    );
    assert.equal(
      [...html.matchAll(/<h1\b/g)].length,
      1,
      `${path}: expected one H1`
    );
    const title = html.match(/<title>([^<]+)<\/title>/)?.[1];
    const description = html.match(
      /<meta\b[^>]*name="description"[^>]*content="([^"]+)"/
    )?.[1];
    assert.ok(title && description, `${path}: missing search metadata`);
    assert.ok(!titles.has(title), `${path}: duplicate title`);
    assert.ok(!descriptions.has(description), `${path}: duplicate description`);
    titles.add(title);
    descriptions.add(description);
  }
});

test("runtime guides are discoverable from home and available in machine-readable indexes", () => {
  const visited = new Set();
  const queue = ["/"];
  while (queue.length) {
    const path = queue.shift();
    if (visited.has(path) || !pages.has(path)) continue;
    visited.add(path);
    for (const href of links(pages.get(path))) {
      const url = new URL(href, `https://dynocap.dev${path}`);
      if (url.origin === "https://dynocap.dev") queue.push(url.pathname);
    }
  }
  for (const path of cluster) {
    assert.ok(
      visited.has(path),
      `${path}: orphan page or missing from sitemap`
    );
    assert.ok(existsSync(new URL(`${path.slice(1)}.md`, dist)));
    assert.ok(read("llms.txt").includes(`${path}.md`));
    assert.ok(read("sitemap.yml").includes(path));
  }
});

test("worktree comparison is linked from home and listed in machine-readable indexes", () => {
  assert.ok(links(pages.get("/")).includes(worktreeComparison));
  assert.ok(pages.has(worktreeComparison));
  assert.ok(
    read("llms.txt").includes(`https://dynocap.dev${worktreeComparison})`)
  );
  assert.ok(read("sitemap.yml").includes(`path: "${worktreeComparison}"`));
});

test("runtime guides and worktree comparison link to real pages and anchor targets", () => {
  for (const path of [...cluster, worktreeComparison]) {
    for (const href of links(pages.get(path))) {
      const url = new URL(href, `https://dynocap.dev${path}`);
      if (url.origin !== "https://dynocap.dev") continue;
      const target = pages.get(url.pathname);
      assert.ok(
        target || existsSync(new URL(url.pathname.slice(1), dist)),
        `${path}: broken link ${href}`
      );
      if (url.hash && target) {
        assert.ok(
          target.includes(`id="${decodeURIComponent(url.hash.slice(1))}"`),
          `${path}: missing anchor ${href}`
        );
      }
    }
  }
});

test("docs breadcrumb schema ends at the canonical page and links to real ancestors", () => {
  for (const [path, html] of pages) {
    if (!path.startsWith("/docs/")) continue;
    const data = [
      ...html.matchAll(
        /<script type="application\/ld\+json">([\s\S]*?)<\/script>/g
      ),
    ].map((match) => JSON.parse(match[1]));
    const breadcrumb = data.find((item) => item["@type"] === "BreadcrumbList");
    assert.ok(breadcrumb, `${path}: missing breadcrumb schema`);
    const items = breadcrumb.itemListElement;
    assert.ok(items.length >= 2);
    assert.equal(items.at(-1).item, `https://dynocap.dev${path}`);
    items.forEach((item, index) => {
      assert.equal(item.position, index + 1);
      assert.ok(item.name);
      assert.ok(pages.has(new URL(item.item).pathname));
    });
  }
});

test("404 is noindex and robots advertises only the search-engine sitemap", () => {
  assert.match(
    read("404.html"),
    /<meta name="robots" content="noindex, follow"/
  );
  assert.ok(!urls.some((url) => new URL(url).pathname.startsWith("/404")));
  assert.deepEqual(read("robots.txt").match(/^Sitemap: .+$/gm), [
    "Sitemap: https://dynocap.dev/sitemap-index.xml",
  ]);
});
