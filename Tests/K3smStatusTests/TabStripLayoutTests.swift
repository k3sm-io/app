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

import Testing

@testable import K3smStatus

@Suite("the console tab strip's width")
struct TabStripLayoutTests {
    private static let titles = ConsoleSection.allCases.map(\.title)

    /// What the strip holds besides the tabs, at its minimum, with an update offered.
    private static func fixedParts(button: Double?) -> Double {
        TabStripLayout.itemSpacing
            + (button.map { $0 + TabStripLayout.itemSpacing } ?? 0)
            + TabStripLayout.searchMinimum + TabStripLayout.itemSpacing
            + TabStripLayout.controlsWidth + TabStripLayout.leadingControlsWidth + TabStripLayout.padding
    }

    @Test("the panel button at the strip's start costs one glyph button in its capsule and one gap")
    func panelButtonCounted() {
        #expect(TabStripLayout.leadingControlsWidth
            == TabStripLayout.iconButtonWidth + 2 * TabStripLayout.groupInset + TabStripLayout.itemSpacing)
        // The strip's minimum is the tabs plus every fixed part, the panel button among them.
        for button in [nil, TabStripLayout.buttonWidth(title: "Update")] {
            let minimum = TabStripLayout.minimumWidth(labels: Self.titles, buttonWidth: button)
            let expected = TabStripLayout.tabsWidth(labels: Self.titles) + Self.fixedParts(button: button)
            #expect(abs(minimum - expected) < 1e-9)
        }
    }

    @Test("the icon buttons are details, tour, info and Settings, side by side in one capsule")
    func iconButtonsCounted() {
        #expect(TabStripLayout.iconButtons == 4)
        #expect(TabStripLayout.controlsWidth == 4 * TabStripLayout.iconButtonWidth + 2 * TabStripLayout.groupInset)
        // A glyph's hover circle holds its symbol, and it fits the tabs' capsule height.
        #expect(TabStripLayout.iconButtonWidth > TabStripLayout.iconSymbolSize)
        #expect(TabStripLayout.iconButtonWidth + 2 * TabStripLayout.groupInset <= TabStripLayout.height)
    }

    @Test("the search field takes the room past the natural width first, up to its ideal, before any tab grows")
    func searchWidthTakesTheRoomFirst() {
        let natural = 860.0
        #expect(TabStripLayout.searchWidth(room: natural, natural: natural) == TabStripLayout.searchMinimum)
        #expect(TabStripLayout.searchWidth(room: natural - 100, natural: natural) == TabStripLayout.searchMinimum)
        #expect(TabStripLayout.searchWidth(room: natural + 50, natural: natural) == TabStripLayout.searchMinimum + 50)
        #expect(TabStripLayout.searchWidth(room: natural + 500, natural: natural) == TabStripLayout.searchIdeal)
        #expect(TabStripLayout.searchWidth(room: .nan, natural: natural) == TabStripLayout.searchMinimum)
        #expect(TabStripLayout.searchWidth(room: .infinity, natural: natural) == TabStripLayout.searchMinimum)
    }

    @Test("a tab is a capsule round its label: least width the label and its padding, growing to a cap")
    func tabCapsuleGeometry() {
        for title in Self.titles {
            #expect(TabStripLayout.tabWidth(title) == TabStripLayout.labelWidth(title) + 2 * TabStripLayout.tabPadding)
            #expect(TabStripLayout.tabWidth(title) < TabStripLayout.tabMaximumWidth)
        }
        // Label to label is the two capsules' padding and their gap, the spacing the butterfly needs.
        #expect(TabStripLayout.tabSpacing == 2 * TabStripLayout.tabPadding + TabStripLayout.tabGap)
        #expect(TabStripLayout.tabSpacing >= 14)
        // The capsule fits in the strip with the waiting butterfly's room above its label.
        #expect(TabStripLayout.tabHeight < TabStripLayout.height)
        #expect(TabStripLayout.tabHeight >= TabStripLayout.fontSize * 2)
        // The tabs at their least are every capsule side by side.
        let capsules = Self.titles.map { TabStripLayout.tabWidth($0) }.reduce(0, +)
            + Double(Self.titles.count - 1) * TabStripLayout.tabGap
        #expect(abs(TabStripLayout.tabsWidth(labels: Self.titles) - capsules) < 1e-9)
    }

    @Test("the nine tabs fit whole at the strip's natural width; a longer tenth raises it; the window's natural width follows")
    func tabStripFitsAtMinimumWidth() {
        #expect(Self.titles.count == 9)
        let button = TabStripLayout.buttonWidth(title: "Updating…")
        let minimum = TabStripLayout.minimumWidth(labels: Self.titles, buttonWidth: button)
        #expect(minimum > 0)

        // No label is shortened, and at the minimum the tabs get every label's width.
        for title in Self.titles {
            #expect(TabStripLayout.display(title) == title)
            #expect(TabStripLayout.labelWidth(title) >= Double(title.count) * TabStripLayout.fontSize * 0.6)
        }
        let tabs = TabStripLayout.tabsWidth(labels: Self.titles)
        #expect(tabs > 0)
        #expect(minimum - Self.fixedParts(button: button) >= tabs)

        // A tenth long title raises the minimum by at least its own width and a gap.
        let eighth = "Interconnects and links"
        let raised = TabStripLayout.minimumWidth(labels: Self.titles + [eighth], buttonWidth: button)
        #expect(raised >= minimum + TabStripLayout.labelWidth(eighth) + TabStripLayout.tabSpacing)

        // The window's natural width follows the strip, never below the floor.
        let window = TabStripLayout.windowNaturalWidth(strip: minimum, inspectorShown: true, panelCollapsed: false,
                                                       inspector: InspectorWidth.defaultWidth)
        #expect(window >= TabStripLayout.windowFloor)
        #expect(window >= PanelLayout.minimum + TabStripLayout.dividerWidth + minimum + TabStripLayout.inspectorWidth)
        let wider = TabStripLayout.windowNaturalWidth(strip: raised, inspectorShown: true, panelCollapsed: false,
                                                      inspector: InspectorWidth.defaultWidth)
        #expect(wider > window)
    }

    @Test("with the Nodes tab the window's natural width still fits a 1440 pt wide display, Update being the Alerts tab's card")
    func nodesTabFitsTheNarrowestLaptop() {
        #expect(Self.titles.contains("Nodes"))
        let without = Self.titles.filter { $0 != "Nodes" }
        do {
            let button: Double? = nil
            let strip = TabStripLayout.minimumWidth(labels: Self.titles, buttonWidth: button)
            // At the inspector's default width, not only at its minimum.
            let window = TabStripLayout.windowNaturalWidth(strip: strip, inspectorShown: true, panelCollapsed: false,
                                                           inspector: InspectorWidth.defaultWidth)
            #expect(window <= 1440, "\(window)")
            // The tab costs its label and one gap, nothing more.
            let before = TabStripLayout.minimumWidth(labels: without, buttonWidth: button)
            #expect(abs(strip - before - TabStripLayout.labelWidth("Nodes") - TabStripLayout.tabSpacing) < 1e-9)
        }
    }

    @Test("with the Stats and Alerts tabs, Alerts last, the window's natural width still fits a 1440 pt wide display")
    func statsTabFitsTheNarrowestLaptop() {
        #expect(Self.titles.suffix(2) == ["Stats", "Alerts"])
        #expect(Self.titles.first == "Workloads")
        let without = Self.titles.filter { $0 != "Stats" }
        do {
            let button: Double? = nil
            let strip = TabStripLayout.minimumWidth(labels: Self.titles, buttonWidth: button)
            // At the inspector's default width, not only at its minimum.
            let window = TabStripLayout.windowNaturalWidth(strip: strip, inspectorShown: true, panelCollapsed: false,
                                                           inspector: InspectorWidth.defaultWidth)
            #expect(window <= 1440, "\(window)")
            let before = TabStripLayout.minimumWidth(labels: without, buttonWidth: button)
            #expect(abs(strip - before - TabStripLayout.labelWidth("Stats") - TabStripLayout.tabSpacing) < 1e-9)
        }
        // The spacing stays a visible gap: at least the width of one label character.
        #expect(TabStripLayout.tabSpacing >= TabStripLayout.fontSize * PanelLayout.advance)
    }

    @Test("the update button counts only when offered")
    func updateButtonCountsWhenOffered() {
        let without = TabStripLayout.minimumWidth(labels: Self.titles, buttonWidth: nil)
        let with = TabStripLayout.minimumWidth(labels: Self.titles, buttonWidth: TabStripLayout.buttonWidth(title: "Update"))
        #expect(abs(with - (without + TabStripLayout.buttonWidth(title: "Update") + TabStripLayout.itemSpacing)) < 1e-9)
    }

    @Test("the Developer mode badge counts in the strip's minimum while it is shown")
    func stripMinimumCountsTheDeveloperBadge() {
        let badge = TabStripLayout.badgeWidth()
        // The estimate errs wide: the title at a narrow advance, its padding and stroke.
        #expect(badge >= Double(TabStripLayout.developerBadgeTitle.count) * TabStripLayout.badgeFontSize * 0.6 + 12 + 2)
        let without = TabStripLayout.minimumWidth(labels: Self.titles, buttonWidth: nil)
        let with = TabStripLayout.minimumWidth(labels: Self.titles, buttonWidth: nil, badgeWidth: badge)
        #expect(abs(with - (without + badge + TabStripLayout.itemSpacing)) < 1e-9)
        // With the panel collapsed and the inspector shown the window's natural width carries it too.
        let windowWithout = TabStripLayout.windowNaturalWidth(strip: without, inspectorShown: true, panelCollapsed: true)
        let windowWith = TabStripLayout.windowNaturalWidth(strip: with, inspectorShown: true, panelCollapsed: true)
        #expect(windowWith > windowWithout)
    }

    @Test("a label is whole up to the cap and shortened at its tail past it")
    func labelCapTruncatesTail() {
        let atCap = String(repeating: "a", count: TabStripLayout.labelCap)
        #expect(TabStripLayout.display(atCap) == atCap)
        let past = atCap + "b"
        let shown = TabStripLayout.display(past)
        #expect(shown.count == TabStripLayout.labelCap)
        #expect(shown.hasSuffix("…"))
        #expect(shown.hasPrefix(String(repeating: "a", count: TabStripLayout.labelCap - 1)))
    }

    @Test("with the panel shown the strip keeps its half padding, whatever the window buttons")
    func openPanelInsetUnchanged() {
        #expect(TabStripLayout.leadingInset(panelCollapsed: false) == TabStripLayout.padding / 2)
        #expect(TabStripLayout.leadingInset(panelCollapsed: false, windowButtonsEdge: 76) == TabStripLayout.padding / 2)
        #expect(TabStripLayout.stripMinimumWidth(strip: 900, panelCollapsed: false, windowButtonsEdge: 76) == 900)
    }

    @Test("with the panel hidden the first tab starts past the window buttons", arguments: [52.0, 68.0, 76.0, 90.0])
    func collapsedInsetClearsTheButtons(edge: Double) {
        let inset = TabStripLayout.leadingInset(panelCollapsed: true, windowButtonsEdge: edge)
        #expect(inset > edge)
        #expect(inset == edge + TabStripLayout.padding / 2)
        #expect(TabStripLayout.stripMinimumWidth(strip: 900, panelCollapsed: true, windowButtonsEdge: edge) == 900 + edge)
    }

    @Test("an unreported or unsettled button edge takes the fallback", arguments: [nil, 0, -4, .nan, .infinity, 500])
    func collapsedInsetFallback(edge: Double?) {
        let inset = TabStripLayout.leadingInset(panelCollapsed: true, windowButtonsEdge: edge)
        #expect(inset == TabStripLayout.windowButtonsFallback + TabStripLayout.padding / 2)
        #expect(inset > TabStripLayout.windowButtonsFallback)
    }

    @Test("the window's natural width with the panel hidden leaves the strip room past the window buttons")
    func collapsedWindowMinimumHoldsTheInset() {
        // A strip wider than the floor leaves, so the strip decides the column.
        let strip = 1200.0
        #expect(strip > TabStripLayout.columnNaturalWidth(strip: 0))
        for edge in [nil, 76.0] {
            let window = TabStripLayout.windowNaturalWidth(strip: strip, inspectorShown: false, panelCollapsed: true,
                                                           windowButtonsEdge: edge)
            // The whole window is the tab column: the inset, the strip's
            // content and its trailing half padding all fit.
            let inset = TabStripLayout.leadingInset(panelCollapsed: true, windowButtonsEdge: edge)
            #expect(window == inset + (strip - TabStripLayout.padding) + TabStripLayout.padding / 2)
        }
    }

    @Test("a narrow strip leaves the floor; collapsing the panel or the inspector lowers the window's natural width")
    func windowMinimumKeepsFloor() {
        #expect(TabStripLayout.windowNaturalWidth(strip: 0, inspectorShown: true, panelCollapsed: false,
                                                  inspector: InspectorWidth.defaultWidth) == TabStripLayout.windowFloor)
        // The natural width counts the inspector at its minimum.
        #expect(TabStripLayout.windowNaturalWidth(strip: 0, inspectorShown: true, panelCollapsed: false)
            == TabStripLayout.windowFloor - (InspectorWidth.defaultWidth - InspectorWidth.minimum))
        let shown = TabStripLayout.windowNaturalWidth(strip: 900, inspectorShown: true, panelCollapsed: false)
        let collapsed = TabStripLayout.windowNaturalWidth(strip: 900, inspectorShown: true, panelCollapsed: true)
        let noInspector = TabStripLayout.windowNaturalWidth(strip: 900, inspectorShown: false, panelCollapsed: false)
        // Collapsed, the strip also clears the window buttons.
        let cleared = TabStripLayout.leadingInset(panelCollapsed: true) - TabStripLayout.padding / 2
        #expect(abs(collapsed - (shown - PanelLayout.minimum - TabStripLayout.dividerWidth + cleared)) < 1e-9)
        #expect(abs(noInspector - (shown - InspectorWidth.minimum - TabStripLayout.dividerWidth)) < 1e-9)
        #expect(TabStripLayout.columnNaturalWidth(strip: 0)
            == TabStripLayout.windowFloor - PanelLayout.minimum - TabStripLayout.inspectorWidth - 2 * TabStripLayout.dividerWidth)
        #expect(TabStripLayout.columnNaturalWidth(strip: 900) == 900)
    }

    @Test("the window's minimum is the panes' minimums and the tab column's, never the strip's labels")
    func windowMinimumIgnoresTheStrip() {
        let column = TabStripLayout.columnMinimum
        let panel = PanelLayout.minimum + TabStripLayout.dividerWidth
        let details = InspectorWidth.minimum + TabStripLayout.dividerWidth
        #expect(TabStripLayout.windowMinimumWidth(inspectorShown: false, panelCollapsed: true) == column)
        #expect(TabStripLayout.windowMinimumWidth(inspectorShown: false, panelCollapsed: false) == panel + column)
        #expect(TabStripLayout.windowMinimumWidth(inspectorShown: true, panelCollapsed: true) == column + details)
        #expect(TabStripLayout.windowMinimumWidth(inspectorShown: true, panelCollapsed: false) == panel + column + details)
        #expect(TabStripLayout.windowMinimumWidth(inspectorShown: true, panelCollapsed: false,
                                                  inspector: InspectorWidth.defaultWidth)
            == panel + column + InspectorWidth.defaultWidth + TabStripLayout.dividerWidth)
        // The column's minimum is below what the strip and every tab were laid out for.
        let strip = TabStripLayout.minimumWidth(labels: Self.titles, buttonWidth: nil)
        #expect(column < strip)
        #expect(column < TabStripLayout.sectionNaturalWidth)
        #expect(TabStripLayout.sectionNaturalWidth == TabStripLayout.columnNaturalWidth(strip: 0))
        // Each minimum is below the matching natural width.
        for inspector in [true, false] {
            for collapsed in [true, false] {
                #expect(TabStripLayout.windowMinimumWidth(inspectorShown: inspector, panelCollapsed: collapsed)
                    < TabStripLayout.windowNaturalWidth(strip: strip, inspectorShown: inspector, panelCollapsed: collapsed))
            }
        }
    }

    @Test("a tab's waiting butterfly stands on its label's first capital, at the word's leading edge, inside the strip")
    func tabWaitingMarkSitsAboveTheLabel() {
        // The system font's metrics at 13, 11 and 17 pt (size, ascent, descent, cap height).
        let fonts: [(size: Double, ascent: Double, descent: Double, cap: Double)] = [
            (13, 12.38, 3.14, 9.17), (11, 10.47, 2.66, 7.76), (17, 16.19, 4.10, 11.99),
        ]
        for font in fonts {
            let mark = TabStripLayout.waitingMarkFrame(ascent: font.ascent, descent: font.descent,
                                                       capHeight: font.cap, markSize: 10)
            let lineTop = (TabStripLayout.height - (font.ascent + font.descent)) / 2
            let capTop = lineTop + font.ascent - font.cap

            // Its feet are on the first letter's cap top, so it is wholly above the letters.
            #expect(abs(mark.footY - capTop) <= 1)
            #expect(mark.maxY - capTop < 1)
            // Its centre is over the first letter, measured from the label's leading edge
            // (each title's first letter at the strip's per-character estimate).
            for title in Self.titles + ["Interconnects and links"] {
                let firstLetter = TabStripLayout.labelWidth(String(title.prefix(1)), fontSize: font.size)
                #expect(mark.midX > 0)
                #expect(mark.midX <= firstLetter)
            }
            // Inside the strip's fixed height, never clipped at its top.
            #expect(mark.minY >= 0)
            #expect(mark.maxY <= TabStripLayout.height)
            #expect(mark.size == 10)
            // It never reaches back over the previous tab's label, which ends a tab gap before this one.
            #expect(mark.minX >= 0)
            #expect(mark.minX > -TabStripLayout.tabSpacing)
        }

        // The mark takes no width: the strip's minimum is the tabs and their spacing, as before.
        let tabs = TabStripLayout.tabsWidth(labels: Self.titles)
        let labels = Self.titles.map { TabStripLayout.labelWidth($0) }.reduce(0, +)
        #expect(abs(tabs - (labels + Double(Self.titles.count - 1) * TabStripLayout.tabSpacing
            + 2 * TabStripLayout.tabPadding)) < 1e-9)
    }
}
