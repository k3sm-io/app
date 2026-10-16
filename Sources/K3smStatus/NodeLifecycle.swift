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

/// NodeLifecycleAction is a change to k3sm itself on this Mac that the node
/// inspector offers for this Mac's own node: Update (whatever the one update
/// plan, `UpdatePlan`, runs: the app-carried update of this Mac or the
/// managed roll from the server), and Restart and Stop (the lifecycle verbs
/// the menu runs). Each goes through the app's checked root step with its
/// own confirmation; none runs on another Mac.
public enum NodeLifecycleAction: String, Sendable, CaseIterable, Identifiable {
    case update
    case restart
    case stop

    public var id: Self { self }

    /// The button's title; each asks before it runs, so each ends in an ellipsis.
    public var title: String {
        switch self {
        case .update: return "Update k3sm…"
        case .restart: return "Restart k3sm…"
        case .stop: return "Stop k3sm…"
        }
    }
}

/// NodeLifecycleOffer is what the node inspector offers for one node's k3sm
/// itself: the actions, in button order, and the line shown under them, nil
/// when there is nothing to say. Only this Mac's own node offers any: the app
/// runs k3sm on this Mac alone, and has no credential on another one.
public struct NodeLifecycleOffer: Equatable, Sendable {
    public let actions: [NodeLifecycleAction]
    public let note: String?

    public init(actions: [NodeLifecycleAction], note: String?) {
        self.actions = actions
        self.note = note
    }

    /// Another Mac's node: updated by the server's managed update or by the
    /// app on that Mac.
    public static let otherNodeNote =
        "This node is another Mac. Update it from the server's managed update (Settings, Updates), "
        + "or restart, stop or update it from the k3sm app on that Mac."
    /// The report names no node as this Mac's, so none is offered.
    public static let ownNodeUnknownNote =
        "k3sm has not said which node is this Mac, so Update, Restart and Stop are in the menu bar item only."
    /// A managed update is rolling: it restarts each node itself.
    public static let rollingNote =
        "A managed update is moving the cluster to a new release and restarts each node itself. "
        + "Update, Restart and Stop return here when it finishes."
    /// This Mac is a worker behind the cluster's target: the managed update
    /// runs on the server (the update plan's `workerBehind` sentence).
    public static let workerBehindNote = UpdateBlock.workerBehindText

    /// The offer for `node`, from the node list, this Mac's report and the
    /// update plan: none for another Mac's node, or when the report names no
    /// node as this Mac's; for this Mac's node, none while k3sm here is not
    /// running or a managed update rolls; else Restart and Stop, with Update
    /// first whenever the plan has a path (enabled or not, as every other
    /// Update control shows it), and the plan's sentence under them when it
    /// is blocked with no path. A cordon changes nothing here.
    public static func decide(_ node: ClusterNode, nodes: [ClusterNode], report: StatusReport?,
                              plan: UpdatePlan) -> NodeLifecycleOffer {
        guard let own = NodesList.own(report: report).node else {
            return NodeLifecycleOffer(actions: [], note: ownNodeUnknownNote)
        }
        guard node.name == own else { return NodeLifecycleOffer(actions: [], note: otherNodeNote) }
        let state = LifecycleState(report: report)
        guard state == .running else {
            return NodeLifecycleOffer(actions: [], note: "k3sm on this Mac is \(state.word); start it from the menu bar item.")
        }
        if plan == .rolling || NodeVersions.decide(nodes, report: report).target?.source == .roll {
            return NodeLifecycleOffer(actions: [], note: rollingNote)
        }
        if plan.path != nil { return NodeLifecycleOffer(actions: [.update, .restart, .stop], note: nil) }
        if case .blocked(let block) = plan { return NodeLifecycleOffer(actions: [.restart, .stop], note: block.sentence) }
        return NodeLifecycleOffer(actions: [.restart, .stop], note: nil)
    }
}
