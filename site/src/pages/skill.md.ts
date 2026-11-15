import type { APIRoute } from "astro";
import skill from "../../../skills/microvm/SKILL.md?raw";

export const GET: APIRoute = () =>
  new Response(skill, {
    headers: {
      "Content-Type": "text/plain; charset=utf-8",
      "X-Content-Type-Options": "nosniff",
    },
  });
