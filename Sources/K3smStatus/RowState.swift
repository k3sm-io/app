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

/// RowState is a status row's `state` word, read as what the app does with
/// it. The words are the CLI's committed row and daemon states; a word this
/// build does not know reads as `unknown`, kept as printed, and never fails a
/// read.
public enum RowState: Equatable, Sendable {
    /// running, ok, ready or healthy.
    case healthy(String)
    /// A check only root can run: nothing was checked and nothing is wrong.
    case needsAdmin
    /// The `update` row: a node runs an older k3sm release than the latest.
    /// Its severity carries the warn; it never moves the verdict.
    case behind
    /// The `update` row: a node runs a release newer than the latest and
    /// none is behind.
    case ahead
    /// The `update` row: a managed update is in progress (`wide.phase`,
    /// `wide.target`, `wide.node`). Drawn as healthy; it never moves the
    /// verdict.
    case rolling
    /// No answer (the `dns` row: none over UDP in 3 s, `wide.tcp` when TCP
    /// answered). Drawn for attention; the row's `warn` severity is what makes
    /// the CLI's verdict degraded, and the app reads the verdict as printed.
    case down
    /// An answer that is not a good one (the `dns` row: a reply with no
    /// address). Drawn for attention, like `down`.
    case unhealthy
    /// Another committed word (stopped, not-ready, skip, ...), shown as printed.
    case reported(String)
    /// The word `unknown`, or a word this build does not know.
    case unknown(String)

    /// The wire word for a check only root can run.
    public static let needsAdminWord = "needs-admin"
    /// The `update` row's wire words for an older and a newer release.
    public static let behindWord = "behind"
    public static let aheadWord = "ahead"
    public static let rollingWord = "rolling"
    public static let downWord = "down"
    public static let unhealthyWord = "unhealthy"

    static let healthyWords: Set<String> = ["running", "ok", "ready", "healthy"]
    static let reportedWords: Set<String> = [
        // daemon row states
        "stopped", "not-loaded", "disabled", "failed", "crash-loop", "waiting", "expired", "corrupt",
        "address-mismatch",
        // other row states
        "not-ready", "wrong-owner", "not-mounted", "absent", "partial", "missing", "skip", "drift",
        "stale",
    ]

    /// Creates a state from the CLI's wire word.
    public init(word: String) {
        if word == Self.needsAdminWord {
            self = .needsAdmin
        } else if word == Self.behindWord {
            self = .behind
        } else if word == Self.aheadWord {
            self = .ahead
        } else if word == Self.rollingWord {
            self = .rolling
        } else if word == Self.downWord {
            self = .down
        } else if word == Self.unhealthyWord {
            self = .unhealthy
        } else if Self.healthyWords.contains(word) {
            self = .healthy(word)
        } else if Self.reportedWords.contains(word) {
            self = .reported(word)
        } else {
            self = .unknown(word)
        }
    }

    /// The wire word, as the CLI prints it.
    public var word: String {
        switch self {
        case .healthy(let w), .reported(let w), .unknown(let w): return w
        case .needsAdmin: return Self.needsAdminWord
        case .behind: return Self.behindWord
        case .ahead: return Self.aheadWord
        case .rolling: return Self.rollingWord
        case .down: return Self.downWord
        case .unhealthy: return Self.unhealthyWord
        }
    }

    /// How the row is drawn.
    public var tone: RowTone {
        switch self {
        case .healthy, .ahead, .rolling: return .healthy
        case .needsAdmin: return .notChecked
        case .behind, .down, .unhealthy, .reported, .unknown: return .attention
        }
    }

    /// Whether the row may make the app read this Mac as other than its
    /// verdict says it is. A `needs-admin` row never does: the CLI keeps it
    /// out of the verdict, and so does the app. Nor does `behind`: an update
    /// being available is drawn for attention, and the cluster still runs;
    /// nor does `rolling`. `down` and `unhealthy` do, as before they had
    /// states of their own.
    public var degradesVerdict: Bool {
        switch self {
        case .healthy, .needsAdmin, .behind, .ahead, .rolling: return false
        case .down, .unhealthy, .reported, .unknown: return true
        }
    }
}

