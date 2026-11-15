import { prefersReducedMotion } from "../engine";

// The landing-page recording plays while it is on screen and pauses when it leaves.
// Under reduced motion it waits on its poster until the visitor presses play.
export function bindDemo() {
  const video = document.querySelector<HTMLVideoElement>("[data-demo]");
  const toggle =
    document.querySelector<HTMLButtonElement>("[data-demo-toggle]");
  if (!video || !toggle) return;
  const label = toggle.querySelector("span");
  // Phones hide the recording, so only fetch its poster where it shows.
  if (video.offsetParent && video.dataset.poster)
    video.poster = video.dataset.poster;

  let chosen = !prefersReducedMotion();
  let visible = false;

  const sync = () => {
    if (label)
      label.textContent = video.paused ? "Play recording" : "Pause recording";
  };
  const update = () => {
    if (chosen && visible) void video.play().catch(() => {});
    else video.pause();
  };

  const observer = new IntersectionObserver(
    ([entry]) => {
      visible = entry.isIntersecting;
      update();
    },
    { threshold: 0.5 }
  );
  observer.observe(video);

  const onToggle = () => {
    chosen = video.paused;
    if (chosen) void video.play().catch(() => {});
    else video.pause();
  };
  toggle.addEventListener("click", onToggle);
  video.addEventListener("play", sync);
  video.addEventListener("pause", sync);
  sync();

  return () => {
    observer.disconnect();
    toggle.removeEventListener("click", onToggle);
    video.removeEventListener("play", sync);
    video.removeEventListener("pause", sync);
    video.pause();
  };
}
