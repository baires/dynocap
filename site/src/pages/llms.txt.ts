import type { APIRoute } from "astro";
import { site, worktreeComparison } from "../data/site";
import {
  docDescription,
  docMarkdownHref,
  docTitle,
  loadDocs,
} from "../lib/docs";

export const GET: APIRoute = async () => {
  const { groups } = await loadDocs();
  const origin = site.url.replace(/\/$/, "");
  const lines = [
    `# ${site.name}`,
    "",
    `> ${site.description}`,
    "",
    "The HTML docs and these Markdown files describe the same pages. Prefer a single page URL when you only need one topic.",
    "",
    "## Workflow comparison",
    "",
    `- [${worktreeComparison.title}](${origin}${worktreeComparison.path}): ${worktreeComparison.description}`,
    "",
  ];
  for (const group of groups) {
    lines.push(`## ${group.title}`, "");
    for (const page of group.pages) {
      const url = `${origin}${docMarkdownHref(page.id)}`;
      lines.push(`- [${docTitle(page)}](${url}): ${docDescription(page)}`);
    }
    lines.push("");
  }
  lines.push(`Full text: ${origin}/llms-full.txt`, "");
  return new Response(lines.join("\n"), {
    headers: {
      "Content-Type": "text/plain; charset=utf-8",
      "X-Content-Type-Options": "nosniff",
    },
  });
};
