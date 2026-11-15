import { defineConfig } from "astro/config";
import sitemap from "@astrojs/sitemap";
import mdx from "@astrojs/mdx";
import { rehypeDocs } from "./src/lib/rehype-docs.mjs";

// Replace `site` with the production URL before deploying.
export default defineConfig({
  site: "https://microvm.dev",
  integrations: [mdx(), sitemap()],
  prefetch: { prefetchAll: true, defaultStrategy: "hover" },
  build: { inlineStylesheets: "auto" },
  markdown: {
    rehypePlugins: [rehypeDocs],
    shikiConfig: { theme: "github-dark" },
  },
});
