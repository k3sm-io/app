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

/// BuildAction is what a row of the build history offers, decided by the
/// build's status alone (`BuildActions.actionsForBuild(status:)`).
public enum BuildAction: String, Sendable, CaseIterable {
    /// Opens the build's stored log in a sheet, following it while it runs.
    case showLog = "show-log"
    /// Stops a running build (`k3sm build cancel`).
    case cancel
    /// Removes a finished build's record and its log (`k3sm build rm`).
    case delete
}

/// BuildActionRequest is a cancel or a delete of one recorded build, fixed
/// when the user asks for it: the id is the one the row listed, admitted by
/// `BuildRecordID`, so a later read cannot change what the confirmed
/// action runs on.
public struct BuildActionRequest: Equatable, ConsoleActionRequest {
    public let action: BuildAction
    public let buildID: BuildRecordID
    /// The row's selection key and the name it shows, both clipped.
    public let rowKey: String
    public let title: String

    public var id: String { "\(action.rawValue):\(buildID.value)" }
    public var section: ConsoleSection { .builds }
    public var verb: String { "build-" + action.rawValue }
    public var kind: ActionKind { action == .delete ? .delete : .change }
    public var deadline: Duration {
        action == .cancel ? PollSchedule.buildCancelDeadline : PollSchedule.actionDeadline
    }

    public var arguments: [String] {
        action == .cancel ? K3smCLI.buildCancelArguments(id: buildID) : K3smCLI.buildRemoveArguments(id: buildID)
    }

    public var confirmation: ActionConfirmation {
        if action == .cancel {
            return ActionConfirmation(
                title: "Cancel the build of \(title)?",
                message: "k3sm stops the build. On the build engine BuildKit cancels the job. The record stays in the history, marked cancelled.",
                verbTitle: "Cancel Build", cancelTitle: "Keep Building", destructive: true)
        }
        return ActionConfirmation(
            title: "Delete the record of \(title)?",
            message: "k3sm removes this build and its stored log from your build history. The image it built stays in the store.",
            verbTitle: "Delete Record", cancelTitle: "Cancel", destructive: true)
    }

    public func report(_ run: ActionRun) -> ActionOutcome {
        let verb = action == .cancel ? "Cancel" : "Delete"
        switch run {
        case .exited(status: 0, _):
            return .succeeded(action == .cancel
                ? "Cancelled build \(buildID.value)."
                : "Deleted the record of build \(buildID.value).")
        case .exited(let status, let output):
            let text = StatusDisplay.errorText(String(decoding: output, as: UTF8.self))
            return .failed(text.isEmpty ? "\(verb) failed: k3sm build exited \(status)." : "\(verb) failed. k3sm said: \(text)")
        case .noAnswer:
            return .failed("\(verb) failed: the k3sm CLI did not answer. Refresh to see where the build stands.")
        case .missing:
            return .failed("\(verb) failed: k3sm is not installed on this Mac.")
        case .refused(let why):
            return .failed("\(verb) failed: the installed k3sm failed the app's check (\(StatusDisplay.errorText(why))), so it was not run.")
        }
    }
}

/// BuildEngineAction is what the Builds tab's toolbar offers for the build
/// engine and its cache, each a `k3sm builder` or `k3sm build prune` run as
/// the user.
public enum BuildEngineAction: String, Sendable, CaseIterable {
    case start
    case stop
    /// `builder delete`, which leads to `resetStart`: the engine and its
    /// cache start over.
    case reset
    /// A reset's `builder up`, asked by the reset's run only after its
    /// delete succeeded; never on the toolbar.
    case resetStart = "reset-start"
    /// The prune's dry run, which leads to the prune behind a confirmation.
    case prunePlan = "prune-plan"
    case prune
}

/// PruneEstimate is what a prune run reported: the bytes and the cache
/// records, read from the CLI's line ("would reclaim 1.2 GB (1234 bytes)
/// from 3 cache record(s)"), never shown as the CLI printed it.
public struct PruneEstimate: Equatable, Sendable {
    public let bytes: Int64
    public let records: Int

