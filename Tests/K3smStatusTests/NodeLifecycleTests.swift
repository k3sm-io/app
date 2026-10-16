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
import Testing

@testable import K3smStatus

/// The node inspector's own-node Update, Restart and Stop (`NodeLifecycleOffer`)
/// and Drain on the console's shared action seam.
@Suite("node lifecycle and drain in the node inspector")
struct NodeLifecycleTests {
    /// mac-a, the control plane, and mac-b, a worker, each on `release`.
    static func nodes(a: String = "0.1.8", b: String = "0.1.8", cordoned: Set<String> = []) -> [ClusterNode] {
        [("mac-a", a, true), ("mac-b", b, false)].map { name, release, cp in
            var node = ClusterNode(name: name, ready: true, kubeletVersion: "v1.36.2+k3sm." + release, controlPlane: cp)
            node.uid = "uid-" + name
            node.unschedulable = cordoned.contains(name)
            return node
        }
    }

    /// This Mac's report: its role's daemon row in `daemon`, the node row
    /// naming `own` (none when nil), and the `update` row when given.
    static func report(own: String?, role: String = "server", daemon: String = "running", update: StatusRow? = nil) -> StatusReport {
        var rows = [StatusRow(name: role, state: daemon, detail: "")]
        if let own { rows.append(StatusRow(name: "node", state: "ready", detail: "2/2 nodes ready · \(own) kubelet v1.36.2")) }
        if let update { rows.append(update) }
        return StatusReport(schemaVersion: 1, verdict: .running, role: role, summary: "", rows: rows)
    }

    static let behind = StatusRow(name: "update", state: "behind", detail: "k3sm v0.1.8 is available; behind: mac-a",
                                  wide: ["latest": "v0.1.8"])
    static let latest = StatusRow(name: "update", state: "healthy", detail: "every node runs k3sm v0.1.8",
                                  wide: ["latest": "v0.1.8"])
    static func rolling(node: String) -> StatusRow {
        StatusRow(name: "update", state: "rolling", detail: "updating the cluster to k3sm v0.1.8: Rolling",
                  wide: ["target": "v0.1.8", "phase": "Rolling", "node": node, "node-phase": "Updating"])
    }

    struct Case: CustomTestStringConvertible, Sendable {
        let name: String
        let nodes: [ClusterNode]
        let selected: String
        let report: StatusReport?
        let actions: [NodeLifecycleAction]
        let note: String?
        let nodeActions: [NodeAction]
        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(name: "this Mac's node behind the latest release, on the server", nodes: nodes(a: "0.1.7"), selected: "mac-a",
             report: report(own: "mac-a", update: behind), actions: [.update, .restart, .stop], note: nil,
             nodeActions: [.cordon, .drain]),
        Case(name: "this Mac's node on the latest release", nodes: nodes(), selected: "mac-a",
             report: report(own: "mac-a", update: latest), actions: [.restart, .stop], note: nil,
             nodeActions: [.cordon, .drain]),
        Case(name: "this Mac's node, no update check, on the server's release", nodes: nodes(), selected: "mac-a",
             report: report(own: "mac-a"), actions: [.restart, .stop], note: nil, nodeActions: [.cordon, .drain]),
        Case(name: "another Mac's node, even behind", nodes: nodes(b: "0.1.7"), selected: "mac-b",
             report: report(own: "mac-a", update: behind), actions: [], note: NodeLifecycleOffer.otherNodeNote,
             nodeActions: [.cordon, .drain]),
        Case(name: "this Mac's node mid-roll", nodes: nodes(a: "0.1.7"), selected: "mac-a",
             report: report(own: "mac-a", update: rolling(node: "mac-a")), actions: [], note: NodeLifecycleOffer.rollingNote,
             nodeActions: [.cordon, .drain]),
        Case(name: "this Mac's node while the roll updates another", nodes: nodes(b: "0.1.7"), selected: "mac-a",
             report: report(own: "mac-a", update: rolling(node: "mac-b")), actions: [], note: NodeLifecycleOffer.rollingNote,
             nodeActions: [.cordon, .drain]),
        Case(name: "another node mid-roll", nodes: nodes(b: "0.1.7"), selected: "mac-b",
             report: report(own: "mac-a", update: rolling(node: "mac-b")), actions: [], note: NodeLifecycleOffer.otherNodeNote,
             nodeActions: [.cordon, .drain]),
        Case(name: "this Mac's node cordoned (or drained)", nodes: nodes(cordoned: ["mac-a"]), selected: "mac-a",
             report: report(own: "mac-a", update: latest), actions: [.restart, .stop], note: nil,
             nodeActions: [.uncordon, .drain]),
        Case(name: "another node cordoned (or drained)", nodes: nodes(cordoned: ["mac-b"]), selected: "mac-b",
             report: report(own: "mac-a", update: latest), actions: [], note: NodeLifecycleOffer.otherNodeNote,
             nodeActions: [.uncordon, .drain]),
        Case(name: "this Mac a worker behind the server", nodes: nodes(b: "0.1.7"), selected: "mac-b",
             report: report(own: "mac-b", role: "agent"), actions: [.restart, .stop], note: NodeLifecycleOffer.workerBehindNote,
             nodeActions: [.cordon, .drain]),
        Case(name: "k3sm on this Mac stopped", nodes: nodes(), selected: "mac-a",
             report: report(own: "mac-a", daemon: "stopped"), actions: [],
             note: "k3sm on this Mac is stopped; start it from the menu bar item.", nodeActions: [.cordon, .drain]),
        Case(name: "the report names no node as this Mac's", nodes: nodes(), selected: "mac-a",
             report: report(own: nil), actions: [], note: NodeLifecycleOffer.ownNodeUnknownNote, nodeActions: [.cordon, .drain]),
        Case(name: "no report yet", nodes: nodes(), selected: "mac-a", report: nil, actions: [],
             note: NodeLifecycleOffer.ownNodeUnknownNote, nodeActions: [.cordon, .drain]),
    ]

