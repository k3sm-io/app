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

/// UpdatePhase is a managed update's display phase as `k3sm update status -o
/// json` prints it. An empty phase is an Update the controller has not
/// reconciled yet, read as pending. A word this build does not know is kept
/// as printed. Whether the roll is over is the CLI's `finished`, never the
/// phase (`UpdateStatus.ended`).
public enum UpdatePhase: Equatable, Sendable {
    case pending
    case rolling
    case succeeded
    case failed
    case cancelled
    case unrecognized(String)

    public init(word: String) {
        switch word {
        case "Pending", "": self = .pending
        case "Rolling": self = .rolling
        case "Succeeded": self = .succeeded
        case "Failed": self = .failed
        case "Cancelled": self = .cancelled
        default: self = .unrecognized(word)
        }
    }

    /// The wire word, as the CLI prints it.
    public var word: String {
        switch self {
        case .pending: return "Pending"
        case .rolling: return "Rolling"
        case .succeeded: return "Succeeded"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        case .unrecognized(let w): return w
        }
    }

    /// Whether the word is one of the three end phases.
    public var isFinished: Bool {
        switch self {
        case .succeeded, .failed, .cancelled: return true
        case .pending, .rolling, .unrecognized: return false
        }
    }
}

/// UpdateNode is one node of a managed update, from the `nodes` list. Every
/// field is untrusted data, "" when missing or not a string.
public struct UpdateNode: Decodable, Equatable, Sendable {
    public let name: String
    public let from: String
    public let to: String
    public let phase: String
    public let message: String
    public let lastProgress: String

    public init(name: String, from: String = "", to: String = "", phase: String = "", message: String = "", lastProgress: String = "") {
        self.name = name
        self.from = from
        self.to = to
        self.phase = phase
        self.message = message
        self.lastProgress = lastProgress
    }

    private enum CodingKeys: String, CodingKey { case name, from, to, phase, message, lastProgress }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) -> String { (try? c.decodeIfPresent(String.self, forKey: key)) ?? "" }
        name = text(.name)
        from = text(.from)
        to = text(.to)
        phase = text(.phase)
        message = text(.message)
        lastProgress = text(.lastProgress)
    }
}

/// UpdateCondition is one entry of the `conditions` list; every field is
/// untrusted data, "" when missing or not a string.
public struct UpdateCondition: Decodable, Equatable, Sendable {
    public let type: String
    public let status: String
    public let reason: String
    public let message: String

    public init(type: String, status: String, reason: String = "", message: String = "") {
        self.type = type
        self.status = status
        self.reason = reason
        self.message = message
    }

    private enum CodingKeys: String, CodingKey { case type, status, reason, message }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) -> String { (try? c.decodeIfPresent(String.self, forKey: key)) ?? "" }
        type = text(.type)
        status = text(.status)
        reason = text(.reason)
        message = text(.message)
    }
}

/// UpdateStatus is the decoded output of `k3sm update status -o json`: the
/// Update's name (absent when the cluster has none), the roll's phase, the
/// version asked for, the release it resolved to (nil until resolved), each
/// node, the conditions, and `finished`, the controller's end-state
/// predicate. Only `phase` is required; any other field that is missing or
/// mistyped reads as empty. With no Update the CLI prints
/// `{"phase":"","version":"","resolved":null,"nodes":[],"conditions":[]}`.
public struct UpdateStatus: Decodable, Equatable, Sendable {
    public struct Resolved: Decodable, Equatable, Sendable {
        public let version: String
        public let digest: String

        public init(version: String, digest: String) {
            self.version = version
            self.digest = digest
        }

