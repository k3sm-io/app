/*
Copyright The k3sm Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

/// TabStripLayout sizes the console's strip, the row above the tab: the tab
/// labels, the search field at its minimum (Update is the Alerts tab's
/// card, so the console's strip passes no `buttonWidth`), and the four icon buttons, with the strip's gaps
/// and padding. Widths are estimated the way `PanelLayout` estimates them,
/// from character counts at the same conservative per-point advance, so the
/// estimate errs wide and a label never has to wrap or shorten at the
/// window's minimum width. A label is drawn on one line; only a label longer
/// than `labelCap` characters is shortened, at its tail.
public enum TabStripLayout {
    /// The tab labels' font size.
    public static let fontSize: Double = 13
    /// The gap between two tabs: 14 pt, the least that still holds the
    /// waiting butterfly's landing (`Perch.landingStart` is 12 pt before the
    /// label). It was 16 before the Stats tab; with `itemSpacing` and
    /// `searchMinimum` it keeps the nine labels, at the estimate's wide
    /// advance, inside a 1440 pt window with the panel and inspector shown.
    public static let tabSpacing: Double = 14
    /// The gap between the strip's items: the tabs, the spacer, the search
    /// field and the icon buttons (12 pt before the Stats tab; the strip's
    /// `HStack` uses this value).
    public static let itemSpacing: Double = 10
    /// The spacer between the tabs and the controls, at its least.
    public static let spacerMinimum: Double = 8
    /// The icon buttons at the strip's end: details, tour, info and Settings.
    public static let iconButtons = 4
    /// One icon button's width (a 16 pt symbol, estimated wide).
    public static let iconButtonWidth: Double = 20
    /// The icon buttons with the gaps between them.
    public static let controlsWidth: Double = Double(iconButtons) * iconButtonWidth + Double(iconButtons - 1) * itemSpacing
    /// The search field's minimum width (100 pt before the Stats tab); it
    /// grows to its ideal 180 pt whenever the window is wider than its least.
    public static let searchMinimum: Double = 72
    /// The strip's horizontal padding, both sides together (half each side).
    public static let padding: Double = 32
    /// The longest label drawn in full; a longer one is shortened at its tail.
    public static let labelCap = 24
    /// The update button's font size (a small control).
    public static let buttonFontSize: Double = 11
    /// The update button's padding around its title, both sides together.
    public static let buttonPadding: Double = 24
    /// The strip's height, fixed: the labels sit at its middle with room
    /// above them for a tab's waiting butterfly, so the mark never clips and
    /// the strip never grows or shifts when it appears or goes.
    public static let height: Double = 52
    /// The waiting butterfly's lowest point (the tips of its lower wings,
    /// where it stands) as a fraction of its frame's height from the top:
    /// the lowest y of the path in the app's `Butterfly` shape.
    public static let markFoot: Double = 0.9267

    /// The window's minimum width before the strip decided it, with the
    /// panel shown and the inspector at its default width.
    public static let windowFloor: Double = 1180
    /// The inspector's default width (`InspectorWidth.defaultWidth`); the
    /// user's drag of its divider moves it from there.
    public static let inspectorWidth: Double = InspectorWidth.defaultWidth
    /// The divider beside the panel, and the one beside the inspector.
    public static let dividerWidth: Double = 1

    /// The details button's symbol: the column it toggles, drawn while the
    /// inspector is shown, a plain window while it is hidden. The button
    /// keeps one colour in both states, so the symbol carries the state and
    /// the help tag (`Help.Strip.details`) says which way a click goes.
    public static func detailsSymbol(shown: Bool) -> String {
        shown ? "sidebar.trailing" : "rectangle"
    }

    /// waitingMarkFrame is where a tab's waiting butterfly is drawn, in the
    /// tab's own box: `stripHeight` tall, its one-line label centred
    /// vertically in it and starting at the box's leading edge. The label's
    /// font gives `ascent`, `descent` (both positive) and `capHeight`. The
    /// mark, `markSize` square, lands at the word's upper-left corner: its
    /// feet (`markFoot`) rest on the cap top of the label's first letter and
    /// its left edge is the label's leading edge, so its body is over that
    /// letter's left side and it never reaches back over the gap before the
    /// tab. It takes no width, so the gaps between labels are the tabs'
    /// spacing alone.
    public static func waitingMarkFrame(ascent: Double, descent: Double, capHeight: Double,
                                        markSize: Double, stripHeight: Double = Self.height) -> MarkFrame {
        let lineTop = (stripHeight - (ascent + descent)) / 2
        let capTop = lineTop + ascent - capHeight
        return MarkFrame(minX: 0, minY: capTop - markSize * markFoot, size: markSize)
    }

    /// `label` as the strip draws it: whole up to `labelCap` characters,
    /// otherwise its first `labelCap - 1` characters and an ellipsis.
    public static func display(_ label: String) -> String {
        guard label.count > labelCap else { return label }
        return String(label.prefix(labelCap - 1)) + "…"
    }

    /// One label's estimated width at `fontSize`, as drawn (`display`).
    public static func labelWidth(_ label: String, fontSize: Double = Self.fontSize) -> Double {
        Double(display(label).count) * fontSize * PanelLayout.advance
    }

    /// The tabs alone: every label at its estimated width, `spacing` apart.
    public static func tabsWidth(labels: [String], fontSize: Double = Self.fontSize, spacing: Double = Self.tabSpacing) -> Double {
        guard !labels.isEmpty else { return 0 }
        return labels.map { labelWidth($0, fontSize: fontSize) }.reduce(0, +) + Double(labels.count - 1) * spacing
    }

    /// The update button's estimated width for `title`.
    public static func buttonWidth(title: String) -> Double {
        Double(title.count) * buttonFontSize * PanelLayout.advance + buttonPadding
    }

    /// The strip's minimum width: the tabs (`tabsWidth`), the spacer at its
    /// least, the update button when one is offered (`buttonWidth` non-nil),
    /// the search field's minimum, the icon buttons, the gaps between the
    /// items and the strip's `padding`.
    public static func minimumWidth(labels: [String], fontSize: Double = Self.fontSize, buttonWidth: Double?,
                                    searchWidth: Double = Self.searchMinimum, spacing: Double = Self.tabSpacing,
                                    padding: Double = Self.padding) -> Double {
        var width = tabsWidth(labels: labels, fontSize: fontSize, spacing: spacing)
        width += itemSpacing + spacerMinimum + itemSpacing
        if let buttonWidth { width += buttonWidth + itemSpacing }
        width += searchWidth + itemSpacing
        return width + controlsWidth + padding
    }

    /// The tab column's minimum width (the strip and the tab under it): the
    /// larger of what the floor leaves after the panel, the inspector at its
    /// default width and both dividers, and the width a `strip` that wide needs.
    public static func columnMinimumWidth(strip: Double) -> Double {
        let floor = windowFloor - PanelLayout.minimum - dividerWidth - inspectorWidth - dividerWidth
        return max(floor, strip)
    }

    /// Where the window's close, minimize and zoom buttons end, measured
    /// from the window's leading edge, when the window cannot say: the
    /// standard buttons under a transparent title bar end before 78 pt.
    public static let windowButtonsFallback: Double = 78
    /// The farthest a reported button edge is believed; a larger value is a
    /// layout that has not settled, and the fallback is used instead.
    public static let windowButtonsCeiling: Double = 200

    /// The strip's leading inset. With the panel shown it is half the
    /// strip's `padding`, the strip starting beside the panel. While the
    /// panel is hidden the strip runs from the window's leading edge, under
    /// the transparent title bar, so the first tab starts that same half
    /// padding past the window buttons: `windowButtonsEdge` is where the
    /// buttons end (nil, non-finite, not positive or past
    /// `windowButtonsCeiling` takes `windowButtonsFallback`).
    public static func leadingInset(panelCollapsed: Bool, windowButtonsEdge: Double? = nil) -> Double {
        let open = padding / 2
        guard panelCollapsed else { return open }
        var edge = windowButtonsFallback
        if let reported = windowButtonsEdge, reported.isFinite, reported > 0, reported <= windowButtonsCeiling {
            edge = reported
        }
        return max(open, edge + open)
    }

    /// The strip's minimum width with its leading inset: `strip` (from
    /// `minimumWidth`, which counts half the padding on each side) plus
    /// what the collapsed panel's inset adds past that half.
    public static func stripMinimumWidth(strip: Double, panelCollapsed: Bool, windowButtonsEdge: Double? = nil) -> Double {
        strip + leadingInset(panelCollapsed: panelCollapsed, windowButtonsEdge: windowButtonsEdge) - padding / 2
    }

    /// The window's minimum width: the panel's minimum and its divider,
    /// nothing while the panel is collapsed, the tab column's minimum (for
    /// a strip that, while the panel is collapsed, also clears the window
    /// buttons, `stripMinimumWidth`), and the inspector at `inspector` (its
    /// minimum unless named) with its divider while it is shown.
    public static func windowMinimumWidth(strip: Double, inspectorShown: Bool, panelCollapsed: Bool,
                                          inspector: Double = InspectorWidth.minimum,
                                          windowButtonsEdge: Double? = nil) -> Double {
        let panel = panelCollapsed ? 0 : PanelLayout.minimum + dividerWidth
        let details = inspectorShown ? inspector + dividerWidth : 0
        let inset = stripMinimumWidth(strip: strip, panelCollapsed: panelCollapsed, windowButtonsEdge: windowButtonsEdge)
        return panel + columnMinimumWidth(strip: inset) + details
    }
}

/// MarkFrame is a square mark's frame in its tab's box, origin at the box's
/// top left, y growing downward.
public struct MarkFrame: Equatable, Sendable {
    public let minX: Double
    public let minY: Double
    public let size: Double

    public init(minX: Double, minY: Double, size: Double) {
        self.minX = minX
        self.minY = minY
        self.size = size
    }

    public var midX: Double { minX + size / 2 }
    public var maxY: Double { minY + size }
    /// Where the mark stands: `TabStripLayout.markFoot` down its frame.
    public var footY: Double { minY + size * TabStripLayout.markFoot }
}