    @Test("this Mac's node offers Update when behind, Restart and Stop; another node none, and says where", arguments: cases)
    func ownNodeLifecycleActions(_ c: Case) throws {
        let node = try #require(c.nodes.first { $0.name == c.selected })
        let offer = NodeLifecycleOffer.decide(node, nodes: c.nodes, report: c.report)
        #expect(offer.actions == c.actions)
        #expect(offer.note == c.note)
        #expect(NodeActions.available(for: node) == c.nodeActions)
        #expect(NodeActions.menu(for: node).items.map(\.request.verb) == c.nodeActions.map { "node-" + $0.rawValue })
    }

    @Test("each lifecycle button asks first and carries its own help tag; Update's names why it is disabled")
    func lifecycleTitlesAndTags() {
        #expect(NodeLifecycleAction.allCases.map(\.title) == ["Update k3sm…", "Restart k3sm…", "Stop k3sm…"])
        let enabled = UpdateNowControl(enabled: true, reason: nil)
        let disabled = UpdateNowControl(enabled: false, reason: UpdateNowControl.unknownReason)
        #expect(Help.Nodes.lifecycle(.update, update: enabled) == Help.Nodes.update.text)
        #expect(Help.Nodes.lifecycle(.update, update: disabled) == UpdateNowControl.unknownReason)
        #expect(Help.Nodes.lifecycle(.restart, update: disabled) == Help.Nodes.restart.text)
        #expect(Help.Nodes.lifecycle(.stop, update: disabled) == Help.Nodes.stop.text)
        for tag in [Help.Nodes.update, Help.Nodes.restart, Help.Nodes.stop] { #expect(Help.Nodes.all.contains(tag)) }
    }

    @Test("drain is a fixed argument list through the CLI's kubectl, after the node's UID read")
    func nodeDrainArguments() throws {
        let node = try #require(ResourceName("mac-b"))
        #expect(K3smCLI.drainArguments(node: node, timeoutSeconds: 120)
            == ["kubectl", "drain", "mac-b", "--ignore-daemonsets", "--delete-emptydir-data", "--timeout=120s"])
        #expect(NodeActions.drainTimeoutSeconds == 120)
        let drain = try #require(NodeActions.request(.drain, for: Self.nodes()[0]))
        #expect(drain.arguments == ["kubectl", "drain", "mac-a", "--ignore-daemonsets", "--delete-emptydir-data", "--timeout=120s"])
        #expect(drain.runs == [drain.arguments])
        #expect(drain.precheckArguments == ["kubectl", "get", "node", "mac-a", "-o", "jsonpath={.metadata.uid}"])
        #expect(drain.uid == "uid-mac-a")
        #expect(drain.deadline == .seconds(150))
        #expect(drain.deadline > PollSchedule.actionDeadline)
        #expect(!drain.arguments.contains("--force"))

        // A name the guard refuses, or no UID, offers no drain at all.
        var flag = ClusterNode(name: "--all", ready: true)
        flag.uid = "u"
        #expect(NodeActions.request(.drain, for: flag) == nil)
        #expect(NodeActions.available(for: flag).isEmpty)
        var nameless = Self.nodes()[1]
        nameless.uid = ""
        #expect(NodeActions.available(for: nameless).isEmpty)
    }

