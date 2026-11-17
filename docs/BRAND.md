# k3sm brand in the app

This page records how the app carries the k3sm brand that k3sm.io uses, so a
view, an icon or a release asset can be checked against one list. The site's
stylesheet is the reference: where the app differs from it, the difference is
listed under [Open differences](#open-differences) until the maintainers rule
on it.

## The mark

The mark is the butterfly. Its source of truth is `Resources/k3sm-mark.svg`,
the same paths the site serves as `favicon.svg` (the favicon only crops the
view box to a square).

| Part | Light | Dark | Used for |
|---|---|---|---|
| Upper wings (`k3sm-a`) | `#022ffb` | `#6f88fe` | the bright half of the two-tone mark |
| Lower wings (`k3sm-b`) | `#011389` | `#2d48fe` | the deep half |

The app draws the mark in three forms:

- **Two-tone**, from the SVG: the app icon (`hack/make-icon.sh` renders
  `Resources/AppIcon.icns`).
- **One silhouette**, from `Butterfly.swift`: the wordmark glyph, which flaps
  (see [Motion](#motion)). The path is the SVG's outline normalised to the
  favicon's square view box.
- **Template**, from `StatusImage.swift`: the menu bar status item, flat black
  that the menu bar tints, with the degraded triangle and the LAN dot as
  badges.

Rules:

- Change the mark in the SVG first, then regenerate the icon and update
  `Butterfly.swift` from it. Never edit one copy alone.
- Never recolour the two-tone mark outside the four values above, and never add
  outlines, gradients or shadows to the mark itself. The single-colour forms
  (template, silhouette) take their colour from the surface they sit on.
- The name is written `k3sm`, lowercase, everywhere, including the start of
  a sentence.

## Colour

The site defines its colours as roles (`--accent`, `--ink`, `--muted`, ...).
The app's `Palette` names colours by role too, so a view never spells a hex
value. The site's roles, for reference:

| Role | Site light | Site dark |
|---|---|---|
| brand bright / deep | `#022ffb` / `#011389` | same |
| accent (links, focus, selection) | `#1633e0` | `#7d97ff` |
| background / surface | `#f7f7f8` / `#ffffff` | `#0a0b0d` / `#101216` |
| ink / muted | `#0b0c0e` / `#6b7177` | `#f3f4f6` / `#9aa1a9` |
| line / line strong | `#e4e6ea` / `#b9bec6` | `#23262c` / `#454a53` |
| good / warn | `#216e45` / `#875810` | `#4cc287` / `#e0a33e` |

The app's accent, not the system blue, marks what is selected or active in
the console: the selected tab's capsule in the strip (`Palette.tint` fill,
`Palette.accent` outline, `Palette.navy` label), the strip's glyphs, and the
focus ring, which takes the catalog's AccentColor (`Palette.controlAccent`).

Text colours meet WCAG AA (4.5:1) against the surface they sit on, in both
appearances. The site's dark palette does throughout (lowest 6.32:1); in
light one pairing falls short: `.swap__tag` sets `--muted` text on
`--surface-2`, 4.37:1. The app's text colours meet it since #31, by the
figures `Palette.swift` gives for each (see [Resolved](#resolved)).

## Type

System faces only, on the site and in the app: San Francisco for text
(`system-ui`, `.system`) and SF Mono for code, names and figures
(`ui-monospace`, `.monospaced`). Figures that update in place use tabular
numbers.

## Open differences

Each item is a place where the app and the site disagree today. Each one
needs a maintainer ruling, not a silent fix.

1. **Accent.** The app uses brand bright `#022ffb` as its accent. The site
   uses `#1633e0` for its accent and keeps `#022ffb` for the mark.
2. **Neutrals.** The app's light-appearance greys are blue-tinted (`wash`
   `#f6f7fb`, `ink2` `#565c73`, `dimText` `#5f6478`); its surface and rules
   are the system's (`windowBackgroundColor`, `separatorColor`). The site's
   are near-neutral (`#f7f7f8`, `#e4e6ea`, `#6b7177`).
3. **Status colours.** The app's ok `#17914f`, warn `#b86a00` and bad
   `#c9302c` are the same in both appearances and differ from the site's
   good `#216e45` and warn `#875810` (the site has no "bad" role). The app
   draws them as dots, so the bar is 3:1 for non-text (WCAG 1.4.11), which
   they meet: the lowest is bad on the dark surface `#1e1e1e` (the dark window background as measured, a system colour), 3.13:1.
4. **The mark's dark colours.** Of the SVG's dark wing values, `Palette`
   carries `#6f88fe` only as `dockMarkGlow` (the Dock mark's glow, #27) and
   `#2d48fe` not at all; the dark `navy` is the site's dark accent `#7d97ff`
   instead.
5. **The navy panel.** The console's Mac panel is `#070d3d` with meters in
   `#5f7bff`, `#b9c5ff` and `#3a4380`. It is the console's own surface, and
   the site has none like it. Either the site adopts it (a hero or a docs
   callout), or this page names it as app-only.
6. **The app icon on macOS 26.** `make-icon.sh` still ships the mark alone on
   a transparent canvas, which macOS 26 draws inside its grey tile. Six
   concepts with a tile of their own are in `docs/icon-concepts/` (#25;
   #33 adds a `--check` that asks macOS how it draws each, and replaces
   `breakout`, which macOS still puts in the grey tile). Five of the six
   recolour the wings and all six add a glow, both of which the mark rule
   above forbids, so adopting one also means amending that rule for the
   icon.

## Resolved

- **Contrast** (#31). `dimText` `#5f6478` / `#9a9fb3` replaces the design's
  `#8a8fa3` (3.21:1 on white): 5.86:1 on white and 6.34:1 on `#1e1e1e`.
- **Dark appearance** (#31). The console follows the system appearance; the
  palette's text and surface colours have dark values.

## Motion

The wordmark's mark flaps (#26): each wing is hinged at the body and turns
toward the viewer, two strokes in 0.8 s, then a random rest of 6 to 18 s.
It moves only while the console is on screen, never spins or bounces, and
holds still when the system's Reduce Motion setting is on. While the console
is up, the Dock icon is a navy tile that holds still with the mark flapping
on it on the same beat (#27; `Palette.dockMark`, `dockMarkGlow`,
`dockTileGlow`); every other screen keeps the shipped icon. The menu bar
item never moves; motion there reads as a notification.

Contrast figures are WCAG 2 relative-luminance ratios computed from the hex
values above.
