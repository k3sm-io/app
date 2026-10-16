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
import K3smStatus

/// LANToggle is what the window shows for the "Allow connections
/// from other devices" setting: whether the checkbox is there at all, its
/// tri-state value, whether it can be clicked (and if not, why), the notes
/// under it, and whether the status item carries the LAN indicator.
///
/// Only an explicit `on` or `off` from a fresh, trusted status read drives
/// the checkbox. A failed read, a stale one, an untrusted CLI or a value the
/// app does not know leaves it disabled with the reason. Nothing is toggled
/// optimistically: the value changes only when a status read says so.
public struct LANToggle: Equatable, Sendable {
    public static let title = "Allow connections from other devices"
    public static let subtitle = "Off: only this Mac and your cluster mesh"
    /// How old a status read may be before the checkbox stops trusting it.
    public static let maxAge: TimeInterval = 120

    /// Whether the checkbox is shown. A role with no switch hides it.
    public let visible: Bool
    /// The recorded setting, as the checkbox shows it.
    public let value: LANSetting
    /// Why the checkbox cannot be clicked; nil when it can.
    public let disabledReason: String?
    /// The lines under the checkbox: a setting that is not recorded, a
    /// recorded value the daemon does not serve, a refused change.
    public let notes: [String]
    /// Whether the status item shows the LAN indicator.
    public let showsIndicator: Bool

    public var enabled: Bool { visible && disabledReason == nil }

    /// The verb a click runs: the opposite of the value shown, and nothing
    /// while the value is unknown.
    public var clickVerb: LifecycleVerb? {
        switch value {
        case .on: return .lanOff
        case .off: return .lanOn
        case .unknown: return nil
        }
    }

    /// Decides the checkbox from the last successful full status read.
    ///
    /// - report: the last full report that decoded, or nil when none has.
    /// - readAt: when that report was read.
    /// - lastReadFailed: whether the most recent read failed.
    /// - trustRefusal: why the installed CLI failed its trust check, if it did.
    /// - blocked: an app-level reason no root step can run now (a developer
    ///   build, a non-admin user, another step running).
    public static func evaluate(report: StatusReport?, readAt: Date?, now: Date, lastReadFailed: Bool,
                                trustRefusal: String?, blocked: String?) -> LANToggle {
        if let report, !report.hasLANSwitch {
            return LANToggle(visible: false, value: .unknown, disabledReason: nil, notes: [], showsIndicator: false)
        }
        let network = report?.network
        let indicator = network.map { $0.setting == .on || $0.applied?.setting == .on } ?? false
        let stale = readAt.map { now.timeIntervalSince($0) > maxAge || now < $0 } ?? true
        var reason: String?
        if let trustRefusal {
            reason = "The app will not run the installed k3sm: " + StatusDisplay.errorText(trustRefusal) + "."
        } else if report == nil || lastReadFailed {
            reason = "k3sm could not read the status of this Mac, so the setting is unknown."
        } else if stale {
            reason = "The status shown is out of date. It is being read again."
        } else if network?.setting == .unknown || network?.recordState == .unknown {
            reason = "The installed k3sm reported a setting this app does not know, so it will not change it."
        } else if let blocked {
            reason = blocked
        }
        let usable = trustRefusal == nil && report != nil && !lastReadFailed && !stale
        let known = network.map { $0.recordState != .unknown } ?? false
        let value = usable && known ? (network?.setting ?? .unknown) : .unknown
        return LANToggle(visible: true, value: value, disabledReason: reason,
                         notes: usable ? notes(network) : [], showsIndicator: indicator)
    }

    /// The notes for a usable reading.
    static func notes(_ network: LANAccess?) -> [String] {
        guard let network else { return [] }
        var out: [String] = []
        if network.recordState == .unreadable {
            out.append("The saved setting could not be read, so k3sm treats it as off. Run `sudo k3sm network lan on` or `off` in Terminal to set it again.")
        } else if !network.recorded {
            out.append("On because no setting is recorded (k3sm installed before this setting existed).")
        }
        if network.appliedReadable == false {
            out.append("What k3sm is serving can be read by an administrator only. Run `sudo k3sm network lan status` in Terminal to see it.")
        }
        if let applied = network.applied {
            let error = StatusDisplay.errorText(applied.error)
            if !error.isEmpty {
                out.append("The last change was refused, and k3sm still serves \(applied.setting.word): \(error)")
            } else if applied.setting != network.setting {
                out.append("The setting is \(network.setting.word), but k3sm still serves \(applied.setting.word).")
            }
        }
        return out
    }
}

