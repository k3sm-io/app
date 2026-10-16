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
    /// The catch-up's question body: the nodes that move, the release (the
    /// one installed on the server), this server when its own Node moves
    /// (last), what the roll leaves as it is (every node already on the
    /// release, the server among them only when its Node is), and that the
    /// server decides the final set when the update starts: the controller
    /// lists the nodes again then, so a node that joins or changes meanwhile
    /// moves too.
    public static func catchUp(tag: String, nodes: [String], server: String) -> String {
        let release = StatusDisplay.clip(tag)
        let others = nodes.filter { $0 != server }
        let serverMoves = nodes.contains(server)
        let name = StatusDisplay.clip(server)
        var text: String
        switch (others.isEmpty, serverMoves) {
        case (false, true):
            text = "k3sm moves \(UpdatePath.names(others)) to \(release), the release installed on the server, one node at a time, "
                + "and then this server, \(name), whose node still runs an older release: the server restarts last. "
                + "Nodes already on it are left as they are."
        case (true, true):
            text = "k3sm moves this server, \(name), whose node still runs an older release, to \(release), the release installed on it; "
                + "the server restarts. Nodes already on it are left as they are."
        default:
            text = "k3sm moves \(UpdatePath.names(others)) to \(release), the release the server runs, one node at a time. "
                + "Nodes already on it, the server too, are left as they are."
        }
        return text + " The server decides the final set when the update starts: a node that joins or changes before then moves to \(release) too. "
            + "Pods on each node that moves restart as it updates. "
            + "The window shows the progress, and the update can be cancelled from there."
    }

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
/// the user chose, the same text, not only an equal version (`0.1.8` or
/// `v0.1.8+x` is not the `v0.1.8` the row names).
public enum UpdatePrecondition {
    /// The release a passed check pins the apply to: the live row's own tag.
    public enum Release: Equatable, Sendable {
        case proceed(ReleaseTag)
        case refused(String)
    }

    public static func check(tag: String, live: StatusReport?) -> LifecyclePrecondition.Verdict {
        switch release(tag: tag, live: live) {
        case .proceed: return .proceed
        case .refused(let why): return .refused(why)
        }
    }

    /// The check, returning the live row's tag as a `ReleaseTag` when it
    /// passes: the text `--version` carries is the text re-checked.
    public static func release(tag: String, live: StatusReport?) -> Release {
        guard let live else {
            return .refused("k3sm could not read the status of this Mac just now, so it did not start the update.")
        }
        if UpdateOffer.rowRolling(in: live) {
            return .refused("An update is already rolling. The window shows its progress.")
        }
        guard let row = live.row(named: "update"), row.rowState == .behind,
              let now = UpdateOffer.latestTag(in: row), now == tag, let pinned = ReleaseTag(now)
        else {
            return .refused("k3sm no longer reports \(StatusDisplay.clip(tag)) as an update for this cluster. Nothing was changed.")
        }
        return .proceed(pinned)
    }

    /// The catch-up's check: the roll pinned to the release installed on the
    /// server. From the live report it must be a server with no roll under
    /// way, whose k3sm reports a tagged release (`StatusReport.release`) with
    /// exactly the text `tag` (`0.1.7` or `v0.1.7+x` is not the `v0.1.7` the
    /// server reports), whose own Node and kubelet version are named (the
    /// `node` row) and whose other nodes are listed, with at least one node
    /// not on that release by its Node's kubelet version (the server's own
    /// included, which then moves last) and none on a newer one
    /// (`ClusterCatchUp`). The pin is the live report's own text, so
    /// `--version` carries the text re-checked.
    public static func serverRelease(tag: String, live: StatusReport?) -> CatchUpRelease {
        guard let live else {
            return .refused("k3sm could not read the status of this Mac just now, so it did not start the update.")
        }
        if UpdateOffer.rowRolling(in: live) {
            return .refused("An update is already rolling. The window shows its progress.")
        }
        guard NodeRole.detect(in: live) == .server else {
            return .refused("This Mac no longer reports itself as the server, so it did not start the update. Nothing was changed.")
        }
        guard let catchUp = ClusterCatchUp.decide(report: live) else {
            return .refused("k3sm could not list the cluster's other nodes just now, so it did not start the update. Nothing was changed.")
        }
        guard let now = catchUp.tag, now == tag, let pinned = ReleaseTag(now) else {
            return .refused("The server no longer runs k3sm \(StatusDisplay.clip(tag)) as a tagged release. Nothing was changed.")
        }
        guard catchUp.serverKnown, let server = catchUp.server else {
            return .refused(UpdateBlock.serverNodeUnknownText + " Nothing was changed.")
        }
        if !catchUp.ahead.isEmpty {
            return .refused(UpdateBlock.nodesAhead(tag: now, nodes: catchUp.ahead).sentence + " Nothing was changed.")
        }
        guard !catchUp.moves.isEmpty else {
            return .refused("Every node runs k3sm \(StatusDisplay.clip(tag)) now, so there is nothing to update. Nothing was changed.")
        }
        return .proceed(pinned, nodes: catchUp.moves, server: server)
    }

