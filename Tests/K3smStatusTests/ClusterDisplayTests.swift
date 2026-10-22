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

    @Test("the cluster's shape", arguments: [
        ("single", report(workers: [], node: nil, workloads: nil) as StatusReport?, ClusterShape.single),
        ("server with two workers", report(workers: [
            StatusWorker(name: "mac-b", role: "agent", version: nil), StatusWorker(name: "mac-c", role: "agent", version: nil),
        ], node: nil, workloads: nil), .serverWithWorkers(macs: 3)),
        ("worker", report(role: "agent", workers: nil, node: nil, workloads: nil), .worker),
        ("server, workers unknown", report(workers: nil, node: nil, workloads: nil), .unknown),
        ("no report", nil, .unknown),
    ])
    func shape(name: String, report: StatusReport?, want: ClusterShape) {
        #expect(ClusterDisplay.shape(of: report) == want, "\(name)")
    }

    @Test("the panel's title follows the shape", arguments: reportCases)
    func titleFollowsShape(_ c: Case) {
        let want: String
        switch ClusterDisplay.shape(of: c.report) {
        case .single: want = ClusterDisplay.singleTitle
        case .serverWithWorkers: want = ClusterDisplay.clusterTitle
        case .worker: want = ClusterDisplay.workerTitle
        case .unknown: want = ClusterDisplay.unknownTitle
        }
        #expect(c.want.title == want)
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
                memory: ClusterUsage(requested: 3.25 * 1_073_741_824, allocatable: 60 * 1_073_741_824, text: "3.2 GB of 60 GB"),
                running: 3),
            ClusterNodeRow(
                name: "mac-b", role: "agent", ready: "Not ready", isReady: false, version: "0.1.6", thisMac: false,
                cores: ClusterUsage(requested: 1.5, allocatable: 7.5, text: "1.5 of 7.5"),
                memory: ClusterUsage(requested: 512 * 1_048_576, allocatable: 6 * 1_073_741_824, text: "512 MB of 6.0 GB"),
                running: 1),
        ])
        #expect(got.cores?.text == "5 of 26.5")
        #expect(got.versions == "versions differ")
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
        #expect(got.nodes.map(\.running) == [1, 3])
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
        #expect(got.nodes.isEmpty && got.cores == nil && got.memory == nil && got.versions == nil)
        #expect(got.line == "2 Macs · 1/2 nodes ready · 4 running · 1 vm")
    }

    @MainActor
    @Test("a node list caught short of the report keeps the two views")
    func nodeListShortOfReport() throws {
        // The node watch's replay as the panel saw it: the first node's
        // frame arrived and the replay settled before the second's did.
        let clock = VirtualClock()
        let launcher = FakeLauncher(clock: clock) { _, _ in
            FakeScript(lines: [watchLine("ADDED", uid: "u-a", name: "mac-a", kind: "Node", namespace: nil)])
        }
        let stream = WatchStream(kind: .nodes, launcher: launcher, clock: clock, jitter: { 0.5 })
        stream.start()
        clock.advance(by: .milliseconds(300))
        #expect(stream.state == .live)
        guard case .value(let read) = NodeListRead.tabResult(exitCode: 0, stdout: try #require(stream.liveList)) else {
            Issue.record("the streamed list did not decode")
            return
        }
        #expect(read.nodes.map(\.name) == ["mac-a"])

        let (report, _, pods) = try Self.twoNodes()
        let got = ClusterDisplay.summary(of: report, nodes: read.nodes, pods: pods)
        #expect(got.title == "Cluster")
        #expect(got.nodeCount == 2)
        #expect(PanelMode.showsSwitch(nodeCount: got.nodeCount))
        #expect(PanelMode.effective(chosen: .cluster, nodeCount: got.nodeCount) == .cluster)
        #expect(got.note == ClusterDisplay.othersUnknown)
        #expect(got.nodes.map(\.name) == ["mac-a"])
    }

    @Test("the node count: the most any source names, never under one", arguments: [
        ("no report, no list", nil as [StatusWorker]?, nil as Int?, 1),
        ("workers unknown, list of two", nil, 2, 2),
        ("one worker, list unknown", [StatusWorker(name: "b", role: "agent")], nil, 2),
        ("one worker, list of one", [StatusWorker(name: "b", role: "agent")], 1, 2),
        ("one worker, empty list", [StatusWorker(name: "b", role: "agent")], 0, 2),
        ("one worker, list of three", [StatusWorker(name: "b", role: "agent")], 3, 3),
        ("no workers, list of one", [], 1, 1),
        ("no workers, empty list", [], 0, 1),
    ])
    func nodeCount(_ name: String, _ workers: [StatusWorker]?, _ listed: Int?, _ want: Int) {
        let report = Self.report(workers: workers, node: nil, workloads: nil)
        let nodes = listed.map { n in (0..<n).map { ClusterNode(name: "n\($0)", ready: true) } }
        #expect(ClusterDisplay.nodeCount(report: report, nodes: nodes) == want, "\(name)")
        #expect(ClusterDisplay.summary(of: report, nodes: nodes, pods: nil).nodeCount == want, "\(name)")
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
        #expect(got.versions == (stat.hasPrefix("versions") ? stat : nil))
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

    @Test("tiles: one node with its lists")
    func tilesSingleNode() throws {
        let (_, nodes, pods) = try Self.twoNodes()
        let report = Self.report(workers: [], node: "1/1 nodes ready · mac-a kubelet v1.36.2", workloads: nil)
        let got = ClusterDisplay.summary(of: report, nodes: nodes.filter { $0.name == "mac-a" }, pods: pods.filter { $0.nodeName != "mac-b" })
        #expect(ClusterDisplay.tiles(for: got) == [
            PanelTile(label: "nodes ready", value: "1/1"),
            PanelTile(label: "pods running", value: "3"),
            PanelTile(label: "cores requested", value: "3.5", detail: "of 19"),
            PanelTile(label: "memory requested", value: "3.2 GB", detail: "of 60 GB"),
        ])
        #expect(got.versions == nil)
    }

    @Test("tiles: two nodes, one not ready, versions differing")
    func tilesTwoNodesDiffer() throws {
        let (report, nodes, pods) = try Self.twoNodes()
        let got = ClusterDisplay.summary(of: report, nodes: nodes, pods: pods)
        #expect(ClusterDisplay.tiles(for: got) == [
            PanelTile(label: "nodes ready", value: "1/2"),
            PanelTile(label: "pods running", value: "4"),
            PanelTile(label: "cores requested", value: "5", detail: "of 26.5"),
            PanelTile(label: "memory requested", value: "3.8 GB", detail: "of 66 GB"),
        ])
        #expect(got.versions == "versions differ")
    }

    @Test("tiles: two ready nodes on one release show the Mac count")
    func tilesTwoNodesAgree() throws {
        let (report, nodes, pods) = try Self.twoNodes()
        let same = nodes.map {
            ClusterNode(name: $0.name, ready: true, kubeletVersion: "v1.36.2+k3sm.0.1.7", controlPlane: $0.controlPlane,
                        allocatableMilliCPU: $0.allocatableMilliCPU, allocatableMemoryBytes: $0.allocatableMemoryBytes)
        }
        let got = ClusterDisplay.summary(of: report, nodes: same, pods: pods)
        #expect(ClusterDisplay.tiles(for: got).map(\.label) == ["Macs", "pods running", "cores requested", "memory requested"])
        #expect(ClusterDisplay.tiles(for: got).first == PanelTile(label: "Macs", value: "2"))
        #expect(got.versions == nil)
        #expect(got.nodes.map(\.version) == [nil, nil])
    }

    @Test("tiles: no report and no lists, nothing to show")
    func tilesNoReport() {
        #expect(ClusterDisplay.tiles(for: ClusterDisplay.summary(of: nil, nodes: nil, pods: nil)).isEmpty)
    }

    @Test("tiles: a report alone gives the counts and no requests")
    func tilesReportOnly() {
        let report = Self.report(workers: [StatusWorker(name: "b", role: "agent")], node: "2/2 nodes ready · a kubelet v1", workloads: "6 running")
        #expect(ClusterDisplay.tiles(for: ClusterDisplay.summary(of: report, nodes: nil, pods: nil)) == [
            PanelTile(label: "Macs", value: "2"), PanelTile(label: "pods running", value: "6"),
        ])
    }

    @Test("tiles: a hostile core request saturates, a hostile label is flattened")
    func tilesHostile() throws {
        let (report, nodes, _) = try Self.twoNodes()
        var pod = try HostRequestsTests.decoded([["1e308"], ["1e308"]])
        pod = pod.map {
            Pod(name: $0.name, namespace: $0.namespace, uid: $0.uid, image: $0.image, kind: $0.kind, phase: $0.phase,
                health: $0.health, ready: $0.ready, restarts: $0.restarts, ports: $0.ports, owner: $0.owner, created: $0.created,
                cpuRequest: $0.cpuRequest, memoryRequest: $0.memoryRequest, nodeName: "mac-a")
        }
        let got = ClusterDisplay.tiles(for: ClusterDisplay.summary(of: report, nodes: nodes, pods: pod))
        #expect(got.first { $0.label == "cores requested" } == PanelTile(label: "cores requested", value: "1000000+", detail: "of 26.5"))
        let flat = ClusterDisplay.tiles(for: ClusterDisplay.summary(
            of: Self.report(workers: [], node: "1/1 nodes ready", workloads: "2 run\u{1B}ning"), nodes: nil, pods: nil))
        #expect(flat == [PanelTile(label: "nodes ready", value: "1/1")])
        #expect(PanelTile(label: "a\nb", value: "1\u{1B}2", detail: "of\r3") == PanelTile(label: "a b", value: "1 2", detail: "of 3"))
    }

    @Test("tiles: a byte request near Int64 beside a normal one saturates instead of vanishing")
    func tilesHostileMemory() throws {
        let (report, nodes, _) = try Self.twoNodes()
        let pods = [testPod("huge", bytes: 9_223_372_036_000_000_000), testPod("ok", bytes: 1 << 30)].map {
            Pod(name: $0.name, namespace: $0.namespace, uid: $0.uid, image: $0.image, kind: $0.kind, phase: $0.phase,
                health: $0.health, ready: $0.ready, restarts: $0.restarts, ports: $0.ports, owner: $0.owner, created: $0.created,
                cpuRequest: $0.cpuRequest, memoryRequest: $0.memoryRequest, nodeName: "mac-a")
        }
        let got = ClusterDisplay.summary(of: report, nodes: nodes, pods: pods)
        let capped = WorkloadsDisplay.bytes(.max)
        #expect(got.memory?.requested == Double(Int64.max))
        #expect(ClusterDisplay.tiles(for: got).first { $0.label == "memory requested" }
            == PanelTile(label: "memory requested", value: capped, detail: "of 66 GB"))
        #expect(got.nodes.first?.memory?.text == "\(capped) of 60 GB")
        #expect(got.nodes.last?.memory?.text == "0 GB of 6.0 GB")
    }

    @Test("tiles: this Mac")
    func macTiles() {
        let got = ClusterDisplay.macTiles(
            cores: 10, memoryBytes: 16 << 30, dataRootUsed: 120 << 30, dataRootSize: 500 << 30, pods: 4,
            coresUsed: 3.25, memoryUsed: 5 << 30)
        #expect(got == [
            PanelTile(label: "cores used", value: "3.25", detail: "of 10 cores"),
            PanelTile(label: "pod memory used", value: "5.0 GB", detail: "of 16 GB"),
            PanelTile(label: "data root", value: "120 GB", detail: "of 500 GB"),
            PanelTile(label: "pods on this Mac", value: "4"),
        ])
        let idle = ClusterDisplay.macTiles(
            cores: 0, memoryBytes: 0, dataRootUsed: 0, dataRootSize: 0, pods: 1,
            coresUsed: WorkloadsDisplay.maxCores, memoryUsed: 0)
        #expect(idle == [
            PanelTile(label: "cores used", value: "1000000+", detail: "cores"),
            PanelTile(label: "pod memory used", value: "0 MB"),
            PanelTile(label: "data root", value: "0 GB"),
            PanelTile(label: "pod on this Mac", value: "1"),
        ])
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

    @Test("the heading shows only without the tabs", arguments: [
        (0, true), (1, true), (2, false), (3, false),
    ] as [(Int, Bool)])
    func heading(_ count: Int, _ want: Bool) {
        #expect(PanelMode.showsHeading(nodeCount: count) == want)
        #expect(PanelMode.showsHeading(nodeCount: count) != PanelMode.showsSwitch(nodeCount: count))
    }
}

