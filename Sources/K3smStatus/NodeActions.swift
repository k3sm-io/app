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

/// NodeAction is a change the console can make to one node: mark it
/// unschedulable (cordon) or schedulable again (uncordon), or drain it
/// (cordon it and evict its pods).
public enum NodeAction: String, Sendable, CaseIterable, Identifiable {
    case cordon
    case uncordon
    case drain

    public var id: Self { self }

    /// The button's title.
    public var title: String {
        switch self {
        case .cordon: return "Cordon"
        case .uncordon: return "Uncordon"
        case .drain: return "Drain"
        }
    }
}

/// NodeActionRequest is one action on one node, fixed when the user asks
/// for it: the name and UID come from the node as it was listed then, so a
/// node recreated under the same name since is refused by its UID.
public struct NodeActionRequest: Equatable, ConsoleActionRequest {
    public let action: NodeAction
    public let node: ResourceName
    /// The node's UID as listed when the action was asked for.
    public let uid: String

    public var id: String { "node-\(action.rawValue):\(node.value)" }
    public var section: ConsoleSection { .nodes }
    public var rowKey: String { node.value }
    public var verb: String { "node-\(action.rawValue)" }
    /// None removes the node: each is a change, never on the Delete key.
    public var kind: ActionKind { .change }

    public var arguments: [String] {
        switch action {
        case .cordon: return K3smCLI.cordonArguments(node: node)
        case .uncordon: return K3smCLI.uncordonArguments(node: node)
        case .drain: return K3smCLI.drainArguments(node: node, timeoutSeconds: NodeActions.drainTimeoutSeconds)
        }
    }

    /// A drain waits for its evictions up to `NodeActions.drainTimeoutSeconds`,
    /// so the runner gives it that and a margin for kubectl's own exit.
    public var deadline: Duration {
        action == .drain ? .seconds(NodeActions.drainTimeoutSeconds + NodeActions.drainDeadlineMarginSeconds)
            : PollSchedule.actionDeadline
    }

    /// Every node action reads the node's UID first (`NodeActions.verify`).
    public var precheckArguments: [String]? { K3smCLI.nodeUIDArguments(node: node) }

    /// Cordon asks first: it stops new pods landing on the node; Drain asks
    /// first: it moves the node's pods. Uncordon only reopens the node, so it
    /// runs on the click, with no ellipsis.
    public var asksFirst: Bool { action != .uncordon }
    public var titleEllipsis: Bool { asksFirst }

    public var confirmation: ActionConfirmation {
        let name = StatusDisplay.clip(node.value)
        switch action {
        case .cordon:
            return ActionConfirmation(
                title: "Cordon \(name)?",
                message: "k3sm marks this node unschedulable, so no new pods are placed on it. "
                    + "The pods running there keep running. Uncordon opens it again.",
                verbTitle: action.title, cancelTitle: "Cancel", destructive: false)
        case .uncordon:
            return ActionConfirmation(
                title: "Uncordon \(name)?", message: "k3sm lets new pods be placed on this node again.",
                verbTitle: action.title, cancelTitle: "Cancel", destructive: false)
        case .drain:
            return ActionConfirmation(
                title: "Drain \(name)?",
                message: NodeActions.drainMessage,
                verbTitle: action.title, cancelTitle: "Cancel", destructive: true)
        }
    }

    public func precheck(_ run: ActionRun) -> ActionOutcome? {
        NodeActions.verify(self, run: run)
    }

    public func report(_ run: ActionRun) -> ActionOutcome {
        NodeActions.report(self, run: run)
    }
}

/// NodeActions decides which actions a node offers, builds their requests
/// and reports their runs.
public enum NodeActions {
    /// How long a drain waits for its pods to be evicted (`--timeout`).
    public static let drainTimeoutSeconds = 120
    /// What the runner allows past that before it stops waiting for kubectl.
    public static let drainDeadlineMarginSeconds = 30

    /// The drain's confirmation: what moves, what is lost, what stays.
    public static let drainMessage =
        "k3sm cordons this node and evicts its pods, so they move to other nodes that can take them; "
        + "a pod with nowhere to go waits as Pending. Data in the pods' emptyDir volumes is lost. "
        + "DaemonSet pods stay. The node takes no new pods until you uncordon it. "
        + "k3sm stops waiting after \(drainTimeoutSeconds / 60) minutes."

    /// The actions a node offers: Cordon while it takes new pods, Uncordon
    /// once cordoned (a drained node is cordoned, so it offers Uncordon),
    /// and Drain either way; nothing for a node whose name `ResourceName`
    /// refuses or that was listed without a UID.
    public static func available(for node: ClusterNode) -> [NodeAction] {
        guard request(node.unschedulable ? .uncordon : .cordon, for: node) != nil else { return [] }
        return [node.unschedulable ? .uncordon : .cordon, .drain]
    }

