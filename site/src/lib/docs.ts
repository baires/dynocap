import { getCollection, type CollectionEntry } from "astro:content";
import { quadrants, site } from "../data/site";

export type DocEntry = CollectionEntry<"docs">;

export function docHref(id: string) {
  return `/docs/${id.replace(/\.mdx?$/, "")}`;
}

export function docMarkdownHref(id: string) {
  return `${docHref(id)}.md`;
}

export function docTitle(entry: DocEntry) {
  return entry.data.title ?? entry.id;
}

export function docDescription(entry: DocEntry) {
  return entry.data.description ?? `${docTitle(entry)} in the DynoCap docs.`;
}

function byPosition(a: DocEntry, b: DocEntry) {
  return (
    (a.data.sidebar_position ?? 99) - (b.data.sidebar_position ?? 99) ||
    a.id.localeCompare(b.id)
  );
}

export async function loadDocs() {
  const docs = await getCollection("docs");
  const groups = quadrants.map((quadrant) => ({
    ...quadrant,
    pages: docs
      .filter((entry) => entry.id.startsWith(`${quadrant.id}/`))
      .sort(byPosition),
  }));
  const flat = groups.flatMap((group) => group.pages);
  return { groups, flat };
}

export function neighbors(flat: DocEntry[], id: string) {
  const index = flat.findIndex((entry) => entry.id === id);
  return {
    previous: index > 0 ? flat[index - 1] : undefined,
    next: index >= 0 && index < flat.length - 1 ? flat[index + 1] : undefined,
  };
}

export function markdownDocument(entry: DocEntry) {
  const title = docTitle(entry);
  const description = entry.data.description;
  const page = new URL(docHref(entry.id), site.url).href;
  const lines = [`# ${title}`, ""];
  if (description) lines.push(description, "");
  lines.push(`HTML: ${page}`, "");
  const body = (entry.body ?? "").replace(/^\uFEFF/, "").trim();
  const withoutDuplicateTitle = body.replace(/^#\s+[^\n]+\n+/, "");
  return `${lines.join("\n")}\n${withoutDuplicateTitle}\n`;
}
