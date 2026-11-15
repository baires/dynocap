import type { APIRoute } from "astro";
import { loadDocs, markdownDocument } from "../../lib/docs";

export async function getStaticPaths() {
  const { flat } = await loadDocs();
  return flat.map((entry) => ({
    params: { slug: entry.id.replace(/\.mdx?$/, "") },
    props: { entry },
  }));
}

export const GET: APIRoute = ({ props }) =>
  new Response(markdownDocument(props.entry), {
    headers: {
      "Content-Type": "text/markdown; charset=utf-8",
      "X-Content-Type-Options": "nosniff",
    },
  });
