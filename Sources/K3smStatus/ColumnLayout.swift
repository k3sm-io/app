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

/// ConsoleTable names each table in the console, one per tab (the Workloads
/// tab has two, its pods and its events). Its raw value is the id its
/// remembered column widths are kept under (`AppPreferences.columnWidthsKey`).
public enum ConsoleTable: String, CaseIterable, Sendable {
    case pods
    case events
    case nodes
    case images
    case builds
    case services
    case storage
    case models
}

/// ColumnID names a resizable column. Its raw value is the column's key in
/// the stored widths, so a rename here forgets what a user dragged.
public enum ColumnID: String, CaseIterable, Sendable {
    case node, runsAs, cores, memory, age
    case reason, object
    case size, nodes, pods
    case status, started, duration
    case version, load
    case type, clusterIP, ports, hosts
    case volume, capacity, phase
    case ready, endpoint
}

/// ColumnEdge is the side of a column its drag handle sits on: the side away
/// from the flexible name column, so the edge under the pointer follows it.
/// A column after the name column is right-anchored and drags by its leading
/// edge; one before it drags by its trailing edge.
public enum ColumnEdge: Sendable {
    case leading
    case trailing
}

/// ColumnSpec is one resizable column: its title, its width before any
/// drag, and the bounds a drag keeps it in. The minimum keeps the title
/// readable (estimated at the header's 11.5 pt, never past the default).
public struct ColumnSpec: Equatable, Sendable {
    public let id: ColumnID
    public let title: String
    public let defaultWidth: Double
    public let minimum: Double
    public let maximum: Double
    /// Whether the column's text sits at its trailing edge (a figure).
    public let alignsTrailing: Bool
    public let edge: ColumnEdge

    /// The header's font size and the estimated advance per point of it.
    static let headerSize = 11.5
    static let advance = 0.62
    /// The narrowest and the widest any column goes.
    static let floor: Double = 24
    static let ceiling: Double = 480

    init(_ id: ColumnID, _ title: String, _ width: Double, trailing: Bool = false, edge: ColumnEdge) {
        self.id = id
        self.title = title
        defaultWidth = width
        minimum = min(width, max(Self.floor, Self.titleWidth(title)))
        maximum = min(Self.ceiling, max(200, width * 3))
        alignsTrailing = trailing
        self.edge = edge
    }

    static func titleWidth(_ title: String) -> Double {
        (Double(title.count) * headerSize * advance).rounded(.up)
    }
}

/// TableColumns is one table's layout: an optional unsized lead cell (a
/// health dot), the fixed columns before the flexible name column, the name
/// column, and the fixed columns after it. The name column takes whatever
/// the fixed columns leave. Every table's header and rows lay out from it.
public struct TableColumns: Sendable {
    public let table: ConsoleTable
    /// The width of the unsized cell before every column, 0 for none.
    public let lead: Double
    public let leading: [ColumnSpec]
    public let flexibleTitle: String
    public let trailing: [ColumnSpec]
    /// The gap between cells.
    public let spacing: Double

    public var columns: [ColumnSpec] { leading + trailing }

    /// The flexible name column's narrowest: its title, and room for a name.
    public var flexibleMinimum: Double { max(120, ColumnSpec.titleWidth(flexibleTitle)) }

    /// What the unsized cells and the gaps between all cells take.
    public var reserved: Double {
        let cells = columns.count + 1 + (lead > 0 ? 1 : 0)
        return lead + spacing * Double(cells - 1)
    }

    public func column(_ id: ColumnID) -> ColumnSpec? {
        columns.first { $0.id == id }
    }

    init(_ table: ConsoleTable, lead: Double = 0, leading: [(ColumnID, String, Double, Bool)] = [],
         flexible: String, trailing: [(ColumnID, String, Double, Bool)] = [], spacing: Double = 12) {
        self.table = table
        self.lead = lead
        self.leading = leading.map { ColumnSpec($0.0, $0.1, $0.2, trailing: $0.3, edge: .trailing) }
        flexibleTitle = flexible
        self.trailing = trailing.map { ColumnSpec($0.0, $0.1, $0.2, trailing: $0.3, edge: .leading) }
        self.spacing = spacing
    }

