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

/// ConsoleRow is one row's identity on a console tab: the kind of row (the
/// tab it belongs to) and the key the tab's decoder gave it. The key is
/// always a clipped string (`Pod.key`, `NodeImage.key`, `ServiceRow.key`,
/// `StorageRow.key`, `ModelRow.key`, or `InspectorDetails.engineRow` for the
/// Builds tab's engine card), so it is safe to show and to store.
public enum ConsoleRow: Hashable, Sendable {
    case pod(String)
    case image(String)
    case build(String)
    case service(String)
    case claim(String)
    case model(String)

    /// A row of `section` keyed `key`.
    public init(section: ConsoleSection, key: String) {
        switch section {
        case .workloads: self = .pod(key)
        case .images: self = .image(key)
        case .builds: self = .build(key)
        case .services: self = .service(key)
        case .storage: self = .claim(key)
        case .models: self = .model(key)
        }
    }

    /// The tab the row belongs to.
    public var section: ConsoleSection {
        switch self {
        case .pod: return .workloads
        case .image: return .images
        case .build: return .builds
        case .service: return .services
        case .claim: return .storage
        case .model: return .models
        }
    }

    /// The decoder's key for the row.
    public var key: String {
        switch self {
        case .pod(let k), .image(let k), .build(let k), .service(let k), .claim(let k), .model(let k): return k
        }
    }
}

/// ConsoleSelection is what the inspector follows: the active tab and at
/// most one selected row per tab. A tab change shows the new tab's own
/// selection, or nothing when it has none, so the inspector never carries a
/// row from the tab just left. A selection is kept per tab while the user is
/// elsewhere and comes back with its tab only while its row is still listed.
/// Nothing here selects for the user; the Workloads tab's first-pod choice
/// is `WorkloadsDisplay.selection`'s.
public struct ConsoleSelection: Equatable, Sendable {
    /// The tab the console shows.
    public private(set) var active: ConsoleSection
    private var rows: [ConsoleSection: ConsoleRow] = [:]

    /// A selection on `active` holding `rows`; a later row of a tab replaces
    /// an earlier one.
    public init(active: ConsoleSection, rows: [ConsoleRow] = []) {
        self.active = active
        for row in rows { self.rows[row.section] = row }
    }

    /// The selection the stored keys name (`ConsoleTabs.restoreSelected`
    /// over `stored(tab)`, so a stored key is clipped and an empty one is
    /// none); each is checked against its tab's first read.
    public static func restore(active: ConsoleSection, stored: (ConsoleSection) -> Any?) -> ConsoleSelection {
        let rows = ConsoleSection.allCases.compactMap { tab in
            ConsoleTabs.restoreSelected(from: stored(tab)).map { ConsoleRow(section: tab, key: $0) }
        }
        return ConsoleSelection(active: active, rows: rows)
    }

    /// The active tab's selected row: what the inspector shows.
    public var current: ConsoleRow? { rows[active] }

    /// One tab's selected row.
    public func selection(in tab: ConsoleSection) -> ConsoleRow? { rows[tab] }

    /// Selects `row` on `tab`, replacing that tab's row. A row of another
    /// kind is refused (false), so one tab can never show another's row.
    @discardableResult
    public mutating func select(_ row: ConsoleRow, in tab: ConsoleSection) -> Bool {
        guard row.section == tab else { return false }
        rows[tab] = row
        return true
    }

    /// Makes `tab` the active one and returns its selection, nil when it has
    /// none. `present` is the keys of the tab's last read: a selected row not
    /// among them is cleared first, so it is not shown and does not come back
    /// later. A tab not read yet passes nil and keeps its row until its read.
    @discardableResult
    public mutating func switchTo(_ tab: ConsoleSection, present: Set<String>? = nil) -> ConsoleRow? {
        active = tab
        if let present { retain(tab, present: present) }
        return current
    }

    /// Clears one tab's selection.
    public mutating func clear(_ tab: ConsoleSection) {
        rows[tab] = nil
    }

    /// What a read of `tab` does: its selected row stays while `present`
    /// lists its key and is cleared otherwise (a failed read lists nothing).
    public mutating func retain(_ tab: ConsoleSection, present: Set<String>) {
        if let row = rows[tab], !present.contains(row.key) { rows[tab] = nil }
    }
}
