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

/// ActionRun is how one CLI run behind a console action ended, as a
/// pre-check or a report reads it.
public enum ActionRun: Equatable, Sendable {
    /// The CLI exited; `output` is its standard output and error together.
    case exited(status: Int32, output: Data)
    /// The CLI could not be started, ran past its deadline or wrote past
    /// its limit: whether the change was made is not known.
    case noAnswer
    /// The CLI is not installed.
    case missing
    /// The installed CLI failed its trust check, so nothing ran.
    case refused(String)
}

/// ActionConfirmation is the question asked before an action runs.
public struct ActionConfirmation: Equatable, Sendable {
    public let title: String
    public let message: String
    /// The title of the button that runs the action.
    public let verbTitle: String
    public let cancelTitle: String
    /// Whether the action removes something, so its button is shown as
    /// destructive.
    public let destructive: Bool

    public init(title: String, message: String, verbTitle: String, cancelTitle: String, destructive: Bool) {
        self.title = title
        self.message = message
        self.verbTitle = verbTitle
        self.cancelTitle = cancelTitle
        self.destructive = destructive
    }
}

/// ActionKind is what an action does to its row: deletes it, or changes it
/// in any other way (a restart deletes a pod only for its owner to recreate
/// it, so it is a change). Only a delete is offered on the Delete key.
public enum ActionKind: String, Equatable, Sendable {
    case delete
    case change
}

/// ActionOutcome is the one line a finished action leaves: it was asked
/// for, it failed, or a pre-check refused it so nothing ran. Its text is the
/// app's own sentence; any CLI text in it has passed `StatusDisplay.errorText`.
public enum ActionOutcome: Equatable, Sendable {
    case succeeded(String)
    case failed(String)
    case refused(String)

    public var text: String {
        switch self {
        case .succeeded(let t), .failed(let t), .refused(let t): return t
        }
    }

    /// Whether the line reads as a failure (failed or refused).
    public var failed: Bool {
        if case .succeeded = self { return false }
        return true
    }
}

/// ConsoleActionRequest is one change the console can make to one row of
/// one tab, fixed when the user asks for it: the argument lists, the
/// optional read run just before the change (whose verdict can refuse it),
/// the question asked first and the line its run leaves. Every tab's
/// actions conform, so one runner confirms, checks, runs and reports them all.
public protocol ConsoleActionRequest: Sendable, Identifiable where ID == String {
    /// The tab whose row the action changes; that tab is read again after it.
    var section: ConsoleSection { get }
    /// The row's selection key in that tab.
    var rowKey: String { get }
    /// The action's fixed name for the app's log; it carries no cluster text.
    var verb: String { get }
    /// Whether the action deletes its row; only a delete is on the Delete key.
    var kind: ActionKind { get }
    /// The CLI arguments the action runs.
    var arguments: [String] { get }
    /// Every CLI run the action makes, in order; most make one, `arguments`.
    /// The runner makes them all, whatever each one's outcome, and reports
    /// them together through `report(runs:)`.
    var runs: [[String]] { get }
    /// The read run just before the action, or nil when it has none.
    var precheckArguments: [String]? { get }
    /// The question asked before it runs.
    var confirmation: ActionConfirmation { get }
    /// What the pre-check's run says: nil when the action may run, otherwise
    /// the line shown instead, and nothing runs.
    func precheck(_ run: ActionRun) -> ActionOutcome?
    /// The line shown after the action's run.
    func report(_ run: ActionRun) -> ActionOutcome
    /// The line shown after all of `runs`, one `ActionRun` each, in order.
    func report(runs: [ActionRun]) -> ActionOutcome
    /// How long the run may take before it is killed.
    var deadline: Duration { get }
    /// Whether the console's confirmation is asked before the run. An
    /// action that only reads (a dry run) or removes nothing (starting the
    /// build engine) runs on the click.
    var asksFirst: Bool { get }
    /// Whether the action's menu item and button end in an ellipsis: true
    /// when more is asked after the click (its confirmation, or the action
    /// it leads to), false for one that runs on the click and leads nowhere.
    var titleEllipsis: Bool { get }
    /// The action asked for next, built from this action's last run (a
    /// prune's dry run leads to the prune it measured, a reset's delete to
    /// its start); it asks its own confirmation when it `asksFirst`. Nil
    /// when the run is the end, and `report(runs:)` gives its line.
    func next(after run: ActionRun) -> (any ConsoleActionRequest)?
}

