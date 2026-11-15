import type { APIRoute } from "astro";
import installer from "../../../scripts/install.sh?raw";

export const GET: APIRoute = () =>
  new Response(installer, {
    headers: {
      "Content-Type": "text/plain; charset=utf-8",
      "X-Content-Type-Options": "nosniff",
    },
  });
