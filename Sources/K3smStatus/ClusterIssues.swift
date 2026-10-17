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

/// IssueLevel is how bad one status row is, from its `severity` word, worst
/// first: the order the Cluster tab groups its issues in. A severity word
/// this build does not know is `reported`, drawn for attention after the
/// warnings; a row with no severity is `unknown` unless its state is a
/// healthy word.
public enum IssueLevel: Int, CaseIterable, Comparable, Sendable {
    /// `fail`: the subsystem is not working.
    case failing
    /// `warn`: it works, but something is wrong.
    case warning
    /// A severity word this build does not know, kept as printed.
    case reported
    /// `unknown`: the check could not tell.
    case unknown
    /// `skip`: the check did not run, a check that needs an administrator included.
    case notChecked

    /// The level of a row, nil for an `ok` row (and a row with no severity
    /// whose state is healthy).
    public init?(row: StatusRow) {
        switch row.severity {
        case "ok": return nil
        case "fail": self = .failing
        case "warn": self = .warning
        case "unknown": self = .unknown
        case "skip": self = .notChecked
        case "":
            if row.rowState.tone == .healthy { return nil }
            self = .unknown
        default: self = .reported
        }
    }

    /// The group's heading.
    public var title: String {
        switch self {
        case .failing: return "Failing"
        case .warning: return "Needs attention"
        case .reported: return "Reported"
        case .unknown: return "Not known"
        case .notChecked: return "Not checked"
        }
    }

    /// How the group's badges are drawn.
    public var tone: RowTone {
        self == .notChecked ? .notChecked : .attention
    }

    /// Whether a row at this level means something is wrong. A row the check
    /// could not read or did not run is listed, but it is not a fault.
    public var isProblem: Bool {
        self == .failing || self == .warning || self == .reported
    }

    public static func < (a: IssueLevel, b: IssueLevel) -> Bool { a.rawValue < b.rawValue }
}

/// RemedyStep is one line of a remedy or of the report's `next` list: the
/// text shown, clipped, and the command a Copy button puts on the pasteboard
/// when the line is one. A line is a command when it starts with `k3sm`,
/// `sudo` or `kubectl` and clipping left it whole; a clipped or cleaned line
/// is shown but never copied, so the pasteboard never holds a command that
/// differs from the one the CLI printed.
public struct RemedyStep: Equatable, Sendable {
    public let text: String
    public let command: String?

    public init(text: String, command: String?) {
        self.text = text
        self.command = command
    }

    /// The words a command line starts with.
    static let commandWords: Set<String> = ["k3sm", "sudo", "kubectl"]

    /// One printed line as a step, nil when it is blank.
    public static func of(_ line: String) -> RemedyStep? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let text = StatusDisplay.clip(trimmed)
        let first = text.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        let command = commandWords.contains(first) && text == trimmed ? text : nil
        return RemedyStep(text: text, command: command)
    }

    /// A row's remedy as its steps: one per printed line, the CLI's form for
    /// a repair that takes more than one command.
    public static func steps(_ remedy: String) -> [RemedyStep] {
        remedy.split(whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" })
            .prefix(ClusterIssues.maxSteps).compactMap { of(String($0)) }
    }
}

/// ClusterIssue is one status row that is not ok, as the Cluster tab's card
/// shows it: the row's name, its state word, its detail and its remedy, each
/// clipped.
public struct ClusterIssue: Equatable, Sendable {
    public let name: String
    public let state: String
    public let detail: String
    public let level: IssueLevel
    /// The remedy's steps, empty when the row names none.
    public let remedy: [RemedyStep]
}

/// ClusterIssueGroup is the issues at one level, in the report's order.
public struct ClusterIssueGroup: Equatable, Sendable {
    public let level: IssueLevel
    public let issues: [ClusterIssue]

    /// The group's heading with its count, "Failing (2)".
    public var heading: String { "\(level.title) (\(issues.count))" }
}

/// ClusterIssues is the Cluster tab: the issues behind the status headline,
/// read only from the full status report the app already polls. Every row
/// whose severity is not `ok` is an issue, grouped by `IssueLevel` worst
/// first, each with its detail and remedy; under them the report's `next`
/// commands. The report carries no rows for its workers (each is a name, a
/// role and a version), so every issue is this Mac's report; a worker's own
/// checks are read on that Mac. Every string is clipped, the report's text
/// being node-reported.
public struct ClusterIssues: Equatable, Sendable {
    /// The most steps one remedy shows, and the most `next` commands.
    public static let maxSteps = 8

    public let groups: [ClusterIssueGroup]
    public let next: [RemedyStep]
    /// Whether nothing is wrong: the verdict is running and no row is
    /// failing, warning or at a level this build does not know.
    public let isClean: Bool
    /// The tab's first line.
    public let headline: String
    /// The report's summary sentence, clipped; nil when clean or empty.
    public let summary: String?
    /// When the report was made, nil when its timestamp is absent or does
    /// not parse.
    public let checkedAt: Date?

    /// The headline before any report is read.
    public static let notRead = "No status report has been read yet."
    /// The headline when nothing is wrong.
    public static let cleanText = "Nothing needs attention."
    /// The line when the report's time is not known.
    public static let checkedUnknown = "Last check time not reported"
    /// The heading over the `next` commands.
    public static let nextTitle = "Next steps"
    /// The inspector's line on this tab, which has no rows to select.
    public static let inspectorText = "Each card names a check, what it found and how to fix it."

