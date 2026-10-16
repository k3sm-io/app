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

@Suite("the Stats tab's series")
struct StatsTests {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    static func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    static func pod(_ name: String, phase: String = "Running", restarts: Int = 0, node: String? = "studio",
                    uid: String? = nil) -> Pod {
        Pod(name: name, namespace: "shop", uid: uid ?? "uid-\(name)", image: "", kind: .nativeProcess, phase: phase,
            health: .waiting(""), ready: true, restarts: restarts, ports: [], owner: nil, created: nil,
            cpuRequest: nil, memoryRequest: nil, nodeName: node)
    }

    static func sample(_ nodes: [String: (Double?, Int64?)]) -> MetricsReading {
        var usage: [String: NodeUsage] = [:]
        for (name, value) in nodes { usage[name] = NodeUsage(name: name, cores: value.0, memoryBytes: value.1) }
        return .sampled(MetricsSample(nodes: usage, pods: nil))
    }

    static func report(update state: String?, phase: String? = nil) -> StatusReport {
        var rows: [StatusRow] = []
        if let state {
            rows.append(StatusRow(name: "update", state: state, detail: "", wide: phase.map { ["phase": $0] } ?? [:]))
        }
        return StatusReport(schemaVersion: 1, verdict: .running, role: "server", summary: "", rows: rows)
    }

    static func claim(_ name: String, phase: String, bytes: Int64?) -> StorageRow {
        StorageRow(key: "pvc/shop/\(name)", namespace: "shop", claim: name, volume: "pv-\(name)", capacityBytes: bytes,
                   phase: phase, storageClass: nil, accessModes: [], uid: "", namespaceName: nil, claimName: nil,
                   volumeName: nil, path: nil, reclaimPolicy: nil, claimed: true)
    }

    static let gib: Int64 = 1_073_741_824

    struct UsageCase {
        let name: String
        let samples: [(Double, MetricsReading)]
        let nodes: [ClusterNode]?
        let cpu: [String: [Double]]
        let memory: [String: [Double]]
        let ringLength: [String: Int]
    }