        private enum CodingKeys: String, CodingKey { case version, digest }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = (try? c.decodeIfPresent(String.self, forKey: .version)) ?? ""
            digest = (try? c.decodeIfPresent(String.self, forKey: .digest)) ?? ""
        }
    }

    public let phase: UpdatePhase
    public let version: String
    public let resolved: Resolved?
    public let nodes: [UpdateNode]
    public let conditions: [UpdateCondition]
    /// The Update's name; "" when the cluster has none.
    public let name: String
    /// Whether the controller says the roll is over.
    public let finished: Bool

    public init(phase: UpdatePhase, version: String, resolved: Resolved? = nil, nodes: [UpdateNode] = [],
                conditions: [UpdateCondition] = [], name: String = "current", finished: Bool = false) {
        self.phase = phase
        self.version = version
        self.resolved = resolved
        self.nodes = nodes
        self.conditions = conditions
        self.name = name
        self.finished = finished
    }

    private enum CodingKeys: String, CodingKey { case phase, version, resolved, nodes, conditions, name, finished }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        phase = UpdatePhase(word: try c.decode(String.self, forKey: .phase))
        version = (try? c.decodeIfPresent(String.self, forKey: .version)) ?? ""
        resolved = (try? c.decodeIfPresent(Resolved.self, forKey: .resolved)) ?? nil
        nodes = (try? c.decodeIfPresent([UpdateNode].self, forKey: .nodes)) ?? []
        conditions = (try? c.decodeIfPresent([UpdateCondition].self, forKey: .conditions)) ?? []
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        finished = (try? c.decodeIfPresent(Bool.self, forKey: .finished)) ?? false
    }

    /// Whether the cluster has an Update at all.
    public var present: Bool { !name.isEmpty || !version.isEmpty }

    /// How a finished roll ended, nil while it runs: the phase when it is an
    /// end phase, else the Progressing condition's reason, else failed (the
    /// remedy a failure shows is the safe one).
    public var ended: UpdatePhase? {
        guard finished else { return nil }
        if phase.isFinished { return phase }
        let reason = conditions.first { $0.type == "Progressing" }.map { UpdatePhase(word: $0.reason) }
        if let reason, reason.isFinished { return reason }
        return .failed
    }

    /// The release the roll goes to: the resolved version, else the one asked for.
    public var target: String {
        if let resolved, !resolved.version.isEmpty { return resolved.version }
        return version
    }

    /// Decodes the CLI's standard output; throws `StatusDecodeError.malformed`
    /// when it is not an update status.
    public static func decode(_ data: Data) throws -> UpdateStatus {
        do {
            return try JSONDecoder().decode(UpdateStatus.self, from: data)
        } catch {
            throw StatusDecodeError.malformed
        }
    }

    /// One `k3sm update status -o json` run as a read result.
    public static func tabResult(exitCode: Int32, stdout: Data) -> TabResult<UpdateStatus> {
        guard exitCode == 0 else { return .failed("k3sm update status exited \(exitCode)") }
        guard let status = try? decode(stdout) else { return .failed("the update status could not be read") }
        return .value(status)
    }
}

/// UpdateApplyResult is what one run of `k3sm update apply --yes` came to,
/// as the progress tracker needs it.
public enum UpdateApplyResult: Equatable, Sendable {
    /// The CLI created the roll (exit 0).
    case started
    /// The CLI refused because a roll already exists (exit 1, "an update is
    /// already rolling (<phase>)"): the app follows that roll.
    case alreadyRolling
    /// Nothing was started: the prompt was dismissed, or the run failed.
    case notStarted
}

/// UpdateProgress is the app's view of the managed update: nothing known,
/// the apply's root step running, a roll in progress, or a finished roll
/// shown until it is dismissed. Moves come from the app's own apply and from
/// each `k3sm update status` read. A finished roll is shown only when the app
/// was following it; one found already finished is not brought up.
public struct UpdateProgress: Equatable, Sendable {
    public enum Stage: Equatable, Sendable {
        case idle
        /// The apply's administrator prompt or root step is running.
        case applying
        /// A roll is in progress; nil until the first status read.
        case rolling(UpdateStatus?)
        case succeeded(UpdateStatus)
        case failed(UpdateStatus)
        case cancelled(UpdateStatus)
    }

    public private(set) var stage: Stage = .idle
    /// The release of the last roll seen to succeed. The `update` row is
    /// recomputed only at the next check, so until then it may still name
    /// this release as available; the offer is not repeated for it.
    public private(set) var completedVersion: String?

    public init(stage: Stage = .idle, completedVersion: String? = nil) {
        self.stage = stage
        self.completedVersion = completedVersion
    }

    /// Whether an update is under way: the menu says "Updating…".
    public var isRolling: Bool {
        switch stage {
        case .applying, .rolling: return true
        case .idle, .succeeded, .failed, .cancelled: return false
        }
    }

    /// The apply's root step is starting.
    public mutating func applyStarted() {
        stage = .applying
    }

    /// The apply's root step finished.
    public mutating func applyFinished(_ result: UpdateApplyResult) {
        guard stage == .applying else { return }
        switch result {
        case .started, .alreadyRolling: stage = .rolling(nil)
        case .notStarted: stage = .idle
        }
    }

    /// Takes one decoded status read. A roll not finished is under way and
    /// followed from here; a finished one ends a roll the app was following
    /// and is ignored otherwise. No Update at all (removed by `k3sm update
    /// abort`, say) leaves nothing to follow.
    public mutating func read(_ status: UpdateStatus) {
        let following: Bool
        switch stage {
        case .applying, .rolling: following = true
        case .idle: following = false
        case .succeeded, .failed, .cancelled: return
        }
        guard status.present else {
            stage = .idle
            return
        }
        switch status.ended {
        case nil, .pending?, .rolling?, .unrecognized?:
            stage = .rolling(status)
        case .succeeded?:
            guard following else { return }
            stage = .succeeded(status)
            completedVersion = status.target
        case .failed?:
            guard following else { return }
            stage = .failed(status)
        case .cancelled?:
            guard following else { return }
            stage = .cancelled(status)
        }
    }

