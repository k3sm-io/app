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

@Suite("metrics-server node and pod usage")
struct MetricsTests {
    static let t0 = Date(timeIntervalSince1970: 1_000_000)

    /// The two-node list beside a metrics list that carries only one of them.
    static func sampledState() throws -> (MetricsState, [ClusterNode]) {
        let nodes = try Nodes.decode(try fixture("kubectl_nodes_two.json"))
        let reading = Metrics.sampled(
            nodes: try fixture("kubectl_metrics_nodes.json"),
            pods: (0, try fixture("kubectl_metrics_pods.json")))
        var state = MetricsState()
        state.apply(reading, at: t0)
        return (state, nodes)
    }

    @Test("node metrics decode and join each node's allocatable for percentages")
    func nodeMetricsDecodeAndPercentages() throws {
        let (state, nodes) = try Self.sampledState()
        let sample = try #require(state.sample)
        // The node with an invalid name is left out; mac-b is not in the list.
        #expect(Set(sample.nodes.keys) == ["mac-a"])
        let a = try #require(sample.nodes["mac-a"])
        #expect(a.cores == 1.425378643)
        #expect(a.memoryBytes == Int64(12_884_901_888))

        // mac-a: 1.43 of 19 allocatable cores, 12 GiB of 60 GiB.
        let load = MetricsDisplay.nodeLoad(named: "mac-a", nodes: nodes, state: state)
        guard case .sampled(let cpu, let memory)? = load else {
            Issue.record("mac-a has a sample: \(String(describing: load))")
            return
        }
        #expect(cpu.text == "1.43 of 19 cores · 8%")
        #expect(cpu.percent == 8)
        #expect(abs((cpu.fraction ?? 0) - 1.425378643 / 19) < 1e-9)
        #expect(memory.text == "12 GB of 60 GB · 20%")
        #expect(memory.percent == 20)
        #expect(abs((memory.fraction ?? 0) - 0.2) < 1e-9)

        // The node missing from the metrics list reads "no metrics yet", never zero.
        #expect(MetricsDisplay.nodeLoad(named: "mac-b", nodes: nodes, state: state) == .noSample)
        #expect(NodeLoad.noSample.text == "no metrics yet")
    }

    @Test("a node whose allocatable is unknown shows the usage without a percentage")
    func noAllocatable() throws {
        let (state, _) = try Self.sampledState()
        let nodes = [ClusterNode(name: "mac-a", ready: true)]
        guard case .sampled(let cpu, let memory)? = MetricsDisplay.nodeLoad(named: "mac-a", nodes: nodes, state: state) else {
            Issue.record("mac-a has a sample")
            return
        }
        #expect(cpu.fraction == nil && cpu.percent == nil)
        #expect(cpu.text == "1.43 cores")
        #expect(memory.text == "12 GB")
    }

    @Test("usage over allocatable shows its real percentage and fills the bar")
    func overAllocatable() {
        let bar = LoadBar.cores(used: 3, allocatable: 2)
        #expect(bar.percent == 150)
        #expect(bar.fraction == 1)
        #expect(bar.text == "3 of 2 cores · 150%")
    }

    @Test("pod metrics sum their containers, keyed like the pod list")
    func podMetrics() throws {
        let (state, _) = try Self.sampledState()
        let pods = try #require(state.sample?.pods)
        let web = try #require(pods["default/web-7d9c"])
        #expect(abs(web.cores - (0.012034567 + 0.000985)) < 1e-12)
        #expect(web.memoryBytes == 49152 * 1024 + 4 * 1024 * 1024)
        #expect(pods["kube-system/coredns-5d78c"]?.cores == 0.002)
    }