    @Test("the series from the samples: the ring, the deltas, the buckets and the percentages")
    func statsSeriesFromSamples() {
        let studio = ClusterNode(name: "studio", ready: true, allocatableMilliCPU: 4000, allocatableMemoryBytes: 8 * Self.gib)
        let laptop = ClusterNode(name: "laptop", ready: true, allocatableMilliCPU: 2000, allocatableMemoryBytes: nil)

        // 1. The usage ring: percentages of allocatable, unknown quantities left out, trimmed by count and age.
        let usage: [UsageCase] = [
            UsageCase(name: "one sample per node, as shares of allocatable",
                      samples: [(0, Self.sample(["studio": (1, 2 * Self.gib), "laptop": (0.5, Self.gib)]))],
                      nodes: [studio, laptop],
                      cpu: ["studio": [25], "laptop": [25]], memory: ["studio": [25]],
                      ringLength: ["studio": 1, "laptop": 1]),
            UsageCase(name: "a quantity that did not parse is no point, never zero",
                      samples: [(0, Self.sample(["studio": (nil, 4 * Self.gib)])), (15, Self.sample(["studio": (2, nil)]))],
                      nodes: [studio], cpu: ["studio": [50]], memory: ["studio": [50]], ringLength: ["studio": 2]),
            UsageCase(name: "usage past allocatable shows as it is",
                      samples: [(0, Self.sample(["studio": (6, nil)]))],
                      nodes: [studio], cpu: ["studio": [150]], memory: [:], ringLength: ["studio": 1]),
            UsageCase(name: "without the node list there is no allocatable, so no line",
                      samples: [(0, Self.sample(["studio": (1, Self.gib)]))],
                      nodes: nil, cpu: [:], memory: [:], ringLength: ["studio": 1]),
            UsageCase(name: "a failed poll adds nothing; an absent API clears the ring",
                      samples: [(0, Self.sample(["studio": (1, Self.gib)])), (15, .failed("x")), (30, .absent("gone"))],
                      nodes: [studio], cpu: [:], memory: [:], ringLength: [:]),
            UsageCase(name: "a sample older than the hour is dropped",
                      samples: [(0, Self.sample(["studio": (1, nil)])), (3601, Self.sample(["studio": (2, nil)]))],
                      nodes: [studio], cpu: ["studio": [50]], memory: [:], ringLength: ["studio": 1]),
            UsageCase(name: "a node that left ages out with its last sample",
                      samples: [(0, Self.sample(["laptop": (1, nil)])), (3700, Self.sample(["studio": (1, nil)]))],
                      nodes: [studio, laptop], cpu: ["studio": [25]], memory: [:], ringLength: ["studio": 1]),
        ]
        for c in usage {
            var history = StatsHistory()
            for (seconds, reading) in c.samples { history.record(reading, at: Self.at(seconds)) }
            let cpu = StatsSeries.cpu(history, nodes: c.nodes)
            let memory = StatsSeries.memory(history, nodes: c.nodes)
            #expect(Dictionary(uniqueKeysWithValues: cpu.map { ($0.node, $0.points.map(\.percent)) }) == c.cpu, "\(c.name): cpu")
            #expect(Dictionary(uniqueKeysWithValues: memory.map { ($0.node, $0.points.map(\.percent)) }) == c.memory, "\(c.name): memory")
            #expect(history.nodes.mapValues(\.count) == c.ringLength, "\(c.name): ring")
            #expect(cpu.map(\.node) == cpu.map(\.node).sorted(), "\(c.name): sorted")
        }

        // The ring holds an hour at the poll's 15 s: 240 points, the oldest dropped first.
        var long = StatsHistory()
        for i in 0..<300 { long.record(Self.sample(["studio": (Double(i) / 100, nil)]), at: Self.at(Double(i) * 15)) }
        #expect(StatsHistory.capacity == 240)
        #expect(long.nodes["studio"]?.count == 240)
        #expect(long.nodes["studio"]?.first?.at == Self.at(60 * 15))
        #expect(long.nodes["studio"]?.last?.at == Self.at(299 * 15))
        var fast = StatsHistory()
        for i in 0..<300 { fast.record(Self.sample(["studio": (1, nil)]), at: Self.at(Double(i))) }
        #expect(fast.nodes["studio"]?.count == 240, "the count bounds the ring when polls come faster")

        // 2. Restarts: deltas between reads, per pod, never negative, from the second read on.
        struct RestartCase {
            let name: String
            let reads: [[Pod]]
            let found: [Int]
        }
        let restartCases: [RestartCase] = [
            RestartCase(name: "the first read is the baseline", reads: [[Self.pod("a", restarts: 5)]], found: []),
            RestartCase(name: "a rise between reads counts once",
                        reads: [[Self.pod("a", restarts: 1)], [Self.pod("a", restarts: 3)], [Self.pod("a", restarts: 3)]],
                        found: [2, 0]),
            RestartCase(name: "pods add up; a new pod is only a baseline",
                        reads: [[Self.pod("a", restarts: 0), Self.pod("b", restarts: 1)],
                                [Self.pod("a", restarts: 1), Self.pod("b", restarts: 4), Self.pod("c", restarts: 9)]],
                        found: [4]),
            RestartCase(name: "a fall adds nothing, and the lower count is the new baseline",
                        reads: [[Self.pod("a", restarts: 5)], [Self.pod("a", restarts: 2)], [Self.pod("a", restarts: 3)]],
                        found: [0, 1]),
            RestartCase(name: "a recreated pod under the same name is a new uid",
                        reads: [[Self.pod("a", restarts: 2, uid: "u1")], [Self.pod("a", restarts: 4, uid: "u2")]],
                        found: [0]),
        ]
        for c in restartCases {
            var history = StatsHistory()
            for (i, pods) in c.reads.enumerated() { history.record(pods: pods, at: Self.at(Double(i) * 30)) }
            #expect(history.restarts.map(\.count) == c.found, "\(c.name)")
            #expect(history.podReads == c.reads.count, "\(c.name): reads")
        }

        // Bucketing: twelve five-minute bars ending now; outside the hour is left out.
        var restarts = StatsHistory()
        restarts.record(pods: [Self.pod("a", restarts: 0)], at: Self.at(0))
        restarts.record(pods: [Self.pod("a", restarts: 2)], at: Self.at(30))
        restarts.record(pods: [Self.pod("a", restarts: 3)], at: Self.at(330))
        restarts.record(pods: [Self.pod("a", restarts: 6)], at: Self.at(3599))
        let buckets = StatsSeries.restarts(restarts, now: Self.at(3600))
        #expect(buckets.count == 12)
        #expect(buckets.first?.start == Self.at(0))
        #expect(buckets.map(\.count) == [2, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3])
        #expect(StatsSeries.restartTotal(buckets) == 6)
        let later = StatsSeries.restarts(restarts, now: Self.at(3630))
        #expect(later.map(\.count) == [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3], "the read at 30 s is past the hour")
        #expect(StatsDisplay.restartsLine(later) == "4 restarts in the last hour")

        // 3. Pods by phase and by node.
        let pods = [Self.pod("a"), Self.pod("b", phase: "Pending", node: nil), Self.pod("c", phase: "Failed", node: "laptop"),
                    Self.pod("d", phase: ""), Self.pod("e", phase: "Evicting"), Self.pod("f", phase: "Running", node: "laptop")]
        #expect(StatsSeries.podsByPhase(pods) == [StatsBucket("Running", 2), StatsBucket("Pending", 1), StatsBucket("Failed", 1),
                                                   StatsBucket("Unknown", 1), StatsBucket("Evicting", 1)])
        #expect(StatsSeries.podsByNode(pods) == [StatsBucket("laptop", 2), StatsBucket("studio", 3), StatsBucket("unscheduled", 1)])

        // 4. Images by node: counts, summed reported sizes, a node reporting no size has none.
        let images: ImagesReading = .listed([
            NodeImage(key: "sha256:a", digest: "sha256:a", names: ["a:1"], sizeBytes: Self.gib, nodes: ["laptop", "studio"]),
            NodeImage(key: "sha256:b", digest: "sha256:b", names: ["b:1"], sizeBytes: 2 * Self.gib, nodes: ["studio"]),
            NodeImage(key: "sha256:c", digest: "sha256:c", names: ["c:1"], sizeBytes: nil, nodes: ["edge"]),
        ])
        #expect(StatsSeries.images(images) == [
            StatsImageNode(node: "edge", count: 1, bytes: nil),
            StatsImageNode(node: "laptop", count: 1, bytes: Self.gib),
            StatsImageNode(node: "studio", count: 2, bytes: 3 * Self.gib),
        ])
        #expect(StatsSeries.images(.notReported) == nil)
        #expect(StatsDisplay.imagesLine(StatsImageNode(node: "studio", count: 2, bytes: 3 * Self.gib)) == "2 images · 3.0 GB")
        #expect(StatsDisplay.imagesLine(StatsImageNode(node: "edge", count: 1, bytes: nil)) == "1 image")

        // 5. Storage: only Bound claims count; the share is of the free space.
        let rows = [Self.claim("a", phase: "Bound", bytes: 10 * Self.gib), Self.claim("b", phase: "Pending", bytes: 5 * Self.gib),
                    Self.claim("c", phase: "Bound", bytes: nil), Self.claim("d", phase: "Bound", bytes: 2 * Self.gib)]
        let volume = DataVolume(recorded: true, name: nil, mountpoint: nil, quotaBytes: nil, encrypted: nil, mounted: true,
                                totalBytes: nil, availBytes: 40 * Self.gib, usedBytes: nil, preVolumeBytes: nil)
        let split = StatsSeries.storage(rows, volume: volume)
        #expect(split == StatsStorage(boundBytes: 12 * Self.gib, boundClaims: 3, availableBytes: 40 * Self.gib))
        #expect(split.boundPercentOfAvailable == 30)
        #expect(StatsDisplay.storageLine(split) == "12 GB bound in 3 claims · 40 GB free · 30% of free")
        let unread = StatsSeries.storage(rows, volume: nil)
        #expect(unread.boundPercentOfAvailable == nil)
        #expect(StatsDisplay.storageLine(unread) == "12 GB bound in 3 claims · free space not read")

        // 6. The update row: one point per change, spans ending where the next begins.
        var updates = StatsHistory()
        updates.record(update: Self.report(update: "current"), at: Self.at(0))
        updates.record(update: Self.report(update: "current"), at: Self.at(30))
        updates.record(update: Self.report(update: "behind"), at: Self.at(60))
        updates.record(update: Self.report(update: "rolling", phase: "Rolling"), at: Self.at(90))
        updates.record(update: Self.report(update: nil), at: Self.at(120))
        #expect(updates.updates.map(\.state) == ["current", "behind", "rolling: Rolling", "not reported"])
        let spans = StatsSeries.updateSpans(updates, now: Self.at(150))
        #expect(spans.map(\.start) == [Self.at(0), Self.at(60), Self.at(90), Self.at(120)])
        #expect(spans.map(\.end) == [Self.at(60), Self.at(90), Self.at(120), Self.at(150)])
        #expect(StatsSeries.updateSpans(updates, now: Self.at(0)).last?.end == Self.at(120), "never before its start")

        // 7. Percentages: capped, and none without a whole.
        #expect(StatsSeries.percent(1, of: 4) == 25)
        #expect(StatsSeries.percent(1, of: 0) == nil)
        #expect(StatsSeries.percent(.infinity, of: 1) == nil)
        #expect(StatsSeries.percent(1e9, of: 1) == StatsSeries.maxPercent)
    }

    @Test("a chart with nothing to draw says why: no samples yet, or unavailable with the reason")
    func statsChartsSayWhyTheyAreEmpty() {
        let studio = ClusterNode(name: "studio", ready: true, allocatableMilliCPU: 4000, allocatableMemoryBytes: Self.gib)
        var history = StatsHistory()
        var metrics = MetricsState()
        #expect(StatsDisplay.cpu(history, metrics: metrics, nodes: [studio]) == .empty("No samples yet"))
        metrics.apply(.failed("the metrics read exited 1"), at: Self.at(0))
        #expect(StatsDisplay.cpu(history, metrics: metrics, nodes: [studio])
            == .empty("Metrics unavailable: the metrics read exited 1"))
        metrics.apply(.absent(Metrics.notInstalled), at: Self.at(15))
        history.record(.absent(Metrics.notInstalled), at: Self.at(15))
        #expect(StatsDisplay.memory(history, metrics: metrics, nodes: [studio])
            == .empty("Metrics unavailable: \(Metrics.notInstalled)"))
        let reading = Self.sample(["studio": (1, Self.gib / 2)])
        metrics.apply(reading, at: Self.at(30))
        history.record(reading, at: Self.at(30))
        #expect(StatsDisplay.cpu(history, metrics: metrics, nodes: [studio]).value?.first?.points.map(\.percent) == [25])
        #expect(StatsDisplay.memory(history, metrics: metrics, nodes: nil) == .empty("No samples yet"))

        #expect(StatsDisplay.pods(.notRead, StatsSeries.podsByPhase) == .empty("No samples yet"))
        #expect(StatsDisplay.pods(.failed("k3sm kubectl exited 1"), StatsSeries.podsByNode)
            == .empty("Pod list unavailable: k3sm kubectl exited 1"))
        #expect(StatsDisplay.pods(.value([]), StatsSeries.podsByPhase) == .empty("No pods"))
        #expect(StatsDisplay.pods(.value([Self.pod("a")]), StatsSeries.podsByPhase) == .ready([StatsBucket("Running", 1)]))

        var restarts = StatsHistory()
        #expect(StatsDisplay.restarts(restarts, pods: .notRead, now: Self.at(0)) == .empty("No samples yet"))
        restarts.record(pods: [Self.pod("a")], at: Self.at(0))
        #expect(StatsDisplay.restarts(restarts, pods: .failed("x"), now: Self.at(0)) == .empty("Pod list unavailable: x"))
        restarts.record(pods: [Self.pod("a")], at: Self.at(30))
        #expect(StatsDisplay.restarts(restarts, pods: .notRead, now: Self.at(30)) == .empty("No restarts in the last hour"))
        restarts.record(pods: [Self.pod("a", restarts: 1)], at: Self.at(60))
        #expect(StatsDisplay.restarts(restarts, pods: .notRead, now: Self.at(60)).value != nil)

        #expect(StatsDisplay.images(.notRead) == .empty("No samples yet"))
        #expect(StatsDisplay.images(.value(.notReported)) == .empty("No node reports the images it holds"))
        #expect(StatsDisplay.images(.value(.listed([]))) == .empty("No images on any node"))
        #expect(StatsDisplay.images(.failed("k3sm kubectl exited 2")) == .empty("Node list unavailable: k3sm kubectl exited 2"))

        #expect(StatsDisplay.storage(.notRead, volume: nil) == .empty(StatsDisplay.storageNotRead))
        #expect(StatsDisplay.storage(.value([]), volume: nil) == .empty("No bound claims"))
        #expect(StatsDisplay.storage(.failed("x"), volume: nil) == .empty("Storage unavailable: x"))

        #expect(StatsDisplay.updates(StatsHistory(), now: Self.at(0)) == .empty("No samples yet"))
    }

    @Test("a loader's state as an input: its value wins, else its failure, else not read")
    func statsInputFromLoad() {
        #expect(StatsInput<[Pod]>.of(load: nil, value: nil) == .notRead)
        #expect(StatsInput<[Pod]>.of(load: .firstRead, value: nil) == .notRead)
        #expect(StatsInput<[Pod]>.of(load: .failed("bad"), value: nil) == .failed("bad"))
        #expect(StatsInput<[Pod]>.of(load: .unavailable("no CLI"), value: nil) == .failed("no CLI"))
        #expect(StatsInput<[Pod]>.of(load: .failed("bad"), value: []) == .value([]))
    }

    @Test("every chart has a title, units and its own help tag; the tab has no rows")
    func statsChartsAreLabelled() {
        #expect(StatsChart.allCases.count == 8)
        for chart in StatsChart.allCases {
            #expect(!chart.title.isEmpty && !chart.unit.isEmpty)
            #expect(Help.Stats.tag(for: chart).label == chart.title)
        }
        #expect(Set(Help.Stats.all.map(\.text)).count == StatsChart.allCases.count)
        #expect(ConsoleTabs.restore(from: "stats") == .stats)
        #expect(ConsoleRow(section: .stats, key: "x").section == .stats)
        #expect(InspectorDetails.emptyText(.stats) == StatsDisplay.inspectorText)
        #expect(TabHeader.placement(.stats) == .none)
    }
}
