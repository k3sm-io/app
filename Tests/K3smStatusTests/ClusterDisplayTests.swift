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

@Suite("the console panel's cluster view")
struct ClusterDisplayTests {
    static func report(role: String = "server", workers: [StatusWorker]?, node: String?, workloads: String?) -> StatusReport {
        var rows: [StatusRow] = []
        if let node { rows.append(StatusRow(name: "node", state: "ready", detail: node)) }
        if let workloads { rows.append(StatusRow(name: "workloads", state: "ok", detail: workloads)) }
        return StatusReport(schemaVersion: 1, verdict: .running, role: role, summary: "", rows: rows, workers: workers)
    }

    static func twoNodes() throws -> (StatusReport, [ClusterNode], [Pod]) {
        let report = Self.report(
            workers: [StatusWorker(name: "mac-b", role: "agent", version: "v1.36.2+k3sm.0.1.6")],
            node: "1/2 nodes ready · mac-a kubelet v1.36.2", workloads: "4 running · 1 succeeded · 1 vm")
        let nodes = try Nodes.decode(try fixture("kubectl_nodes_two.json"))
        let pods = try Workloads.decode(try fixture("kubectl_pods_two_nodes.json")).pods
        return (report, nodes, pods)
    }

    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let report: StatusReport?
        let want: ClusterSummary
        var testDescription: String { name }
    }

    /// Report-only cases: the node and pod lists are unknown, so the stats
    /// are the rows as printed. This is what the status item's menu shows.
    static let reportCases: [Case] = [
        Case(
            name: "single node",
            report: report(workers: [], node: "1/1 nodes ready · my-mac kubelet v1.36.2", workloads: "6 running · 2 succeeded · 3 vm"),
            want: ClusterSummary(
                title: "This Mac is the cluster",
                stats: [
                    ClusterStat(label: "nodes ready", value: "1/1"), ClusterStat(label: "running", value: "6"),
                    ClusterStat(label: "succeeded", value: "2"), ClusterStat(label: "vm", value: "3"),
                ],
                note: nil, nodeCount: 1)),
        Case(
            name: "two nodes from the report",
            report: report(
                workers: [StatusWorker(name: "node-b", role: "agent")],
                node: "2/2 nodes ready · my-mac kubelet v1.36.2", workloads: "6 running"),
            want: ClusterSummary(
                title: "Cluster",
                stats: [
                    ClusterStat(label: "Macs", value: "2"), ClusterStat(label: "nodes ready", value: "2/2"),
                    ClusterStat(label: "running", value: "6"),
                ],
                note: nil, nodeCount: 2)),
        Case(
            name: "workers unknown",
            report: report(workers: nil, node: "apiserver unreachable", workloads: "apiserver unreachable"),
            want: ClusterSummary(title: "This Mac", stats: [], note: "other nodes unknown", nodeCount: 1)),
        Case(
            name: "a worker",
            report: report(role: "agent", workers: nil, node: "2/2 nodes ready · laptop kubelet v1.36.2", workloads: "4 running"),
            want: ClusterSummary(
                title: "Joined a cluster",
                stats: [ClusterStat(label: "nodes ready", value: "2/2"), ClusterStat(label: "running", value: "4")],
                note: nil, nodeCount: 1)),
        Case(
            name: "a zero failed count is kept as printed",
            report: report(workers: [], node: "1/1 nodes ready", workloads: "3 running · 0 failed"),
            want: ClusterSummary(
                title: "This Mac is the cluster",
                stats: [
                    ClusterStat(label: "nodes ready", value: "1/1"), ClusterStat(label: "running", value: "3"),
                    ClusterStat(label: "failed", value: "0"),
                ],
                note: nil)),
        Case(
            name: "control characters in a label are flattened",
            report: report(workers: [], node: "1/1 nodes ready", workloads: "2 run\u{1B}ning"),
            want: ClusterSummary(
                title: "This Mac is the cluster",
                stats: [ClusterStat(label: "nodes ready", value: "1/1"), ClusterStat(label: "run ning", value: "2")],
                note: nil)),
        Case(name: "no report yet", report: nil, want: ClusterSummary(title: "This Mac", stats: [], note: nil)),
    ]

    @Test("from the report alone", arguments: reportCases)
    func fromReport(_ c: Case) {
        #expect(ClusterDisplay.summary(of: c.report, nodes: nil, pods: nil) == c.want)
    }

    @Test("two nodes with requests")
    func twoNodesWithRequests() throws {
        let (report, nodes, pods) = try Self.twoNodes()
        let got = ClusterDisplay.summary(of: report, nodes: nodes, pods: pods)
        #expect(got.title == "Cluster")
        #expect(got.nodeCount == 2)
        #expect(got.line == "2 Macs · 1/2 nodes ready · 4 running · 5 of 26.5 cores requested · 3.8 GB of 66 GB memory requested · 1 vm · versions differ")
        #expect(got.nodes == [
            ClusterNodeRow(
                name: "mac-a", role: "server", ready: "Ready", isReady: true, version: "0.1.7", thisMac: true,
                cores: ClusterUsage(requested: 3.5, allocatable: 19, text: "3.5 of 19"),
                memory: ClusterUsage(requested: 3.25 * 1_073_741_824, allocatable: 60 * 1_073_741_824, text: "3.2 GB of 60 GB")),
            ClusterNodeRow(
                name: "mac-b", role: "agent", ready: "Not ready", isReady: false, version: "0.1.6", thisMac: false,
                cores: ClusterUsage(requested: 1.5, allocatable: 7.5, text: "1.5 of 7.5"),
                memory: ClusterUsage(requested: 512 * 1_048_576, allocatable: 6 * 1_073_741_824, text: "512 MB of 6.0 GB")),
        ])
        #expect(got.cores?.text == "5 of 26.5")
        #expect(got.podsByNode == "3 on mac-a · 1 on mac-b")
    }

    @Test("this Mac's node comes first, whatever its name")
    func ownNodeFirst() throws {
        let (_, nodes, pods) = try Self.twoNodes()
        let worker = Self.report(role: "agent", workers: nil, node: "1/2 nodes ready · mac-b kubelet v1.36.2", workloads: nil)
        let got = ClusterDisplay.summary(of: worker, nodes: nodes, pods: pods)
        #expect(got.title == "Joined a cluster")
        #expect(got.nodes.map(\.name) == ["mac-b", "mac-a"])
        #expect(got.nodes.map(\.role) == ["agent", "server"])
        #expect(got.nodes.map(\.thisMac) == [true, false])
        #expect(got.podsByNode == "1 on mac-b · 3 on mac-a")
    }

    @Test("single node with its lists")
    func singleNodeLists() throws {
        let (_, nodes, pods) = try Self.twoNodes()
        let mine = nodes.filter { $0.name == "mac-a" }
        let report = Self.report(workers: [], node: "1/1 nodes ready · mac-a kubelet v1.36.2", workloads: nil)
        let got = ClusterDisplay.summary(of: report, nodes: mine, pods: pods.filter { $0.nodeName != "mac-b" })
        #expect(got.title == "This Mac is the cluster")
        #expect(got.nodeCount == 1)
        #expect(got.line == "1/1 nodes ready · 3 running · 3.5 of 19 cores requested · 3.2 GB of 60 GB memory requested · 1 vm · k3sm 0.1.7")
        #expect(got.nodes.map(\.version) == [nil])
        #expect(PanelMode.effective(chosen: .cluster, nodeCount: got.nodeCount) == .thisMac)
    }

    @Test("nodes unknown: no rows, no meters, the pod counts still shown")
    func nodesUnknown() throws {
        let (report, _, pods) = try Self.twoNodes()
        let got = ClusterDisplay.summary(of: report, nodes: nil, pods: pods)
        #expect(got.title == "Cluster")
        #expect(got.nodeCount == 2)
        #expect(got.nodes.isEmpty && got.cores == nil && got.memory == nil && got.podsByNode == nil)
        #expect(got.line == "2 Macs · 1/2 nodes ready · 4 running · 1 vm")
    }

    @Test("an unknown allocatable leaves the cluster meter out")
    func allocatableUnknown() throws {
        let (report, nodes, pods) = try Self.twoNodes()
        let partial = nodes.map {
            $0.name == "mac-b" ? ClusterNode(name: "mac-b", ready: true, allocatableMilliCPU: nil, allocatableMemoryBytes: 1) : $0
        }
        let got = ClusterDisplay.summary(of: report, nodes: partial, pods: pods)
        #expect(got.cores == nil)
        #expect(got.memory != nil)
        #expect(got.nodes.last?.cores == nil)
        #expect(got.nodes.first?.cores?.text == "3.5 of 19")
    }

    @Test("the node rows show versions only when they do not all agree", arguments: [
        ("v1.36.2+k3sm.0.1.7", [nil, nil] as [String?], "k3sm 0.1.7"),
        ("v1.36.2+k3sm.0.1.6", ["0.1.7", "0.1.6"], "versions differ"),
        ("v1.36.2", ["0.1.7", "v1.36.2"], "versions: some unknown"),
        (nil, ["0.1.7", "version unknown"], "versions: some unknown"),
    ] as [(String?, [String?], String)])
    func versionRows(_ other: String?, _ want: [String?], _ stat: String) throws {
        let (report, nodes, pods) = try Self.twoNodes()
        let mine = try #require(nodes.first { $0.name == "mac-a" })
        let mixed = nodes.map {
            $0.name == "mac-b"
                ? ClusterNode(name: "mac-b", ready: $0.ready, kubeletVersion: other, controlPlane: $0.controlPlane,
                              allocatableMilliCPU: $0.allocatableMilliCPU, allocatableMemoryBytes: $0.allocatableMemoryBytes)
                : $0
        }
        let got = ClusterDisplay.summary(of: report, nodes: mixed, pods: pods)
        #expect(mine.k3smRelease == SemanticVersion("0.1.7"))
        #expect(got.nodes.map(\.version) == want)
        #expect(got.stats.last?.text == stat)
        #expect(ClusterDisplay.summary(of: report, nodes: mixed, pods: nil).stats.last?.text == stat)
    }

    struct SplitCase: Sendable, CustomTestStringConvertible {
        let name: String
        let node: String?
        let nodeCount: Int
        let want: [String]
        var testDescription: String { name }
    }

    static let splitCases: [SplitCase] = [
        SplitCase(name: "server of two: its own bound pods", node: "1/2 nodes ready · mac-a kubelet v1.36.2", nodeCount: 2, want: ["linux-a", "web-a", "web-b"]),
        SplitCase(name: "worker of two: its own bound pods", node: "1/2 nodes ready · mac-b kubelet v1.36.2", nodeCount: 2, want: ["api-b"]),
        SplitCase(name: "one node: an unscheduled pod counts", node: "1/1 nodes ready · mac-a kubelet v1.36.2", nodeCount: 1, want: ["linux-a", "pending", "web-a", "web-b"]),
        SplitCase(name: "two nodes, own node not named: none", node: "apiserver unreachable", nodeCount: 2, want: []),
        SplitCase(name: "one node, own node not named: every unfinished pod", node: "apiserver unreachable", nodeCount: 1, want: ["api-b", "linux-a", "pending", "web-a", "web-b"]),
    ]

    @Test("the This Mac meters count only this Mac's unfinished pods", arguments: splitCases)
    func thisMacSplit(_ c: SplitCase) throws {
        let (_, _, pods) = try Self.twoNodes()
        let report = Self.report(workers: [], node: c.node, workloads: nil)
        let got = ClusterDisplay.thisMacPods(pods, report: report, nodeCount: c.nodeCount).map(\.name).sorted()
        #expect(got == c.want)
        #expect(!got.contains("job-done"))
    }

    @Test("the vendored status fixtures", arguments: [
        ("status_json_running.json", "This Mac is the cluster", "1/1 nodes ready · 3 running"),
        ("status_json_server-with-workers.json", "Cluster", "3 Macs · 3/3 nodes ready · 3 running"),
        ("status_json_unknown.json", "This Mac", nil),
    ] as [(String, String, String?)])
    func fixtures(_ name: String, _ title: String, _ line: String?) throws {
        let got = ClusterDisplay.summary(of: try StatusReport.decode(try fixture(name)), nodes: nil, pods: nil)
        #expect(got.title == title)
        #expect(got.line == line)
    }

    @Test("the view mode", arguments: [
        (nil, 1, PanelMode.thisMac), (PanelMode.cluster, 1, .thisMac), (nil, 2, .cluster),
        (PanelMode.thisMac, 2, .thisMac), (PanelMode.cluster, 3, .cluster),
    ] as [(PanelMode?, Int, PanelMode)])
    func mode(_ chosen: PanelMode?, _ count: Int, _ want: PanelMode) {
        #expect(PanelMode.effective(chosen: chosen, nodeCount: count) == want)
        #expect(PanelMode.showsSwitch(nodeCount: count) == (count > 1))
    }
}