    @Test("a pod's inspector rows: its usage and the sample's age, or no metrics yet")
    func podFacts() throws {
        let (state, _) = try Self.sampledState()
        let workloads = try Workloads.decode(try fixture("kubectl_pods_running.json"))
        let pod = try #require(workloads.pods.first)
        let listed = Pod.withName("web-7d9c", namespace: "default", from: pod)
        let facts = MetricsDisplay.podFacts(listed, state: state, now: Self.t0.addingTimeInterval(12))
        #expect(facts.map(\.label) == ["CPU used", "Memory used", "Sampled"])
        #expect(facts[0].value.hasPrefix("0.013 cores"))
        #expect(facts[1].value == "52 MB")
        #expect(facts[2].value == "12 s ago")

        let missing = Pod.withName("gone", namespace: "default", from: pod)
        #expect(MetricsDisplay.podFacts(missing, state: state, now: Self.t0) == [InspectorFact("Load", "no metrics yet")])
        #expect(MetricsDisplay.podFacts(listed, state: MetricsState(), now: Self.t0).isEmpty)
    }

    @Test("a list of another kind, or not JSON, is a failed read that keeps the last sample")
    func notAMetricsList() throws {
        var (state, _) = try Self.sampledState()
        let before = state.sample
        let pods = try fixture("kubectl_metrics_pods.json")
        state.apply(Metrics.sampled(nodes: pods, pods: nil), at: Self.t0.addingTimeInterval(15))
        #expect(state.sample == before)
        #expect(state.sampledAt == Self.t0)
        #expect(state.lastError == "kubectl returned a PodMetricsList, not node metrics")
        #expect(Metrics.sampled(nodes: Data("nope".utf8), pods: nil) == .failed("the node metrics could not be read"))
    }

    @Test("a failed pod read keeps the nodes and leaves the pods unknown")
    func podReadFailed() throws {
        let reading = Metrics.sampled(nodes: try fixture("kubectl_metrics_nodes.json"), pods: (1, Data()))
        guard case .sampled(let sample) = reading else {
            Issue.record("the nodes decoded")
            return
        }
        #expect(sample.nodes["mac-a"] != nil)
        #expect(sample.pods == nil)
    }

