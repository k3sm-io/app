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

/// RowActivation is what a double-click on a console row opens: the same
/// view the row's existing open action shows. A row whose tab has an
/// inspector body for it opens its detail there (the details column is
/// shown if it was hidden); a row with a log and no detail opens the log
/// pane; a row with neither does nothing. A single click still only
/// selects, and the context menu is unchanged.
public enum RowActivation: Equatable, Sendable {
    /// Select the row and show the details column with its inspector.
    case detail(ConsoleRow)
    /// Open this log in the log pane.
    case logs(LogPaneSource)
    /// Nothing opens.
    case none

    /// The rule every row follows: its detail first, then its log, else
    /// nothing.
    public static func resolve(detail: ConsoleRow?, log: LogPaneSource?) -> RowActivation {
        if let detail { return .detail(detail) }
        if let log { return .logs(log) }
        return .none
    }

    /// What a double-click on `row` opens. Pods, nodes, images, builds (the
    /// engine card and each record), services, volume claims and models
    /// each have an inspector body, so they open their detail; a pod's and
    /// a build's log stay one action away there (Open Log, Show Log), as
    /// they were. The Stats and Alerts tabs list no rows.
    public static func destination(for row: ConsoleRow) -> RowActivation {
        resolve(detail: hasDetail(row) ? row : nil, log: nil)
    }

    /// Whether the inspector draws a body for `row` (`ConsoleInspector`).
    public static func hasDetail(_ row: ConsoleRow) -> Bool {
        switch row {
        case .pod, .node, .image, .build, .service, .claim, .model: return true
        case .stat, .issue: return false
        }
    }
}
