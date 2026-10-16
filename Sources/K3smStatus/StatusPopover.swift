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

/// StatusPopover decides what the console's info popover shows: the state
/// headline, only the checks that are not ok, the version line, the
/// lifecycle buttons, and every check behind a closed "All checks"
/// disclosure. The root step's log shows only while a step runs or after one
/// failed.
public enum StatusPopover {
    /// The disclosure that holds the full table and Refresh.
    public static let allChecksTitle = "All checks"

    /// Whether a row is a problem the popover lists: the CLI's severity is
    /// `warn` or `fail`. `ok`, `skip` (nothing to probe) and `unknown`
    /// (could not probe) are not; the headline's lock already counts the checks
    /// that need an administrator. A row with no severity word, or one this
    /// build does not know, falls back to how the row is drawn: a state
    /// drawn for attention that moves the verdict.
    public static func isProblem(_ row: StatusRow) -> Bool {
        switch row.severity {
        case "warn", "fail": return true
        case "ok", "skip", "unknown": return false
        default: return row.rowState.tone == .attention && row.rowState.degradesVerdict
        }
    }

    /// The rows the popover lists, in report order and clipped as the full
    /// table clips them (`StatusDisplay.rows`): those `isProblem` selects.
    public static func problemRows(of report: StatusReport) -> [StatusRow] {
        zip(report.rows.prefix(StatusDisplay.maxRows), StatusDisplay.rows(of: report))
            .filter { isProblem($0.0) }
            .map(\.1)
    }

    /// The line shown in place of the problem rows when there are none:
    /// "All N checks are ok.", N counting the checks whose severity is ok;
    /// "No check could run." when none is. Nil while a problem is listed.
    public static func allOkLine(_ report: StatusReport) -> String? {
        guard problemRows(of: report).isEmpty else { return nil }
        let ok = report.rows.prefix(StatusDisplay.maxRows).filter { $0.severity == "ok" || ($0.severity.isEmpty && $0.rowState.tone == .healthy) }.count
        switch ok {
        case 0: return "No check could run."
        case 1: return "The 1 check is ok."
        default: return "All \(ok) checks are ok."
        }
    }

    /// Whether the last root step's log shows: there is one, and a step is
    /// running or the last one did not succeed.
    public static func showsLog(logTail: String, running: Bool, lastStepSucceeded: Bool) -> Bool {
        !logTail.isEmpty && (running || !lastStepSucceeded)
    }
}