/// LANSource picks the report that drives the checkbox and the status item
/// dot from the two reads the app makes: the full report (with the daemon's
/// applied state, read when the menu opens, every minute while the item shows,
/// and around a change) and the daemons probe (without it, read at the poll
/// rate). The newer read wins. When the probe is newer, the last full read's
/// applied state rides along only while the two reads agree on the setting
/// and the record, so a stale applied report is never shown against a changed
/// setting.
public enum LANSource {
    public typealias Read = (report: StatusReport, at: Date)

    public static func choose(full: Read?, probe: Read?) -> Read? {
        guard let probe else { return full }
        guard let full else { return probe }
        if full.at >= probe.at { return full }
        let f = full.report.network
        let p = probe.report.network
        guard f.fieldPresent, p.fieldPresent, f.setting == p.setting, f.recorded == p.recorded,
              f.recordState == p.recordState else { return probe }
        let network = LANAccess(
            setting: p.setting, recorded: p.recorded, covers: p.covers, alwaysOn: p.alwaysOn,
            applied: f.applied, recordState: p.recordState, appliedReadable: f.appliedReadable)
        let r = probe.report
        return (StatusReport(
            schemaVersion: r.schemaVersion, verdict: r.verdict, role: r.role, summary: r.summary, rows: r.rows,
            stoppedBy: r.stoppedBy, workers: r.workers, joinTarget: r.joinTarget, network: network), probe.at)
    }
}

/// LANConfirmationText is the question the app asks before turning LAN
/// access on: what becomes reachable, and what the switch does not cover.
public enum LANConfirmationText {
    public static let title = "Allow connections from other devices?"
    /// The most items either list names; the rest are counted.
    public static let maxItems = 8

    /// The families the switch moves, in words.
    static func families(_ covers: [String]) -> String {
        let words = (covers.isEmpty ? ["nodeports", "loadbalancers", "ingress"] : covers).map { word -> String in
            switch word {
            case "nodeports": return "NodePort"
            case "loadbalancers": return "LoadBalancer"
            case "ingress": return "ingress"
            default: return StatusDisplay.errorText(word)
            }
        }
        return list(words)
    }

    /// The listeners the switch does not cover, in words.
    static func listener(_ word: String) -> String {
        switch word {
        case "apiserver": return "the API server (this Mac and the cluster mesh only)"
        case "join": return "the worker join port (every request needs a join token)"
        case "mesh": return "the wireguard mesh port (it answers only cluster peers)"
        default: return StatusDisplay.errorText(word)
        }
    }

    /// Joins at most `maxItems` words; a longer list ends "and N more".
    static func list(_ all: [String]) -> String {
        if all.count > maxItems {
            return all.prefix(maxItems).joined(separator: ", ") + " and \(all.count - maxItems) more"
        }
        let words = all
        switch words.count {
        case 0: return ""
        case 1: return words[0]
        default: return words.dropLast().joined(separator: ", ") + " and " + words[words.count - 1]
        }
    }

    /// What turning the switch on makes reachable.
    public static func reachable(_ network: LANAccess) -> String {
        "The \(families(network.covers)) listeners of this Mac's workloads will answer on every network this Mac is on, and any device on those networks can reach them."
    }

    /// What the switch does not cover, from the report's `alwaysOn`.
    public static func notCovered(_ network: LANAccess) -> String {
        guard let always = network.alwaysOn else {
            return "k3sm did not say which listeners this setting leaves alone."
        }
        guard !always.isEmpty else {
            return "No other listener on this Mac faces the network."
        }
        return "This setting does not change " + list(always.map(listener)) + "."
    }
}

/// LANPrecondition decides, from a status report read just now, whether a
/// LAN verb may go ahead: the live setting must be an explicit on or off,
/// the one the user acted on, and not already the target.
public enum LANPrecondition {
    public static func check(_ verb: LifecycleVerb, expected: LANSetting, live: StatusReport?) -> LifecyclePrecondition.Verdict {
        guard verb.isLAN else {
            return .refused("\(verb.title) is not a LAN access verb. Nothing was changed.")
        }
        guard let live else {
            return .refused("k3sm could not read the status of this Mac just now, so it did not change the setting.")
        }
        guard live.hasLANSwitch else {
            return .refused("This Mac has no k3sm node with this setting. Nothing was changed.")
        }
        let now = live.network.setting
        guard now != .unknown, live.network.recordState != .unknown else {
            return .refused("The installed k3sm reported a setting this app does not know, so it did not change it.")
        }
        guard now == expected else {
            return .refused("The setting is \(now.word) now, not \(expected.word) as it was when you chose it. Nothing was changed.")
        }
        let target: LANSetting = verb == .lanOn ? .on : .off
        guard now != target else {
            return .refused("The setting is already \(now.word). Nothing was changed.")
        }
        return .proceed
    }
}

