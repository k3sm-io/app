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
}