@Suite("the node list")
struct NodesTests {
    @Test("two nodes decode tolerantly, an invalid name is left out")
    func twoNodes() throws {
        let nodes = try Nodes.decode(try fixture("kubectl_nodes_two.json"))
        #expect(nodes == [
            ClusterNode(
                name: "mac-a", ready: true, kubeletVersion: "v1.36.2+k3sm.0.1.7", internalIP: "100.64.0.1", controlPlane: true,
                capacityMilliCPU: 20000, allocatableMilliCPU: 19000,
                capacityMemoryBytes: 64 * 1_073_741_824, allocatableMemoryBytes: 60 * 1_073_741_824),
            ClusterNode(
                name: "mac-b", ready: false, kubeletVersion: "v1.36.2+k3sm.0.1.6", internalIP: "100.64.1.1", controlPlane: false,
                capacityMilliCPU: 8000, allocatableMilliCPU: 7500,
                capacityMemoryBytes: 8 * 1_073_741_824, allocatableMemoryBytes: 6 * 1_073_741_824),
        ])
        #expect(nodes[0].k3smRelease == SemanticVersion("0.1.7"))
    }

    @Test("unparseable fields are unknown, not a failure")
    func tolerant() throws {
        let json = """
        {"kind":"NodeList","items":[{"metadata":{"name":"n1","labels":"x"},"status":{"capacity":{"cpu":"lots","memory":7},
        "allocatable":{"cpu":"-1","memory":"1e400"},"conditions":[{"type":"Ready"}],"nodeInfo":{"kubeletVersion":""},"addresses":"x"}}]}
        """
        #expect(try Nodes.decode(Data(json.utf8)) == [ClusterNode(name: "n1", ready: false)])
    }

    @Test("a list of another kind is refused by name", arguments: [
        (#"{"kind":"PodList","items":[]}"#, NodesDecodeError.notANodeList("PodList")),
        (#"{"kind":"List","items":[{"kind":"Pod"}]}"#, NodesDecodeError.notANodeList("List")),
        ("not json", NodesDecodeError.malformed),
        (#"{"kind":"NodeList"}"#, NodesDecodeError.malformed),
    ])
    func refused(_ json: String, _ want: NodesDecodeError) {
        #expect(throws: want) { try Nodes.decode(Data(json.utf8)) }
    }

    @Test("a pod carries its node name only when it is valid")
    func podNodeName() throws {
        let pods = try Workloads.decode(try fixture("kubectl_pods_two_nodes.json")).pods
        #expect(Dictionary(uniqueKeysWithValues: pods.map { ($0.name, $0.nodeName ?? "-") }) == [
            "web-a": "mac-a", "web-b": "mac-a", "linux-a": "mac-a", "job-done": "mac-a", "api-b": "mac-b", "pending": "-",
        ])
    }
}
