import { gsap } from "gsap";
import { ScrollTrigger } from "gsap/ScrollTrigger";
import { prefersReducedMotion } from "../engine";

gsap.registerPlugin(ScrollTrigger);

export function bindReady() {
  const cleanups: Array<() => void> = [];
  const caret = document.querySelector<HTMLElement>("[data-caret]");
  const prompt = document.querySelector<HTMLElement>(".prompt");

  if (caret && prompt && !prefersReducedMotion()) {
    const blink = gsap.to(caret, {
      autoAlpha: 0,
      duration: 0.55,
      repeat: -1,
      yoyo: true,
      ease: "steps(1)",
    });
    const trigger = ScrollTrigger.create({
      trigger: prompt,
      start: "top bottom",
      end: "bottom top",
      onLeave: () => blink.pause(),
      onLeaveBack: () => blink.pause(),
      onEnter: () => blink.play(),
      onEnterBack: () => blink.play(),
    });
    cleanups.push(() => {
      trigger.kill();
      blink.kill();
    });
  }

  document
    .querySelectorAll<HTMLButtonElement>("[data-copy]")
    .forEach((button) => {
      const label = button.querySelector("span");
      const previous = label?.textContent ?? "Copy command";
      const onClick = async () => {
        const value = button.dataset.copy ?? "";
        try {
          await navigator.clipboard.writeText(value);
          if (label) label.textContent = "Copied";
        } catch {
          if (label) label.textContent = "Select and copy";
        }
        window.setTimeout(() => {
          if (label) label.textContent = previous;
        }, 1400);
      };
      button.addEventListener("click", onClick);
      cleanups.push(() => button.removeEventListener("click", onClick));
    });

  return () => cleanups.forEach((fn) => fn());
}
