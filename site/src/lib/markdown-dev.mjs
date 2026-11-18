import { defineMiddleware } from "astro:middleware";
import { convertPage } from "./markdown-pages.mjs";

export const onRequest = defineMiddleware(async ({ request, url }, next) => {
  if (!["GET", "HEAD"].includes(request.method)) return next();

  const { pathname } = url;
  const htmlUrl = new URL(url);
  if (
    [
      "/index.md",
      "/docs/index.md",
      "/dynocap-vs-git-worktrees/index.md",
    ].includes(pathname)
  ) {
    htmlUrl.pathname =
      pathname.slice(0, -"index.md".length).replace(/\/$/, "") || "/";
  } else if (pathname.startsWith("/docs/") && pathname.endsWith(".md")) {
    htmlUrl.pathname = pathname.slice(0, -3);
  } else {
    return next();
  }
  const html = await next(htmlUrl);
  if (!html.ok) return html;

  return new Response(
    request.method === "HEAD"
      ? null
      : convertPage(await html.text(), htmlUrl.pathname),
    {
      headers: {
        "Content-Type": "text/markdown; charset=utf-8",
        "X-Content-Type-Options": "nosniff",
      },
    }
  );
});