extension ConsoleActionRequest {
    public var precheckArguments: [String]? { nil }
    public func precheck(_ run: ActionRun) -> ActionOutcome? { nil }
    public var runs: [[String]] { [arguments] }
    public func report(runs: [ActionRun]) -> ActionOutcome { report(runs.first ?? .noAnswer) }
    public var deadline: Duration { PollSchedule.actionDeadline }
    public var asksFirst: Bool { true }
    public var titleEllipsis: Bool { true }
    public func next(after run: ActionRun) -> (any ConsoleActionRequest)? { nil }
}

/// ActionMenuItem is one action a row offers, as the row's context menu,
/// the inspector's buttons and the Delete key all show it.
public struct ActionMenuItem: Identifiable, Sendable {
    public let request: any ConsoleActionRequest

    public init(_ request: any ConsoleActionRequest) {
        self.request = request
    }

    public var id: String { request.id }
    /// The item's title: the verb, with an ellipsis when more is asked
    /// after the click (`titleEllipsis`).
    public var title: String { request.confirmation.verbTitle + (request.titleEllipsis ? "…" : "") }
    public var destructive: Bool { request.confirmation.destructive }
    public var kind: ActionKind { request.kind }
}

/// LocalAction is a row action that runs no CLI and changes nothing on the
/// cluster: text put on the pasteboard, or a web address opened in the
/// default browser. Its value is built and checked in `K3smStatus` (a copy
/// from a decoded, clipped field that passed its own check; an address only
/// http or https), so the app only performs it.
public enum LocalAction: Equatable, Sendable {
    case copy(String)
    case open(URL)
    /// A shell in one container of a pod, opened in Terminal
    /// (`PodShellCommand`), only for a CLI that passes its trust check then.
    case openShell(PodShell)
    /// One container's recent log, summarized on this Mac by Apple's
    /// on-device model (`LogSummaryPrompt`); it reads, and changes nothing.
    case summarizeLogs(LogSummaryTarget)
    /// A recorded build's stored log, in the console's log sheet
    /// (`k3sm build logs`); `follow` keeps reading while the build runs.
    case showBuildLog(BuildLogTarget)
}

/// BuildLogTarget is the build a log sheet reads: its id, only as a
/// `BuildRecordID`, the clipped name the sheet shows, and whether the build
/// was running when the log was asked for.
public struct BuildLogTarget: Equatable, Sendable {
    public let id: BuildRecordID
    public let title: String
    public let follow: Bool

    public init(id: BuildRecordID, title: String, follow: Bool) {
        self.id = id
        self.title = title
        self.follow = follow
    }
}

/// PodShell is the one container a Terminal shell opens in: the pod, its
/// namespace and the container, each only as a `ResourceName`.
public struct PodShell: Equatable, Sendable {
    public let namespace: ResourceName
    public let pod: ResourceName
    public let container: ResourceName

    public init(namespace: ResourceName, pod: ResourceName, container: ResourceName) {
        self.namespace = namespace
        self.pod = pod
        self.container = container
    }

    /// The alert shown when the installed CLI failed its trust check, so no
    /// shell was opened; `why` passes `errorText`.
    public static func refusedAlert(why: String) -> (title: String, text: String) {
        ("k3sm will not run the installed k3sm", "It failed the app's check: \(StatusDisplay.errorText(why)).")
    }
}

/// LocalMenuItem is one local action a row offers. It asks nothing first,
/// so its title has no ellipsis, and the runner never sees it.
public struct LocalMenuItem: Identifiable, Equatable, Sendable {
    /// Fixed per item, unique within a row's menu ("copy-ip", "open").
    public let id: String
    public let title: String
    public let action: LocalAction

    public init(id: String, title: String, action: LocalAction) {
        self.id = id
        self.title = title
        self.action = action
    }
}

/// ActionMenu is the actions one row offers, in order: its local actions
/// (copies, open in browser), then the requests that run the CLI. Each tab
/// builds it with one function, and the context menu, the inspector and the
/// Delete key all read that one value, so they cannot offer different
/// actions. The Delete key reads only the requests.
public struct ActionMenu: Sendable {
    public let items: [ActionMenuItem]
    public let local: [LocalMenuItem]

    public init(_ requests: [any ConsoleActionRequest], local: [LocalMenuItem] = []) {
        items = requests.map(ActionMenuItem.init)
        self.local = local
    }

    public static let empty = ActionMenu([])

