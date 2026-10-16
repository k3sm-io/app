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

import K3smStatus

/// UpdateConfirmationText is the fixed text of the questions asked before
/// the managed update's root steps.
public enum UpdateConfirmationText {
    public static let apply = "k3sm updates the cluster one node at a time, the server last. Pods on each node restart as it updates. The window shows the progress, and the update can be cancelled from there."
    public static let cancel = "k3sm stops the update before the next node. Nodes already updated keep the release they run now."
}

/// UpdatePrecondition decides, from a status report read just now, whether
/// the apply may go ahead: the live `update` row must still offer the release
/// the user chose.
public enum UpdatePrecondition {
    public static func check(tag: String, live: StatusReport?) -> LifecyclePrecondition.Verdict {
        guard let live else {
            return .refused("k3sm could not read the status of this Mac just now, so it did not start the update.")
        }
        if UpdateOffer.rowRolling(in: live) {
            return .refused("An update is already rolling. The window shows its progress.")
        }
        guard let row = live.row(named: "update"), row.rowState == .behind,
              let now = UpdateOffer.latestTag(in: row), SemanticVersion(now) == SemanticVersion(tag)
        else {
            return .refused("k3sm no longer reports \(StatusDisplay.clip(tag)) as an update for this cluster. Nothing was changed.")
        }
        return .proceed
    }
}

/// UpdateDriver runs one managed update verb from a click to its outcome.
/// The apply re-reads the status and refuses unless the `update` row still
/// offers the release the user chose, asks (naming it), re-reads and checks
/// again, then hands `k3sm update apply --yes` to the administrator prompt
/// through the checked lifecycle script. The cancel asks, then runs
/// `k3sm update cancel` the same way. Every run is a fresh prompt.
public struct UpdateDriver: Sendable {
    public enum Result: Equatable, Sendable {
        /// Refused before any prompt; the sentence says why.
        case refused(String)
        /// The user answered no.
        case declined
        /// The root step ran: what it means for the progress tracker (the
        /// apply only), the outcome, and the sentence to show.
        case ran(UpdateApplyResult, PrivilegedOutcome, String)
    }

    /// What the CLI prints when an unfinished Update already exists: "k3sm
    /// update apply: the Update current to v0.1.8 is Rolling; follow it with
    /// `k3sm update status --watch`, or stop it with `k3sm update cancel`".
    /// The shorter form is the one first agreed for the contract.
    public static let alreadyRollingMarkers = ["follow it with `k3sm update status --watch`", "an update is already rolling"]

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

    /// Starts the update to `tag`, the release the user was offered.
    public func apply(tag: String) async -> Result {
        let first = await readStatus()
        if case .refused(let why) = UpdatePrecondition.check(tag: tag, live: first) { return .refused(why) }
        guard let first else { return .refused("k3sm could not read the status of this Mac just now.") }
        guard await confirm(LifecycleConfirmation(verb: .updateApply, report: first)) else { return .declined }
        let second = await readStatus()
        if case .refused(let why) = UpdatePrecondition.check(tag: tag, live: second) { return .refused(why) }
        let run = await runner.runAsRootReportingError(LifecycleScriptBuilder.render(.updateApply, teamID: teamID), input: nil)
        return Self.classify(run, verb: .updateApply)
    }

    /// Cancels the rolling update.
    public func cancel() async -> Result {
        let empty = StatusReport(schemaVersion: StatusReport.supportedSchemaVersion, verdict: .unknown, role: "", summary: "", rows: [])
        guard await confirm(LifecycleConfirmation(verb: .updateCancel, report: empty)) else { return .declined }
        let run = await runner.runAsRootReportingError(LifecycleScriptBuilder.render(.updateCancel, teamID: teamID), input: nil)
        return Self.classify(run, verb: .updateCancel)
    }

    /// Reads one finished root step. An apply that exits 0 started the roll;
    /// one that exits 1 saying a roll already exists is followed as one; any
    /// other outcome started nothing, and its sentence carries the CLI's own
    /// error text, cleaned.
    public static func classify(_ run: PrivilegedRun, verb: LifecycleVerb) -> Result {
        let cliText = run.errorOutput.map(StatusDisplay.errorText) ?? ""
        switch run.outcome {
        case .succeeded:
            return .ran(verb == .updateApply ? .started : .notStarted, run.outcome, LifecycleOutcome.text(run.outcome, verb: verb))
        case .failed(LifecycleExit.failed) where verb == .updateApply && alreadyRollingMarkers.contains(where: cliText.contains):
            return .ran(.alreadyRolling, run.outcome, "An update is already rolling. The window shows its progress.")
        case .failed(let status) where status == LifecycleExit.failed && !cliText.isEmpty:
            return .ran(.notStarted, run.outcome, "k3sm \(verb.command) failed: " + cliText)
        default:
            return .ran(.notStarted, run.outcome, LifecycleOutcome.text(run.outcome, verb: verb))
        }
    }
}