    public init(bytes: Int64, records: Int) {
        self.bytes = bytes
        self.records = records
    }

    /// The figure from a prune run's output: the line that starts with
    /// `marker` ("would reclaim" for the dry run, "reclaimed" for the
    /// prune), its "(N bytes)" and its "from M cache record(s)"; nil when no
    /// line has that shape.
    public static func parse(_ output: Data, marker: String) -> PruneEstimate? {
        let text = String(decoding: output, as: UTF8.self)
        for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let words = line.split(separator: " ")
            guard line.hasPrefix(marker + " "), let bytesAt = words.firstIndex(where: { $0.hasPrefix("(") }),
                  bytesAt + 1 < words.count, words[bytesAt + 1] == "bytes)",
                  let bytes = Int64(words[bytesAt].dropFirst()), bytes >= 0,
                  let fromAt = words.firstIndex(of: "from"), fromAt > bytesAt, fromAt + 2 < words.count,
                  words[fromAt + 2].hasPrefix("cache"),
                  let records = Int(words[fromAt + 1]), records >= 0 else { continue }
            return PruneEstimate(bytes: bytes, records: records)
        }
        return nil
    }

    /// "1.2 GB from 34 cache records".
    public var text: String {
        let size = bytes > 0 ? WorkloadsDisplay.bytes(bytes) : "0 KB"
        return "\(size) from \(records) cache record\(records == 1 ? "" : "s")"
    }
}

/// BuildEngineRequest is one engine or cache action, asked from the Builds
/// tab's toolbar and run by the trusted CLI as the user, with the
/// environment every console read gets and no `--work-dir`, so the CLI
/// picks the user's admin kubeconfig as `k3sm kubectl` does. Its line lands
/// on the engine card's row.
public struct BuildEngineRequest: Equatable, ConsoleActionRequest {
    public let action: BuildEngineAction
    /// The dry run's figure, on the prune that follows it.
    public let estimate: PruneEstimate?

    public init(_ action: BuildEngineAction, estimate: PruneEstimate? = nil) {
        self.action = action
        self.estimate = estimate
    }

    public var id: String { "engine:" + action.rawValue }
    public var section: ConsoleSection { .builds }
    public var rowKey: String { InspectorDetails.engineRow }
    public var verb: String { "builder-" + action.rawValue }
    /// Reset removes the engine's cache, so it is the one delete; the card
    /// offers no row menu, so it is never on the Delete key.
    public var kind: ActionKind { action == .reset ? .delete : .change }

    public var arguments: [String] {
        switch action {
        case .start, .resetStart: return K3smCLI.builderUpArguments
        case .stop: return K3smCLI.builderDownArguments
        case .reset: return K3smCLI.builderDeleteArguments
        case .prunePlan: return K3smCLI.buildPrunePlanArguments
        case .prune: return K3smCLI.buildPruneArguments
        }
    }

    public var deadline: Duration {
        switch action {
        case .start, .resetStart: return PollSchedule.builderUpDeadline
        case .stop, .reset, .prunePlan: return PollSchedule.builderDeadline
        case .prune: return PollSchedule.buildPruneDeadline
        }
    }

    /// Start and the dry run run on the click: neither removes anything,
    /// and the dry run leads to the question. A reset's start follows the
    /// question its reset asked. Stop, Reset and the prune ask.
    public var asksFirst: Bool {
        switch action {
        case .start, .resetStart, .prunePlan: return false
        case .stop, .reset, .prune: return true
        }
    }

