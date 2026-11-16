# DynoCap site

## Concept card

```
Idea:        Give a coding agent a copied project in a local Linux sandbox, then review what comes back.
Metaphor:    The task lifecycle, shown as a short command sequence beside the promise.
Signature:   Four annotated commands, clone → exec → diff → finish, with a live caret at the entry point.
Emotion:     I understand what this does, how to start, and what happens to my files.
Motion verb: snap. A label shifts 4px and its rule locks. The capsule brand mark opens on hover or keyboard focus; the page content never travels or pins.
Screenshot:  The outcome at display size, beside the complete task lifecycle.
```

Anchor: DynoCap copies a project into a disposable workspace, executes commands through one local daemon, and exports verified results before destroying the guest. The guest has its own kernel, no host directory mount, and no network device by default.

Audience: experienced developers and frequent coding-agent users. The page is a product introduction with a short tutorial path, not a replacement for CLI reference.

Approved narrative (revised 15 Nov 2026): outcome + qualified 299 ms claim → speed → isolation → control → MCP + skill → CLI/SDK → setup → get started. Speed, isolation, and control each get their own composition so the page sells why before asking for an install.

User steering: lead installation with Homebrew, show curl and source as alternatives, even before publishing the release channels.

Concept alternatives (originality / fit / feasibility / portability, lower portability is better):

- Task lifecycle, from the actual working process: 4 / 5 / 5 / 1. Selected because it makes the next action and the result explicit. Signature is the annotated command sequence; emotion is confidence; screenshot is headline beside four commands.
- Guest boundary, from the isolation architecture: 4 / 5 / 3 / 2. A host/guest dividing line could explain separation but would delay the first useful action. Signature would be commands crossing the boundary; emotion is control.
- Command grammar, from the CLI's formal system: 3 / 4 / 5 / 3. A page organized by verbs would be concise but too close to reference documentation. Signature would be a command index; emotion is precision.

Idle: the caret, and the demo recording, which plays only while half on screen and never autoplays under reduced motion. Docs and the 404 stay still. Native scrolling. No loader, progress bar, or pinned chapters. The capsule logo is the sole illustrative brand element.

## Palette

| Role    | Hex       | Use                                        |
| ------- | --------- | ------------------------------------------ |
| ground  | `#000000` | The machine. Every page.                   |
| ink     | `#F2F2F0` | Type and the wordmark                      |
| muted   | `#A3A39C` | Secondary type. Passes AA on black         |
| line    | `#2A2A28` | Hairlines                                  |
| accent  | `#F0A202` | The ready mark: caret, focus, current rule |
| curtain | `#000000` | Page transition panel                      |

The accent is the caret, the lock rule, and the capsule logo’s prompt and indicator. It is never a filled button and never a colored word in a headline.

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
- Inline links in docs: muted underline at rest, accent underline on hover. The guide sidebar and the page outline share one treatment: a 1px line rail, a 2px accent rule on the current page or section.

## Capsule identity

The shared `BrandLogo.astro` owns the horizontal capsule-and-wordmark lockup in the header and a larger footer version. Its outlined Avenir Next wordmark comes from `assets/brand`; UI typography stays Switzer/Plex. SVG ink, ground, and amber map to the existing `--c-fg`, `--c-bg`, and `--c-accent` tokens in `src/styles/tokens.css`.

On fine hover pointers, the shell rests closed; hover or visible keyboard focus opens the two halves and reveals the guest cube. Leaving or blurring closes it. Only transforms and opacity transition, within reserved bounds; there is no idle loop or new JavaScript. Touch and reduced-motion visitors see the complete open mark without animation. Home links retain their accessible name, visible focus, and normal navigation. The favicon uses the simplified capsule mark at a larger optical size, with SVG and 16/32/48px ICO variants. The 1200 × 630 social image pairs the open capsule with the outlined wordmark and a short product description, on the site’s black ground. Regenerate with `python3 scripts/generate-site-brand.py` (requires Pillow and `rsvg-convert`). GitHub links in the primary navigation and footer point to the canonical `site.repository` in `src/data/site.ts`.

## Docs

Read mode. Three columns at 1200px and wider: guide (15rem), article (70ch), outline (13rem, "On this page", h2 and h3, scroll-spied, plus the Markdown link). Below 1200px the outline hides and the Markdown link stays at the end of the article. Below 768px the guide collapses into an "All docs" disclosure.

