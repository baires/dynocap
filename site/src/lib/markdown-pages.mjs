import { readFile, writeFile } from "node:fs/promises";
import { fromHtml } from "hast-util-from-html";
import { toMdast } from "hast-util-to-mdast";
import { gfmToMarkdown } from "mdast-util-gfm";
import { toMarkdown } from "mdast-util-to-markdown";
import { acceptsMarkdown } from "./accepts-markdown.mjs";
import { markdownAssetPath } from "./markdown-asset-path.mjs";

const omittedTags = new Set([
  "aside",
  "button",
  "nav",
  "script",
  "style",
  "svg",
  "video",
]);
const omittedClasses = new Set(["docs-md", "demo__phone"]);

function cleanContent(node) {
  if (node.type !== "element") return [node];
  const { tagName, properties } = node;
  const classes = properties.className ?? [];
  if (
    omittedTags.has(tagName) ||
    properties.hidden ||
    properties.ariaHidden === "true" ||
    classes.some((name) => omittedClasses.has(name))
  ) {
    return [];
  }

  if (tagName === "pre" && properties.dataLanguage) {
    const code = node.children.find((child) => child.tagName === "code");
    if (code)
      code.properties.className = [`language-${properties.dataLanguage}`];
  }
  if (classes.includes("code-frame")) {
    node.children = node.children.filter(
      (child) => child.tagName !== "figcaption"
    );
  }
  node.children = node.children.flatMap(cleanContent);
  if (/^h[1-6]$/.test(tagName)) {
    node.children = node.children.map((child) =>
      child.tagName === "br" ? { type: "text", value: " " } : child
    );
  }
  // Astro drops whitespace between some adjacent inline elements.
  node.children = node.children.flatMap((child, index, children) => {
    const previous = children[index - 1];
    if (
      (previous?.tagName === "a" && child.tagName === "a") ||
      (previous?.properties?.role === "columnheader" &&
        child.properties?.role === "columnheader")
    ) {
      return [{ type: "text", value: " / " }, child];
    }
    if (
      (child.tagName === "a" &&
        previous?.type === "text" &&
        /[\p{L}\p{N}]$/u.test(previous.value)) ||
      (previous?.tagName === "a" &&
        child.type === "text" &&
        /^[\p{L}\p{N}]/u.test(child.value))
    ) {
      return [{ type: "text", value: " " }, child];
    }
    return [child];
  });
  return classes.includes("heading-link") ? node.children : [node];
}

export function convertPage(html, pathname) {
  const document = fromHtml(html);
  const root = document.children.find((node) => node.tagName === "html");
  const body = root?.children.find((node) => node.tagName === "body");
  const main = body?.children.find((node) => node.tagName === "main");
  if (!main)
    throw new Error(`Markdown generation requires <main> in ${pathname}`);

  const content = {
    type: "root",
    children: main.children.flatMap(cleanContent),
  };
  return toMarkdown(toMdast(content), {
    bullet: "-",
    fences: true,
    extensions: [gfmToMarkdown()],
  });
}

export function markdownPages() {
  return {
    name: "dynocap-markdown-pages",
    hooks: {
      "astro:config:setup": ({ command, addMiddleware }) => {
        if (command === "dev") {
          addMiddleware({
            entrypoint: new URL("./markdown-dev.mjs", import.meta.url),
            order: "pre",
          });
        }
      },
      "astro:server:setup": ({ server }) => {
        server.middlewares.use((request, response, next) => {
          if (!request.url || !["GET", "HEAD"].includes(request.method)) {
            return next();
          }
          const [pathname] = request.url.split("?", 1);
          const page = pathname.replace(/\/$/, "") || "/";
          if (
            page === "/" ||
            page === "/docs" ||
            page === "/dynocap-vs-git-worktrees" ||
            (page.startsWith("/docs/") && !page.endsWith(".md"))
          ) {
            response.appendHeader("Vary", "Accept");
            // Astro strips request headers before rendering prerendered routes.
            if (acceptsMarkdown(request.headers.accept)) {
              request.url =
                markdownAssetPath(page) + request.url.slice(pathname.length);
            }
          }
          next();
        });
      },
      "astro:build:done": async ({ dir, pages }) => {
        await Promise.all(
          pages.map(async ({ pathname }) => {
            const path = pathname.replace(/\/$/, "");
            if (path === "404") return;
            const directory = new URL(path ? `${path}/` : "./", dir);
            const html = await readFile(
              new URL("index.html", directory),
              "utf8"
            );
            await writeFile(
              new URL(markdownAssetPath(`/${path}`).slice(1), dir),
              convertPage(html, `/${path}`)
            );
          })
        );
      },
    },
  };
}
