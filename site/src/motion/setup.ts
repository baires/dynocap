import { gsap } from "gsap";
import { ease, onPage, setTransition } from "../engine";
import { bindReady } from "./task";

export function setupMotion() {
  setTransition({
    leave: (curtain) => {
      const seam = curtain.querySelector(".curtain__seam");
      const panel = curtain.querySelector(".curtain__panel");
      return gsap
        .timeline()
        .set(curtain, { autoAlpha: 1 })
        .set(panel, { autoAlpha: 0 })
        .fromTo(
          seam,
          { scaleX: 0 },
          { scaleX: 1, duration: 0.32, ease: ease.inOut }
        );
    },
    enter: (curtain) => {
      const seam = curtain.querySelector(".curtain__seam");
      return gsap
        .timeline()
        .to(seam, { scaleX: 0, duration: 0.28, ease: ease.inOut })
        .set(curtain, { autoAlpha: 0 });
    },
  });

  onPage(() => bindReady());
}
