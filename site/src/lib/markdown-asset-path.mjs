export function markdownAssetPath(pathname) {
  const path = pathname.replace(/\/$/, "");
  return path.startsWith("/docs/") ? `${path}.md` : `${path}/index.md`;
}
