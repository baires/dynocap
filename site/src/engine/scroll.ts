// Smooth scroll on ONE clock: Lenis is driven by gsap.ticker, ScrollTrigger reads Lenis.
// Reduced motion → native scroll, no Lenis.
import Lenis from "lenis";
import { gsap } from "gsap";
import { ScrollTrigger } from "gsap/ScrollTrigger";
import { prefersReducedMotion } from "./env";

gsap.registerPlugin(ScrollTrigger);

let lenis: Lenis | null = null;
const listeners = new Set<(s: ScrollState) => void>();

export type ScrollState = { y: number; velocity: number; progress: number };
const state: ScrollState = { y: 0, velocity: 0, progress: 0 };

let anchorsBound = false;

export function initScroll() {
  if (!anchorsBound) {
    anchorsBound = true;
    addEventListener("click", onSamePageAnchor, true);
    addEventListener("popstate", () => {
      if (history.state !== null) return;
      scrollToHash();
    });
  }
  if (lenis || prefersReducedMotion()) {
    // Still publish native scroll position for WebGL sync.
    if (!lenis) addEventListener("scroll", nativeTick, { passive: true });
    return;
  }
  lenis = new Lenis({
    lerp: 1,
    smoothWheel: false,
    syncTouch: false,
    anchors: false,
  });
  lenis.on("scroll", (l: Lenis) => {
    state.y = l.scroll;
    state.velocity = l.velocity;
    state.progress = l.limit > 0 ? l.scroll / l.limit : 0; // Lenis reports 1 on pages that cannot scroll
    ScrollTrigger.update();
    listeners.forEach((fn) => fn(state));
  });
  gsap.ticker.add((time) => lenis?.raf(time * 1000));
  gsap.ticker.lagSmoothing(0);
}

function nativeTick() {
  const max = document.documentElement.scrollHeight - innerHeight;
  state.velocity = scrollY - state.y;
  state.y = scrollY;
  state.progress = max > 0 ? scrollY / max : 0;
  listeners.forEach((fn) => fn(state));
}

export const onScroll = (fn: (s: ScrollState) => void) => {
  listeners.add(fn);
  return () => listeners.delete(fn);
};
export const scrollState = () => state;
export const stopScroll = () => lenis?.stop();
export const startScroll = () => lenis?.start();
export function resetScroll() {
  if (lenis) lenis.scrollTo(0, { immediate: true, force: true });
  else scrollTo(0, 0);
  state.y = 0;
  state.velocity = 0;
}
function headerOffset() {
  const raw = getComputedStyle(document.documentElement).scrollPaddingTop;
  const parsed = Number.parseFloat(raw);
  return Number.isFinite(parsed) ? parsed : 0;
}

/** Scroll to a same-page hash. Returns false when the page has no such element. */
export function scrollToHash(
  hash = location.hash,
  immediate = prefersReducedMotion()
) {
  if (!hash || hash === "#") return false;
  let el: Element | null = null;
  try {
    el = document.querySelector(hash);
  } catch {
    return false;
  }
  if (!(el instanceof HTMLElement)) return false;
  const top = Math.max(
    0,
    el.getBoundingClientRect().top + scrollY - headerOffset()
  );
  if (lenis) {
    lenis.scrollTo(top, {
      force: true,
      immediate,
      duration: immediate ? 0 : 0.45,
    });
  } else {
    scrollTo({ top, behavior: immediate ? "auto" : "smooth" });
  }
  return true;
}

/** Repeat after fonts load. A fresh page is shorter until the display face arrives. */
export function settleHash(hash = location.hash) {
  if (!scrollToHash(hash, true)) return;
  document.fonts.ready.then(() => scrollToHash(hash, true));
}

function onSamePageAnchor(event: MouseEvent) {
  if (
    event.button !== 0 ||
    event.metaKey ||
    event.ctrlKey ||
    event.shiftKey ||
    event.altKey
  )
    return;
  const anchor = (event.target as Element | null)?.closest?.("a[href]");
  if (!(anchor instanceof HTMLAnchorElement)) return;
  if (anchor.target && anchor.target !== "_self") return;
  const url = new URL(anchor.href, location.href);
  if (
    url.origin !== location.origin ||
    url.pathname !== location.pathname ||
    !url.hash
  )
    return;
  if (!scrollToHash(url.hash)) return;
  event.preventDefault();
  event.stopPropagation();
  const next = `${url.pathname}${url.search}${url.hash}`;
  if (`${location.pathname}${location.search}${location.hash}` !== next) {
    history.pushState(null, "", next);
  }
  anchor.closest("details")?.removeAttribute("open");
}

export function scrollToTarget(target: string | HTMLElement | number) {
  if (lenis)
    lenis.scrollTo(target, {
      duration: 1.4,
      easing: (t) => 1 - Math.pow(1 - t, 4),
    });
  else if (typeof target === "number") scrollTo({ top: target });
  else
    (typeof target === "string"
      ? document.querySelector(target)
      : target
    )?.scrollIntoView();
}
