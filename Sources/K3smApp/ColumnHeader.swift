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

import K3smStatus
import SwiftUI

/// ColumnsModel is every table's column widths on screen, one
/// `ColumnWidths` per `ConsoleTable`, read from `AppPreferences` at launch
/// and written back when a drag ends or a column is reset. It also keeps
/// each header's measured width (not published: it only bounds a drag) and
/// the width a column had when its drag began.
@MainActor
final class ColumnsModel: ObservableObject {
    @Published private(set) var widths: [ConsoleTable: ColumnWidths]
    private var available: [ConsoleTable: Double] = [:]
    private var dragStart: (ConsoleTable, ColumnID, Double)?
    private let preferences: AppPreferences

    init(preferences: AppPreferences = AppPreferences()) {
        self.preferences = preferences
        var widths: [ConsoleTable: ColumnWidths] = [:]
        for layout in TableColumns.all { widths[layout.table] = preferences.columnWidths(layout) }
        self.widths = widths
    }

    func widths(_ table: ConsoleTable) -> ColumnWidths {
        widths[table] ?? ColumnWidths(TableColumns.of(table))
    }

    /// The header's width inside its padding, the width its rows lay out in.
    func measured(_ table: ConsoleTable, width: Double) {
        available[table] = width
    }

    /// A drag of `column`'s handle, `translation` points from where it began.
    func drag(_ table: ConsoleTable, _ column: ColumnID, translation: Double) {
        var current = widths(table)
        if dragStart == nil || dragStart?.0 != table || dragStart?.1 != column {
            dragStart = (table, column, current.width(column))
        }
        guard let start = dragStart?.2 else { return }
        current.resize(column, from: start, translation: translation, available: available[table])
        if current != widths[table] { widths[table] = current }
    }

    func endDrag(_ table: ConsoleTable) {
        dragStart = nil
        preferences.setColumnWidths(widths(table))
    }

    /// A double-click on `column`'s handle: back to its default width.
    func reset(_ table: ConsoleTable, _ column: ColumnID) {
        var current = widths(table)
        current.reset(column)
        widths[table] = current
        preferences.setColumnWidths(current)
    }

    /// View > Reset Column Widths and Reset Window Layout: every table back.
    func resetAll() {
        dragStart = nil
        for layout in TableColumns.all { widths[layout.table] = ColumnWidths(layout) }
        preferences.resetColumnWidths()
    }
}

extension ColumnWidths {
    /// The column's width for a frame.
    func cg(_ id: ColumnID) -> CGFloat { CGFloat(width(id)) }
}

/// ColumnHeader is a table's column titles, laid out from its
/// `TableColumns` and the widths on `ColumnsModel`, with a drag handle on
/// the edge of every fixed column that faces the name column (`ColumnEdge`).
/// `help` gives a title its tag by column, for one whose unit or meaning
/// its title does not show.
struct ColumnHeader: View {
    let layout: TableColumns
    @ObservedObject var columns: ColumnsModel
    var help: [ColumnID: HelpTag] = [:]
    var flexibleHelp: HelpTag?

    var body: some View {
        let widths = columns.widths(layout.table)
        HStack(spacing: CGFloat(layout.spacing)) {
            if layout.lead > 0 { Color.clear.frame(width: CGFloat(layout.lead), height: 1) }
            ForEach(layout.leading, id: \.id) { cell($0, widths) }
            Text(verbatim: layout.flexibleTitle).frame(maxWidth: .infinity, alignment: .leading).help(optional: flexibleHelp)
            ForEach(layout.trailing, id: \.id) { cell($0, widths) }
        }
        .font(.system(size: 11.5)).foregroundStyle(Palette.dimText)
        .onGeometryChange(for: Double.self) { Double($0.size.width) } action: { [columns, layout] width in
            columns.measured(layout.table, width: width)
        }
        .padding(.horizontal, 20).padding(.top, 10)
    }

    private func cell(_ column: ColumnSpec, _ widths: ColumnWidths) -> some View {
        let leading = column.edge == .leading
        // The handle's centre sits in the middle of the gap beside the column.
        let shift = (CGFloat(layout.spacing) + ColumnHandle.width) / 2
        return Text(verbatim: column.title)
            .lineLimit(1)
            .frame(width: widths.cg(column.id), alignment: column.alignsTrailing ? .trailing : .leading)
            .help(optional: help[column.id])
            .overlay(alignment: leading ? .leading : .trailing) {
                ColumnHandle(table: layout.table, column: column.id, columns: columns)
                    .offset(x: leading ? -shift : shift)
            }
    }
}

/// ColumnHandle is the thin hit area between two header titles: the column
/// resize pointer over it, a drag resizes its column, a double-click puts
/// the column back to its default width. A faint hairline marks it.
struct ColumnHandle: View {
    static let width: CGFloat = 8
    let table: ConsoleTable
    let column: ColumnID
    let columns: ColumnsModel

    var body: some View {
        Rectangle().fill(Palette.line).frame(width: 1, height: 11)
            .frame(width: Self.width, height: 16)
            .contentShape(Rectangle())
            .pointerStyle(.columnResize)
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in columns.drag(table, column, translation: Double(value.translation.width)) }
                .onEnded { _ in columns.endDrag(table) })
            .onTapGesture(count: 2) { columns.reset(table, column) }
            .help(Help.Columns.handle)
            .accessibilityLabel(Text(verbatim: "Resize column"))
    }
}