    /// The Dismiss button: a finished roll leaves the window.
    public mutating func dismiss() {
        switch stage {
        case .succeeded, .failed, .cancelled: stage = .idle
        case .idle, .applying, .rolling: break
        }
    }

    /// Whether the app reads `k3sm update status` now: always while a roll
    /// is followed; while idle when an update is offered or the `update` row
    /// says one is rolling (so a roll started elsewhere is found and
    /// followed); never while the apply runs or a finished roll is shown.
    public func readsStatus(offerShown: Bool, rowRolling: Bool = false) -> Bool {
        switch stage {
        case .rolling: return true
        case .idle: return offerShown || rowRolling
        case .applying, .succeeded, .failed, .cancelled: return false
        }
    }

    /// Whether the panel offers Cancel: while a roll is pending or rolling.
    public var canCancel: Bool {
        guard case .rolling(let status) = stage else { return false }
        return status.map { !$0.finished } ?? true
    }

    /// The remedy a failed roll shows.
    public static let failedRemedy = "Run k3sm update abort in Terminal, then try again."

    /// What the window's progress panel shows, or nil when it shows none.
    public var panel: UpdatePanel? {
        switch stage {
        case .idle:
            return nil
        case .applying:
            return UpdatePanel(title: "Starting the update…", detail: nil, remedy: nil, nodes: [], showsCancel: false, showsDismiss: false)
        case .rolling(let status):
            let title = status.map { s in
                let target = StatusDisplay.clip(s.target)
                return (target.isEmpty ? "Updating k3sm" : "Updating to " + target) + " · " + StatusDisplay.clip(s.phase.word)
            } ?? "Updating k3sm"
            return UpdatePanel(title: title, detail: status == nil ? "Waiting for the first progress report." : nil,
                               remedy: nil, nodes: UpdatePanel.lines(status), showsCancel: canCancel, showsDismiss: false)
        case .succeeded(let s):
            return UpdatePanel(title: UpdatePanel.versioned("Updated to", s, else: "The update finished"),
                               detail: "Every node runs the new release.", remedy: nil,
                               nodes: UpdatePanel.lines(s), showsCancel: false, showsDismiss: true)
        case .failed(let s):
            return UpdatePanel(title: UpdatePanel.versioned("The update to", s, suffix: " failed", else: "The update failed"),
                               detail: UpdatePanel.failureMessage(s), remedy: Self.failedRemedy,
                               nodes: UpdatePanel.lines(s), showsCancel: false, showsDismiss: true)
        case .cancelled(let s):
            return UpdatePanel(title: UpdatePanel.versioned("The update to", s, suffix: " was cancelled", else: "The update was cancelled"),
                               detail: nil, remedy: nil, nodes: UpdatePanel.lines(s), showsCancel: false, showsDismiss: true)
        }
    }
}

/// UpdatePanel is the window's update progress panel as text: a title, an
/// optional detail and remedy, one line per node, and which buttons it
/// offers. Every string from the CLI is clipped.
public struct UpdatePanel: Equatable, Sendable {
    public let title: String
    public let detail: String?
    public let remedy: String?
    public let nodes: [UpdateNodeLine]
    public let showsCancel: Bool
    public let showsDismiss: Bool

    static func lines(_ status: UpdateStatus?) -> [UpdateNodeLine] {
        (status?.nodes ?? []).prefix(StatusDisplay.maxRows).map(UpdateNodeLine.init)
    }

    static func versioned(_ head: String, _ s: UpdateStatus, suffix: String = "", else plain: String) -> String {
        let target = StatusDisplay.clip(s.target)
        return target.isEmpty ? plain + "." : StatusDisplay.clip(head + " " + target + suffix + ".")
    }

    /// The failed node's message, else the message of a condition that
    /// names the failure (its type or reason `Failed`), else nil; clipped.
    static func failureMessage(_ s: UpdateStatus) -> String? {
        if let node = s.nodes.first(where: { $0.phase.lowercased() == "failed" }) {
            let message = StatusDisplay.clip(node.message)
            let name = StatusDisplay.clip(node.name)
            if !message.isEmpty { return StatusDisplay.clip(name.isEmpty ? message : name + ": " + message) }
        }
        if let c = s.conditions.first(where: { ($0.type == "Failed" || $0.reason == "Failed") && !$0.message.isEmpty }) {
            return StatusDisplay.clip(c.message)
        }
        return nil
    }
}