@Suite("the node list")
struct NodesTests {
    @Test("two nodes decode tolerantly, an invalid name is left out")
    func twoNodes() throws {
        // The inspector's fields (`NodesTabTests`) are compared there; here the panel's.
        let nodes = try Nodes.decode(try fixture("kubectl_nodes_two.json")).map {
            ClusterNode(name: $0.name, ready: $0.ready, kubeletVersion: $0.kubeletVersion, internalIP: $0.internalIP,
                        controlPlane: $0.controlPlane, capacityMilliCPU: $0.capacityMilliCPU,
                        allocatableMilliCPU: $0.allocatableMilliCPU, capacityMemoryBytes: $0.capacityMemoryBytes,
                        allocatableMemoryBytes: $0.allocatableMemoryBytes)
        }
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
        var want = ClusterNode(name: "n1", ready: false)
        want.conditions = [NodeCondition(type: "Ready", status: "Unknown")]
        #expect(try Nodes.decode(Data(json.utf8)) == [want])
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

/// A pod with only the fields the console's arithmetic, search and
/// selection read.
func testPod(_ name: String, namespace: String = "default", image: String = "registry.local/app:1",
             cores: Double? = nil, bytes: Int64? = nil, node: String? = nil) -> Pod {
    Pod(name: name, namespace: namespace, uid: "\(namespace)-\(name)", image: image, kind: .nativeProcess,
        phase: "Running", health: .running, ready: true, restarts: 0, ports: [], owner: nil, created: nil,
        cpuRequest: cores, memoryRequest: bytes, nodeName: node)
}

@Suite("what the pods ask of this Mac")
struct HostRequestsTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let pods: [Pod]
        let want: PodRequests
        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(name: "no pods", pods: [], want: PodRequests(cores: 0, memoryBytes: 0)),
        Case(name: "no pod requests anything", pods: [testPod("a"), testPod("b")], want: PodRequests(cores: 0, memoryBytes: 0)),
        Case(
            name: "requests summed over pods",
            pods: [testPod("a", cores: 0.25, bytes: 256 << 20), testPod("b", cores: 1.5, bytes: 1 << 30)],
            want: PodRequests(cores: 1.75, memoryBytes: (256 << 20) + (1 << 30))),
        Case(
            name: "a pod without a request adds nothing",
            pods: [testPod("a", cores: 2), testPod("b", bytes: 512 << 20), testPod("c")],
            want: PodRequests(cores: 2, memoryBytes: 512 << 20)),
        Case(
            name: "bytes past Int64 saturate instead of trapping",
            pods: [testPod("a", bytes: .max), testPod("b", bytes: 1)],
            want: PodRequests(cores: 0, memoryBytes: .max)),
    ]

