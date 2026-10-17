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

import Foundation
import Testing

@testable import K3smStatus

@Suite("the inspector's width")
struct InspectorWidthTests {
    @Test("the inspector opens at its default width when nothing usable is stored")
    func defaultWhenNothingStored() {
        #expect(InspectorWidth.restore(from: nil) == InspectorWidth.defaultWidth)
        #expect(InspectorWidth.restore(from: "wide") == InspectorWidth.defaultWidth)
        #expect(InspectorWidth.restore(from: Double.nan) == InspectorWidth.defaultWidth)
        #expect(InspectorWidth.restore(from: Double.infinity) == InspectorWidth.defaultWidth)
        #expect(InspectorWidth.defaultWidth == TabStripLayout.inspectorWidth)
        #expect(InspectorWidth.minimum <= InspectorWidth.defaultWidth)
        #expect(InspectorWidth.defaultWidth <= InspectorWidth.ceiling)
    }

    @Test("a dragged width is stored and read back across a relaunch")
    func dragPersisted() {
        let defaults = UserDefaults(suiteName: "InspectorWidthTests.\(UUID().uuidString)")!
        let stored = InspectorWidth.dragged(412)
        #expect(stored == 412)
        defaults.set(stored, forKey: InspectorWidth.key)
        #expect(InspectorWidth.restore(from: defaults.object(forKey: InspectorWidth.key)) == 412)
        // An integer written by hand reads back too.
        defaults.set(300, forKey: InspectorWidth.key)
        #expect(InspectorWidth.restore(from: defaults.object(forKey: InspectorWidth.key)) == 300)
        #expect(AppPreferences.layoutKeys.contains(InspectorWidth.key))
    }

    @Test("a width clamps to the minimum and the ceiling, and to what the tab column leaves")
    func clampToMinAndMax() {
        #expect(InspectorWidth.dragged(10) == InspectorWidth.minimum)
        #expect(InspectorWidth.dragged(5000) == InspectorWidth.ceiling)
        #expect(InspectorWidth.dragged(.nan) == InspectorWidth.defaultWidth)
        #expect(InspectorWidth.restore(from: 1.0) == InspectorWidth.minimum)
        #expect(InspectorWidth.restore(from: 99_999.0) == InspectorWidth.ceiling)

        // The tab column keeps its minimum: 1000 pt shared with a 608 pt column
        // leaves 391 pt for the inspector past the divider between them.
        let range = InspectorWidth.range(shared: 1000, columnMinimum: 608)
        #expect(range == InspectorWidth.minimum...(1000 - 608 - TabStripLayout.dividerWidth))
        #expect(InspectorWidth.clamp(500, to: range) == range.upperBound)
        #expect(InspectorWidth.clamp(100, to: range) == InspectorWidth.minimum)
        // With no room past the column the range is the minimum alone.
        #expect(InspectorWidth.range(shared: 700, columnMinimum: 608) == InspectorWidth.minimum...InspectorWidth.minimum)
        // A huge window still stops at the ceiling; before the first layout the
        // range is the whole span.
        #expect(InspectorWidth.range(shared: 5000, columnMinimum: 608).upperBound == InspectorWidth.ceiling)
        #expect(InspectorWidth.range(shared: nil, columnMinimum: 608) == InspectorWidth.minimum...InspectorWidth.ceiling)
    }

    @Test("after the first layout only a change of the stored width moves the divider")
    func fixedAfterFirstLayout() {
        var keeper = PaneKeeper()
        // The first layout places the stored width.
        #expect(keeper.place(320) == 320)
        // A re-render (or a window resize) storing the same width places nothing.
        #expect(keeper.place(320) == nil)
        // A drag records where the user left it; the model storing it places nothing.
        keeper.dragged(to: 400)
        #expect(keeper.place(400) == nil)
        // A layout reset stores the default again, which is placed.
        #expect(keeper.place(InspectorWidth.defaultWidth) == InspectorWidth.defaultWidth)
        // Shown again after a collapse, the stored width is placed again.
        keeper.reset()
        #expect(keeper.place(InspectorWidth.defaultWidth) == InspectorWidth.defaultWidth)
        #expect(keeper.place(.nan) == nil)
    }

    @Test("the details button keeps one colour, so its symbol carries the state")
    func detailsSymbolCarriesState() {
        #expect(TabStripLayout.detailsSymbol(shown: true) != TabStripLayout.detailsSymbol(shown: false))
        #expect(Help.Strip.details(shown: true) == Help.Strip.hideDetails)
        #expect(Help.Strip.details(shown: false) == Help.Strip.showDetails)
    }
}
