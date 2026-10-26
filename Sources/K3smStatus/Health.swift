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

/// HealthFacts is everything the startup health check reads about k3sm on
/// this Mac: two file facts, the installed CLI's trust check, the last full
/// status report and the two versions. It holds no verdict of its own.
public struct HealthFacts: Equatable, Sendable {
    /// The installed CLI's trust check, as the classifier sees it.
    public enum CLITrust: Equatable, Sendable {
        /// The CLI passed the check the app makes before every run.
        case trusted
        /// The CLI failed it; the reason is the app's own sentence.
        case refused(String)
        /// Nothing was checked (there is no install to check).
        case unchecked
    }

    /// Whether `/Library/k3sm` exists.
    public let installRootExists: Bool
    /// Whether `/Library/k3sm/k3sm` exists (an `lstat`, so a symlink counts).
    public let cliPresent: Bool
    public let cliTrust: CLITrust
    /// The last full report that decoded on this refresh; nil when the read
    /// failed or did not run.
    public let report: StatusReport?
    /// The version bundled in the app, nil for an unstamped build.
    public let payloadVersion: SemanticVersion?
    /// The installed CLI's version, nil when unknown.
    public let installedVersion: SemanticVersion?

    public init(installRootExists: Bool, cliPresent: Bool, cliTrust: CLITrust, report: StatusReport?,
                payloadVersion: SemanticVersion?, installedVersion: SemanticVersion?) {
        self.installRootExists = installRootExists
        self.cliPresent = cliPresent
        self.cliTrust = cliTrust
        self.report = report
        self.payloadVersion = payloadVersion
        self.installedVersion = installedVersion
    }
}

/// HealthState is what the startup health check found about k3sm on this
/// Mac. It decides the window's screen (`showsFirstRun`) and carries what
/// the console's state line and banner show. `healthy` means no install,
/// trust, daemon or version problem was found; the cluster's own verdict
/// (degraded, unknown) stays the status headline's to show.
public enum HealthState: Equatable, Sendable {
    /// No `/Library/k3sm`, or the CLI itself reports no install.
    case notInstalled
    /// k3sm is installed and stopped: a recorded stop (its `stoppedBy`), or
    /// the node daemon down with netd not running either.
    case installedStopped(StoppedBy?)
    /// One of netd and the node daemon runs and the other is down; the
    /// launchd labels of those down.
    case partlyRunning(down: [String])
    /// `/Library/k3sm` exists but its CLI does not.
    case cliMissing
    /// The installed CLI failed the trust check, so the app runs nothing.
    case cliUntrusted(String)
    /// The CLI ran but no report could be read, and no version mismatch
    /// explains it.
    case statusUnreadable
    /// The installed CLI and the app's payload are different releases;
    /// `relation` is the payload against the installed one (`newer`: the
    /// install is behind, `older`: it is ahead).
    case versionMismatch(payload: SemanticVersion, installed: SemanticVersion, relation: PayloadRelation)
    case healthy

    /// Whether the window shows the first run (start or join) rather than
    /// the console: only when nothing is installed.
    public var showsFirstRun: Bool { self == .notInstalled }

    /// Whether this is a half-installed k3sm that Repair (the install run
    /// again over it from the app's payload) is offered for: the command
    /// missing or untrusted, or one daemon down beside the other. `RepairPolicy`
    /// reads it; the guided panel (`GuidedSteps`) offers Repair for the same
    /// states, and a test keeps the two in step.
    public var repairable: Bool {
        switch self {
        case .cliMissing, .cliUntrusted, .partlyRunning: return true
        default: return false
        }
    }

