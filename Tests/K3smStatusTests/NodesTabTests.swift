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

/// The Nodes tab: its rows, the node inspector's body, and Cordon and
/// Uncordon on the console's shared action seam.
@Suite("the Nodes tab and the node inspector")
struct NodesTabTests {
    static let t0 = Date(timeIntervalSince1970: 1_792_144_800) // 2026-10-16T10:00:00Z
    static let now = t0.addingTimeInterval(27)

    static let nodeMetrics = #"""
    {"kind":"NodeMetricsList","items":[{"metadata":{"name":"mac-a"},"usage":{"cpu":"1425378643n","memory":"12582912Ki"}}]}
    """#
    static let podMetrics = #"""
    {"kind":"PodMetricsList","items":[{"metadata":{"name":"web-a","namespace":"default"},
     "containers":[{"name":"web","usage":{"cpu":"250m","memory":"128Mi"}}]}]}
    """#

    /// Two samples 15 s apart, mac-a in both, mac-b in neither.
    static func sampled() -> MetricsState {
        var state = MetricsState()
        for i in 0..<2 {
            state.apply(Metrics.sampled(nodes: Data(nodeMetrics.utf8), pods: (exit: 0, stdout: Data(podMetrics.utf8))),
                        at: t0.addingTimeInterval(Double(i) * 15))
        }
        return state
    }

    static func nodes() throws -> [ClusterNode] {
        try Nodes.decode(try fixture("kubectl_nodes_inspect.json"))
    }

    static func pods() throws -> [Pod] {
        try Workloads.decode(try fixture("kubectl_pods_two_nodes.json")).pods
    }

    @Test("each node's inspector: facts, live load, conditions with their transition, taints and its pods")
    func nodeInspectorDetails() throws {
        let nodes = try Self.nodes()
        let pods = try Self.pods()
        let metrics = Self.sampled()
        let a = try #require(nodes.first { $0.name == "mac-a" })
        let b = try #require(nodes.first { $0.name == "mac-b" })

        // The control-plane node, sampled, with three running pods and a finished one left out.
        let sampled = InspectorDetails.node(a, nodes: nodes, report: nil, pods: pods, metrics: metrics, now: Self.now)
        #expect([sampled.header.kind, sampled.header.title] == ["Node", "mac-a"])
        #expect(sampled.header.subtitle == nil)
        #expect(sampled.header.facts.map { [$0.label, $0.value] } == [
            ["Role", "server"], ["Status", "Ready"], ["Scheduling", "takes new pods"],
            ["Kubelet", "v1.36.2+k3sm.0.1.7"], ["k3sm", "current: runs 0.1.7, cluster target 0.1.7 (the server's release)"],
            ["Latest", "not reported"],
            ["Addresses", "100.64.0.1 (InternalIP), mac-a (Hostname)"],
            ["Capacity", "20 cores · 64 GB · 110 pods"], ["Allocatable", "19 cores · 60 GB · 110 pods"],
        ])
        guard case .sampled(let cpu, let memory, let sparkline, let age) = sampled.load else {
            Issue.record("mac-a is sampled: \(sampled.load)"); return
        }
        #expect(cpu.text == "1.43 of 19 cores · 8%")
        #expect(memory.text == "12 GB of 60 GB · 20%")
        #expect(sparkline.count == 2)
        #expect(abs(sparkline[1] - 1.425378643 / 19) < 1e-9)
        #expect(age == "sampled 12 s ago")
        #expect(sampled.conditions == [
            NodeConditionLine(type: "Ready", text: "True since 1 h ago · KubeletReady", healthy: true),
            NodeConditionLine(type: "MemoryPressure", text: "False since 1 h ago · KubeletHasSufficientMemory", healthy: true),
        ])
        #expect(sampled.taints.isEmpty)
        #expect(sampled.pods == [
            NodePodLine(name: "default/linux-a", usage: "no metrics yet"),
            NodePodLine(name: "default/web-a", usage: "0.25 cores · 128 MB"),
            NodePodLine(name: "default/web-b", usage: "no metrics yet"),
        ])

        // The cordoned, NotReady node with taints, which the sample does not carry.
        let unsampled = InspectorDetails.node(b, nodes: nodes, report: nil, pods: pods, metrics: metrics, now: Self.now)
        #expect(unsampled.header.facts.map { [$0.label, $0.value] } == [
            ["Role", "agent"], ["Status", "Not ready"], ["Scheduling", "cordoned: no new pods"],
            ["Kubelet", "v1.36.2+k3sm.0.1.6"], ["k3sm", "behind: runs 0.1.6, cluster target 0.1.7 (the server's release)"],
            ["Latest", "not reported"], ["Addresses", "100.64.1.1 (InternalIP)"],
            ["Capacity", "8 cores · 8.0 GB · 110 pods"], ["Allocatable", "7.5 cores · 6.0 GB · 110 pods"],
        ])
        #expect(unsampled.load == .unsampled("no metrics yet"))
        #expect(unsampled.conditions == [
            NodeConditionLine(type: "Ready", text: "False since 2 d ago · KubeletNotReady", healthy: false),
            NodeConditionLine(type: "MemoryPressure", text: "Unknown · NodeStatusUnknown", healthy: false),
        ])
        // A taint without a key is left out.
        #expect(unsampled.taints == ["node.kubernetes.io/unschedulable:NoSchedule", "dedicated=gpu:NoExecute"])
        #expect(unsampled.pods == [NodePodLine(name: "default/api-b", usage: "no metrics yet")])

        // Before any sample, before the pod list, and while the API is absent.
        let early = InspectorDetails.node(a, nodes: nodes, report: nil, pods: nil, metrics: MetricsState(), now: Self.now)
        #expect(early.load == .unsampled("no metrics yet"))
        #expect(early.pods == nil)
        var absent = metrics
        absent.apply(.absent(Metrics.notInstalled), at: Self.now)
        #expect(InspectorDetails.node(a, nodes: nodes, report: nil, pods: pods, metrics: absent, now: Self.now).load
            == .unsampled(Metrics.notInstalled))
        #expect(InspectorDetails.node(a, nodes: nodes, report: nil, pods: pods, metrics: absent, now: Self.now).pods?[1].usage
            == "no metrics yet")
    }

    @Test("this Mac's node takes the report's role and is named so")
    func ownNodeRole() throws {
        let nodes = try Self.nodes()
        let report = try StatusReport.decode(try fixture("status_json_running.json"))
        guard let own = NodesList.own(report: report).node else { Issue.record("the running fixture names its node"); return }
        let renamed = nodes.map { node -> ClusterNode in
            guard node.name == "mac-b" else { return node }
            var copy = ClusterNode(name: own, ready: node.ready, kubeletVersion: node.kubeletVersion)
            copy.uid = node.uid
            return copy
        }
        let mine = try #require(renamed.first { $0.name == own })
        let body = InspectorDetails.node(mine, nodes: renamed, report: report, pods: [], metrics: MetricsState(), now: Self.now)
        #expect(body.header.subtitle == NodesDisplay.thisMac)
        #expect(body.header.facts.first?.value == NodesList.own(report: report).role)
        #expect(body.pods == [])
        #expect(NodesList.rows(renamed, report: report, metrics: MetricsState()).first?.key == own)
    }

    @Test("the list's rows, this Mac's first, with status, version and load; the search")
    func rows() throws {
        let nodes = try Self.nodes()
        let rows = NodesList.rows(nodes, report: nil, metrics: Self.sampled())
        #expect(rows.map { [$0.key, $0.role, $0.status, $0.version, $0.load] } == [
            ["mac-a", "server", "Ready", "0.1.7 · current", "8% CPU · 20% memory"],
            ["mac-b", "agent", "Not ready · cordoned", "0.1.6 · behind", "no metrics yet"],
        ])
        #expect(NodesList.rows(nodes, report: nil, metrics: MetricsState()).allSatisfy { $0.load.isEmpty })
        #expect(NodesList.visible(rows, query: "B").map(\.key) == ["mac-b"])
        #expect(NodesList.visible(rows, query: "server").map(\.key) == ["mac-a"])
        #expect(NodesList.visible(rows, query: " ").count == 2)
        #expect(NodesList.keys(nodes) == ["mac-a", "mac-b"])
        #expect(NodesList.keys(nil) == nil)
    }

    @Test("a node row is its own kind on its own tab")
    func selection() {
        #expect(ConsoleRow(section: .nodes, key: "mac-a") == .node("mac-a"))
        #expect(ConsoleRow.node("mac-a").section == .nodes)
        var selection = ConsoleSelection(active: .nodes, rows: [.node("mac-a"), .pod("default/web-a")])
        #expect(selection.current == .node("mac-a"))
        let refused = selection.select(.node("mac-b"), in: .workloads)
        #expect(!refused)
        selection.retain(.nodes, present: ["mac-b"])
        #expect(selection.current == nil)
        #expect(selection.selection(in: .workloads) == .pod("default/web-a"))
        #expect(InspectorDetails.emptyText(.nodes) == "Select a node.")
    }

    @Test("cordon, uncordon and the UID read are fixed argument lists through the CLI's kubectl")
    func cordonArgumentsGolden() throws {
        let node = try #require(ResourceName("mac-b"))
        #expect(K3smCLI.cordonArguments(node: node) == ["kubectl", "cordon", "mac-b"])
        #expect(K3smCLI.uncordonArguments(node: node) == ["kubectl", "uncordon", "mac-b"])
        #expect(K3smCLI.nodeUIDArguments(node: node) == ["kubectl", "get", "node", "mac-b", "-o", "jsonpath={.metadata.uid}"])
        let nodes = try Self.nodes()
        let cordon = try #require(NodeActions.request(.cordon, for: nodes[0]))
        #expect(cordon.arguments == ["kubectl", "cordon", "mac-a"])
        #expect(cordon.precheckArguments == ["kubectl", "get", "node", "mac-a", "-o", "jsonpath={.metadata.uid}"])
        #expect(cordon.runs == [cordon.arguments])
        let uncordon = try #require(NodeActions.request(.uncordon, for: nodes[1]))
        #expect(uncordon.arguments == ["kubectl", "uncordon", "mac-b"])
    }

    struct Availability: Sendable, CustomTestStringConvertible {
        let name: String
        let node: String
        let uid: String
        let unschedulable: Bool
        let want: [NodeAction]
        var testDescription: String { name }
    }

    @Test("a node offers Cordon or Uncordon by its schedulable state", arguments: [
        Availability(name: "schedulable", node: "mac-a", uid: "u", unschedulable: false, want: [.cordon]),
        Availability(name: "cordoned", node: "mac-b", uid: "u", unschedulable: true, want: [.uncordon]),
        Availability(name: "listed without a UID", node: "mac-a", uid: "", unschedulable: false, want: []),
        Availability(name: "cordoned, without a UID", node: "mac-b", uid: "", unschedulable: true, want: []),
        Availability(name: "a name the guard refuses", node: "--all", uid: "u", unschedulable: false, want: []),
        Availability(name: "a name with a capital", node: "Mac-A", uid: "u", unschedulable: true, want: []),
    ])
    func availability(_ c: Availability) {
        var node = ClusterNode(name: c.node, ready: true)
        node.uid = c.uid
        node.unschedulable = c.unschedulable
        #expect(NodeActions.available(for: node) == c.want)
        let menu = NodeActions.menu(for: node)
        #expect(menu.items.count == c.want.count)
        #expect(menu.local.isEmpty)
        #expect(menu.deleteKeyItem == nil)
    }

    @Test("only Cordon asks first; both are changes on the Nodes tab with their own tags")
    func requests() throws {
        let nodes = try Self.nodes()
        let cordon = try #require(NodeActions.request(.cordon, for: nodes[0]))
        let uncordon = try #require(NodeActions.request(.uncordon, for: nodes[1]))
        #expect(cordon.asksFirst)
        #expect(!uncordon.asksFirst)
        #expect(ActionMenuItem(cordon).title == "Cordon…")
        #expect(ActionMenuItem(uncordon).title == "Uncordon")
        for request in [cordon, uncordon] {
            #expect(request.kind == .change)
            #expect(request.section == .nodes)
            #expect(!request.confirmation.destructive)
            #expect(Help.Actions.tag(for: ActionMenuItem(request)) != Help.Actions.other)
        }
        #expect(cordon.rowKey == "mac-a")
        #expect(cordon.uid == "0a9e44d1-node-a")
        #expect(cordon.confirmation.title == "Cordon mac-a?")
        #expect(cordon.confirmation.message.contains("keep running"))
        #expect(cordon.id != uncordon.id)
    }

    @Test("the UID read refuses a node that changed, and the runs report in one line")
    func verifyAndReport() throws {
        let cordon = try #require(NodeActions.request(.cordon, for: try Self.nodes()[0]))
        #expect(cordon.precheck(.exited(status: 0, output: Data("0a9e44d1-node-a\n".utf8))) == nil)
        #expect(cordon.precheck(.exited(status: 0, output: Data("other".utf8)))
            == .refused("Cordon refused: the node changed since you clicked; nothing was changed."))
        #expect(cordon.precheck(.exited(status: 1, output: Data(#"Error from server (NotFound): nodes "mac-a" not found"#.utf8)))?.failed == true)
        #expect(cordon.precheck(.noAnswer)?.text.contains("did not answer") == true)
        #expect(cordon.report(.exited(status: 0, output: Data())) == .succeeded("Cordon asked: no new pods are placed on mac-a."))
        let hostile = cordon.report(.exited(status: 1, output: Data("bad\u{1B}[31m\nline".utf8)))
        #expect(hostile.failed)
        #expect(!hostile.text.contains("\u{1B}"))
        #expect(cordon.report(.missing) == .failed("Cordon failed: k3sm is not installed on this Mac."))
    }
}