    @Test("an absent API hides the rows and says why, from the APIService or the read's error")
    func absentAPI() throws {
        let unavailable = Metrics.unavailable(nodesExit: 1, apiService: (0, try fixture("kubectl_apiservice_metrics_unavailable.json")))
        #expect(unavailable == .absent(
            "The metrics API is unavailable: MissingEndpoints: endpoints for service/metrics-server in \"kube-system\" have no addresses with port name \"https\""))
        let notFound = Metrics.unavailable(
            nodesExit: 1,
            apiService: (1, Data("Error from server (NotFound): apiservices.apiregistration.k8s.io \"v1beta1.metrics.k8s.io\" not found\n".utf8)))
        #expect(notFound == .absent(Metrics.notInstalled))
        // The API is available, so this read's failure is transient.
        let available = Metrics.unavailable(nodesExit: 1, apiService: (0, try fixture("kubectl_apiservice_metrics_available.json")))
        #expect(available == .failed("the metrics read exited 1"))
        // The APIService read itself failed some other way: its own text.
        let refused = Metrics.unavailable(nodesExit: 1, apiService: (1, Data("The connection to the server was refused\u{1b}[0m\n".utf8)))
        #expect(refused == .failed("The connection to the server was refused [0m"))
        #expect(Metrics.unavailable(nodesExit: 1, apiService: nil) == .failed("the metrics read exited 1"))

        var (state, nodes) = try Self.sampledState()
        state.apply(unavailable, at: Self.t0.addingTimeInterval(15))
        #expect(state.sample == nil)
        #expect(state.history.isEmpty)
        #expect(MetricsDisplay.nodeLoad(named: "mac-a", nodes: nodes, state: state) == nil)
        guard case .absent(let why) = unavailable else { return }
        #expect(state.absent == why)
        #expect(MetricsDisplay.note(state, now: Self.t0.addingTimeInterval(20)) == why)
        // A later sample brings the rows back.
        state.apply(Metrics.sampled(nodes: try fixture("kubectl_metrics_nodes.json"), pods: nil), at: Self.t0.addingTimeInterval(30))
        #expect(state.absent == nil)
        #expect(MetricsDisplay.nodeLoad(named: "mac-a", nodes: nodes, state: state) != nil)
    }

    @Test("the note says how old the sample is, and when the last read failed")
    func note() throws {
        var (state, _) = try Self.sampledState()
        #expect(MetricsDisplay.note(MetricsState(), now: Self.t0) == nil)
        #expect(MetricsDisplay.note(state, now: Self.t0.addingTimeInterval(12)) == "Used, from metrics-server, 12 s ago.")
        state.apply(.failed("the k3sm CLI did not answer"), at: Self.t0.addingTimeInterval(15))
        #expect(MetricsDisplay.note(state, now: Self.t0.addingTimeInterval(130))
            == "Used, from metrics-server, 2 min ago. The last read failed: the k3sm CLI did not answer")
    }

    @Test("ages", arguments: [(0.0, "just now"), (4.9, "just now"), (12, "12 s ago"), (59, "59 s ago"), (60, "1 min ago"), (7200, "2 h ago"), (-5, "just now")])
    func ages(_ c: (Double, String)) {
        #expect(MetricsDisplay.age(since: Self.t0, now: Self.t0.addingTimeInterval(c.0)) == c.1)
    }

    @Test("the ring keeps the last few samples per node, oldest first, for a sparkline")
    func ring() throws {
        let nodes = try fixture("kubectl_metrics_nodes.json")
        var state = MetricsState()
        for i in 0..<(MetricsState.historyLength + 3) {
            state.apply(Metrics.sampled(nodes: nodes, pods: nil), at: Self.t0.addingTimeInterval(Double(i) * 15))
        }
        #expect(state.history["mac-a"]?.count == MetricsState.historyLength)
        #expect(state.history["mac-b"] == nil)
        let line = MetricsDisplay.sparkline(named: "mac-a", nodes: try Nodes.decode(try fixture("kubectl_nodes_two.json")), state: state)
        #expect(line.count == MetricsState.historyLength)
        #expect(line.allSatisfy { abs($0 - 1.425378643 / 19) < 1e-9 })
        #expect(MetricsDisplay.sparkline(named: "mac-a", nodes: nil, state: state).isEmpty)
        // A failed read adds no point.
        state.apply(.failed("x"), at: Self.t0.addingTimeInterval(1000))
        #expect(state.history["mac-a"]?.count == MetricsState.historyLength)
    }

    @Test("This Mac's node: the one the report names, else the only node")
    func thisMacNode() throws {
        let report = try StatusReport.decode(try fixture("status_json_running.json"))
        let own = ClusterDisplay.ownNodeName(report)
        #expect(MetricsDisplay.thisMacNode(report: report, nodes: nil) == own)
        #expect(MetricsDisplay.thisMacNode(report: nil, nodes: [ClusterNode(name: "solo", ready: true)]) == "solo")
        #expect(MetricsDisplay.thisMacNode(report: nil, nodes: [ClusterNode(name: "a", ready: true), ClusterNode(name: "b", ready: true)]) == nil)
    }
}

extension Pod {
    /// A copy of `pod` under another name and namespace.
    static func withName(_ name: String, namespace: String, from pod: Pod) -> Pod {
        Pod(name: name, namespace: namespace, uid: pod.uid, image: pod.image, kind: pod.kind, phase: pod.phase,
            health: pod.health, ready: pod.ready, restarts: pod.restarts, ports: pod.ports, owner: pod.owner,
            created: pod.created, cpuRequest: pod.cpuRequest, memoryRequest: pod.memoryRequest, nodeName: pod.nodeName)
    }
}

@Suite("the metrics poll's cadence")
struct MetricsScheduleTests {
    static let t0 = Date(timeIntervalSince1970: 2_000_000)

