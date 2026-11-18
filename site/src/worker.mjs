import { acceptsMarkdown } from "./lib/accepts-markdown.mjs";
import { apiCatalogBody, apiCatalogHeaders } from "./lib/api-catalog.mjs";
import { markdownAssetPath } from "./lib/markdown-asset-path.mjs";

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    // The assets binding does not serve an extensionless file in .well-known.
    if (url.pathname === "/.well-known/api-catalog") {
      if (!["GET", "HEAD"].includes(request.method)) {
        return new Response(null, {
          status: 405,
          headers: { Allow: "GET, HEAD" },
        });
      }
      return new Response(request.method === "HEAD" ? null : apiCatalogBody, {
        headers: apiCatalogHeaders,
      });
    }
    if (
      url.pathname.startsWith("/openapi/") &&
      url.pathname.endsWith(".json")
    ) {
      if (!["GET", "HEAD"].includes(request.method)) {
        return new Response(null, {
          status: 405,
          headers: { Allow: "GET, HEAD" },
        });
      }
      const asset = await env.ASSETS.fetch(request);
      if (!asset.ok && asset.status !== 304) return asset;
      const headers = new Headers(asset.headers);
      headers.set("Content-Type", "application/openapi+json");
      headers.set("X-Content-Type-Options", "nosniff");
      return new Response(request.method === "HEAD" ? null : asset.body, {
        status: asset.status,
        headers,
      });
    }
    // Static Assets redirects directory URLs to their trailing-slash form.
    if (
      !["GET", "HEAD"].includes(request.method) ||
      !url.pathname.endsWith("/")
    ) {
      return env.ASSETS.fetch(request);
    }

    if (acceptsMarkdown(request.headers.get("Accept"))) {
      url.pathname = markdownAssetPath(url.pathname);
      const markdown = await env.ASSETS.fetch(new Request(url, request));
      if (markdown.ok || markdown.status === 304) {
        const response = new Response(markdown.body, markdown);
        response.headers.set("Content-Type", "text/markdown; charset=utf-8");
        response.headers.set("X-Content-Type-Options", "nosniff");
        response.headers.append("Vary", "Accept");
        return response;
      }
      await markdown.body?.cancel();
    }

    const asset = await env.ASSETS.fetch(request);
    if (!asset.ok && asset.status !== 304) return asset;
    const response = new Response(asset.body, asset);
    response.headers.append("Vary", "Accept");
    return response;
  },
};
