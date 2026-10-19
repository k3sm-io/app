# Stats cards and headline figures

Status: implemented. The direction below is accepted and the Design section describes what the
implementation PR builds (`StatsCards.swift` in `K3smStatus`, `StatsSection.swift` and the
`Palette.stats…` entries in `K3smApp`).

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

## Design

**The card.** One `StatsTile` per `StatsChart`, in a `LazyVGrid` of 300 pt-minimum columns with
18 pt gutters on a page of `Palette.statsPage`, so two cards sit across when the column has
room and one otherwise. Every card is 290 pt tall (`StatsSection.cardHeight`), so a row of cards
lines up whatever each one holds. A card is `Palette.statsCard` under a 14 pt radius with a
hairline `Palette.statsLine` border, 18 pt by 16 pt of padding, and reads top down: the label
(the symbol at 15 pt in `Palette.statsAccent`, 20 pt wide, then the title at 14 pt semibold in
the primary text colour), the units line at 11.5 pt in `Palette.statsMuted`, the headline when
the chart has one (the figure at 36 pt bold, monospaced digits, in `Palette.statsNumber`, its
caption at 12.5 pt in `Palette.statsMuted` on the same baseline), then the chart filling the
rest. The card follows the app's appearance; the forced dark appearance of the navy tiles is
gone, and so is `Palette.deepRaised` on this tab. The whole card is one accessibility element
and carries the chart's help tag, `Help.Stats.tag(for:)`, as the tile did; the symbol sits
beside the title that names it and is hidden from accessibility, so no new tag is needed and
the catalog is unchanged.

**The label and the symbol.** `StatsCardLabel.of(_:)` in `K3smStatus` gives each card its
`chart`, `symbolName`, `title` and `unit`; the title and units are the chart's own, the symbol
is decided in `StatsCardLabel.symbolName(for:)` and pinned by `StatsCardsTests.cardLabels`,
one distinct SF Symbol per chart, named for what the chart counts: `cpu` (CPU), `memorychip`
(memory), `shippingbox` (pods by phase), `square.stack.3d.up` (pods by node),
`arrow.clockwise` (restarts), `square.3.layers.3d` (images), `internaldrive` (storage),
`arrow.down.circle` (managed update). The symbol stays on the label type rather than on
`StatsChart`, so `StatsChart` keeps naming the chart and the label names how its card presents it.

**The headline figures.** `StatsHeadline.charts` lists the four charts that carry one, in the
tab's order; the other four (CPU, memory, images, managed update) show their chart alone, since
their data has no single figure. Each is decided from the chart's `StatsChartState`, the same
value the chart draws, by a `StatsHeadline` function in `K3smStatus`; the view only renders it.
A chart whose state is its empty line has no headline (`nil`): the line says why, and the card
never shows a zero in place of data it does not have.

| chart | figure | caption | from |
|---|---|---|---|
| Pods by phase | the Running bucket's count, `0` when the list has pods and none runs | `running` | `StatsDisplay.pods(_, StatsSeries.podsByPhase)` |
| Pods by node | the number of nodes with pods | `node carries every pod` for one node; `nodes carry N pods` otherwise (`pod` for one) | `StatsDisplay.pods(_, StatsSeries.podsByNode)` |
| Container restarts | the hour's total, `StatsSeries.restartTotal`, never zero: an hour without restarts is the chart's empty line | `in the last hour` | `StatsDisplay.restarts` |
| Storage | the data volume's free space as `WorkloadsDisplay.bytes` sizes it (`158 GB`, `1.2 GB`, `512 MB`; `0 GB` when none is free); none until the volume's report was read | `free on the data root` | `StatsDisplay.storage` |

No headline string is cluster-supplied: the figures are counts and sizes and the captions
fixed words, so nothing passes `StatusDisplay.clip`; the lines under the charts and the empty
lines keep passing through it as before.

**The empty state.** A chart with nothing to draw shows `StatsEmptyLine`: the card's own
symbol large (28 pt, light weight, `Palette.statsEmpty`, hidden from accessibility) over the
line `StatsDisplay` gives, centred in the space the chart would fill. The symbol reaches the
line through a SwiftUI environment value the card sets, so the chart views stay unaware of it.

**The palette.** Every entry has a light and a dark value and states its contrast in
`Sources/K3smApp/Palette.swift`; text is at least 4.5:1 on the card and on the page in both
appearances, marks at least 3:1 where they carry meaning.

| entry | light | dark | sits on | ratio light (card, page) | ratio dark (card, page) | role |
|---|---|---|---|---|---|---|
| `statsPage` | #f7f7f8 | #0a0b0d | | | | the page behind the cards |
| `statsCard` | #ffffff | #101216 | page | | | a card |
| `statsLine` | #e4e6ea | #23262c | card | 1.25:1 | 1.24:1 | the border and the axes' grid, a hairline |
| `statsAccent` | #1633e0 | #7d97ff | card | 8.13:1, 7.59:1 | 6.91:1, 7.26:1 | the symbol beside the title |
| `statsNumber` | #011389 | #b9c5ff | card | 14.43:1, 13.47:1 | 11.15:1, 11.71:1 | the headline figure |
| `statsMuted` | #6b7177 | #9aa1a9 | card | 4.94:1, 4.61:1 | 7.18:1, 7.54:1 | units, captions, axis labels, the empty line |
| `statsBar` | #022ffb | #6f88fe | card | 7.49:1, 7.0:1 | 5.92:1, 6.21:1 | a bar; the first series |
| `statsBarSoft` | #5f7bff | #3d5bff | card | 3.64:1, 3.4:1 | 3.69:1, 3.88:1 | the second bar: free space, Succeeded pods |
| `statsOk` | #216e45 | #4cc287 | card | 6.21:1, 5.8:1 | 8.37:1, 8.79:1 | Running pods; the second series |
| `statsWarn` | #875810 | #e0a33e | card | 6.12:1, 5.71:1 | 8.46:1, 8.89:1 | Pending pods, the restart bars; the third series |
| `statsEmpty` | #b9bec6 | #454a53 | card | 1.87:1 | 2.1:1 | the empty state's symbol, decorative beside its line |

`Palette.statsSeries` colours the usage lines and the update bands, one per node or state in
turn: `statsBar`, `statsOk`, `statsWarn`, then the existing `vm` orange (#c77700: 3.46:1 light,
5.42:1 dark), `statsNumber` and the system red `bad` (#c9302c: 5.33:1 light, 3.52:1 dark).
Failed pods keep `bad`; a phase the lists do not name takes `statsEmpty`.

**The charts inside a card.** The usage lines (CPU, memory) and the update bands keep their
plots at 150 pt with the legend when there is more than one line; the axes draw their grid in
`statsLine` and their labels in `statsMuted` in place of the white-on-navy marks. The count
charts (pods by phase, pods by node, images, storage) draw thin rounded bars: 12 pt capsules,
one 30 pt row per bar, the row labels on the left and no value axis (`StatsBars`), the count
or size at each bar's end in `statsMuted`; a chart with one bar shows neither the row label
nor the count, since the headline says both. The restart bars take `statsWarn` over the hour's
time axis.

**Out of scope, as decided.** No "All clear" card. `StatsHistory`, `StatsSeries` and the
loaders are untouched; the cards render the series the tab already has.

**Docs.** `docs/ARCHITECTURE.md`: the `StatsChart`, `StatsChartState`, `StatsInput`,
`StatsDisplay` row gains `StatsCardLabel` and `StatsHeadline`; the `StatsSection` row describes
the cards in place of the navy tiles. `README.md`: the Stats tab's sentence says cards, not navy
tiles, and names the headline figures.

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
