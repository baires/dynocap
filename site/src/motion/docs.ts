// Marks the outline entry for the section being read. Docs pages only.
export function bindDocs() {
  const links = [
    ...document.querySelectorAll<HTMLAnchorElement>(".docs-outline ol a"),
  ];
  if (!links.length) return;

  const targets = links
    .map((link) =>
      document.getElementById(decodeURIComponent(link.hash.slice(1)))
    )
    .filter((target): target is HTMLElement => Boolean(target));

  const mark = () => {
    const line = window.innerHeight * 0.25;
    let current = targets[0];
    for (const target of targets) {
      if (target.getBoundingClientRect().top <= line) current = target;
      else break;
    }
    links.forEach((link) => {
      const active = link.hash.slice(1) === current?.id;
      if (active) link.setAttribute("aria-current", "location");
      else link.removeAttribute("aria-current");
    });
  };

  let frame = 0;
  const onScroll = () => {
    cancelAnimationFrame(frame);
    frame = requestAnimationFrame(mark);
  };
  mark();
  window.addEventListener("scroll", onScroll, { passive: true });
  return () => {
    cancelAnimationFrame(frame);
    window.removeEventListener("scroll", onScroll);
  };
}
