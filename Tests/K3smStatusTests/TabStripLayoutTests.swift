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
        TabStripLayout.itemSpacing + TabStripLayout.spacerMinimum + TabStripLayout.itemSpacing
            + (button.map { $0 + TabStripLayout.itemSpacing } ?? 0)
            + TabStripLayout.searchMinimum + TabStripLayout.itemSpacing
            + TabStripLayout.controlsWidth + TabStripLayout.padding
    }

    @Test("the icon buttons are details, tour, info and Settings, with the gaps between them")
    func iconButtonsCounted() {
        #expect(TabStripLayout.iconButtons == 4)
        #expect(TabStripLayout.controlsWidth == 4 * TabStripLayout.iconButtonWidth + 3 * TabStripLayout.itemSpacing)
    }

    @Test("the six tabs fit whole at the minimum width; a longer seventh raises it; the window follows")
    func tabStripFitsAtMinimumWidth() {
        #expect(Self.titles.count == 6)
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

        // A seventh long title raises the minimum by at least its own width and a gap.
        let seventh = "Interconnects and links"
        let raised = TabStripLayout.minimumWidth(labels: Self.titles + [seventh], buttonWidth: button)
        #expect(raised >= minimum + TabStripLayout.labelWidth(seventh) + TabStripLayout.tabSpacing)

        // The window's minimum follows the strip, never below the floor.
        let window = TabStripLayout.windowMinimumWidth(strip: minimum, inspectorShown: true, panelCollapsed: false)
        #expect(window >= TabStripLayout.windowFloor)
        #expect(window >= PanelLayout.minimum + TabStripLayout.dividerWidth + minimum + TabStripLayout.inspectorWidth)
        let wider = TabStripLayout.windowMinimumWidth(strip: raised, inspectorShown: true, panelCollapsed: false)
        #expect(wider > window)
    }

    @Test("the update button counts only when offered")
    func updateButtonCountsWhenOffered() {
        let without = TabStripLayout.minimumWidth(labels: Self.titles, buttonWidth: nil)
        let with = TabStripLayout.minimumWidth(labels: Self.titles, buttonWidth: TabStripLayout.buttonWidth(title: "Update"))
        #expect(abs(with - (without + TabStripLayout.buttonWidth(title: "Update") + TabStripLayout.itemSpacing)) < 1e-9)
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

    @Test("a narrow strip leaves the floor; collapsing the panel or the inspector lowers the window")
    func windowMinimumKeepsFloor() {
        #expect(TabStripLayout.windowMinimumWidth(strip: 0, inspectorShown: true, panelCollapsed: false)
            == TabStripLayout.windowFloor)
        let shown = TabStripLayout.windowMinimumWidth(strip: 900, inspectorShown: true, panelCollapsed: false)
        let collapsed = TabStripLayout.windowMinimumWidth(strip: 900, inspectorShown: true, panelCollapsed: true)
        let noInspector = TabStripLayout.windowMinimumWidth(strip: 900, inspectorShown: false, panelCollapsed: false)
        #expect(abs(collapsed - (shown - PanelLayout.minimum - TabStripLayout.dividerWidth)) < 1e-9)
        #expect(abs(noInspector - (shown - TabStripLayout.inspectorWidth - TabStripLayout.dividerWidth)) < 1e-9)
        #expect(TabStripLayout.contentMinimumWidth(strip: 0, inspectorShown: false)
            == TabStripLayout.windowFloor - PanelLayout.minimum - TabStripLayout.dividerWidth - TabStripLayout.inspectorWidth)
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
        #expect(abs(tabs - (labels + Double(Self.titles.count - 1) * TabStripLayout.tabSpacing)) < 1e-9)
    }
}
