import { gsap } from "gsap";
import figure from "../../figures/chamber/chamber-data.json";
import { prefersReducedMotion } from "../engine";

const travel = figure.travel;
const [ux, uy] = figure.unit;

export function bindChamber() {
  const stage = document.querySelector<HTMLElement>(".iso-stage");
  const slip = stage?.querySelector<SVGGElement>('[data-part="slip"]');
  if (!stage || !slip) return () => {};
  const readout = stage
    .closest(".iso-figure")
    ?.querySelector<HTMLElement>("[data-readout]");
  let x = 0;
  let target = 0;
  let clock = 0;
  let touring = !prefersReducedMotion();
  let visible = false;
  let armed = false;
  let idle = 0;

  const textFor = (value: number) =>
    value > travel * 0.55 ? "patch out · port 5252" : "sealed · port 5252";
  const draw = () => {
    slip.setAttribute(
      "transform",
      `translate(${(ux * x).toFixed(2)} ${(uy * x).toFixed(2)})`
    );
    const text = textFor(x);
    if (readout && readout.textContent !== text) readout.textContent = text;
    stage.setAttribute("aria-valuenow", String(Math.round(x)));
    stage.setAttribute("aria-valuetext", text);
  };
  const step = () => {
    const dt = Math.min(gsap.ticker.deltaRatio(60) / 60, 0.05);
    if (visible && touring && !prefersReducedMotion()) {
      clock += dt;
      const phase = clock % 6.4;
      target =
        phase < 1.4 ? 0 : phase < 3.2 ? travel : phase < 4.6 ? travel : 0;
    }
    const next = prefersReducedMotion()
      ? target
      : x + (target - x) * (1 - Math.exp(-dt / 0.32));
    x = Math.abs(next - target) < 0.04 ? target : next;
    draw();
    if (!visible && x === target) {
      gsap.ticker.remove(step);
      armed = false;
    }
  };
  const arm = () => {
    if (!armed) {
      armed = true;
      gsap.ticker.add(step);
    }
  };
  const steer = (next: number) => {
    touring = false;
    target = Math.min(travel, Math.max(0, next));
    window.clearTimeout(idle);
    idle = window.setTimeout(() => {
      touring = !prefersReducedMotion();
      clock = 0;
      arm();
    }, 3200);
    arm();
  };
  const onPointer = (event: PointerEvent) => {
    const box = stage.getBoundingClientRect();
    const share = Math.min(
      1,
      Math.max(0, (event.clientX - box.left) / box.width)
    );
    steer(share * travel);
  };
  const onKey = (event: KeyboardEvent) => {
    const jump = event.shiftKey ? 10 : 4;
    if (event.key === "ArrowRight" || event.key === "ArrowUp")
      steer(target + jump);
    else if (event.key === "ArrowLeft" || event.key === "ArrowDown")
      steer(target - jump);
    else if (event.key === "Home") steer(0);
    else if (event.key === "End") steer(travel);
    else return;
    event.preventDefault();
  };
  const observer = new IntersectionObserver(
    (entries) => {
      visible = entries.some((entry) => entry.isIntersecting);
      if (visible) arm();
    },
    { rootMargin: "80px" }
  );
  observer.observe(stage);
  stage.addEventListener("pointermove", onPointer);
  stage.addEventListener("pointerdown", onPointer);
  stage.addEventListener("keydown", onKey);
  draw();
  return () => {
    gsap.ticker.remove(step);
    observer.disconnect();
    window.clearTimeout(idle);
    stage.removeEventListener("pointermove", onPointer);
    stage.removeEventListener("pointerdown", onPointer);
    stage.removeEventListener("keydown", onKey);
  };
}