    /// The one line the console shows for this state, nil when healthy.
    /// Every CLI-supplied part passes `StatusDisplay.clip`.
    public var line: String? {
        switch self {
        case .notInstalled:
            return "k3sm is not installed on this Mac."
        case .installedStopped(let stoppedBy):
            guard let stoppedBy else { return "k3sm is installed and stopped." }
            return StoppedNotice.title(for: stoppedBy) + "."
        case .partlyRunning(let down):
            return "k3sm is partly running: \(down.joined(separator: " and ")) \(down.count == 1 ? "is" : "are") not running."
        case .cliMissing:
            return "k3sm is installed, but \(K3smCLI.path) is missing."
        case .cliUntrusted(let why):
            return "The app will not run the installed k3sm: \(StatusDisplay.clip(why))."
        case .statusUnreadable:
            return "k3sm is installed, but its status could not be read."
        case .versionMismatch(let payload, let installed, let relation):
            let side = relation == .older ? "newer" : "older"
            return "The installed k3sm (\(installed)) is \(side) than this app's (\(payload))."
        case .healthy:
            return nil
        }
    }

    /// The line the console's status shows under the report's headline: nil
    /// when healthy, and for a stop, which the headline and the stopped-by
    /// line already say. Without a report it is the whole headline (`line`).
    public var statusLine: String? {
        if case .installedStopped = self { return nil }
        return line
    }
}

/// HealthClassifier decides `HealthState` from `HealthFacts`. It is pure:
/// the app gathers the facts, this decides. The order is the contract:
///
///  1. No `/Library/k3sm`: not installed.
///  2. No CLI under it: missing. 3. A CLI that fails its trust check: untrusted.
///  4. No decoded report: a version mismatch when one is known (a newer CLI
///     may print a report this build cannot read), else unreadable.
///  5. The CLI's own `not-installed` verdict: not installed.
///  6. A recorded stop, or the node daemon down with netd not up: stopped.
///     One of the two up and the other down: partly running.
///  7. A version mismatch. 8. Otherwise healthy.
///
/// A state word this build does not know claims neither up nor down, so it
/// never makes a state on its own.
public enum HealthClassifier {
    /// netd's launchd label (k3sm's `pkg/install`).
    public static let netdLabel = "io.k3sm.netd"
    /// netd's row in the status report.
    static let netdRow = "netd"

    /// Daemon row words that mean the launchd job is not serving.
    static let downWords: Set<String> = ["stopped", "not-loaded", "disabled", "failed", "crash-loop"]
    /// Daemon row words that mean the job is up: `running`, and the joining
    /// worker's credential words, which describe the credential, not the pid.
    static let upWords: Set<String> = ["running", "waiting", "expired", "corrupt", "address-mismatch"]

    enum Daemon { case up, down, unknown }

    static func daemon(_ row: StatusRow?) -> Daemon {
        guard let row else { return .unknown }
        if upWords.contains(row.state) { return .up }
        if downWords.contains(row.state) { return .down }
        return .unknown
    }

    public static func classify(_ facts: HealthFacts) -> HealthState {
        guard facts.installRootExists else { return .notInstalled }
        guard facts.cliPresent else { return .cliMissing }
        if case .refused(let why) = facts.cliTrust { return .cliUntrusted(why) }
        let mismatch = versionMismatch(facts)
        guard let report = facts.report else { return mismatch ?? .statusUnreadable }
        if report.verdict == .notInstalled { return .notInstalled }
        if let stoppedBy = report.stoppedBy { return .installedStopped(stoppedBy) }
        let role = NodeRole.detect(in: report)
        let node = daemon(role.flatMap { report.row(named: $0.rawValue) })
        let netd = daemon(report.row(named: netdRow))
        switch (node, netd) {
        case (.down, .up):
            return .partlyRunning(down: [role?.daemonLabel].compactMap { $0 })
        case (.down, _):
            return .installedStopped(nil)
        case (.up, .down):
            return .partlyRunning(down: [netdLabel])
        default:
            break
        }
        return mismatch ?? .healthy
    }

    /// The mismatch state when both versions are known and differ.
    static func versionMismatch(_ facts: HealthFacts) -> HealthState? {
        guard let payload = facts.payloadVersion, let installed = facts.installedVersion else { return nil }
        let relation = PayloadRelation(payload: payload, installed: installed)
        return relation == .same ? nil : .versionMismatch(payload: payload, installed: installed, relation: relation)
    }
}
