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

@Suite("table column widths")
struct ColumnLayoutTests {
    private static func fresh() -> UserDefaults {
        let name = "io.k3sm.app.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("a drag resizes within the column's bounds and the name column's remainder, a reset and the store round-trip")
    func columnWidthsResizeAndPersist() {
        // Every tab's table is defined, once, with today's widths as defaults.
        #expect(Set(TableColumns.all.map(\.table)) == Set(ConsoleTable.allCases))
        #expect(TableColumns.pods.columns.map(\.defaultWidth) == [84, 74, 54, 66, 50])
        #expect(TableColumns.events.columns.map(\.defaultWidth) == [50, 130, 170])
        for layout in TableColumns.all {
            #expect(Set(layout.columns.map(\.id)).count == layout.columns.count, "\(layout.table)")
            for column in layout.columns {
                // A minimum keeps the title readable and never passes the default.
                #expect(column.minimum >= Double(column.title.count) * 11.5 * 0.62 || column.minimum == column.defaultWidth,
                        "\(layout.table).\(column.id)")
                #expect(column.minimum <= column.defaultWidth && column.defaultWidth <= column.maximum)
            }
            // A column after the name column drags by its leading edge, one before it by its trailing edge.
            #expect(layout.columns.allSatisfy { $0.edge == (layout.leading.contains($0) ? .trailing : .leading) })
        }

        var widths = ColumnWidths(TableColumns.pods)
        #expect(widths.isDefault)
        #expect(widths.width(.node) == 84)
        let node = TableColumns.pods.column(.node)!
        // A leading-edge handle: a drag left widens the column, one right narrows it.
        let table: [(start: Double, dx: Double, available: Double?, want: Double)] = [
            (84, .nan, nil, 84),
            (84, -30, nil, 114),
            (84, 30, nil, 54),
            (84, 200, nil, node.minimum),
            (84, -900, nil, node.maximum),
            (84, -900, 700, 700 - TableColumns.pods.reserved - TableColumns.pods.flexibleMinimum - (74 + 54 + 66 + 50)),
            (84, -900, 300, node.minimum),
        ]
        for row in table {
            widths.resize(.node, from: row.start, translation: row.dx, available: row.available)
            #expect(widths.width(.node) == row.want, "\(row)")
        }
        // A trailing-edge handle (Events' columns before the message) moves the other way.
        var events = ColumnWidths(TableColumns.events)
        events.resize(.reason, from: 130, translation: 40, available: nil)
        #expect(events.width(.reason) == 170)

        // The name column takes what the fixed columns leave, never less than nothing.
        widths.resetAll()
        let fixed = 84.0 + 74 + 54 + 66 + 50
        #expect(widths.flexibleWidth(available: 800) == 800 - TableColumns.pods.reserved - fixed)
        #expect(widths.flexibleWidth(available: 100) == 0)

        // A double-click resets one column; the others keep theirs.
        widths.resize(.node, from: 84, translation: -20, available: nil)
        widths.resize(.age, from: 50, translation: -10, available: nil)
        widths.reset(.node)
        #expect(widths.width(.node) == 84 && widths.width(.age) == 60)
        #expect(widths.stored == ["age": 60])

        // Remembered per tab; a stored value is clamped, junk and unknown ids are dropped.
        let defaults = Self.fresh()
        let prefs = AppPreferences(defaults: defaults)
        prefs.setColumnWidths(widths)
        #expect(prefs.columnWidths(TableColumns.pods) == widths)
        #expect(prefs.columnWidths(TableColumns.events).isDefault)
        defaults.set(["node": 9999.0, "age": "wide", "nope": 10.0, "cores": 1], forKey: AppPreferences.columnWidthsKey(.pods))
        let restored = prefs.columnWidths(TableColumns.pods)
        #expect(restored.width(.node) == node.maximum)
        #expect(restored.width(.age) == 50)
        #expect(restored.width(.cores) == TableColumns.pods.column(.cores)!.minimum)
        #expect(Set(restored.stored.keys) == ["node", "cores"])
        defaults.set("not a dictionary", forKey: AppPreferences.columnWidthsKey(.events))
        #expect(prefs.columnWidths(TableColumns.events).isDefault)
        // Setting the defaults back stores nothing.
        prefs.setColumnWidths(ColumnWidths(TableColumns.events))
        #expect(defaults.object(forKey: AppPreferences.columnWidthsKey(.events)) == nil)

        // Reset Column Widths clears every tab's; Reset Window Layout does too.
        prefs.setColumnWidths(widths)
        prefs.resetColumnWidths()
        #expect(prefs.columnWidths(TableColumns.pods).isDefault)
        prefs.setColumnWidths(widths)
        #expect(AppPreferences.layoutKeys.contains(AppPreferences.columnWidthsKey(.pods)))
        prefs.resetLayout()
        #expect(defaults.object(forKey: AppPreferences.columnWidthsKey(.pods)) == nil)
    }
}
