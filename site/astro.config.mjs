import { defineConfig } from "astro/config";
import sitemap from "@astrojs/sitemap";
import mdx from "@astrojs/mdx";
import { rehypeHeadingIds } from "@astrojs/markdown-remark";
import { markdownPages } from "./src/lib/markdown-pages.mjs";
import { rehypeDocs } from "./src/lib/rehype-docs.mjs";
import { dynocapTheme } from "./src/lib/shiki-theme.mjs";

export default defineConfig({
  site: "https://dynocap.dev",
  trailingSlash: "never",
  integrations: [mdx(), sitemap(), markdownPages()],
  prefetch: { prefetchAll: true, defaultStrategy: "hover" },
  build: { inlineStylesheets: "auto" },
  markdown: {
    // Heading ids first, so rehypeDocs can turn each heading into a link to itself.
    rehypePlugins: [rehypeHeadingIds, rehypeDocs],
    shikiConfig: { theme: dynocapTheme },
  },
});