    @Test("cores and bytes are summed over the pods' requests", arguments: cases)
    func hostArithmeticSumsPodRequests(_ c: Case) {
        #expect(ClusterDisplay.requests(of: c.pods) == c.want)
    }

    struct CPUCase: Sendable, CustomTestStringConvertible {
        let name: String
        /// Each pod's containers' cpu requests, as the API served them.
        let pods: [[String]]
        let wantCores: Double
        let wantSum: String
        let wantRows: [String]
        var testDescription: String { name }
    }

    static func decoded(_ pods: [[String]]) throws -> [Pod] {
        let items = pods.enumerated().map { i, cpus in
            let containers = cpus.map { #"{"name":"c","image":"x","resources":{"requests":{"cpu":"\#($0)"}}}"# }
            return #"{"metadata":{"name":"p\#(i)","namespace":"default"},"spec":{"containers":[\#(containers.joined(separator: ","))]},"status":{"phase":"Running"}}"#
        }
        return try Workloads.decode(Data(#"{"kind":"PodList","items":[\#(items.joined(separator: ","))]}"#.utf8)).pods
    }

    static let cpuCases: [CPUCase] = [
        CPUCase(name: "ordinary requests", pods: [["500m"], ["1.5"]], wantCores: 2, wantSum: "2", wantRows: ["0.50", "1.5"]),
        CPUCase(name: "2^63 cores saturates", pods: [["9223372036854775807"]],
                wantCores: WorkloadsDisplay.maxCores, wantSum: "1000000+", wantRows: ["1000000+"]),
        CPUCase(name: "two pods at 1e308 saturate instead of summing to infinity", pods: [["1e308"], ["1e308"]],
                wantCores: WorkloadsDisplay.maxCores, wantSum: "1000000+", wantRows: ["1000000+", "1000000+"]),
        CPUCase(name: "one pod whose containers sum to infinity", pods: [["1e308", "1e308"]],
                wantCores: WorkloadsDisplay.maxCores, wantSum: "1000000+", wantRows: ["1000000+"]),
        CPUCase(name: "a negative quantity is no request", pods: [["-1"], ["250m"]], wantCores: 0.25, wantSum: "0.25", wantRows: ["", "0.25"]),
    ]

    @Test("hostile cpu requests saturate and render a capped figure", arguments: cpuCases)
    func hostileCPURequests(_ c: CPUCase) throws {
        let pods = try Self.decoded(c.pods)
        let sum = ClusterDisplay.requests(of: pods).cores
        #expect(sum == c.wantCores)
        #expect(sum.isFinite)
        #expect(WorkloadsDisplay.cores(sum) == c.wantSum)
        #expect(pods.map { WorkloadsDisplay.cores($0.cpuRequest) } == c.wantRows)
    }

    @Test("a negative, NaN or infinite core value built outside the decoder never traps")
    func coreValuesOutsideTheDecoder() {
        let pods = [testPod("a", cores: -2), testPod("b", cores: .nan), testPod("c", cores: .infinity), testPod("d", cores: 1)]
        #expect(ClusterDisplay.requests(of: pods).cores == WorkloadsDisplay.maxCores)
        #expect(ClusterDisplay.requests(of: [pods[0], pods[1], pods[3]]).cores == 1)
        #expect(WorkloadsDisplay.cores(-2) == "")
        #expect(WorkloadsDisplay.cores(.nan) == "")
        #expect(WorkloadsDisplay.cores(.infinity) == "1000000+")
        #expect(WorkloadsDisplay.cores(9_223_372_036_854_775_807) == "1000000+")
    }
}

@Suite("the panel's stacked load bars: requested behind used")
struct LoadStackTests {
    static let cores = ClusterUsage(requested: 3.5, allocatable: 19, text: "3.5 of 19")
    static let memory = ClusterUsage(requested: 3.2e9, allocatable: 60e9, text: "3.2 GB of 60 GB")

    static func row(cores: ClusterUsage? = cores, memory: ClusterUsage? = memory) -> ClusterNodeRow {
        ClusterNodeRow(name: "mac-a", role: "server", ready: "Ready", isReady: true, version: nil, thisMac: true,
                       cores: cores, memory: memory, running: 3)
    }

    static func close(_ a: Double?, _ b: Double) -> Bool { a.map { abs($0 - b) < 1e-9 } ?? false }

    @Test("both known: the request as the band, the use over it, used first in the figures")
    func bothKnown() {
        let used = LoadBar.cores(used: 1.43, allocatable: 19)
        let stack = LoadStack.cores(requested: Self.cores, used: used)
        #expect(Self.close(stack.requested, 3.5 / 19))
        #expect(Self.close(stack.used, 1.43 / 19))
        #expect(stack.parts == [.requested, .used])
        #expect(stack.lines == ["1.43 used of 19 cores", "3.5 requested"])
        #expect(stack.lines(titled: "CPU") == ["CPU 1.43 used of 19 cores", "3.5 requested"])

        let bytes = LoadStack.memory(requested: Self.memory, used: .memory(used: 12_000_000_000, allocatable: 60_000_000_000))
        #expect(bytes.lines == ["\(MetricsDisplay.bytes(12_000_000_000)) used of \(MetricsDisplay.bytes(60_000_000_000))", "3.2 GB requested"])
    }

    @Test("the shares are clamped: never below 0, use never past the whole bar")
    func sharesClamped() {
        let over = LoadStack.cores(requested: ClusterUsage(requested: 40, allocatable: 19, text: "40 of 19"),
                                   used: .cores(used: 38, allocatable: 19))
        #expect(over.requested == 1)
        #expect(over.used == 1)
        #expect(over.lines.first == "38 used of 19 cores")

        let built = LoadStack(requested: -0.5, used: 1.7, lines: [])
        #expect(built.requested == 0)
        #expect(built.used == 1)
        let nan = LoadStack(requested: .nan, used: .infinity, lines: [])
        #expect(nan.requested == 0)
        #expect(nan.used == 0)

        let hostile = LoadStack.cores(requested: ClusterUsage(requested: .nan, allocatable: 19, text: "? of 19"), used: nil)
        #expect(hostile.requested == nil)
        let noTotal = LoadStack.cores(requested: ClusterUsage(requested: 2, allocatable: 0, text: "2 of 0"), used: nil)
        #expect(noTotal.requested == nil)
        #expect(noTotal.parts.isEmpty)
    }

    @Test("only the request known: the band alone, the key names only Requested")
    func onlyRequested() {
        let bars = NodeBars.of(row: Self.row(), load: nil)
        #expect(bars.cpu.parts == [.requested])
        #expect(bars.cpu.used == nil)
        #expect(bars.cpu.lines == ["3.5 requested of 19 cores"])
        #expect(bars.memory.lines == ["3.2 GB requested of 60 GB"])
        #expect(bars.note == nil)
        #expect(LoadStack.key(bars.stacks) == [.requested])
    }

    @Test("only the use known: the solid part alone, the key names only Used")
    func onlyUsed() {
        let load = NodeLoad.sampled(cpu: .cores(used: 1.43, allocatable: 19), memory: .memory(used: 12_000_000_000, allocatable: 60_000_000_000))
        let bars = NodeBars.of(row: nil, load: load)
        #expect(bars.cpu.parts == [.used])
        #expect(bars.cpu.requested == nil)
        #expect(bars.cpu.lines == ["1.43 used of 19 cores"])
        #expect(LoadStack.key(bars.stacks) == [.used])

        // A use without an allocatable has a figure but no share: nothing drawn, no key.
        let unbounded = LoadStack.cores(requested: nil, used: .cores(used: 1.43, allocatable: nil))
        #expect(unbounded.parts.isEmpty)
        #expect(unbounded.lines == ["1.43 used"])
        #expect(LoadStack.key([unbounded]).isEmpty)
    }

    @Test("a node the sample lacks keeps its request and says no metrics yet")
    func noSample() {
        let bars = NodeBars.of(row: Self.row(), load: .noSample)
        #expect(bars.note == MetricsDisplay.noMetricsYet)
        #expect(bars.cpu.parts == [.requested])
        #expect(bars.hasFigures)
        let unknown = NodeBars.of(row: Self.row(cores: nil, memory: nil), load: nil)
        #expect(!unknown.hasFigures)
        #expect(unknown.note == nil)
        #expect(LoadStack.key(unknown.stacks).isEmpty)
    }

    @Test("the key covers the block: each part any bar draws, Requested first")
    func keyCoversBlock() {
        let requestedOnly = LoadStack(requested: 0.2, used: nil, lines: ["x"])
        let usedOnly = LoadStack(requested: nil, used: 0.1, lines: ["y"])
        #expect(LoadStack.key([usedOnly, requestedOnly]) == [.requested, .used])
        #expect(LoadStack.key([requestedOnly, requestedOnly]) == [.requested])
        #expect(LoadStack.key([]) == [])
        #expect(LoadPart.allCases.map(\.label) == ["Requested", "Used"])
    }

    @Test("the footnotes the bars and key now say are gone from the panel")
    func footnotesRemoved() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for file in ["Sources/K3smApp/MacPanel.swift", "Sources/K3smApp/LoadViews.swift"] {
            let source = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            #expect(!source.contains("Requested by pods, not used."), "\(file)")
            #expect(source.contains("LoadKey("), "\(file) draws the key")
        }
        // The absent API's reason (the metrics-server hint) is not a panel note.
        var state = MetricsState()
        state.apply(.absent(Metrics.notInstalled), at: Date(timeIntervalSince1970: 0))
        #expect(MetricsDisplay.note(state) == nil)
        #expect(state.absent == Metrics.notInstalled)
    }
}
