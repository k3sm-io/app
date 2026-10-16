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

/// TabHeader places a tab's bulk actions (its buttons over many rows and
/// the last bulk action's line) on the tab's own header row, at its
/// trailing edge, rather than in the console's strip. Workloads always has
/// that row, for its Pods / Events switch; Storage and Builds show one only
/// while it holds something; the other tabs offer no bulk action and keep
/// no header row.
public enum TabHeader {
    /// Where a tab's bulk actions go.
    public enum Placement: Equatable, Sendable {
        /// The trailing edge of the row that holds the tab's sub-view switch.
        case switchRow
        /// A header row of the tab's own, shown only while it holds something.
        case ownRow
        /// Nowhere: the tab offers no bulk action.
        case none
    }

    /// The header row's height, the same on every tab.
    public static let height: Double = 28
    /// The header row's horizontal padding, each side.
    public static let horizontalPadding: Double = 20
    /// The space above the header row.
    public static let topPadding: Double = 10
    /// The gap between the header row's items.
    public static let spacing: Double = 10

    /// Where `section`'s bulk actions go.
    public static func placement(_ section: ConsoleSection) -> Placement {
        switch section {
        case .workloads: return .switchRow
        case .storage, .builds: return .ownRow
        case .nodes, .images, .services, .models: return .none
        }
    }

    /// Whether `section` draws a header row of its own: Workloads always,
    /// a tab with `.ownRow` placement only while it offers a bulk action or
    /// shows the last one's line, any other tab never.
    public static func showsRow(_ section: ConsoleSection, hasActions: Bool, hasLine: Bool) -> Bool {
        switch placement(section) {
        case .switchRow: return true
        case .ownRow: return hasActions || hasLine
        case .none: return false
        }
    }
}
