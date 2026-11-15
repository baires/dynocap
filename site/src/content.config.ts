import { defineCollection, z } from "astro:content";
import { docsLoader } from "./lib/docs-loader.mjs";

const docs = defineCollection({
  loader: docsLoader(),
  schema: z.object({
    title: z.string().optional(),
    description: z.string().optional(),
    sidebar_position: z.coerce.number().optional(),
  }),
});

export const collections = { docs };