- Headings h2 to h4 link to themselves; hover draws a 2px accent underline. Each h2 opens with a 1px rule; Markdown `---` separators are hidden so rules never double.
- Code blocks: `#0B0B0A` surface, 1px line border, a caption bar with the language and a Copy button (the site's `data-copy` handler). Lines never wrap; the block scrolls. The Shiki theme (`src/lib/shiki-theme.mjs`) uses ink, muted comments, and one warm literal `#E6CB8E`; the accent stays out of code.
- Inline code: `#161615` chip, no border; plain inside links and headings.
- Tables scroll inside `.table-scroll`; headers are muted Plex Mono. Below 768px rows stack with labels.
- The docs content cache keys on the Markdown source plus the rehype pipeline and theme, so pipeline edits re-render every page.
- Page transition: none. Navigation swaps the page instantly; there is no curtain, seam, or loading line (removed 15 Nov 2026 at the user's request).
- Reduced motion: native scroll, no caret blink, no intro. Every section is in document flow.

## Composition

```
HERO       [outcome + lede + install + qualified claim | annotated task lifecycle]
DEMO       [claim                             | recording conditions]
           [real VHS recording, full width, hairlines above and below, no window chrome]
           [play/pause | "Show the commands" transcript]
SPEED      [claim                             | lede]
           [0 to 1 s scale: 11 · 299 · 491 · 989 ms placed at true positions]
           [method and exclusions]
ISOLATION  [claim                             | lede + security link]
           [On your Mac | accent boundary line | Inside the microVM], then caveat
CONTROL    [claim                             | lede]
           [one real clone command, flags underlined in accent]
           [runtime | resources | network | lifetime]
AGENTS     [MCP tools + setup                 | skill rules + source file]
           [terminal | purpose | reference link], then SDK
SETUP      [initial preparation explanation   | installation guide]
           [01 Homebrew install             | copyable brew + curl/source alternatives]
           [02 prepare description           | copyable doctor commands]
CLOSE      [your next task                    | get started + docs]
```

Phone at 390px: the headline, explanation and primary start action precede the workflow. The speed scale becomes rows, each with a 2px accent bar whose width is its share of one second. The boundary stacks host above guest; the control command breaks one flag per line. Setup descriptions precede their code. Measurements become rows with values to the right. Code wraps within its own surface. Display type uses mixed rem/viewport clamp values with bounds below a 2.5 ratio so zoom can enlarge text.

## Genericness test

Preserve the existing black/amber, Switzer/Plex identity. Keep the lifecycle in the hero; the numbers appear once there as a qualified claim, then as a measured scale. No terminal window chrome, fake output, gradient, feature-card kit, or new animation system. The numbers support the argument after readers understand the workflow.

## Copy limits and evidence

The user explicitly chose the intended release experience: Homebrew is primary, curl and source builds are alternatives. The Homebrew command is `brew install baires/tap/dynocap` (github.com/baires/homebrew-tap). https://dynocap.dev/install.sh is the curl command, and the site serves `scripts/install.sh` at `/install.sh`. The source build remains `./scripts/build-macos.sh` from a checkout. Do not invent a published skill installer. Start source snippets from an existing DynoCap source checkout and link the full prerequisite guide. Doctor's first preparation downloads verified inputs and may take minutes; do not imply first installation takes milliseconds. The hero example runs uname rather than assuming project dependencies exist.

SDK and MCP packages ship in this repository; their public npm packages are not available. Link local setup guides. The production URL https://dynocap.dev remains a placeholder.

299 ms: raw run median, 6 runs after warmup; 491 ms: one-file shell:1 clone, 3 runs; 989 ms: repository clone, 387 files, 2 runs. One Apple Silicon Mac, 13 Nov 2026, daemon already running and artifacts prepared. Raw run used 1 vCPU, 1024 MB, warm page cache. Source: docs/research/boot-time.md. Never conflate raw boot, project import, dependency installs, or first preparation.

MCP and the DynoCap skill must be discoverable from the hero and primary navigation. Distinguish tool access from procedural instructions. Serve the repository skill as raw Markdown at /skill.md so the linked content stays in sync. Never present the unpublished skill installer as available.

## Verification, 14 November 2026

Production build passes. Final site audit crawled 21 pages: zero FAIL and zero WARN. Final browser checks found no broken internal links; the brew copy button matches the displayed command; /skill.md matches the repository skill byte for byte. No horizontal overflow at 320, 390, 768, 1024, or 1920 pixels. Homepage, docs index, task tutorial, and 404 have no runtime exceptions or axe violations in the final build. Expanded installation alternatives remain keyboard accessible; the inline prerequisite link is 24px tall.

Two visual QA passes covered desktop, throttled mobile, reduced motion, keyboard focus, hover, and navigation. Homepage throttled mobile LCP: 864ms; CLS: 0; scroll: 60fps. Reduced motion hides no content and has no moving elements. Small caret motion is intentional and may fall below the automated idle-motion detector's threshold; no decorative animation was added to satisfy it.

Fresh critic estimate: Design 8.0, Usability 8.5, Creativity 7.2, Content 8.5; weighted 8.04/10. Remaining opportunities: vary one lower section's split composition, and show a real agent change becoming a patch. Preserve the approved restrained identity rather than adding spectacle for originality alone.

Astro check still reports the pre-existing GSAP callback return-type error in src/engine/reveal.ts:109. That file is outside this change. Production compilation succeeds.

## Demo recording

`site/demo/workflow.tape` drives the real CLI through clone, exec, diff, and finish on a one-file project, with `cat README.md` before and after to show the host file unchanged. `site/demo/record.sh` records it in a throwaway `DYNOCAP_HOME` (APFS clones of the prepared image and runtime), so no personal paths reach the published video. Output: `public/demo/dynocap-workflow.{webm,mp4,png}`, about 0.5 MB each. Typing is scripted; every wait after Enter is the real command, and the timings are never edited. Theme: black ground, ink text, amber cursor, Plex Mono when installed (Menlo otherwise). Keep `demo.commands` in `src/data/site.ts` in step with the tape. Below 768px the video and its poster are not loaded; the commands list and a link to the MP4 take their place.