/// LANOutcome is the sentence after a LAN verb ran: the lifecycle outcome,
/// the CLI's own error text (cleaned and truncated), and the value the status
/// confirms afterwards.
public enum LANOutcome {
    public static func text(_ run: PrivilegedRun, verb: LifecycleVerb, confirmed: LANSetting) -> String {
        let target: LANSetting = verb == .lanOn ? .on : .off
        var text = LifecycleOutcome.text(run.outcome, verb: verb)
        if run.outcome == .succeeded, confirmed != target {
            text = "k3sm reported the change as done, but the status now reads \(confirmed.word)."
        }
        if case .failed = run.outcome {
            let said = StatusDisplay.errorText(run.errorOutput ?? "")
            if !said.isEmpty {
                text += " k3sm said: " + said
            }
            if confirmed != .unknown {
                text += " The setting is \(confirmed.word)."
            }
        }
        return text
    }
}

/// LANDriver runs one LAN verb from a click to its outcome: read the status
/// live and refuse a changed or unknown setting; for on, ask first (what
/// becomes reachable and what is not covered, Cancel the default) and read
/// again; hand the verb's root script to the administrator prompt; then read
/// the status again and report the value it confirms. Off needs no question.
public struct LANDriver: Sendable {
    public enum Result: Equatable, Sendable {
        /// Refused before any prompt; the sentence says why.
        case refused(String)
        /// The user answered no to the confirmation.
        case declined
        /// The administrator prompt ran; the sentence is the outcome and
        /// `confirmed` the setting the status reads afterwards.
        case ran(PrivilegedOutcome, String, confirmed: LANSetting)
    }

    let teamID: TeamID
    let readStatus: @Sendable () async -> StatusReport?
    let confirm: @MainActor @Sendable (LifecycleConfirmation) async -> Bool
    let runner: any PrivilegedRunner

    public init(
        teamID: TeamID,
        readStatus: @escaping @Sendable () async -> StatusReport?,
        confirm: @escaping @MainActor @Sendable (LifecycleConfirmation) async -> Bool,
        runner: any PrivilegedRunner
    ) {
        self.teamID = teamID
        self.readStatus = readStatus
        self.confirm = confirm
        self.runner = runner
    }

    /// The refusal when the listeners changed while the question was open.
    public static let changedWhileAsking =
        "What this setting covers changed while the question was open, so the answer no longer matches it. Nothing was changed. Try again to see the new list."

    public func perform(_ verb: LifecycleVerb, expected: LANSetting) async -> Result {
        let first = await readStatus()
        if case .refused(let why) = LANPrecondition.check(verb, expected: expected, live: first) {
            return .refused(why)
        }
        if verb == .lanOn {
            guard let first else { return .refused("k3sm could not read the status of this Mac just now.") }
            guard await confirm(LifecycleConfirmation(verb: verb, report: first)) else {
                return .declined
            }
            let second = await readStatus()
            if case .refused(let why) = LANPrecondition.check(verb, expected: expected, live: second) {
                return .refused(why)
            }
            // The question named what becomes reachable and what is not
            // covered; consent to a different set is not consent.
            if let second, second.network.covers != first.network.covers || second.network.alwaysOn != first.network.alwaysOn {
                return .refused(Self.changedWhileAsking)
            }
        }
        guard verb.isLAN, let fixed = LifecycleScriptBuilder.FixedVerb(verb) else {
            return .refused("\(verb.title) is not a LAN access verb. Nothing was changed.")
        }
        let run = await runner.runAsRootReportingError(LifecycleScriptBuilder.render(fixed, teamID: teamID), input: nil)
        let after = await readStatus()
        let confirmed = after.map { $0.hasLANSwitch ? $0.network.setting : .unknown } ?? .unknown
        return .ran(run.outcome, LANOutcome.text(run, verb: verb, confirmed: confirmed), confirmed: confirmed)
    }
}
