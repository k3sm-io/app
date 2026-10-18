# The k3sm look for the info popover and Settings

Status: scaffold. The direction below is accepted; the Design section is the contributor's to
write in the design PR, which comes before the code.

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

## Design (left for the contributor)

To be written in the design PR:

- Part 1: the popover's layout at 420 pt, the two cards, their eyebrows, the top bar and the
  faint mark; the version cards for each case `versionLine` covers today; the update button's
  place.
- Part 2: the eyebrow style, the corner mark and version, and the one tint.
- Part 3: the asset catalog's contents, the script's steps and the tool it needs, and the
  `Palette` accent entry.
- The `docs/ARCHITECTURE.md` and `README.md` lines each part updates.

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