    /// The tab for `report`; nil is not read yet.
    public static func of(_ report: StatusReport?) -> ClusterIssues {
        guard let report else {
            return ClusterIssues(groups: [], next: [], isClean: false, headline: notRead, summary: nil, checkedAt: nil)
        }
        var byLevel: [IssueLevel: [ClusterIssue]] = [:]
        for row in report.rows.prefix(StatusDisplay.maxRows) {
            guard let level = IssueLevel(row: row) else { continue }
            byLevel[level, default: []].append(ClusterIssue(
                name: StatusDisplay.clip(row.name), state: StatusDisplay.clip(row.state),
                detail: StatusDisplay.clip(row.detail), level: level, remedy: RemedyStep.steps(row.remedy)))
        }
        let groups = IssueLevel.allCases.compactMap { level in
            byLevel[level].map { ClusterIssueGroup(level: level, issues: $0) }
        }
        let problems = groups.filter(\.level.isProblem).reduce(0) { $0 + $1.issues.count }
        let clean = problems == 0 && report.verdict == .running
        let summary = StatusDisplay.clip(report.summary)
        return ClusterIssues(
            groups: groups,
            next: report.next.prefix(maxSteps).compactMap(RemedyStep.of),
            isClean: clean,
            headline: clean ? cleanText : headline(problems: problems, verdict: report.verdict),
            summary: clean || summary.isEmpty ? nil : summary,
            checkedAt: parse(report.timestamp))
    }

    /// The headline while something is wrong: the count of failing and
    /// warning rows, or, with none, the verdict's word as the headline shows it.
    static func headline(problems: Int, verdict: Verdict) -> String {
        switch problems {
        case 0: return "\(StatusHeadline.word(verdict)), with no failing check."
        case 1: return "1 check needs attention."
        default: return "\(problems) checks need attention."
        }
    }

    /// When the report was checked, as the tab says it: "Last checked just
    /// now", "Last checked 40 s ago", "Last checked 3 min ago", "Last checked
    /// 2 h ago"; a time in the future reads as just now.
    public func checkedLine(now: Date = Date()) -> String {
        guard let checkedAt else { return Self.checkedUnknown }
        let seconds = max(0, now.timeIntervalSince(checkedAt))
        switch seconds {
        case ..<5: return "Last checked just now"
        case ..<60: return "Last checked \(Int(seconds)) s ago"
        case ..<3600: return "Last checked \(Int(seconds / 60)) min ago"
        default: return "Last checked \(Int(seconds / 3600)) h ago"
        }
    }

    /// The report's RFC 3339 timestamp, with or without fractional seconds.
    static func parse(_ text: String) -> Date? {
        guard !text.isEmpty, text.count <= 64 else { return nil }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }
}

/// UpdateCard is the Cluster tab's first card while the update plan offers
/// Update (`UpdatePlan.buttonTitle`, the condition the console strip's button
/// had): a title naming what is behind, the plan's line, and the button with
/// the plan's own title ("Update", or "Updating…" while a roll runs) and
/// state. The strip carries no update button; this card is its home.
public struct UpdateCard: Equatable, Sendable {
    public let title: String
    /// What the update does, or why it cannot run (`UpdatePlan.line`).
    public let detail: String?
    public let buttonTitle: String
    public let isEnabled: Bool

    /// The title while a managed update runs.
    public static let rollingTitle = "An update is rolling"

    /// The card for `plan`, nil when the plan offers no Update. A catch-up
    /// names its nodes' count; a managed roll counts the nodes the report
    /// shows on an older release than its tag (the server's own release and
    /// each worker's), or says the release is available when none is known
    /// to be behind; the app-carried update names this Mac.
    public static func of(plan: UpdatePlan, report: StatusReport?) -> UpdateCard? {
        guard let button = plan.buttonTitle else { return nil }
        let title: String
        if plan == .rolling {
            title = rollingTitle
        } else {
            switch plan.path {
            case .catchUp(let tag, let nodes)?: title = behind(nodes.count, tag)
            case .managed(let tag)?:
                let count = behindCount(report, tag: tag)
                title = count > 0 ? behind(count, tag) : "k3sm \(tag) is available"
            case .payload(let version)?: title = "This Mac is behind \(version)"
            case nil: title = rollingTitle
            }
        }
        return UpdateCard(title: StatusDisplay.clip(title), detail: plan.line.map(StatusDisplay.clip),
                          buttonTitle: button, isEnabled: plan.isEnabled)
    }

    /// "1 node behind v0.1.9", "3 nodes behind v0.1.9".
    static func behind(_ count: Int, _ tag: String) -> String {
        "\(count) \(count == 1 ? "node" : "nodes") behind \(tag)"
    }

    /// How many of the report's nodes run a known release older than `tag`.
    static func behindCount(_ report: StatusReport?, tag: String) -> Int {
        guard let report, let target = SemanticVersion(tag) else { return 0 }
        let releases = [report.release.flatMap { SemanticVersion($0.text) }] + (report.workers ?? []).map(\.k3smRelease)
        return releases.compactMap { $0 }.filter { $0 < target }.count
    }
}
