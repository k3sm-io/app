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

    @Test("an absent API hides the rows and keeps why, from the APIService or the read's error")
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
        // The panel draws the requests alone then, and no footnote says why.
        #expect(MetricsDisplay.note(state, now: Self.t0.addingTimeInterval(20)) == nil)
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
        #expect(K3smCLI.metricsArguments == ["kubectl", "get", "nodes.metrics.k8s.io,pods.metrics.k8s.io", "-A", "-o", "json"])
        #expect(K3smCLI.metricsAPIServiceArguments == ["kubectl", "get", "apiservice", "v1beta1.metrics.k8s.io", "-o", "json"])
        #expect(OutputLimit.metrics == 16 << 20)
    }

    /// A `kubectl get ... -o json` List of `nodes` NodeMetrics and `pods`
    /// PodMetrics (two containers each), printed indented as kubectl does.
    static func combinedList(nodes: Int, pods: Int) throws -> Data {
        var items: [[String: Any]] = (0..<nodes).map { i in
            ["apiVersion": "metrics.k8s.io/v1beta1", "kind": "NodeMetrics",
             "metadata": ["name": "mac-\(i)", "creationTimestamp": "2026-10-16T09:59:58Z",
                          "labels": ["kubernetes.io/hostname": "mac-\(i)", "kubernetes.io/os": "darwin"]],
             "timestamp": "2026-10-16T09:59:47Z", "window": "10.071s",
             "usage": ["cpu": "1425378643n", "memory": "12582912Ki"]]
        }
        items += (0..<pods).map { i in
            ["apiVersion": "metrics.k8s.io/v1beta1", "kind": "PodMetrics",
             "metadata": ["name": "workload-7d9c5f8b6-x\(i)", "namespace": "namespace-\(i % 40)",
                          "creationTimestamp": "2026-10-16T09:59:58Z", "labels": ["app": "workload", "pod-template-hash": "7d9c5f8b6"]],
             "timestamp": "2026-10-16T09:59:41Z", "window": "14.512s",
             "containers": [["name": "main", "usage": ["cpu": "12034567n", "memory": "49152Ki"]],
                            ["name": "sidecar", "usage": ["cpu": "985u", "memory": "4Mi"]]]]
        }
        let list: [String: Any] = ["apiVersion": "v1", "kind": "List", "metadata": ["resourceVersion": ""], "items": items]
        return try JSONSerialization.data(withJSONObject: list, options: [.prettyPrinted, .sortedKeys])
    }

    @Test("the one read's limit holds 64 nodes and 10,000 pods printed indented, and decodes them")
    func combinedLimit() throws {
        let data = try Self.combinedList(nodes: 64, pods: 10_000)
        #expect(data.count < OutputLimit.metrics, "\(data.count) bytes")
        // The old per-list limit could not hold this read.
        #expect(data.count > 4 << 20, "\(data.count) bytes")
        guard case .sampled(let sample) = Metrics.sampled(combined: data) else {
            Issue.record("the list decodes")
            return
        }
        #expect(sample.nodes.count == 64)
        #expect(sample.pods?.count == 10_000)
    }

    @Test("the one read: nodes and pods interleaved, a bad name skipped, an unparsed quantity unknown")
    func combinedParse() throws {
        guard case .sampled(let sample) = Metrics.sampled(combined: try fixture("kubectl_metrics_combined.json")) else {
            Issue.record("the combined list decodes")
            return
        }
        // Not_A_Name, the second node item, is left out.
        #expect(Set(sample.nodes.keys) == ["mac-a"])
        #expect(sample.nodes["mac-a"] == NodeUsage(name: "mac-a", cores: 1.425378643, memoryBytes: 12_884_901_888))
        let pods = try #require(sample.pods)
        #expect(Set(pods.keys) == ["default/web-7d9c", "kube-system/coredns-5d78c"])
        #expect(abs((pods["default/web-7d9c"]?.cores ?? 0) - (0.012034567 + 0.000985)) < 1e-12)
        #expect(pods["kube-system/coredns-5d78c"] == PodUsage(cores: 0.002, memoryBytes: 18432 * 1024))
        // The same samples as the two lists read apart.
        #expect(Metrics.sampled(combined: try fixture("kubectl_metrics_combined.json")) == Metrics.sampled(
            nodes: try fixture("kubectl_metrics_nodes.json"), pods: (0, try fixture("kubectl_metrics_pods.json"))))

        let odd = Data(#"""
        {"kind":"List","items":[
         {"kind":"PodMetrics","metadata":{"name":"api","namespace":"Bad Namespace"},"containers":[{"usage":{"cpu":"1","memory":"1Mi"}}]},
         {"kind":"NodeMetrics","metadata":{"name":"mac-b"},"usage":{"cpu":"lots","memory":"2Gi"}},
         {"kind":"Pod","metadata":{"name":"stray","namespace":"default"}},
         {"kind":"PodMetrics","metadata":{"name":"idle","namespace":"default"},"containers":[{"usage":{"cpu":"?","memory":"?"}}]},
         "not an object",
         {"kind":"NodeMetrics","metadata":{"name":"bad_node"},"usage":{"cpu":"1","memory":"1Mi"}}
        ]}
        """#.utf8)
        guard case .sampled(let oddSample) = Metrics.sampled(combined: odd) else {
            Issue.record("a list with odd items still decodes")
            return
        }
        // A CPU that does not parse is unknown, never zero; the memory stays.
        #expect(oddSample.nodes == ["mac-b": NodeUsage(name: "mac-b", cores: nil, memoryBytes: 2_147_483_648)])
        // A refused namespace, another kind, and a pod with no usage that parses are left out.
        #expect(oddSample.pods == [:])
    }

    @Test("the one read: a top level of another kind, or not JSON, fails the poll")
    func combinedWrongKind() throws {
        #expect(Metrics.sampled(combined: try fixture("kubectl_metrics_nodes.json"))
            == .failed("kubectl returned a NodeMetricsList, not a metrics list"))
        #expect(Metrics.sampled(combined: Data(#"{"kind":"PodMetrics","items":[]}"#.utf8))
            == .failed("kubectl returned a PodMetrics, not a metrics list"))
        #expect(Metrics.sampled(combined: Data("nope".utf8)) == .failed("the metrics could not be read"))
        #expect(Metrics.sampled(combined: Data(#"{"kind":"List"}"#.utf8)) == .failed("the metrics could not be read"))
        // A failed poll keeps the last sample.
        var (state, _) = try MetricsTests.sampledState()
        let before = state.sample
        state.apply(Metrics.sampled(combined: Data("nope".utf8)), at: Self.t0)
        #expect(state.sample == before)
        #expect(state.lastError == "the metrics could not be read")
    }

    @Test("a failed read that still printed nodes, or pods, yields them; nothing parsed asks the APIService")
    func combinedPartial() throws {
        let nodesOnly = Data(#"""
        {"kind":"List","items":[{"kind":"NodeMetrics","metadata":{"name":"mac-a"},"usage":{"cpu":"500m","memory":"1Gi"}}]}
        """#.utf8)
        #expect(Metrics.sampled(combined: nodesOnly, exit: 1) == .sampled(MetricsSample(
            nodes: ["mac-a": NodeUsage(name: "mac-a", cores: 0.5, memoryBytes: 1 << 30)], pods: nil)))
        let podsOnly = Data(#"""
        {"kind":"List","items":[{"kind":"PodMetrics","metadata":{"name":"web","namespace":"default"},
         "containers":[{"usage":{"cpu":"250m","memory":"128Mi"}}]}]}
        """#.utf8)
        #expect(Metrics.sampled(combined: podsOnly, exit: 1) == .sampled(MetricsSample(
            nodes: [:], pods: ["default/web": PodUsage(cores: 0.25, memoryBytes: 128 << 20)])))
        // Nothing usable: the caller asks the APIService.
        #expect(Metrics.sampled(combined: Data(), exit: 1) == nil)
        #expect(Metrics.sampled(combined: Data(#"{"kind":"List","items":[]}"#.utf8), exit: 1) == nil)
        #expect(Metrics.sampled(combined: Data(#"{"kind":"List","items":[{"kind":"Pod"}]}"#.utf8), exit: 1) == nil)
        #expect(Metrics.sampled(combined: try fixture("kubectl_metrics_nodes.json"), exit: 1) == nil)
        // At 0 it is the whole read, an empty pod list included.
        #expect(Metrics.sampled(combined: nodesOnly, exit: 0) == .sampled(MetricsSample(
            nodes: ["mac-a": NodeUsage(name: "mac-a", cores: 0.5, memoryBytes: 1 << 30)], pods: [:])))
        #expect(Metrics.sampled(combined: Data("nope".utf8), exit: 0) == .failed("the metrics could not be read"))
    }

    @Test("a draw carried from an absent read never shortens the 60 s absent wait")
    func absentWaitUnderJitter() {
        for unit in [0.0, 0.25, 0.5, 0.99, 1.0] {
            let due = 60 * (1 + PollJitter.maxFraction * unit)
            for elapsed in stride(from: 0.0, to: 60.0, by: 2.5) {
                let step = MetricsSchedule.step(
                    visible: true, lastRead: Self.t0, now: Self.t0.addingTimeInterval(elapsed), absent: true, unit: unit)
                guard case .wait(let wait) = step else {
                    Issue.record("read after \(elapsed) s at unit \(unit), before the absent interval")
                    continue
                }
                #expect(wait >= .milliseconds(Int64((60 - elapsed) * 1000)), "unit \(unit), \(elapsed) s in")
                #expect(wait <= .milliseconds(Int64(((due - elapsed) * 1000).rounded(.up))))
            }
            // Due at the spread interval (a millisecond over, for the rounding).
            #expect(MetricsSchedule.step(visible: true, lastRead: Self.t0, now: Self.t0.addingTimeInterval(due + 0.001), absent: true, unit: unit) == .read)
            // The same draw on the next, sampled, wait: never under 15 s either.
            guard case .wait(let next) = MetricsSchedule.step(
                visible: true, lastRead: Self.t0, now: Self.t0, absent: false, unit: unit) else {
                Issue.record("a fresh read waits")
                continue
            }
            #expect(next >= .seconds(15))
        }
    }

    @Test("jitter only lengthens a wait, by at most a fifth", arguments: [
        (0.0, 15.0), (0.5, 16.5), (1.0, 18.0), (-3.0, 15.0), (7.0, 18.0), (Double.nan, 15.0),
        (Double.infinity, 18.0), (-Double.infinity, 15.0),
    ])
    func jitterBounds(_ c: (Double, Double)) {
        let spread = PollJitter.spread(.seconds(15), unit: c.0)
        #expect(spread == .milliseconds(Int64(c.1 * 1000)), "unit \(c.0): \(spread)")
        #expect(spread >= .seconds(15))
        #expect(spread <= .seconds(18))
    }

    @Test("jitter leaves a zero wait alone, and a draw is in 0...1")
    func jitterEdges() {
        #expect(PollJitter.spread(.zero, unit: 1) == .zero)
        #expect(PollJitter.spread(.seconds(-1), unit: 1) == .seconds(-1))
        for _ in 0..<1000 {
            let unit = PollJitter.draw()
            #expect((0...1).contains(unit))
        }
    }

    @Test("Low power stays at least twice Normal for every poll, whatever the jitter")
    func lowPowerUnderJitter() {
        let normal = PollProfile.normal.intervals.all
        let low = PollProfile.lowPower.intervals.all
        for (n, l) in zip(normal, low) {
            #expect(n.name == l.name)
            for unit in [0.0, 0.5, 1.0] {
                // The same draw on both; at 1 both are at their most.
                #expect(PollJitter.spread(l.value, unit: unit) >= PollJitter.spread(n.value, unit: unit) * 2, "\(n.name) at \(unit)")
            }
        }
    }

    @Test("the metrics wait is spread by the draw passed in, and exact at 0")
    func jitteredStep() {
        // At unit 1 the 15 s interval is 18 s: 5 s in, 13 s are left.
        #expect(MetricsSchedule.step(visible: true, lastRead: Self.t0, now: Self.t0.addingTimeInterval(5), absent: false, unit: 1) == .wait(.seconds(13)))
        #expect(MetricsSchedule.step(visible: true, lastRead: Self.t0, now: Self.t0.addingTimeInterval(15), absent: false, unit: 1) == .wait(.seconds(3)))
        #expect(MetricsSchedule.step(visible: true, lastRead: Self.t0, now: Self.t0.addingTimeInterval(18), absent: false, unit: 1) == .read)
        #expect(MetricsSchedule.step(visible: true, lastRead: Self.t0, now: Self.t0.addingTimeInterval(20), absent: true, unit: 0.5) == .wait(.seconds(46)))
        // The same draw gives the same answer: nothing is drawn inside step.
        let a = MetricsSchedule.step(visible: true, lastRead: Self.t0, now: Self.t0.addingTimeInterval(4), absent: false, unit: 0.37)
        let b = MetricsSchedule.step(visible: true, lastRead: Self.t0, now: Self.t0.addingTimeInterval(4), absent: false, unit: 0.37)
        #expect(a == b)
        // Unit 0 is the exact schedule.
        #expect(MetricsSchedule.step(visible: true, lastRead: Self.t0, now: Self.t0.addingTimeInterval(5), absent: false, unit: 0) == .wait(.seconds(10)))
        // The hidden recheck is not spread.
        #expect(MetricsSchedule.step(visible: false, lastRead: Self.t0, now: Self.t0, absent: false, unit: 1) == .wait(MetricsSchedule.hiddenRecheck))
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