/// UpdateNodeLine is one row of the progress panel's node table, clipped.
public struct UpdateNodeLine: Equatable, Sendable {
    public let name: String
    /// "v0.1.7 → v0.1.8", one side alone when the other is not reported.
    public let versions: String
    public let phase: String
    public let message: String

    public init(_ node: UpdateNode) {
        name = StatusDisplay.clip(node.name)
        let from = StatusDisplay.clip(node.from)
        let to = StatusDisplay.clip(node.to)
        switch (from.isEmpty, to.isEmpty) {
        case (false, false): versions = StatusDisplay.clip(from + " → " + to)
        case (true, false): versions = "→ " + to
        case (false, true): versions = from
        case (true, true): versions = ""
        }
        phase = StatusDisplay.clip(node.phase)
        message = StatusDisplay.clip(node.message)
    }
}

/// UpdateOffer is whether the status item's menu and the console offer the
/// managed update, decided from the full report's `update` row: only a
/// `behind` row with a valid latest tag offers one, and only while no update
/// is under way. `ok`, `ahead`, `unknown`, any other word, and no row offer
/// nothing. While an update rolls, both read "Updating…", disabled. A
/// privileged action, it is shown disabled with the reason on a developer
/// build or when the app cannot run it as root.
public enum UpdateOffer: Equatable, Sendable {
    case hidden
    /// The update to `tag` is offered; disabled when `disabledReason` is set.
    case available(tag: String, disabledReason: String?)
    /// An update is under way.
    case updating

    /// The reason a developer build gives, as for Stop and Restart.
    public static let developerBuildReason =
        "This build of k3sm is not Developer ID signed, so it cannot update k3sm. Use `sudo k3sm update apply` in Terminal."

    /// The longest tag accepted.
    static let maxTagLength = 40

    public static func decide(report: StatusReport?, progress: UpdateProgress, developerBuild: Bool, blocked: String?) -> UpdateOffer {
        if progress.isRolling || rowRolling(in: report) { return .updating }
        guard let row = report?.row(named: "update"), row.rowState == .behind, let tag = latestTag(in: row) else {
            return .hidden
        }
        if let done = progress.completedVersion.flatMap(SemanticVersion.init), SemanticVersion(tag) == done {
            return .hidden
        }
        return .available(tag: tag, disabledReason: developerBuild ? developerBuildReason : blocked)
    }

    /// Whether the report's `update` row says a managed update is in
    /// progress: the `rolling` state, with `wide.phase` (absent before the
    /// controller reconciles, read as pending) not an end phase. The same
    /// `UpdatePhase` reading as the update status read decides it.
    public static func rowRolling(in report: StatusReport?) -> Bool {
        guard let row = report?.row(named: "update"), row.rowState == .rolling else { return false }
        return !UpdatePhase(word: row.wide["phase"] ?? "").isFinished
    }

    /// The release a `behind` row offers: `wide.latest`, else the tag the
    /// detail names ("k3sm v0.1.8 is available; ..."). A tag must parse as a
    /// release version (ASCII only, at most 40 characters), so nothing else
    /// a row carries reaches a title; nil when neither is one.
    public static func latestTag(in row: StatusRow) -> String? {
        if let wide = row.wide["latest"], valid(wide) { return wide }
        let words = row.detail.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: false)
        if words.count >= 3, words[0] == "k3sm", words[2] == "is" {
            let tag = String(words[1])
            if valid(tag) { return tag }
        }
        return nil
    }

    static func valid(_ tag: String) -> Bool {
        !tag.isEmpty && tag.count <= maxTagLength && tag.allSatisfy(\.isASCII) && SemanticVersion(tag) != nil
    }

    /// The status item's menu title, nil when hidden.
    public var menuTitle: String? {
        switch self {
        case .hidden: return nil
        case .available(let tag, _): return "Update to \(StatusDisplay.clip(tag))…"
        case .updating: return "Updating…"
        }
    }

    /// The console button's title, nil when hidden.
    public var buttonTitle: String? {
        switch self {
        case .hidden: return nil
        case .available: return "Update"
        case .updating: return "Updating…"
        }
    }

    /// Whether the item and the button can be clicked.
    public var isEnabled: Bool {
        if case .available(_, nil) = self { return true }
        return false
    }

    /// Why the item is disabled, nil when enabled or hidden.
    public var disabledReason: String? {
        switch self {
        case .available(_, let reason): return reason
        case .updating: return "An update is rolling; the window shows its progress."
        case .hidden: return nil
        }
    }

    /// The tag offered, nil unless available.
    public var tag: String? {
        if case .available(let tag, _) = self { return tag }
        return nil
    }
}