    public var confirmation: ActionConfirmation {
        switch action {
        case .start:
            return ActionConfirmation(title: "Start the build engine?", message: "k3sm starts the build engine and waits for it to serve.",
                                      verbTitle: "Start Engine", cancelTitle: "Cancel", destructive: false)
        case .resetStart:
            return ActionConfirmation(title: "Start the build engine again?", message: "k3sm starts the build engine after its reset.",
                                      verbTitle: "Start Engine", cancelTitle: "Cancel", destructive: false)
        case .stop:
            return ActionConfirmation(title: "Stop the build engine?", message: "k3sm stops the build engine and keeps its build cache. A build running on it stops too.",
                                      verbTitle: "Stop Engine", cancelTitle: "Cancel", destructive: false)
        case .reset:
            return ActionConfirmation(
                title: "Reset the build engine?",
                message: "k3sm removes the build engine and its build cache, then starts it again. The next build starts with a cold cache. Images already built stay in the store.",
                verbTitle: "Reset Engine", cancelTitle: "Cancel", destructive: true)
        case .prunePlan:
            return ActionConfirmation(title: "Prune the build cache?", message: "k3sm first measures what a prune would reclaim.",
                                      verbTitle: "Prune Cache", cancelTitle: "Cancel", destructive: false)
        case .prune:
            let figure = estimate.map { "A prune reclaims about \($0.text). " } ?? ""
            return ActionConfirmation(
                title: "Prune the build cache?",
                message: figure + "Cache a running build holds is kept, and BuildKit's own records stay. The next build rebuilds any layer it needs.",
                verbTitle: "Prune Cache", cancelTitle: "Cancel", destructive: true)
        }
    }

    /// The dry run leads to the prune, carrying its figure, when it found
    /// something to reclaim; a reset's delete leads to its start once it
    /// succeeded.
    public func next(after run: ActionRun) -> (any ConsoleActionRequest)? {
        guard case .exited(status: 0, let output) = run else { return nil }
        switch action {
        case .prunePlan:
            guard let estimate = PruneEstimate.parse(output, marker: "would reclaim"), estimate.bytes > 0 else { return nil }
            return BuildEngineRequest(.prune, estimate: estimate)
        case .reset:
            return BuildEngineRequest(.resetStart)
        case .start, .stop, .resetStart, .prune:
            return nil
        }
    }

    public func report(_ run: ActionRun) -> ActionOutcome {
        let verb: String
        switch action {
        case .start: verb = "Start"
        case .stop: verb = "Stop"
        case .reset, .resetStart: verb = "Reset"
        case .prunePlan, .prune: verb = "Prune"
        }
        switch run {
        case .exited(status: 0, let output):
            switch action {
            case .start: return .succeeded("The build engine is ready.")
            case .stop: return .succeeded("The build engine is stopped. Its build cache is kept.")
            case .reset: return .succeeded("The build engine and its cache were removed.")
            case .resetStart: return .succeeded("The build engine was reset and is ready, with an empty cache.")
            case .prunePlan:
                guard let estimate = PruneEstimate.parse(output, marker: "would reclaim") else {
                    return .failed("Prune stopped: k3sm did not say what a prune would reclaim, so nothing was removed.")
                }
                return .succeeded(estimate.bytes == 0 ? "The build cache has nothing to reclaim." : "A prune would reclaim about \(estimate.text).")
            case .prune:
                guard let done = PruneEstimate.parse(output, marker: "reclaimed") else {
                    return .succeeded("The build cache was pruned.")
                }
                return .succeeded("Reclaimed \(done.text).")
            }
        case .exited(let status, let output):
            let text = StatusDisplay.errorText(String(decoding: output, as: UTF8.self))
            return .failed(text.isEmpty ? "\(verb) failed: k3sm exited \(status)." : "\(verb) failed. k3sm said: \(text)")
        case .noAnswer:
            return .failed("\(verb) failed: k3sm did not answer. Refresh to see the engine's state.")
        case .missing:
            return .failed("\(verb) failed: k3sm is not installed on this Mac.")
        case .refused(let why):
            return .failed("\(verb) failed: the installed k3sm failed the app's check (\(StatusDisplay.errorText(why))), so it was not run.")
        }
    }
}

