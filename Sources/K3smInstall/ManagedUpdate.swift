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
    /// What `k3sm update abort` leaves, as `cmd/k3sm/update.go`
    /// (`runUpdateAbort`) does it: the Update is marked Cancelled, not
    /// deleted; no node's release changes; every `k3sm.io/update-*`
    /// annotation is removed, and a cordon is lifted only where the
    /// controller's `k3sm.io/update-cordoned` says the controller set it.
    public static let abort = "k3sm ends the update now and marks it Cancelled; it stays on record until the next update replaces it. Nothing is rolled back: every node keeps the release it runs, and a node already installing may still finish. On every node k3sm clears the update's annotations and lifts the cordon the update set. A node you cordoned yourself stays cordoned."
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

/// UpdateApplyAnswer is the answer to the apply's question: no, or yes with
/// the downgrade checkbox's state (off unless the question offered it).
public enum UpdateApplyAnswer: Equatable, Sendable {
    case declined
    case confirmed(allowDowngrade: Bool)
}

/// UpdateDriver runs one managed update verb from a click to its outcome.
/// The apply re-reads the status and refuses unless the `update` row still
/// offers the release the user chose, asks (naming the release and every
/// option that is not the default, and offering a downgrade only when the
/// row names a node newer than the latest), re-reads and checks again, then
/// hands `k3sm update apply --yes`, with exactly the options the question
/// showed and the downgrade answer, to the administrator prompt through the
/// checked lifecycle script. The options are frozen when `apply` is called;
/// nothing is read from the preferences after that. The cancel asks, then runs
/// `k3sm update cancel` the same way, and the abort asks, then runs `k3sm
/// update abort` the same way. Every run is a fresh prompt.
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
    let confirmApply: @MainActor @Sendable (LifecycleConfirmation) async -> UpdateApplyAnswer
    let runner: any PrivilegedRunner

    public init(
        teamID: TeamID,
        readStatus: @escaping @Sendable () async -> StatusReport?,
        confirm: @escaping @MainActor @Sendable (LifecycleConfirmation) async -> Bool,
        confirmApply: @escaping @MainActor @Sendable (LifecycleConfirmation) async -> UpdateApplyAnswer,
        runner: any PrivilegedRunner
    ) {
        self.teamID = teamID
        self.readStatus = readStatus
        self.confirm = confirm
        self.confirmApply = confirmApply
        self.runner = runner
    }

    /// Starts the update to `tag`, the release the user was offered, with
    /// `options` as read at the click (a downgrade in them is ignored: only
    /// the question's checkbox allows one).
    public func apply(tag: String, options: UpdateOptions = .defaults) async -> Result {
        let frozen = UpdateOptions(drain: options.drain, allowDowngrade: false, signature: options.signature)
        let first = await readStatus()
        if case .refused(let why) = UpdatePrecondition.check(tag: tag, live: first) { return .refused(why) }
        guard let first else { return .refused("k3sm could not read the status of this Mac just now.") }
        let question = LifecycleConfirmation(update: frozen, report: first)
        guard case .confirmed(let downgrade) = await confirmApply(question) else { return .declined }
        var confirmed = frozen
        confirmed.allowDowngrade = downgrade && question.offersDowngrade
        let second = await readStatus()
        if case .refused(let why) = UpdatePrecondition.check(tag: tag, live: second) { return .refused(why) }
        let script = LifecycleScriptBuilder.render(.updateApply, teamID: teamID, update: confirmed)
        let run = await runner.runAsRootReportingError(script, input: nil)
        return Self.classify(run, verb: .updateApply)
    }

    /// Cancels the rolling update.
    public func cancel() async -> Result {
        let empty = StatusReport(schemaVersion: StatusReport.supportedSchemaVersion, verdict: .unknown, role: "", summary: "", rows: [])
        guard await confirm(LifecycleConfirmation(verb: .updateCancel, report: empty)) else { return .declined }
        let run = await runner.runAsRootReportingError(LifecycleScriptBuilder.render(.updateCancel, teamID: teamID), input: nil)
        return Self.classify(run, verb: .updateCancel)
    }

    /// Aborts the update: the recovery after a failed step, or the way to end
    /// a roll at once. The question says what abort leaves
    /// (`UpdateConfirmationText.abort`); the CLI reads the Update and the
    /// nodes itself, so the run carries nothing but the verb.
    public func abort() async -> Result {
        let empty = StatusReport(schemaVersion: StatusReport.supportedSchemaVersion, verdict: .unknown, role: "", summary: "", rows: [])
        guard await confirm(LifecycleConfirmation(verb: .updateAbort, report: empty)) else { return .declined }
        let run = await runner.runAsRootReportingError(LifecycleScriptBuilder.render(.updateAbort, teamID: teamID), input: nil)
        return Self.classify(run, verb: .updateAbort)
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