    /// The node's actions as its context menu and the inspector show them.
    public static func menu(for node: ClusterNode) -> ActionMenu {
        ActionMenu(available(for: node).compactMap { request($0, for: node) })
    }

    /// The request for one action on a node, or nil when its name or UID
    /// does not allow one.
    public static func request(_ action: NodeAction, for node: ClusterNode) -> NodeActionRequest? {
        guard let name = ResourceName(node.name), !node.uid.isEmpty else { return nil }
        return NodeActionRequest(action: action, node: name, uid: node.uid)
    }

    /// What the UID read just before the action says: nil when the node is
    /// still the one listed, so the action runs; otherwise the line shown
    /// instead, and nothing runs.
    public static func verify(_ request: NodeActionRequest, run: ActionRun) -> ActionOutcome? {
        let verb = request.action.title
        let changed = ActionOutcome.refused("\(verb) refused: the node changed since you clicked; nothing was changed.")
        switch run {
        case .exited(status: 0, let output):
            let read = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return read == request.uid ? nil : changed
        case .exited(let status, let output):
            let raw = String(decoding: output, as: UTF8.self)
            if raw.contains("(NotFound)") { return changed }
            let text = StatusDisplay.errorText(raw)
            return .failed("\(verb) failed; nothing was changed. " + (text.isEmpty ? "k3sm kubectl exited \(status)" : "kubectl said: \(text)"))
        case .noAnswer:
            return .failed("\(verb) failed: the k3sm CLI did not answer the node check; nothing was changed.")
        case .missing, .refused:
            return report(request, run: run)
        }
    }

    /// The line shown after a run. CLI text passes `StatusDisplay.errorText`.
    public static func report(_ request: NodeActionRequest, run: ActionRun) -> ActionOutcome {
        let verb = request.action.title
        let name = StatusDisplay.clip(request.node.value)
        switch run {
        case .exited(status: 0, _):
            switch request.action {
            case .cordon: return .succeeded("\(verb) asked: no new pods are placed on \(name).")
            case .uncordon: return .succeeded("\(verb) asked: \(name) takes new pods again.")
            case .drain:
                let evicted = evictedCount(in: output(run))
                return .succeeded("Drained \(name): \(pods(evicted)) evicted. It takes no new pods until you uncordon it.")
            }
        case .exited(let status, let output):
            let raw = String(decoding: output, as: UTF8.self)
            if request.action == .drain {
                let evicted = evictedCount(in: output)
                let text = StatusDisplay.errorText(errorLines(raw))
                let said = text.isEmpty ? "k3sm kubectl exited \(status)." : "kubectl said: \(text)"
                return .failed("Drain of \(name) stopped after \(pods(evicted)) evicted; the node stays cordoned. " + said)
            }
            let text = StatusDisplay.errorText(raw)
            return .failed(text.isEmpty ? "\(verb) failed: k3sm kubectl exited \(status)" : "\(verb) failed. kubectl said: \(text)")
        case .noAnswer:
            return .failed("\(verb) failed: the k3sm CLI did not answer. Refresh to see whether the node changed.")
        case .missing:
            return .failed("\(verb) failed: k3sm is not installed on this Mac.")
        case .refused(let why):
            return .failed("\(verb) failed: the installed k3sm failed the app's check (\(StatusDisplay.errorText(why))), so it was not run.")
        }
    }

    /// How many pods a drain's output says were evicted: one
    /// `pod/<name> evicted` line each, as kubectl prints them.
    public static func evictedCount(in output: Data) -> Int {
        String(decoding: output, as: UTF8.self).split(whereSeparator: \.isNewline).filter { line in
            let words = line.split(separator: " ")
            return words.count == 2 && words[0].hasPrefix("pod/") && words[1] == "evicted"
        }.count
    }

    /// The lines of a failed drain's output that carry kubectl's error, so
    /// the report shows the cause and not the progress lines before it; the
    /// whole output when no line starts `error`.
    static func errorLines(_ raw: String) -> String {
        let lines = raw.split(whereSeparator: \.isNewline).filter { $0.hasPrefix("error") }
        return lines.isEmpty ? raw : lines.joined(separator: " ")
    }

    private static func output(_ run: ActionRun) -> Data {
        if case .exited(_, let output) = run { return output }
        return Data()
    }

    /// "1 pod", "3 pods".
    static func pods(_ n: Int) -> String {
        n == 1 ? "1 pod" : "\(n) pods"
    }
}
