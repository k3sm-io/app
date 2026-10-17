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

/// IssueLevel is how bad one listed status row is, from its `severity`
/// word, worst first: the order the Alerts tab groups its issues in. A
/// severity word this build does not know is `reported`, drawn for attention
/// after the warnings, so a newer k3sm's rows still show. Only a fault is
/// listed: an `ok` row, a row the check could not tell (`unknown`) or did not
/// run (`skip`, a check that needs an administrator included), and a row with
/// no severity, are not.
public enum IssueLevel: Int, CaseIterable, Comparable, Sendable {
    /// `fail`: the subsystem is not working.
    case failing
    /// `warn`: it works, but something is wrong.
    case warning
    /// A severity word this build does not know, kept as printed.
    case reported

    /// The level of a row, nil for a row the tab does not list: `ok`,
    /// `unknown`, `skip` and an empty severity.
    public init?(row: StatusRow) {
        switch row.severity {
        case "ok", "unknown", "skip", "": return nil
        case "fail": self = .failing
        case "warn": self = .warning
        default: self = .reported
        }
    }

    /// The group's heading.
    public var title: String {
        switch self {
        case .failing: return "Failing"
        case .warning: return "Needs attention"
        case .reported: return "Reported"
        }
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

/// ClusterIssue is one status row that is not ok, as the Alerts tab's card
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

/// ClusterIssues is the Alerts tab: the issues behind the status headline,
/// read only from the full status report the app already polls. Every row
/// that is failing, needs attention or carries a severity this build does
/// not know is an issue, grouped by `IssueLevel` worst first, each with its
/// detail and remedy; under them the report's `next` commands. The
/// `workloads` row is never listed, whatever its state: the Workloads,
/// Nodes and Images tabs are that check. The report carries no rows for its workers (each is a name, a
/// role and a version), so every issue is this Mac's report; a worker's own
/// checks are read on that Mac. Every string is clipped, the report's text
/// being node-reported.
public struct ClusterIssues: Equatable, Sendable {
    /// The most steps one remedy shows, and the most `next` commands.
    public static let maxSteps = 8

    public let groups: [ClusterIssueGroup]
    public let next: [RemedyStep]
    /// Whether nothing is wrong: the verdict is running and no row is
    /// listed.
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
    /// The resting line when nothing is wrong and no card is shown.
    public static let healthyText = "Everything is healthy"
    /// The status row the tab never lists: its own tabs show it.
    public static let workloadsRow = "workloads"
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
            guard row.name != workloadsRow, let level = IssueLevel(row: row) else { continue }
            byLevel[level, default: []].append(ClusterIssue(
                name: StatusDisplay.clip(row.name), state: StatusDisplay.clip(row.state),
                detail: StatusDisplay.clip(row.detail), level: level, remedy: RemedyStep.steps(row.remedy)))
        }
        let groups = IssueLevel.allCases.compactMap { level in
            byLevel[level].map { ClusterIssueGroup(level: level, issues: $0) }
        }
        let problems = groups.reduce(0) { $0 + $1.issues.count }
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

    /// The one sentence the tab rests on when nothing is wrong and no card
    /// is shown: "Everything is healthy, last checked 3 min ago.", or with no
    /// known check time "Everything is healthy."
    public func healthyLine(now: Date = Date()) -> String {
        guard checkedAt != nil else { return Self.healthyText + "." }
        let line = checkedLine(now: now)
        return Self.healthyText + ", " + line.prefix(1).lowercased() + line.dropFirst() + "."
    }

    /// Whether the tab rests in its field: the report is clean and no update
    /// card is shown.
    public func rests(withCard card: Bool) -> Bool { isClean && groups.isEmpty && !card }

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

/// UpdateCard is the Alerts tab's first card while the update plan offers
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

/// FieldPose is where the Alerts tab's resting butterfly is at one moment,
/// in the field's unit square (x right, y down): its centre, its wing beat
/// (`FlappingButterfly`'s hinge angle in degrees), its tilt in degrees, and
/// whether it is perched, drawn side-on and still.
public struct FieldPose: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let beat: Double
    public let tilt: Double
    public let perched: Bool
}

/// FieldFlight is the field the Alerts tab rests in when nothing is wrong
/// and the butterfly's slow loop over it, as pure functions of the time so
/// the view only samples them. The field is a gentle hill line with a few
/// flowers on it; the loop is a figure of eight above the flowers, one lap
/// in `period`, with a slow flutter and a small bob, leaning into the way
/// it flies. Under Reduce Motion the butterfly perches on the tallest
/// flower instead and does not move.
public enum FieldFlight {
    /// One lap of the loop, in seconds.
    public static let period: TimeInterval = 18
    /// One wing beat, in seconds, slower than the waiting mark's.
    public static let beatPeriod: TimeInterval = 0.6
    /// The widest the wings open on a beat, in degrees.
    public static let beatPeak: Double = 50
    /// The most the butterfly leans into a turn, in degrees.
    public static let maxTilt: Double = 12
    /// Where the ground lies, as a fraction of the field's height from the top.
    public static let ground: Double = 0.82
    /// The flowers: each one's x and its height above the ground, both as
    /// fractions of the field.
    public static let flowers: [(x: Double, height: Double)] = [
        (0.12, 0.10), (0.27, 0.16), (0.44, 0.09), (0.63, 0.22), (0.78, 0.12), (0.91, 0.08),
    ]
    /// The flower the butterfly perches on under Reduce Motion: the tallest.
    public static let perch = 3

    /// The hill line's height above `ground` at `x`, a fraction of the
    /// field's height: two long, low swells.
    public static func hill(at x: Double) -> Double {
        0.035 * sin(2 * .pi * (x * 1.3 + 0.1)) + 0.02 * sin(2 * .pi * x * 0.55)
    }

    /// The top of flower `index`, where a perched butterfly's feet are.
    public static func flowerTop(_ index: Int) -> (x: Double, y: Double) {
        let flower = flowers[index]
        return (flower.x, ground - hill(at: flower.x) - flower.height)
    }

    /// The pose `now` seconds into the flight; perched and still under
    /// `reduceMotion`.
    public static func pose(at now: TimeInterval, reduceMotion: Bool) -> FieldPose {
        if reduceMotion {
            let top = flowerTop(perch)
            return FieldPose(x: top.x, y: top.y, beat: 0, tilt: 0, perched: true)
        }
        let theta = 2 * .pi * now / period
        let x = 0.5 + 0.36 * sin(theta)
        let y = 0.33 + 0.1 * sin(2 * theta) + 0.02 * sin(2 * .pi * now / (period / 5))
        let beat = beatPeak * (0.5 - 0.5 * cos(2 * .pi * now / beatPeriod))
        return FieldPose(x: x, y: y, beat: beat, tilt: maxTilt * cos(theta), perched: false)
    }
}
