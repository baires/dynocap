import type { APIRoute } from "astro";
import { site, worktreeComparison } from "../data/site";
import {
  docDescription,
  docHref,
  docMarkdownHref,
  docTitle,
  loadDocs,
} from "../lib/docs";

function quote(value: string) {
  return `"${value.replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/\n/g, "\\n")}"`;
}

export const GET: APIRoute = async () => {
  const { groups } = await loadDocs();
  const origin = site.url.replace(/\/$/, "");
  const lines = [`site: ${quote(origin)}`, "pages:"];
  const pages = [
    {
      title: site.name,
      path: "/",
      description: site.description,
    },
    worktreeComparison,
    {
      title: "Docs",
      path: "/docs",
      description:
        "Where to start with DynoCap: boot a guest, run a project task, or connect the SDK and MCP.",
    },
  ];

  for (const page of pages) {
    lines.push(
      `  - title: ${quote(page.title)}`,
      `    path: ${quote(page.path)}`,
      `    url: ${quote(`${origin}${page.path}`)}`,
      `    description: ${quote(page.description)}`
    );
  }

  for (const group of groups) {
    for (const page of group.pages) {
      const path = docHref(page.id);
      lines.push(
        `  - title: ${quote(docTitle(page))}`,
        `    path: ${quote(path)}`,
        `    url: ${quote(`${origin}${path}`)}`,
        `    description: ${quote(docDescription(page))}`,
        `    group: ${quote(group.title)}`,
        `    markdown: ${quote(`${origin}${docMarkdownHref(page.id)}`)}`
      );
    }
  }

  lines.push("");
  return new Response(lines.join("\n"), {
    headers: {
      "Content-Type": "text/yaml; charset=utf-8",
      "X-Content-Type-Options": "nosniff",
    },
  });
};
