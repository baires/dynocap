// Astro adapter (ClientRouter). Call start(setup) once from the layout's <script>.
// The leave animation runs IN PARALLEL with fetching the next page, so transitions add no latency.
import { boot, cleanup, enter, leave, syncFlags } from "./index";

let navigating = false;

export function start(setup?: () => void) {
  document.addEventListener("astro:before-preparation", (event) => {
    navigating = true;
    const load = (event as Event & { loader: () => Promise<void> }).loader;
    (event as Event & { loader: () => Promise<void> }).loader = async () => {
      await Promise.all([leave(), load()]);
    };
  });
  document.addEventListener("astro:before-swap", () => cleanup());
  document.addEventListener("astro:after-swap", () => {
    syncFlags();
    document.getElementById("loader")?.remove();
  });
  document.addEventListener("astro:page-load", () => {
    if (!navigating) return;
    navigating = false;
    void enter();
  });
  void boot(setup);
}