    public static let pods = TableColumns(.pods, lead: 16, flexible: "Pod", trailing: [
        (.node, "Node", 84, false), (.runsAs, "Runs as", 74, false), (.cores, "Cores", 54, true),
        (.memory, "Memory", 66, true), (.age, "Age", 50, true),
    ])
    public static let events = TableColumns(.events, lead: 16, leading: [
        (.age, "Age", 50, false), (.reason, "Reason", 130, false), (.object, "Object", 170, false),
    ], flexible: "Message")
    public static let nodes = TableColumns(.nodes, flexible: "Node", trailing: [
        (.status, "Status", 130, false), (.version, "Version", 130, false), (.load, "Load", 160, false),
    ])
    public static let images = TableColumns(.images, flexible: "Image", trailing: [
        (.size, "Size", 66, true), (.pods, "Pods", 44, true), (.nodes, "Nodes", 140, false),
    ])
    public static let builds = TableColumns(.builds, flexible: "Image", trailing: [
        (.status, "Status", 96, false), (.started, "Started", 132, false), (.duration, "Duration", 70, true),
    ])
    public static let services = TableColumns(.services, flexible: "Service", trailing: [
        (.type, "Type", 80, false), (.clusterIP, "Cluster IP", 100, false), (.ports, "Ports", 130, false),
        (.hosts, "Hosts", 150, false),
    ])
    public static let storage = TableColumns(.storage, flexible: "Claim", trailing: [
        (.volume, "Volume", 150, false), (.capacity, "Capacity", 66, true), (.phase, "Phase", 80, false),
    ])
    public static let models = TableColumns(.models, lead: 16, flexible: "Model", trailing: [
        (.phase, "Phase", 80, false), (.ready, "Ready", 54, true), (.endpoint, "Endpoint", 150, false),
    ])

    /// Every table, one per `ConsoleTable`.
    public static let all: [TableColumns] = [pods, events, nodes, images, builds, services, storage, models]

    public static func of(_ table: ConsoleTable) -> TableColumns {
        all.first { $0.table == table }!
    }
}

/// ColumnWidths is one table's widths as the user left them: only the
/// columns dragged away from their default are stored, so a reset is a
/// removal. A drag is clamped to the column's bounds and, when the table's
/// width is known, to what leaves the name column its minimum; the name
/// column's own width is the remainder (`flexibleWidth`).
public struct ColumnWidths: Equatable, Sendable {
    public let table: ConsoleTable
    public private(set) var stored: [String: Double]

    private var layout: TableColumns { TableColumns.of(table) }

    public init(_ layout: TableColumns, stored: [String: Double] = [:]) {
        table = layout.table
        self.stored = stored
    }

    public var isDefault: Bool { stored.isEmpty }

    /// The column's width now: what the user left it at, or its default.
    public func width(_ id: ColumnID) -> Double {
        stored[id.rawValue] ?? layout.column(id)?.defaultWidth ?? 0
    }

    /// The name column's width in a table `available` wide: what the fixed
    /// columns, the lead cell and the gaps leave, never below nothing.
    public func flexibleWidth(available: Double) -> Double {
        max(0, available - layout.reserved - layout.columns.map { width($0.id) }.reduce(0, +))
    }

    /// `proposed` for `id`, within its bounds and, with `available`, never
    /// so wide that the name column drops below its minimum; a proposal that
    /// is not finite is the column's current width.
    public func clamped(_ id: ColumnID, _ proposed: Double, available: Double?) -> Double {
        guard let column = layout.column(id) else { return 0 }
        guard proposed.isFinite else { return width(id) }
        var upper = column.maximum
        if let available, available.isFinite {
            let others = layout.columns.filter { $0.id != id }.map { width($0.id) }.reduce(0, +)
            upper = min(upper, available - layout.reserved - layout.flexibleMinimum - others)
        }
        return max(column.minimum, min(upper, proposed))
    }

    /// A drag of `id`'s handle by `translation` points from where it was
    /// `start` wide: a trailing-edge handle widens the column as it moves
    /// right, a leading-edge one as it moves left.
    public mutating func resize(_ id: ColumnID, from start: Double, translation: Double, available: Double?) {
        guard let column = layout.column(id), translation.isFinite else { return }
        let proposed = column.edge == .trailing ? start + translation : start - translation
        set(id, clamped(id, proposed, available: available))
    }

    /// Puts `id` back to its default (a double-click on its handle).
    public mutating func reset(_ id: ColumnID) {
        stored[id.rawValue] = nil
    }

    /// Puts every column back to its default.
    public mutating func resetAll() {
        stored = [:]
    }

    private mutating func set(_ id: ColumnID, _ width: Double) {
        stored[id.rawValue] = width == layout.column(id)?.defaultWidth ? nil : width
    }

    /// The widths kept for `layout`: each stored number clamped to its
    /// column's bounds; anything not a dictionary, a value not a number, and
    /// an id the table does not have are dropped.
    public static func restore(_ layout: TableColumns, from stored: Any?) -> ColumnWidths {
        var widths = ColumnWidths(layout)
        guard let dict = stored as? [String: Any] else { return widths }
        for column in layout.columns {
            let value: Double
            switch dict[column.id.rawValue] {
            case let d as Double: value = d
            case let i as Int: value = Double(i)
            default: continue
            }
            guard value.isFinite else { continue }
            widths.set(column.id, max(column.minimum, min(column.maximum, value)))
        }
        return widths
    }
}