/// RowTone is how a status row is drawn: its glyph, its colour and the word
/// accessibility reads, so the colour is never the only signal.
public enum RowTone: Equatable, Sendable {
    case healthy
    /// Not checked from this account; neutral, never a fault.
    case notChecked
    case attention

    /// The SF Symbol name of the row's glyph.
    public var symbolName: String {
        switch self {
        case .healthy: return "checkmark.circle.fill"
        case .notChecked: return "minus.circle"
        case .attention: return "exclamationmark.triangle.fill"
        }
    }

    /// The word accessibility reads for the glyph.
    public var word: String {
        switch self {
        case .healthy: return "ok"
        case .notChecked: return "not checked"
        case .attention: return "needs attention"
        }
    }
}

extension StatusDisplay {
    /// The sentence a `needs-admin` row shows instead of its detail.
    public static let needsAdminText = "needs an administrator"

    /// The detail a row shows, clipped: a `needs-admin` row says it needs an
    /// administrator and names the row's own remedy, for example "needs an
    /// administrator; run sudo k3sm status". A `behind`, `ahead`, `rolling`,
    /// `down` or `unhealthy` row shows
    /// its detail as printed, then "; run " and its remedy when it has one.
    /// Any other row shows its detail.
    public static func rowDetail(_ row: StatusRow) -> String {
        let remedy = clip(row.remedy)
        switch row.rowState {
        case .needsAdmin:
            return clip(remedy.isEmpty ? needsAdminText : needsAdminText + "; run " + remedy)
        case .behind, .ahead, .rolling, .down, .unhealthy:
            let detail = clip(row.detail)
            return remedy.isEmpty ? detail : clip(detail + "; run " + remedy)
        default:
            return clip(row.detail)
        }
    }

    /// The text the window's left panel shows beside a row's name: the
    /// `needs-admin` sentence for such a row, the state word for any other.
    public static func panelText(_ row: StatusRow) -> String {
        row.rowState == .needsAdmin ? rowDetail(row) : clip(row.state)
    }

    /// How many of the report's rows are `needs-admin`.
    public static func needsAdminCount(_ report: StatusReport) -> Int {
        report.rows.filter { $0.rowState == .needsAdmin }.count
    }

    /// "1 check needs an administrator", "3 checks need an administrator",
    /// or nil when there are none.
    public static func needsAdminLine(_ report: StatusReport) -> String? {
        let n = needsAdminCount(report)
        switch n {
        case 0: return nil
        case 1: return "1 check needs an administrator"
        default: return "\(n) checks need an administrator"
        }
    }

    /// The window's status headline, clipped: "k3sm <verdict>", the summary
    /// after a middle dot, then the needs-admin count. The verdict is the
    /// CLI's word, whatever the rows say.
    public static func headline(_ report: StatusReport) -> String {
        var parts = ["k3sm \(report.verdict.word)"]
        if !report.summary.isEmpty { parts.append(report.summary) }
        if let line = needsAdminLine(report) { parts.append(line) }
        return clip(parts.joined(separator: " · "))
    }

    /// The left panel's state line, clipped: "Running, 4 pods" while the
    /// verdict is running, else "<verdict>: <summary>", then the needs-admin
    /// count; "Status not read, 4 pods" before any report.
    public static func panelStateLine(_ report: StatusReport?, podCount: Int) -> String {
        let count = "\(podCount) \(podCount == 1 ? "pod" : "pods")"
        guard let report else { return "Status not read, \(count)" }
        var line = report.verdict == .running ? "Running, \(count)" : "\(report.verdict.word): \(report.summary)"
        if let admin = needsAdminLine(report) { line += " · " + admin }
        return clip(line)
    }
}
