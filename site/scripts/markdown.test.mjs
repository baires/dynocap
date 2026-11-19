import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { after, before, test } from "node:test";
import { unstable_startWorker } from "wrangler";

const markdown = "text/markdown";
const html = "text/html";
let worker;
let origin;

before(async () => {
  worker = await unstable_startWorker({
    config: "wrangler.jsonc",
    dev: { server: { port: 0 } },
  });
  origin = await worker.url;
});

after(async () => {
  await worker?.dispose();
});

function request(path, accept, options = {}) {
  const headers = new Headers(options.headers);
  if (accept) headers.set("Accept", accept);
  return fetch(new URL(path, origin), { ...options, headers });
}

function assertVariant(response, type, status = 200) {
  assert.equal(response.status, status, response.url);
  assert.equal(response.headers.get("Content-Type")?.split(";")[0], type);
  assert.match(response.headers.get("Vary") ?? "", /(?:^|,\s*)accept(?:,|$)/i);
}

test("every page in the sitemap serves HTML by default and Markdown on request", async () => {
  const locations = (xml) => [...xml.matchAll(/<loc>([^<]+)<\/loc>/g)];
  const index = await request("/sitemap-index.xml");
  const sitemaps = locations(await index.text());
  assert.ok(sitemaps.length);

  for (const [, sitemap] of sitemaps) {
    const xml = await request(new URL(sitemap).pathname);
    const pages = locations(await xml.text());
    assert.ok(pages.length);
    for (const [, page] of pages) {
      const path = new URL(page).pathname;
      const browser = await request(path);
      assertVariant(browser, html);
      assert.match(await browser.text(), /<!doctype html>/i);

      const agent = await request(path, markdown);
      assertVariant(agent, markdown);
      const body = await agent.text();
      assert.match(body, /^# .+/);

      if (path.startsWith("/docs/")) {
        assert.ok(
          !existsSync(new URL(`../dist${path}/index.md`, import.meta.url))
        );
        const standalone = await request(`${path}.md`, html);
        assert.equal(standalone.status, 200);
        assert.match(
          standalone.headers.get("Content-Type"),
          /^text\/markdown\b/
        );
        assert.equal(standalone.headers.get("ETag"), agent.headers.get("ETag"));
        assert.equal(await standalone.text(), body);
      }
    }
  }
});

test("Markdown contains page content, formatted code and tables", async () => {
  const home = await (await request("/", markdown)).text();
  assert.match(home, /brew install baires\/tap\/dynocap/);
  assert.doesNotMatch(home, /<script\b|<svg\b|Play recording|Copy commands/);

  const guide = await (
    await request("/docs/tutorials/getting-started", markdown)
  ).text();
  assert.match(guide, /```sh\nbrew install/);
  assert.match(guide, /^\| File at the project root\s+\| Runtime\s+\|$/m);
  assert.doesNotMatch(guide, /<nav\b|<aside\b|On this page|View as Markdown/);
});

test("Accept preferences, HEAD, and conditional requests select the correct variant", async () => {
  for (const accept of [
    "text/*, */*;q=0.1",
    "text/markdown;q=0",
    "text/html, text/markdown;q=0.5",
  ]) {
    const response = await request("/", accept);
    assertVariant(response, html);
    await response.body.cancel();
  }

  const agent = await request("/", "Text/Markdown; q=1, text/html;q=0.5", {
    method: "HEAD",
  });
  assertVariant(agent, markdown);
  assert.equal(await agent.text(), "");
  const etag = agent.headers.get("ETag");
  assert.ok(etag);

  const options = { headers: { "If-None-Match": etag } };
  const unchanged = await request("/", markdown, options);
  assertVariant(unchanged, markdown, 304);
  const browser = await request("/", html, options);
  assertVariant(browser, html);
  await browser.body.cancel();
});

test("homepage Link headers advertise the catalog and each interface", async () => {
  for (const [path, accept, method] of [
    ["/", undefined, "GET"],
    ["/", undefined, "HEAD"],
    ["/", markdown, "GET"],
  ]) {
    const response = await request(path, accept, { method });
    assert.equal(response.status, 200, `${method} ${path}`);
    const link = response.headers.get("Link") ?? "";
    assert.match(link, /<\/\.well-known\/api-catalog>; rel="api-catalog"/);
    assert.match(link, /rel="service-desc"/);
    assert.match(link, /rel="service-doc"/);
    assert.match(link, /<\/llms\.txt>; rel="describedby"/);
    await response.body?.cancel();
  }

  const home = await request("/");
  const targets = [...(home.headers.get("Link") ?? "").matchAll(/<([^>]+)>/g)];
  assert.ok(targets.length >= 4);
  for (const [, target] of targets) {
    const resource = await request(target, undefined, { redirect: "manual" });
    assert.equal(resource.status, 200, target);
    await resource.body?.cancel();
  }
  await home.body?.cancel();
});

test("api catalog is an RFC 9727 linkset for each local interface", async () => {
  const response = await request("/.well-known/api-catalog");
  assert.equal(response.status, 200);
  assert.equal(
    response.headers.get("Content-Type")?.split(";")[0],
    "application/linkset+json"
  );
  assert.match(
    response.headers.get("Content-Type") ?? "",
    /profile="https:\/\/www\.rfc-editor\.org\/info\/rfc9727"/
  );
  assert.match(response.headers.get("Link") ?? "", /rel="api-catalog"/);

  const catalog = await response.json();
  assert.ok(catalog.linkset.length >= 3);
  for (const entry of catalog.linkset) {
    assert.match(entry.anchor, /^https:\/\/dynocap\.dev\/docs\/reference\//);
    const specUrl = new URL(entry["service-desc"][0].href);
    const spec = await request(specUrl.pathname);
    assert.equal(spec.status, 200);
    assert.match(
      spec.headers.get("Content-Type") ?? "",
      /^application\/openapi\+json\b/
    );
    const document = await spec.json();
    assert.match(document.openapi, /^3\./);
    assert.equal(typeof document.info.title, "string");
    assert.deepEqual(document.paths, {});

    const doc = await request(new URL(entry["service-doc"][0].href).pathname);
    assert.equal(doc.status, 200);
    assert.match(doc.headers.get("Content-Type") ?? "", /^text\/html\b/);
    await doc.body.cancel();
  }

  const head = await request("/.well-known/api-catalog", undefined, {
    method: "HEAD",
  });
  assert.equal(head.status, 200);
  assert.match(head.headers.get("Link") ?? "", /rel="api-catalog"/);
  assert.equal(await head.text(), "");
});

test("redirects, 404s, and existing standalone assets retain their behavior", async () => {
  const canonical = await request("/docs", html, { redirect: "manual" });
  assert.equal(canonical.status, 200);
  assert.match(
    await canonical.text(),
    /<link rel="canonical" href="https:\/\/dynocap\.dev\/docs"/
  );

  const redirect = await request("/docs/?source=test", markdown, {
    redirect: "manual",
  });
  assert.equal(redirect.status, 307);
  assert.equal(redirect.headers.get("Location"), "/docs?source=test");

  const missing = await request("/docs/missing", markdown);
  assert.equal(missing.status, 404);
  assert.match(missing.headers.get("Content-Type"), /^text\/html\b/);
  await missing.body.cancel();

  const index = await request("/llms.txt", markdown);
  assert.match(index.headers.get("Content-Type"), /^text\/plain\b/);
  assert.match(await index.text(), /^# DynoCap/);
});