    /// The row key of an action over many rows (a tab's bulk action). No
    /// row's key starts with "*", since every key is built from names
    /// `ResourceName` or the decoders accept.
    public static let bulkRowKey = "*bulk"

    public var isEmpty: Bool { items.isEmpty && local.isEmpty }

    /// The action the Delete key asks for: the row's first `.delete`
    /// action, behind the same confirmation; nil when it offers none. A
    /// destructive action that is not a delete (Restart) is never on the key.
    public var deleteKeyItem: ActionMenuItem? {
        items.first { $0.kind == .delete }
    }
}

/// ActionReport is one action's lifecycle, as the console shows it: asked
/// for and awaiting its confirmation, running, then its outcome (succeeded,
/// failed, or refused by its pre-check). The outcome stays through the read
/// the runner asks for after the run, so it is seen beside the list that
/// read returns, and clears on the next successful read of the same tab.
public struct ActionReport: Equatable, Sendable {
    public enum Phase: String, Equatable, Sendable {
        case pending, running, succeeded, failed, refused
    }

    public let section: ConsoleSection
    public let rowKey: String
    /// The request's id, so the report names the action it follows.
    public let actionID: String
    public let phase: Phase
    /// The outcome's line; "" while pending or running.
    public let text: String
    /// Whether the read asked for after the run has returned.
    public let refreshed: Bool

    private init(section: ConsoleSection, rowKey: String, actionID: String, phase: Phase, text: String, refreshed: Bool) {
        self.section = section
        self.rowKey = rowKey
        self.actionID = actionID
        self.phase = phase
        self.text = text
        self.refreshed = refreshed
    }

    /// An action asked for and awaiting its confirmation.
    public static func pending(_ request: some ConsoleActionRequest) -> ActionReport {
        ActionReport(section: request.section, rowKey: request.rowKey, actionID: request.id, phase: .pending, text: "", refreshed: false)
    }

    /// Whether the action has finished, with a line to show.
    public var finished: Bool {
        phase == .succeeded || phase == .failed || phase == .refused
    }

    /// Whether the line reads as a failure.
    public var failed: Bool {
        phase == .failed || phase == .refused
    }

    /// The confirmation was given: pending becomes running; any other phase
    /// is kept.
    public func confirmed() -> ActionReport {
        guard phase == .pending else { return self }
        return with(phase: .running)
    }

    /// The confirmation was declined: a pending action leaves no report;
    /// any other phase is kept.
    public func cancelled() -> ActionReport? {
        phase == .pending ? nil : self
    }

    /// The run ended with `outcome`: running becomes the outcome's phase;
    /// any other phase is kept.
    public func finished(_ outcome: ActionOutcome) -> ActionReport {
        guard phase == .running else { return self }
        switch outcome {
        case .succeeded(let t): return with(phase: .succeeded, text: t)
        case .failed(let t): return with(phase: .failed, text: t)
        case .refused(let t): return with(phase: .refused, text: t)
        }
    }

    /// The read the runner asked for after the run has returned.
    public func refreshDone() -> ActionReport {
        guard finished else { return self }
        return ActionReport(section: section, rowKey: rowKey, actionID: actionID, phase: phase, text: text, refreshed: true)
    }

    /// What one finished read of a tab does to the report: a successful
    /// read of its own tab, after the runner's read has returned, clears it
    /// (nil); a failed read, another tab's read, or any read while the
    /// action is pending, running or awaiting that read keeps it.
    public func afterRead(of tab: ConsoleSection, succeeded: Bool) -> ActionReport? {
        (finished && refreshed && succeeded && tab == section) ? nil : self
    }

    private func with(phase: Phase, text: String = "") -> ActionReport {
        ActionReport(section: section, rowKey: rowKey, actionID: actionID, phase: phase, text: text, refreshed: false)
    }
}

/// DeleteKey decides whether a key press is the console's Delete key for
/// the selected row: Delete (51) or Forward Delete (117) with no Command,
/// Option or Control, and only while no text is being edited, no sheet or
/// dialog is up and the tour is not running, so typing in the search field
/// and the tour's own keys are never taken.
public enum DeleteKey {
    public static func matches(code: UInt16, commandOptionOrControl: Bool, editingText: Bool, sheetShown: Bool, tourShown: Bool) -> Bool {
        guard code == 51 || code == 117 else { return false }
        return !commandOptionOrControl && !editingText && !sheetShown && !tourShown
    }
}
