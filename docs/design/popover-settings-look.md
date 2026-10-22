# The k3sm look for the info popover and Settings

Status: part 1 (the popover) designed and implemented; parts 2 and 3 to follow, each filling in
its own section below.

## Summary

The info popover and the Settings window take the k3sm look in three parts, one PR each:

1. **The popover highlight look**: the popover widens from 380 pt to 420 pt and shows the
   versions as two version cards under small-caps eyebrows.
2. **Settings**: eyebrows over the groups, the app's version beside a 16 pt mark in the
   window's corner in place of the "Version" group, and one `.tint` across the panes.
3. **An app accent colour** through `NSAccentColorName`, from a committed one-colour asset
   catalog (`Assets.car`), light #022ffb and dark #7d97ff.

## Scope

In scope:

- `StatusPopoverPanel` and its version row (`Sources/K3smApp/Views.swift`).
- The Settings panes' group titles, the "Version" group in `Sources/K3smApp/GeneralPane.swift`,
  and the panes' tint.
- The app's accent colour, its asset catalog and the script that reproduces it.

Out of scope:

- What the popover reports (the status, the checks, the lifecycle and update controls) and what
  Settings controls; only their look changes.
- The console window, its tabs and the navy Mac panel.

## Decisions fixed by the maintainer

1. **Three PRs, in order**: the popover (1), then Settings (2), then the accent colour (3).
   Parts 1 and 2 stand without part 3: each looks right with the system accent.
2. **Version cards are `K3smStatus` decisions.** Which cards the popover shows, their eyebrows,
   values and notes are decided in `K3smStatus` beside `AppVersion.versionLine`, and
   unit-tested. The contract sketch is `VersionCard` in `Sources/K3smStatus/VersionCards.swift`;
   it is a proposal this design PR may change. Part 2 needs no new decision type: its corner
   version is `AppVersion.title`, which exists, and its eyebrows restyle the groups' titles.
   Part 3 needs none either.
3. **The asset catalog is committed only with the script that reproduces it.** `Assets.car`
   lands together with `hack/make-accent.sh`, reviewed the way `Resources/AppIcon.icns` and
   `hack/make-icon.sh` are: running the script reproduces the committed file. It uses only tools
   that ship with Xcode or the Command Line Tools. The accent pair in the catalog (light
   #022ffb, dark #7d97ff) is the same pair as a `Palette` accent entry in code. A user-chosen
   system accent still wins.
4. **No dependency.** `Package.swift`, `hack/verify-deps.sh` and `hack/deps.allow` are not
   touched by any of the three parts.
5. **Every new control gets a help tag from the catalog** in `Sources/K3smStatus/Help.swift`,
   per `CLAUDE.md`; every new string the popover shows comes from `K3smStatus`, every
   cluster-supplied part clipped by `StatusDisplay.clip`.
6. **Contrast is stated per mode.** Every colour a part adds or reuses for text or a mark
   states its contrast ratio against its surface in the light and in the dark appearance, as
   the entries in `Sources/K3smApp/Palette.swift` do (text at least 4.5:1, WCAG 2).

## Design

### Part 1: the popover

**Layout at 420 pt.** `StatusPopoverPanel.width` goes from 380 to 420 pt so the two version
cards sit side by side with room for a note. Padding is 18 pt at the sides, 20 pt at the top
(under the bar) and 16 pt at the bottom. The order inside `StatusView` is unchanged: the
status headline (17 pt bold), the stopped-by and health lines, the problem rows, the stream
line, then the version cards, the lifecycle controls, the update plan, the divider and
"All checks".

**The bar and the mark.** A 3 pt `Rectangle` in `Palette.accent` runs along the top edge, and
`Butterfly` is drawn 150 by 143 pt in `Palette.navy` at 6 percent opacity, offset 28 pt right
and 24 pt down so it bleeds off the bottom-right corner; the panel is clipped. Both are
decoration: `accessibilityHidden(true)`, no help tag (neither is a control or a meaning-bearing
mark). `Palette.accent` is new: light #022ffb (7.49:1 on white, 6.34:1 on #ececec), dark
#7d97ff, the navy's dark value (6.15:1 on #1e1e1e, 4.73:1 on #323232); #022ffb alone measures
2.22:1 on #1e1e1e, which is why the pair. Part 3 ships the same pair as the app's accent.

**The version cards.** `AppVersion.versionCards(installed:payload:)` in `K3smStatus` decides
two `VersionCard`s for the same cases `versionLine(installed:payload:)` covers, and the
view renders what it is given:

| case | first card | second card |
|---|---|---|
| release build, installed older | INSTALLED 0.1.8 | THIS APP 0.1.9 · a newer release |
| release build, installed the same | INSTALLED 0.1.9 | THIS APP 0.1.9 · up to date |
| release build, installed newer | INSTALLED 0.2.0 | THIS APP 0.1.9 · an older release |
| release build, installed unknown | INSTALLED unknown | THIS APP 0.1.9 |
| development build (no release carried) | INSTALLED 0.1.8 | THIS APP v0.0.0-0.2026…-910af952ea03 · development build |
| binary outside a bundle | INSTALLED 0.1.8 | THIS APP unknown |

The eyebrows are `VersionCard.installedEyebrow` and `VersionCard.appEyebrow`, stored as shown
(small capitals are the text, not a style). Values are `SemanticVersion` descriptions or
`AppVersion.text`, already clipped; a development build never shows `0.0.0`. `versionLine`
stays as the cards' accessibility label (the two cards are one accessibility element), so
VoiceOver reads the sentence it read before.

**The cards on screen.** `VersionCardView` draws a card: the eyebrow at 11 pt semibold with
0.6 pt tracking, the value at 20 pt semibold with monospaced digits (one line; a long
pseudo-version scales down to 60 percent and truncates in the middle), the note at 12 pt
secondary after it, 10 pt vertical and 12 pt horizontal padding, `Palette.raised` fill,
`Palette.line` border, 8 pt continuous corners, and a 3 pt left edge. The first card's edge
is `Palette.accent` and its eyebrow `Palette.navy` (12.4:1 light, 4.67:1 dark on the tint);
the second card's edge is `Palette.unknown` and its eyebrow `Palette.ink2` (5.60:1 / 6.41:1
at worst). The value and the note keep the system's primary and secondary text colours.

