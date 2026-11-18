export function acceptsMarkdown(accept) {
  let markdown = 0;
  let html = 0;
  for (const range of (accept ?? "").split(",")) {
    const [type, ...parameters] = range.trim().toLowerCase().split(";");
    const mediaType = type.trim();
    if (mediaType !== "text/markdown" && mediaType !== "text/html") continue;

    const weight = parameters
      .map((value) => value.trim())
      .find((value) => value.startsWith("q="));
    const quality = weight === undefined ? 1 : Number(weight.slice(2));
    if (!(quality > 0 && quality <= 1)) continue;
    if (mediaType === "text/markdown") markdown = Math.max(markdown, quality);
    else html = Math.max(html, quality);
  }
  return markdown > 0 && markdown >= html;
}