    @Test("drain asks first, says the pods move and emptyDir data is lost, and is a change, never the Delete key")
    func drainConfirmation() throws {
        let drain = try #require(NodeActions.request(.drain, for: Self.nodes()[1]))
        #expect(drain.asksFirst)
        #expect(drain.kind == .change)
        #expect(drain.section == .nodes)
        #expect(drain.rowKey == "mac-b")
        #expect(drain.verb == "node-drain")
        #expect(ActionMenuItem(drain).title == "Drain…")
        #expect(NodeActions.menu(for: Self.nodes()[1]).deleteKeyItem == nil)
        let c = drain.confirmation
        #expect(c.title == "Drain mac-b?")
        #expect(c.verbTitle == "Drain")
        #expect(c.destructive)
        #expect(c.message.contains("evicts its pods, so they move to other nodes"))
        #expect(c.message.contains("emptyDir volumes is lost"))
        #expect(c.message.contains("until you uncordon it"))
        #expect(Help.Actions.tag(for: ActionMenuItem(drain)) != Help.Actions.other)
    }

    @Test("drain reports how many pods were evicted, or kubectl's error after the count")
    func drainReport() throws {
        let drain = try #require(NodeActions.request(.drain, for: Self.nodes()[0]))
        #expect(drain.precheck(.exited(status: 0, output: Data("uid-mac-a".utf8))) == nil)
        #expect(drain.precheck(.exited(status: 0, output: Data("uid-other".utf8)))
            == .refused("Drain refused: the node changed since you clicked; nothing was changed."))

        let done = """
        node/mac-a cordoned
        Warning: ignoring DaemonSet-managed Pods: kube-system/svclb-x
        evicting pod default/web-a
        evicting pod default/web-b
        pod/web-a evicted
        pod/web-b evicted
        node/mac-a drained

        """
        #expect(drain.report(.exited(status: 0, output: Data(done.utf8)))
            == .succeeded("Drained mac-a: 2 pods evicted. It takes no new pods until you uncordon it."))
        #expect(drain.report(.exited(status: 0, output: Data("node/mac-a cordoned\nnode/mac-a drained\n".utf8)))
            == .succeeded("Drained mac-a: 0 pods evicted. It takes no new pods until you uncordon it."))

        let stuck = """
        node/mac-a cordoned
        evicting pod default/web-a
        pod/web-a evicted
        error: unable to drain node "mac-a" due to error: cannot delete Pods that declare no controller (use --force to override): default/bare\u{1B}[31m, continuing command...

        """
        let failed = drain.report(.exited(status: 1, output: Data(stuck.utf8)))
        #expect(failed.failed)
        #expect(failed.text.hasPrefix("Drain of mac-a stopped after 1 pod evicted; the node stays cordoned. kubectl said: error: unable to drain node"))
        #expect(!failed.text.contains("evicting pod"))
        #expect(!failed.text.contains("\u{1B}"))
        #expect(drain.report(.exited(status: 1, output: Data()))
            == .failed("Drain of mac-a stopped after 0 pods evicted; the node stays cordoned. k3sm kubectl exited 1."))
        #expect(drain.report(.noAnswer).text.contains("did not answer"))
        #expect(drain.report(.missing) == .failed("Drain failed: k3sm is not installed on this Mac."))
    }
}
