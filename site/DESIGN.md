# MicroVM site

## Concept card

```
Idea:        Give a coding agent a copied project in a local Linux sandbox, then review what comes back.
Metaphor:    The task lifecycle, shown as a short command sequence beside the promise.
Signature:   Four annotated commands, clone → exec → diff → finish, with a live caret at the entry point.
Emotion:     I understand what this does, how to start, and what happens to my files.
Motion verb: snap. A label shifts 4px and its rule locks. Nothing travels, pins, or illustrates.
Screenshot:  The outcome at display size, beside the complete task lifecycle.
```

Anchor: MicroVM copies a project into a disposable workspace, executes commands through one local daemon, and exports verified results before destroying the guest. The guest has its own kernel, no host directory mount, and no network device by default.

Audience: experienced developers and frequent coding-agent users. The page is a product introduction with a short tutorial path, not a replacement for CLI reference.

Approved narrative: outcome → everyday workflow → initial setup → MCP + skill → CLI/SDK → isolation → runtimes → qualified measurements → get started.

User steering: lead installation with Homebrew, show curl and source as alternatives, even before publishing the release channels.

Concept alternatives (originality / fit / feasibility / portability, lower portability is better):

- Task lifecycle, from the actual working process: 4 / 5 / 5 / 1. Selected because it makes the next action and the result explicit. Signature is the annotated command sequence; emotion is confidence; screenshot is headline beside four commands.
- Guest boundary, from the isolation architecture: 4 / 5 / 3 / 2. A host/guest dividing line could explain separation but would delay the first useful action. Signature would be commands crossing the boundary; emotion is control.
- Command grammar, from the CLI's formal system: 3 / 4 / 5 / 3. A page organized by verbs would be concise but too close to reference documentation. Signature would be a command index; emotion is precision.

Idle: the caret only, driven by the existing GSAP clock and paused off screen. Docs and the 404 stay still. Native scrolling. No loader, progress bar, pinned chapters, or figure.

## Palette

| Role    | Hex       | Use                                        |
| ------- | --------- | ------------------------------------------ |
| ground  | `#000000` | The machine. Every page.                   |
| ink     | `#F2F2F0` | Type and the wordmark                      |
| muted   | `#A3A39C` | Secondary type. Passes AA on black         |
| line    | `#2A2A28` | Hairlines                                  |
| accent  | `#F0A202` | The ready mark: caret, focus, current rule |
| curtain | `#000000` | Page transition panel                      |

The accent is the caret and the lock rule. It is never a filled button and never a colored word in a headline.

## Type

- Switzer (Fontshare), weights 400, 500, 600. Display and UI.
- IBM Plex Mono, weights 400 and 500. The time unit, commands, and code.
- Display tracking: the time `-0.06em`, headlines `-0.045em`. Leading 0.82 on the time, 0.92 on display, 1.5 on body.
- Body 16 to 18px. Nav and captions 13 to 14px.

## Grid and shape

12 columns. Gutter `clamp(1rem, 0.6rem + 1.6vw, 2.5rem)`. Radius is 0. Section padding alternates between `8u` and `14u`.

## Motion

One easing family from the engine (`expo.out`, `expo.inOut`, `power3.out`). Large moves are slower than small ones. The only repeating motion is the caret, 0.45s, `steps(1)`.

- Primary targets (nav, copy, command links, CTAs): the label snaps 4px right and a 2px rule locks from the left. Press shifts 1px down. Under reduced motion the rule is already there and nothing translates.
- Utility links (license, docs in the footer): color only.
- Inline links in docs: underline at rest. The guide sidebar uses color and a 2px current rule, with no hover draw.
- Page transition: an accent rule draws across the page that is already on screen, then draws back off the next page. The panel stays clear, so type never disappears into a black frame.
- Reduced motion: native scroll, no caret blink, no intro. Every section is in document flow.

## Composition

```
HERO       [outcome + explanation + start link | annotated task lifecycle]
SETUP      [initial preparation explanation   | installation guide]
           [01 Homebrew install             | copyable brew + curl/source alternatives]
           [02 prepare description           | copyable doctor commands]
AGENTS     [MCP tools + setup                 | skill rules + source file]
           [terminal | purpose | reference link], then SDK
BOUNDARY   [guest kernel and isolation        | concrete guarantees]
RUNTIMES   [project detection explanation], then compact runtime scale
EVIDENCE   [qualified claim                   | measurement conditions link]
           [raw boot        | tiny project   | repository clone]
           [method and exclusions]
CLOSE      [your next task                    | get started + docs]
```

Phone at 390px: the headline, explanation and primary start action precede the workflow. Setup descriptions precede their code. Measurements become rows with values to the right. Code wraps within its own surface. Display type uses mixed rem/viewport clamp values with bounds below a 2.5 ratio so zoom can enlarge text.

## Genericness test

Preserve the existing black/amber, Switzer/Plex identity. Replace the giant benchmark hero with the actual lifecycle. No terminal window chrome, fake output, gradient, feature-card kit, or new animation system. The numbers support the argument after readers understand the workflow.

## Copy limits and evidence

The user explicitly chose the intended release experience: Homebrew is primary, curl and source builds are alternatives. Homebrew and https://microvm.dev/install.sh are planned launch contracts, marked placeholder in the content data. The source build remains available today. Do not invent a published skill installer. Start source snippets from an existing MicroVM source checkout and link the full prerequisite guide. Doctor's first preparation downloads verified inputs and may take minutes; do not imply first installation takes milliseconds. The hero example runs uname rather than assuming project dependencies exist.

SDK and MCP packages ship in this repository; their public npm packages are not available. Link local setup guides. The production URL https://microvm.dev remains a placeholder.

299 ms: raw run median, 6 runs after warmup; 491 ms: one-file shell:1 clone, 3 runs; 989 ms: repository clone, 387 files, 2 runs. One Apple Silicon Mac, 13 Nov 2026, daemon already running and artifacts prepared. Raw run used 1 vCPU, 1024 MB, warm page cache. Source: docs/research/boot-time.md. Never conflate raw boot, project import, dependency installs, or first preparation.

MCP and the MicroVM skill must be discoverable from the hero and primary navigation. Distinguish tool access from procedural instructions. Serve the repository skill as raw Markdown at /skill.md so the linked content stays in sync. Never present the unpublished skill installer as available.

## Verification, 14 November 2026

Production build passes. Final site audit crawled 21 pages: zero FAIL and zero WARN. Final browser checks found no broken internal links; the brew copy button matches the displayed command; /skill.md matches the repository skill byte for byte. No horizontal overflow at 320, 390, 768, 1024, or 1920 pixels. Homepage, docs index, task tutorial, and 404 have no runtime exceptions or axe violations in the final build. Expanded installation alternatives remain keyboard accessible; the inline prerequisite link is 24px tall.

Two visual QA passes covered desktop, throttled mobile, reduced motion, keyboard focus, hover, and navigation. Homepage throttled mobile LCP: 864ms; CLS: 0; scroll: 60fps. Reduced motion hides no content and has no moving elements. Small caret motion is intentional and may fall below the automated idle-motion detector's threshold; no decorative animation was added to satisfy it.

Fresh critic estimate: Design 8.0, Usability 8.5, Creativity 7.2, Content 8.5; weighted 8.04/10. Remaining opportunities: vary one lower section's split composition, and show a real agent change becoming a patch. Preserve the approved restrained identity rather than adding spectacle for originality alone.

Astro check still reports the pre-existing GSAP callback return-type error in src/engine/reveal.ts:109. That file is outside this change. Production compilation succeeds.