**The update button's place.** Under the cards, left-aligned, small, with the same
`Help.Strip.update(plan)` tag and the same enablement as before. `UpdateSection` keeps the
plan's line under it.

**Section eyebrows.** Two small-caps titles from `StatusPopover` in `Palette.navy`, each
shown only when it has something under it: `buildNotesTitle` ("What this build can do") over
the lifecycle controls when the popover carries a note on what the build cannot do
(`lifecycleSupport` unavailable or `availability` disabled), and `updatesTitle` ("Updates")
over the update plan's line while there is one. With no note the lifecycle controls stand
alone, as today. "All checks" keeps its title and takes 14 pt medium in `Palette.navy`, the
disclosure chevron tinted the same.

**The height cap.** The content sits in a vertical `ScrollView`, and the panel is as tall as
its measured content (`AppModel.statusPopoverMeasured`, published only when it moves by a point
or more) up to `StatusPopoverPanel.maxHeight(screen:)`: the main screen's visible height less a
120 pt margin (`screenMargin`), never under a 200 pt floor (`floor`), with 800 pt standing in
when there is no screen to ask. Past the cap the content scrolls, so an open All checks list on
a short screen stays reachable, and a closed one takes only its own room. Before the first
measurement `height(content:screen:)` is nil and the popover sizes itself.
`Tests/K3smAppTests/StatusPopoverPanelTests.swift` pins the cap, the margin, the floor and the
stand-in.

**Not changed.** What the popover reports, its controls and their help tags, the root step's
log and the outcome message.

**Docs.** `docs/ARCHITECTURE.md`: the `AppVersion` row names `versionCards` beside
`versionLine`; the `StatusPopover` row names the two section titles; the `Views` row says the
popover is 420 pt with the cards and scrolls past its height cap. `README.md`: the info button's paragraph says the versions
are two cards with the Update button under them.

### Part 2: Settings

To be written in part 2's PR: the eyebrow style, the corner mark and version, and the one tint.
### Part 3: the accent colour

To be written in part 3's PR: the asset catalog's contents, the script's steps and the tool it
needs, and how the catalog's pair matches `Palette.accent`.

## Gate

Each part's PR owes:

- **Part 1**: `Tests/K3smStatusTests/VersionCardsTests.swift`, which today pins the contract's
  shape only and gains a test for every case of the cards; `Tests/K3smStatusTests/AppVersionTests.swift`
  and `Tests/K3smStatusTests/StatusPopoverTests.swift` stay green.
- **Part 2**: `Tests/K3smStatusTests/HelpCatalogTests.swift` for any new tag, and
  `hack/verify-help.sh` (run by `hack/ci.sh`).
- **Part 3**: `hack/make-accent.sh` reproduces the committed `Assets.car`, and the bundle built
  by `hack/build-app.sh` carries it and names it in `NSAccentColorName`.
- **Every part**: `K3SM_DIR=<k3sm checkout> hack/ci.sh`, the app gate, green.

## Open questions

Answered by the maintainer when the direction was accepted:

- **Which of the three parts?** All three, one PR each, in the order above.
- **Is a committed binary asset catalog acceptable?** Yes, as a reviewed build input committed
  with the script that reproduces it, like the app icon.
