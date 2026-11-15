import type { APIRoute } from "astro";
import { site } from "../data/site";
import { docHref, loadDocs, markdownDocument } from "../lib/docs";

export const GET: APIRoute = async () => {
  const { flat } = await loadDocs();
  const origin = site.url.replace(/\/$/, "");
  const parts = flat.map((entry) => {
    const page = `${origin}${docHref(entry.id)}`;
    return markdownDocument(entry).replace(/\nHTML: .+\n/, `\nHTML: ${page}\n`);
  });
  return new Response(parts.join("\n\n---\n\n"), {
    headers: {
      "Content-Type": "text/plain; charset=utf-8",
      "X-Content-Type-Options": "nosniff",
    },
  });
};