    @Test("the reads are fixed, read-only and go through the bundled kubectl")
    func arguments() {
        #expect(K3smCLI.nodeMetricsArguments == ["kubectl", "get", "--raw", "/apis/metrics.k8s.io/v1beta1/nodes"])
        #expect(K3smCLI.podMetricsArguments == ["kubectl", "get", "--raw", "/apis/metrics.k8s.io/v1beta1/pods"])
        #expect(K3smCLI.metricsAPIServiceArguments == ["kubectl", "get", "apiservice", "v1beta1.metrics.k8s.io", "-o", "json"])
        #expect(OutputLimit.metrics == 4 << 20)
    }

    @Test("15 s between reads, never faster, 60 s while the API is absent")
    func cadence() {
        #expect(MetricsSchedule.interval == .seconds(15))
        #expect(MetricsSchedule.interval >= PollSchedule.objectsInterval)
        #expect(MetricsSchedule.absentInterval == .seconds(60))
    }

    @Test("a visible console reads at once, then when the interval has passed since the last read")
    func dueWhileVisible() {
        #expect(MetricsSchedule.step(visible: true, lastRead: nil, now: Self.t0, absent: false) == .read)
        #expect(MetricsSchedule.step(visible: true, lastRead: Self.t0, now: Self.t0.addingTimeInterval(5), absent: false) == .wait(.seconds(10)))
        #expect(MetricsSchedule.step(visible: true, lastRead: Self.t0, now: Self.t0.addingTimeInterval(15), absent: false) == .read)
        #expect(MetricsSchedule.step(visible: true, lastRead: Self.t0, now: Self.t0.addingTimeInterval(20), absent: true) == .wait(.seconds(40)))
        #expect(MetricsSchedule.step(visible: true, lastRead: Self.t0, now: Self.t0.addingTimeInterval(60), absent: true) == .read)
        // A clock that went back waits one whole interval, never reads at once.
        #expect(MetricsSchedule.step(visible: true, lastRead: Self.t0, now: Self.t0.addingTimeInterval(-30), absent: false) == .wait(.seconds(15)))
    }

    @Test("a hidden window never reads; it looks again shortly")
    func hidden() {
        #expect(MetricsSchedule.step(visible: false, lastRead: nil, now: Self.t0, absent: false) == .wait(MetricsSchedule.hiddenRecheck))
        #expect(MetricsSchedule.step(visible: false, lastRead: Self.t0, now: Self.t0.addingTimeInterval(600), absent: false) == .wait(MetricsSchedule.hiddenRecheck))
    }

    @Test("a reopened console does not read again before the interval")
    func reopened() {
        // Closed 4 s after a read and reopened 3 s later: 8 s still to wait.
        #expect(MetricsSchedule.step(visible: true, lastRead: Self.t0, now: Self.t0.addingTimeInterval(7), absent: false) == .wait(.seconds(8)))
    }
}

@Suite("Kubernetes quantities, the metrics grammar")
struct MetricsQuantityTests {
    @Test("CPU", arguments: [
        ("1425378643n", 1.425378643), ("250000u", 0.25), ("985u", 0.000985), ("500m", 0.5),
        ("2", 2.0), ("0", 0.0), ("0n", 0.0), ("1.5", 1.5),
    ])
    func cores(_ c: (String, Double)) {
        #expect(Quantity.cores(c.0) == c.1)
    }

    @Test("memory", arguments: [
        ("12582912Ki", Int64(12_884_901_888)), ("48Mi", Int64(50_331_648)), ("2Gi", Int64(2_147_483_648)),
        ("1Ti", Int64(1_099_511_627_776)), ("500k", Int64(500_000)), ("3M", Int64(3_000_000)),
        ("4G", Int64(4_000_000_000)), ("123456", Int64(123_456)),
    ])
    func memory(_ c: (String, Int64)) {
        #expect(Quantity.bytes(c.0) == c.1)
    }

    @Test("garbage and negatives are nil", arguments: ["", "n", "m", "-5n", "12x", "nanu", "infm", "5 m"])
    func garbage(_ s: String) {
        #expect(Quantity.cores(s) == nil)
    }
}
