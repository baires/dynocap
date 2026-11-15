import { writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import * as k from "/Users/alexissgarbossa/.agents/skills/anatomy/kit/iso-kit.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const WIDTH = 640;
const HEIGHT = 420;

const PLATE = { x: -156, y: -84, w: 312, d: 168, r: 8 };
const PLATE_H = 12;
const FOOT_H = 5;
const CHAMBER = { x: -8, y: -34, w: 112, d: 74, r: 3 };
const CH_H = 44;
const LID = k.insetPlan(CHAMBER, 3);
const LID_H = 7;
const SLIP = { x: CHAMBER.x + CHAMBER.w - 6, y: -6, w: 34, d: 16, r: 1 };
const SLIP_Z = 20;
const TRAVEL = 40;
const TERM = { x: -138, y: -16, w: 30, d: 34, r: 2 };
const TERM_H = 16;

const P = k.fitProjection(
  [
    ...k.boxCorners(PLATE, -PLATE_H - FOOT_H, 0),
    ...k.boxCorners(CHAMBER, 0, CH_H + LID_H),
    [SLIP.x + SLIP.w + TRAVEL, SLIP.y, SLIP_Z],
  ],
  WIDTH,
  HEIGHT,
  { pad: 36, azimuth: 48 }
);

const at = (point) => k.iso(point, P);
const S = (paths, style) => k.solidSvg(paths, style);
const L = (d, style) => k.lineSvg(d, style);
const D = (points, style) => k.dotsSvg(points, style);
const byDepth = (points) =>
  [...points].sort(
    (a, b) => k.depthOf([a[0], a[1], 0], P) - k.depthOf([b[0], b[1], 0], P)
  );

function plate() {
  const out = [
    `<path class="iso-halo" d="${k.haloOf(PLATE, -PLATE_H - FOOT_H, PLATE_H, P)}"/>`,
  ];
  for (const [x, y] of byDepth(k.corners(PLATE, 18))) {
    out.push(
      S(k.cylinder(x, y, 7, -PLATE_H - FOOT_H, 1.8, P, 24), { tone: "lo" })
    );
    out.push(
      S(k.cylinder(x, y, 5.2, -PLATE_H - FOOT_H + 1.8, FOOT_H - 1.8, P, 24), {
        tone: "mid",
      })
    );
  }
  out.push(S(k.slabOf(PLATE, -PLATE_H, PLATE_H, P, 8, 1.4), { tone: "mid" }));
  out.push(L(k.planOutline(k.insetPlan(PLATE, 7), 0, P), { tone: "lo" }));
  const screws = k.corners(PLATE, 12);
  out.push(
    L(screws.map(([x, y]) => k.ring(x, y, 2.4, 0, P, 16)).join(""), {
      tone: "lo",
    })
  );
  out.push(
    D(
      screws.map(([x, y]) => at([x, y, 0])),
      { size: 0.5 }
    )
  );
  const strip = {
    x: PLATE.x + 16,
    y: PLATE.y + PLATE.d - 16,
    w: PLATE.w - 32,
    d: 7,
    r: 1,
  };
  out.push(S(k.slabOf(strip, 0, 0.7, P, 3), { tone: "lo", crease: "none" }));
  const ticks = k.topTicks(
    strip.x + 4,
    strip.x + strip.w - 4,
    8,
    4,
    strip.y + 0.8,
    0.7,
    [1.6, 3.2],
    P
  );
  out.push(L(ticks.minor, { tone: "lo" }), L(ticks.major, { tone: "mid" }));
  out.push(
    D(
      [
        at([strip.x + 2, strip.y + 3.5, 0.7]),
        at([strip.x + strip.w - 2, strip.y + 3.5, 0.7]),
      ],
      { size: 0.45 }
    )
  );
  const label = { x: -20, y: PLATE.y + 10, w: 46, d: 14, r: 1 };
  out.push(S(k.slabOf(label, 0, 0.8, P, 3), { tone: "lo", crease: "none" }));
  out.push(
    L(k.planOutline(k.insetPlan(label, 1.5), 0.8, P), { tone: "faint" })
  );
  out.push(
    D(
      k.corners(label, 2).map(([x, y]) => at([x, y, 0.8])),
      { size: 0.35 }
    )
  );
  return out.join("");
}

function terminal() {
  const out = [];
  out.push(S(k.slabOf(TERM, 0, TERM_H, P, 4, 0.6), { tone: "mid" }));
  out.push(
    L(k.planOutline(k.insetPlan(TERM, 2), TERM_H, P), { tone: "faint" })
  );
  const posts = [
    [TERM.x + 8, TERM.y + 10],
    [TERM.x + 8, TERM.y + TERM.d - 10],
  ];
  for (const [x, y] of posts) {
    out.push(S(k.cylinder(x, y, 2.2, TERM_H, 3, P, 16), { tone: "mid" }));
    out.push(L(k.ring(x, y, 2.2, TERM_H + 3, P, 16), { tone: "lo" }));
    out.push(D([at([x, y, TERM_H + 3])], { size: 0.4 }));
  }
  const cable = {
    x: TERM.x + TERM.w - 2,
    y: -3,
    w: CHAMBER.x - (TERM.x + TERM.w) + 6,
    d: 6,
    r: 1,
  };
  out.push(S(k.slabOf(cable, 8, 4, P, 3, 0.3), { tone: "mid" }));
  out.push(S(k.cylinder(CHAMBER.x + 4, 0, 4.2, 6, 8, P, 20), { tone: "mid" }));
  out.push(L(k.ring(CHAMBER.x + 4, 0, 4.2, 14, P, 20), { tone: "lo" }));
  out.push(
    S(k.cylinder(TERM.x + TERM.w - 2, 0, 3.4, 8, 4, P, 16), { tone: "lo" })
  );
  return out.join("");
}

function chamber() {
  const out = [];
  out.push(S(k.slabOf(CHAMBER, 0, CH_H, P, 6, 0.8), { tone: "mid" }));
  out.push(
    L(k.planOutline(k.insetPlan(CHAMBER, 2.2), CH_H, P), { tone: "lo" })
  );
  out.push(S(k.slabOf(LID, CH_H, LID_H, P, 6, 0.5), { tone: "mid" }));
  const lidScrews = k.corners(LID, 6);
  out.push(
    L(
      lidScrews
        .map(([x, y]) => k.ring(x, y, 1.8, CH_H + LID_H, P, 14))
        .join(""),
      { tone: "lo" }
    )
  );
  out.push(
    D(
      lidScrews.map(([x, y]) => at([x, y, CH_H + LID_H])),
      { size: 0.4 }
    )
  );
  const window = k.insetPlan(LID, 14);
  out.push(L(k.planOutline(window, CH_H + LID_H, P), { tone: "mid" }));
  out.push(
    L(k.planOutline(k.insetPlan(window, 2), CH_H + LID_H, P), { tone: "faint" })
  );
  const knob = [LID.x + LID.w - 16, LID.y + 14];
  out.push(
    S(k.cylinder(knob[0], knob[1], 5.5, CH_H + LID_H, 5, P, 28), {
      tone: "mid",
    })
  );
  out.push(
    L(k.knurl(knob[0], knob[1], 5.5, CH_H + LID_H, CH_H + LID_H + 5, 28, P), {
      tone: "lo",
    })
  );
  out.push(
    L(
      k.lineOnTop(
        [knob[0], knob[1]],
        [knob[0] + 5.5, knob[1]],
        CH_H + LID_H + 5,
        P
      ),
      { tone: "hi" }
    )
  );
  out.push(
    D([at([knob[0], knob[1], CH_H + LID_H + 5])], { size: 0.45, tone: "hi" })
  );
  const lamp = [LID.x + 14, LID.y + LID.d - 14];
  out.push(
    S(k.cylinder(lamp[0], lamp[1], 3.2, CH_H + LID_H, 2.4, P, 20), {
      tone: "mid",
      lit: true,
    })
  );
  out.push(
    L(k.ring(lamp[0], lamp[1], 3.2, CH_H + LID_H + 2.4, P, 20), { tone: "lit" })
  );
  const backLip = {
    x: CHAMBER.x + CHAMBER.w - 2,
    y: SLIP.y - 3,
    w: 4,
    d: SLIP.d + 6,
    r: 0.6,
  };
  out.push(S(k.slabOf(backLip, SLIP_Z - 3, 2.2, P, 2, 0.2), { tone: "lo" }));
  return out.join("");
}

function slip() {
  const frontLip = {
    x: CHAMBER.x + CHAMBER.w - 2,
    y: SLIP.y - 3,
    w: 4,
    d: SLIP.d + 6,
    r: 0.6,
  };
  return [
    `<g data-part="slip">`,
    S(k.slabOf(SLIP, SLIP_Z, 1.4, P, 3, 0.2), { tone: "hi", flat: true }),
    L(k.planOutline(k.insetPlan(SLIP, 2), SLIP_Z + 1.4, P), { tone: "mid" }),
    `</g>`,
    S(k.slabOf({ ...frontLip, y: frontLip.y }, SLIP_Z + 1.6, 2.2, P, 2, 0.2), {
      tone: "mid",
    }),
    S(
      k.slabOf(
        {
          x: CHAMBER.x + CHAMBER.w + 28,
          y: SLIP.y - 2,
          w: 4,
          d: SLIP.d + 4,
          r: 0.4,
        },
        0,
        SLIP_Z + 4,
        P,
        2
      ),
      { tone: "lo" }
    ),
  ].join("");
}

const svg = k.figureSvg({
  width: WIDTH,
  height: HEIGHT,
  label:
    "A sealed chamber on a bench. A cable leaves the left side and a patch slip leaves the right.",
  body: [plate(), terminal(), chamber(), slip()],
});

const unit = k.axisVector(P, [1, 0, 0]);
const body = k.plateHtml({
  fig: "Fig 1",
  title: "Sealed chamber",
  hint: "Slide the patch",
  readout: "sealed · port 5252",
  keys: [
    {
      mark: "lit",
      label: "The lamp is the only thing lit while the guest is sealed",
    },
    {
      mark: "raised",
      label: "The patch slip, which travels 40 units out of the slot",
    },
  ],
  caption:
    "A bench chamber for one guest. The flat cable is the vsock on port 5252. Slide the slip and the patch leaves. The lamp stays on the lid.",
  body: `<div class="iso-stage" tabindex="0" role="slider" aria-label="Sealed chamber. Arrow keys slide the patch out of the slot." aria-valuemin="0" aria-valuemax="${TRAVEL}" aria-valuenow="0" aria-valuetext="sealed, port 5252">${svg}</div>`,
});

const page = k.pageHtml({
  title: "Sealed chamber",
  theme: "dark",
  body,
  width: 720,
});
writeFileSync(join(HERE, "chamber.html"), page);
writeFileSync(
  join(HERE, "chamber-data.json"),
  JSON.stringify({ unit, travel: TRAVEL, port: 5252 })
);
writeFileSync(join(HERE, "../../src/figures/chamber-plate.html"), body);
writeFileSync(join(HERE, "../../src/figures/chamber.css"), k.ISO_CSS);
console.log("wrote chamber", unit);
