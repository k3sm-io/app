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
/// unschedulable (cordon) or schedulable again (uncordon). Drain is not one.
public enum NodeAction: String, Sendable, CaseIterable, Identifiable {
    case cordon
    case uncordon

    public var id: Self { self }

    /// The button's title.
    public var title: String {
        switch self {
        case .cordon: return "Cordon"
        case .uncordon: return "Uncordon"
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
    /// Neither removes the node: both are changes, never on the Delete key.
    public var kind: ActionKind { .change }

    public var arguments: [String] {
        switch action {
        case .cordon: return K3smCLI.cordonArguments(node: node)
        case .uncordon: return K3smCLI.uncordonArguments(node: node)
        }
    }

    /// Every node action reads the node's UID first (`NodeActions.verify`).
    public var precheckArguments: [String]? { K3smCLI.nodeUIDArguments(node: node) }

    /// Cordon asks first: it stops new pods landing on the node. Uncordon
    /// only reopens it, so it runs on the click, with no ellipsis.
    public var asksFirst: Bool { action == .cordon }
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
    /// The action a node offers by its schedulable state: Cordon while it
    /// takes new pods, Uncordon once cordoned; nothing for a node whose name
    /// `ResourceName` refuses or that was listed without a UID.
    public static func available(for node: ClusterNode) -> [NodeAction] {
        guard request(node.unschedulable ? .uncordon : .cordon, for: node) != nil else { return [] }
        return [node.unschedulable ? .uncordon : .cordon]
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
            }
        case .exited(let status, let output):
            let text = StatusDisplay.errorText(String(decoding: output, as: UTF8.self))
            return .failed(text.isEmpty ? "\(verb) failed: k3sm kubectl exited \(status)" : "\(verb) failed. kubectl said: \(text)")
        case .noAnswer:
            return .failed("\(verb) failed: the k3sm CLI did not answer. Refresh to see whether the node changed.")
        case .missing:
            return .failed("\(verb) failed: k3sm is not installed on this Mac.")
        case .refused(let why):
            return .failed("\(verb) failed: the installed k3sm failed the app's check (\(StatusDisplay.errorText(why))), so it was not run.")
        }
    }
}