/// BuildActions decides what the Builds tab offers: each history row's
/// actions by its status, and the toolbar's engine actions by the engine's
/// state.
public enum BuildActions {
    /// A recorded build's actions, in menu order: the log always; Cancel
    /// only while it runs; Delete only once it has finished. A status the
    /// app does not know offers the log alone.
    public static func actionsForBuild(status: BuildStatus) -> [BuildAction] {
        switch status {
        case .running: return [.showLog, .cancel]
        case .succeeded, .failed, .cancelled: return [.showLog, .delete]
        case .other: return [.showLog]
        }
    }

    /// A row's menu, as its context menu, the inspector and the Delete key
    /// show it: Show Log as its local action, Cancel or Delete as its
    /// request. A record whose id `BuildRecordID` refuses offers nothing.
    public static func menu(for record: BuildRecord) -> ActionMenu {
        guard let id = record.id else { return .empty }
        var requests: [any ConsoleActionRequest] = []
        var local: [LocalMenuItem] = []
        for action in actionsForBuild(status: record.status) {
            switch action {
            case .showLog:
                let target = BuildLogTarget(id: id, title: record.title, follow: record.status == .running)
                local.append(LocalMenuItem(id: "show-log", title: "Show Log", action: .showBuildLog(target)))
            case .cancel, .delete:
                requests.append(BuildActionRequest(action: action, buildID: id, rowKey: record.key, title: record.title))
            }
        }
        return ActionMenu(requests, local: local)
    }

    /// The toolbar's engine actions for the engine's last read: nothing
    /// before a read; Start while no engine pod runs (and Reset when a cache
    /// is left); Stop and Reset while one does; and Prune Cache only while it
    /// serves, since BuildKit does the pruning.
    public static func engineActions(_ engine: BuildEngine?) -> [BuildEngineAction] {
        guard let engine else { return [] }
        switch engine.state {
        case .absent: return engine.cache == nil ? [.start] : [.start, .reset]
        case .pending: return [.stop, .reset]
        case .failed: return [.start, .stop, .reset]
        case .ready: return [.prunePlan, .stop, .reset]
        }
    }

    /// The toolbar's items.
    public static func toolbar(_ engine: BuildEngine?) -> [ActionMenuItem] {
        engineActions(engine).map { ActionMenuItem(BuildEngineRequest($0)) }
    }
}

/// BuildLog is a build log sheet's text and the line under it, from the
/// bytes read so far and how the read ended.
public enum BuildLog {
    public enum End: Equatable, Sendable {
        /// Still reading.
        case reading
        /// The CLI exited; 0 means the whole log was printed.
        case exited(Int32)
        /// The output passed `OutputLimit.buildLog`.
        case truncated
        /// The read ran past its deadline, or the CLI did not answer.
        case stopped
        case missing
        case refused(String)
    }

    /// The sheet's text: the bytes as UTF-8, block-cleaned (`StatusDisplay.body`).
    public static func text(_ data: Data) -> String {
        StatusDisplay.body(String(decoding: data, as: UTF8.self))
    }

    /// The line under the log.
    public static func status(_ end: End, follow: Bool, id: BuildRecordID, empty: Bool) -> String {
        switch end {
        case .reading: return follow ? "Following the build while it runs…" : "Reading the log…"
        case .exited(0): return empty ? "The build has logged nothing." : (follow ? "The build finished." : "End of the log.")
        case .exited(let status): return "k3sm build logs exited \(status)."
        case .truncated: return "The log is longer than \(OutputLimit.buildLog >> 20) MiB; the rest is in `k3sm build logs \(id.value)`."
        case .stopped: return "The app stopped reading the log. Open it again, or run `k3sm build logs -f \(id.value)`."
        case .missing: return "k3sm is not installed on this Mac."
        case .refused(let why): return "The installed k3sm failed the app's check (\(StatusDisplay.errorText(why))), so it was not run."
        }
    }
}
