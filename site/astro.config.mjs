import { defineConfig } from "astro/config";
import sitemap from "@astrojs/sitemap";
import mdx from "@astrojs/mdx";
import { rehypeHeadingIds } from "@astrojs/markdown-remark";
import { rehypeDocs } from "./src/lib/rehype-docs.mjs";
import { microvmTheme } from "./src/lib/shiki-theme.mjs";

// Replace `site` with the production URL before deploying.
export default defineConfig({
  site: "https://microvm.dev",
  integrations: [mdx(), sitemap()],
  prefetch: { prefetchAll: true, defaultStrategy: "hover" },
  build: { inlineStylesheets: "auto" },
  markdown: {
    // Heading ids first, so rehypeDocs can turn each heading into a link to itself.
    rehypePlugins: [rehypeHeadingIds, rehypeDocs],
    shikiConfig: { theme: microvmTheme },
  },
});
