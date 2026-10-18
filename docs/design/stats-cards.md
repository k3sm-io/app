# Stats cards and headline figures

Status: scaffold. The direction below is accepted; the Design section is the contributor's to
write in the design PR, which comes before the code.

## Summary

The Stats tab moves from one navy tile per chart to cards that follow the app's appearance:
light cards by day and the site's dark palette by night. Each card carries an SF Symbol, the
chart's title and its units, and a headline figure where the chart's data has one.

## Scope

In scope:

- The Stats tab's cards: their surface, the symbol, title and units over each chart, the
  headline figure and its caption, and the chart styling inside the card.
- The headline figures as decisions in `K3smStatus`, with unit tests.
- The palette entries the cards need, each with a light and a dark value.

Out of scope:

- The "All clear" summary card.
- `StatsHistory`, `StatsSeries` and what the charts plot; the cards render the series the tab
  already has.
- Every tab other than Stats, and the navy Mac panel, which keeps its look.

## Decisions fixed by the maintainer

1. **Light by day, dark by night.** The cards are light in the light appearance and use the
   site's dark palette in the dark appearance, following the app's appearance setting. They are
   no longer drawn in a forced dark appearance.
2. **One PR** carries the cards and the headline figures together.
3. **The navy panel look is retired on this tab.** The Stats tab no longer uses
   `Palette.deepRaised` tiles; the navy Mac panel elsewhere is unchanged.
4. **The "All clear" summary card is out of scope** for this work.
5. **Headline figures are `K3smStatus` decisions.** Which charts carry a headline, the figure,
   and its caption are decided in `K3smStatus` and unit-tested; the view only renders them. A
   chart without the data for one shows no headline, never a zero. The contract sketch is
   `StatsHeadline` and `StatsCardLabel` in `Sources/K3smStatus/StatsCards.swift`; it is a
   proposal this design PR may change.
6. **Strings and help tags follow the app's rules** (`CLAUDE.md`): every new string a card shows
   comes from `StatsDisplay` (or a type beside it in `K3smStatus`), every cluster-supplied part
   passes `StatusDisplay.clip`, and every new control or unlabelled mark gets its help tag from
   the catalog in `Sources/K3smStatus/Help.swift`.
7. **Palette entries state their contrast.** Each new `Palette` entry carries a light and a dark
   value with its contrast ratio stated against the surface it sits on, as the existing entries
   in `Sources/K3smApp/Palette.swift` do (text at least 4.5:1, WCAG 2).

## Design (left for the contributor)

To be written in the design PR:

- The card's layout: symbol, title, units, headline and chart, and how the grid flows.
- The palette entries, their light and dark values and the contrast ratio of each.
- The symbol for each `StatsChart`, and where it lives (`StatsCardLabel` or `StatsChart`).
- Which charts carry a headline, its figure and caption, and the input each is decided from.
- The empty state inside a card (today `StatsEmptyLine`).
- The chart styling inside a card (bars, lines, series colours in both appearances).
- The `docs/ARCHITECTURE.md` rows the change updates.

## Gate

The implementation PR owes:

- `Tests/K3smStatusTests/StatsCardsTests.swift`: today it pins the contract's shape only; the
  implementation adds a test for each card's label and for each chart's headline, its absence
  included.
- `Tests/K3smStatusTests/StatsTests.swift`: the existing Stats tests stay green, and the
  `HelpCatalogTests` pass for any new tag.
- `K3SM_DIR=<k3sm checkout> hack/ci.sh`: the app gate, green.

## Open questions

Answered by the maintainer when the direction was accepted:

- **Cards and headlines as one PR, or headlines first?** One PR.
- **Should the Stats tab leave the navy panel look?** Yes; the navy look is retired on this
  tab.