    /// The catch-up's verdict: the pinned release, the nodes that move (in
    /// the controller's order, this server last when it moves) and this
    /// server's Node name.
    public enum CatchUpRelease: Equatable, Sendable {
        case proceed(ReleaseTag, nodes: [String], server: String)
        case refused(String)
    }
}

/// UpdateTarget is which release an apply is pinned to, and so which check
/// guards it: the latest release the server's update check names (the
/// `update` row, `UpdatePrecondition.release`), or the release the server
/// itself runs, for the nodes behind it (`UpdatePrecondition.serverRelease`).
public enum UpdateTarget: Equatable, Sendable {
    case latest
    case serverRelease
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
/// showed, the downgrade answer and `--version` with the live row's tag, the
/// text it re-checked, to the administrator prompt through the checked lifecycle
/// script. A tag that is not a release tag (`ReleaseTag`) is refused before
/// anything is read or asked. The options are frozen when `apply` is called;
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

    /// The refusal for a tag `ReleaseTag` does not accept. It does not echo
    /// the tag.
    public static let invalidTagText = "k3sm did not start the update: the release it was offered does not have a valid release tag. Nothing was changed."

    /// Starts the update to `tag`, the release the user was offered, with
    /// `options` as read at the click (a downgrade in them is ignored: only
    /// the question's checkbox allows one). The run is pinned to `tag` with
    /// `--version`, so a release published after the last check is not the
    /// one rolled.
    public func apply(tag: String, options: UpdateOptions = .defaults) async -> Result {
        await apply(tag: tag, target: .latest, options: options)
    }

    /// Starts the update to `tag` pinned as `target` says. For `.latest`,
    /// as `apply(tag:options:)`. For `.serverRelease` (the catch-up), the
    /// live report must still say the server runs exactly `tag` with a node
    /// not on it (`UpdatePrecondition.serverRelease`), before the question
    /// and again after it; the question names the release and the nodes that
    /// move, offers no downgrade, and the run is refused when the nodes that
    /// would move changed while it was open. The script is the same apply
    /// script, `k3sm update apply --yes` with the options and `--version tag`.
    public func apply(tag: String, target: UpdateTarget, options: UpdateOptions = .defaults) async -> Result {
        guard ReleaseTag(tag) != nil else { return .refused(Self.invalidTagText) }
        if target == .serverRelease { return await catchUp(tag: tag, options: options) }
        let frozen = UpdateOptions(drain: options.drain, allowDowngrade: false, signature: options.signature)
        let first = await readStatus()
        if case .refused(let why) = UpdatePrecondition.release(tag: tag, live: first) { return .refused(why) }
        guard let first else { return .refused("k3sm could not read the status of this Mac just now.") }
        let question = LifecycleConfirmation(update: frozen, report: first)
        guard case .confirmed(let downgrade) = await confirmApply(question) else { return .declined }
        var confirmed = frozen
        confirmed.allowDowngrade = downgrade && question.offersDowngrade
        let second = await readStatus()
        let release: ReleaseTag
        switch UpdatePrecondition.release(tag: tag, live: second) {
        case .proceed(let pinned): release = pinned
        case .refused(let why): return .refused(why)
        }
        let script = LifecycleScriptBuilder.renderUpdateApply(teamID: teamID, options: confirmed, release: release)
        let run = await runner.runAsRootReportingError(script, input: nil)
        return Self.classify(run, verb: .updateApply)
    }

    /// The catch-up's apply: `apply(tag:target:options:)` for `.serverRelease`.
    private func catchUp(tag: String, options: UpdateOptions) async -> Result {
        let frozen = UpdateOptions(drain: options.drain, allowDowngrade: false, signature: options.signature)
        let asked: [String]
        let server: String
        switch UpdatePrecondition.serverRelease(tag: tag, live: await readStatus()) {
        case .proceed(_, let nodes, let name):
            asked = nodes
            server = name
        case .refused(let why): return .refused(why)
        }
        let question = LifecycleConfirmation(catchUp: frozen, tag: tag, nodes: asked, server: server)
        guard case .confirmed = await confirmApply(question) else { return .declined }
        let release: ReleaseTag
        switch UpdatePrecondition.serverRelease(tag: tag, live: await readStatus()) {
        case .proceed(let pinned, let nodes, let name) where nodes == asked && name == server: release = pinned
        case .proceed:
            return .refused("The nodes behind k3sm \(StatusDisplay.clip(tag)) changed while the question was open. Nothing was changed.")
        case .refused(let why): return .refused(why)
        }
        let script = LifecycleScriptBuilder.renderUpdateApply(teamID: teamID, options: frozen, release: release)
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
