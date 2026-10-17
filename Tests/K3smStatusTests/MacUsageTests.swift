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

@Suite("This Mac charts: usage beside requests")
struct MacUsageTests {
    static let gib: Int64 = 1 << 30
    static let mib: Int64 = 1 << 20

    static func close(_ a: [Double?], _ b: [Double?]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { x, y in
            switch (x, y) {
            case (nil, nil): return true
            case (let x?, let y?): return abs(x - y) < 1e-9
            default: return false
            }
        }
    }

    struct CoreCase: Sendable, CustomTestStringConvertible {
        let name: String
        let used: Double?
        let wantUsed: [Double?]
        let legend: [UsageLegendRow]
        var testDescription: String { name }
    }

    static let coreCases: [CoreCase] = [
        CoreCase(name: "part of the second core", used: 1.8,
                 wantUsed: [1, 0.8, 0, 0], legend: [UsageLegendRow("Used", "1.80 cores", .used)]),
        CoreCase(name: "a quarter of the first core", used: 0.25,
                 wantUsed: [0.25, 0, 0, 0], legend: [UsageLegendRow("Used", "0.25 cores", .used)]),
        CoreCase(name: "no sample: empty cells and no legend row", used: nil,
                 wantUsed: [nil, nil, nil, nil], legend: []),
        CoreCase(name: "past the grid: every cell full, the real figure kept", used: 12,
                 wantUsed: [1, 1, 1, 1], legend: [UsageLegendRow("Used", "12 cores", .used)]),
        CoreCase(name: "an idle sample is zero use, not no sample", used: 0,
                 wantUsed: [0, 0, 0, 0], legend: [UsageLegendRow("Used", "0 cores", .used)]),
    ]

    @Test("the core grid fills what is used", arguments: coreCases)
    func coreGrid(_ c: CoreCase) {
        let got = MacUsage.cores(count: 4, performance: 2, used: c.used)
        #expect(got.cells.map(\.performance) == [true, true, false, false])
        #expect(Self.close(got.cells.map(\.used), c.wantUsed), "\(got.cells.map(\.used))")
        #expect(got.legend == c.legend)
        #expect(got.sampled == (c.used != nil))
    }

    @Test("a hostile or missing core count draws no cells and no NaN")
    func coreGridHostile() {
        let got = MacUsage.cores(count: -3, performance: 8, used: .infinity)
        #expect(got.cells.isEmpty)
        let nan = MacUsage.cores(count: 2, performance: 1, used: .nan)
        #expect(nan.cells.map(\.used) == [0, 0])
    }

    struct MemoryCase: Sendable, CustomTestStringConvertible {
        let name: String
        let inUse: Int64
        let podsUsed: Int64?
        let segments: [ChartSegment]
        let legend: [UsageLegendRow]
        var testDescription: String { name }
    }

    static let memoryCases: [MemoryCase] = [
        MemoryCase(name: "pods' use, then the rest in use", inUse: 10 * gib, podsUsed: 2 * gib,
                   segments: [ChartSegment(share: 2.0 / 16, swatch: .used), ChartSegment(share: 8.0 / 16, swatch: .system)],
                   legend: [UsageLegendRow("Used by pods", "2.0 GB", .used), UsageLegendRow("macOS and apps", "8.0 GB", .system)]),
        MemoryCase(name: "no sample: everything in use as one stretch", inUse: 10 * gib, podsUsed: nil,
                   segments: [ChartSegment(share: 10.0 / 16, swatch: .system)],
                   legend: [UsageLegendRow("In use", "10 GB", .system)]),
        MemoryCase(name: "no pods: an idle sample draws no pod segment", inUse: 10 * gib, podsUsed: 0,
                   segments: [ChartSegment(share: 10.0 / 16, swatch: .system)],
                   legend: [UsageLegendRow("Used by pods", "0 MB", .used), UsageLegendRow("macOS and apps", "10 GB", .system)]),
        MemoryCase(name: "more in use than the Mac has: the bar fills, never past it", inUse: 20 * gib, podsUsed: 6 * gib,
                   segments: [ChartSegment(share: 6.0 / 16, swatch: .used), ChartSegment(share: 10.0 / 16, swatch: .system)],
                   legend: [UsageLegendRow("Used by pods", "6.0 GB", .used), UsageLegendRow("macOS and apps", "14 GB", .system)]),
    ]

    @Test("the memory meter: pods' use, then macOS and apps", arguments: memoryCases)
    func memoryMeter(_ c: MemoryCase) {
        let got = MacUsage.memory(total: 16 * Self.gib, inUse: c.inUse, podsUsed: c.podsUsed)
        #expect(got.segments.map(\.swatch) == c.segments.map(\.swatch))
        #expect(Self.close(got.segments.map(\.share), c.segments.map(\.share)), "\(got.segments)")
        #expect(got.legend == c.legend)
        #expect(got.sampled == (c.podsUsed != nil))
        #expect(got.segments.map(\.share).reduce(0, +) <= 1 + 1e-9)
    }

    @Test("an unread machine size draws an empty meter with its legend")
    func memoryUnread() {
        let got = MacUsage.memory(total: 0, inUse: Self.gib, podsUsed: nil)
        #expect(got.segments.isEmpty)
        #expect(got.legend == [UsageLegendRow("In use", "1.0 GB", .system)])
    }

    /// The two-node pods, this Mac being mac-a, and a sample that carries
    /// mac-a and some of its pods.
    static func sampled(nodes: [String: NodeUsage]? = nil, pods: [String: PodUsage]?) throws -> (MetricsState, [Pod]) {
        let all = try Workloads.decode(try fixture("kubectl_pods_two_nodes.json")).pods
        let report = ClusterDisplayTests.report(workers: [], node: "1/2 nodes ready · mac-a kubelet v1.36.2", workloads: nil)
        let mine = ClusterDisplay.thisMacPods(all, report: report, nodeCount: 2)
        var state = MetricsState()
        state.apply(.sampled(MetricsSample(
            nodes: nodes ?? ["mac-a": NodeUsage(name: "mac-a", cores: 1.8, memoryBytes: 9 * gib)],
            pods: pods)), at: Date(timeIntervalSince1970: 1_000_000))
        return (state, mine)
    }

    static let podUsage: [String: PodUsage] = [
        "default/web-a": PodUsage(cores: 0.1, memoryBytes: 100 * mib),
        "default/web-b": PodUsage(cores: 0.2, memoryBytes: 200 * mib),
        "default/api-b": PodUsage(cores: 1, memoryBytes: gib),
    ]

    @Test("use comes from this Mac's node and the working sets of its own pods")
    func usageFromSample() throws {
        let (state, mine) = try Self.sampled(pods: Self.podUsage)
        #expect(mine.map(\.name).sorted() == ["linux-a", "web-a", "web-b"])
        #expect(MacUsage.cpuUsed(node: "mac-a", state: state) == 1.8)
        // api-b runs on mac-b; linux-a has no sample yet and adds nothing.
        #expect(MacUsage.podsMemoryUsed(mine, node: "mac-a", state: state) == 300 * Self.mib)
    }

    @Test("no usage without a sample of this node: never zero")
    func noSample() throws {
        let (state, mine) = try Self.sampled(pods: Self.podUsage)
        #expect(MacUsage.cpuUsed(node: "mac-b", state: state) == nil)
        #expect(MacUsage.podsMemoryUsed(mine, node: "mac-b", state: state) == nil)
        #expect(MacUsage.cpuUsed(node: nil, state: state) == nil)
        #expect(MacUsage.podsMemoryUsed(mine, node: nil, state: state) == nil)
        #expect(MacUsage.cpuUsed(node: "mac-a", state: MetricsState()) == nil)
        #expect(MacUsage.podsMemoryUsed(mine, node: "mac-a", state: MetricsState()) == nil)

        var absent = state
        absent.apply(.absent(Metrics.notInstalled), at: Date(timeIntervalSince1970: 1_000_015))
        #expect(MacUsage.cpuUsed(node: "mac-a", state: absent) == nil)
        #expect(MacUsage.podsMemoryUsed(mine, node: "mac-a", state: absent) == nil)

        // The pod read failed: the node's CPU stands, the pods' memory does not.
        let (podsFailed, _) = try Self.sampled(pods: nil)
        #expect(MacUsage.cpuUsed(node: "mac-a", state: podsFailed) == 1.8)
        #expect(MacUsage.podsMemoryUsed(mine, node: "mac-a", state: podsFailed) == nil)

        // A node quantity that did not parse is no sample, not zero.
        let (unparsed, _) = try Self.sampled(nodes: ["mac-a": NodeUsage(name: "mac-a", cores: nil, memoryBytes: nil)], pods: [:])
        #expect(MacUsage.cpuUsed(node: "mac-a", state: unparsed) == nil)
        #expect(MacUsage.podsMemoryUsed(mine, node: "mac-a", state: unparsed) == 0)
    }

    @Test("the note under the charts says which has no sample")
    func note() {
        let cores = { (used: Double?) in MacUsage.cores(count: 2, performance: 1, used: used) }
        let memory = { (used: Int64?) in MacUsage.memory(total: 16, inUse: 8, podsUsed: used) }
        #expect(MacUsage.note(cores: cores(1), memory: memory(1)) == nil)
        #expect(MacUsage.note(cores: cores(nil), memory: memory(nil)) == MacUsage.noSample)
        #expect(MacUsage.note(cores: cores(1), memory: memory(nil)) == "No pod memory sample yet.")
        #expect(MacUsage.note(cores: cores(nil), memory: memory(1)) == "No CPU usage sample yet.")
        for text in [MacUsage.noSample, "No pod memory sample yet.", "No CPU usage sample yet."] {
            #expect(!text.lowercased().contains("request"))
        }
    }

    @Test("the use tiles show what is used of the whole, with their own help tag")
    func tilesWithUse() {
        let got = ClusterDisplay.macTiles(
            cores: 10, memoryBytes: 16 * Self.gib, dataRootUsed: 120 * Self.gib, dataRootSize: 500 * Self.gib,
            pods: 4, coresUsed: 1.8, memoryUsed: 300 * Self.mib)
        #expect(got[0] == PanelTile(label: "cores used", value: "1.80", detail: "of 10 cores"))
        #expect(got[1] == PanelTile(label: "pod memory used", value: "300 MB", detail: "of 16 GB"))
        #expect(got[2].detail == "of 500 GB")
        #expect(Help.Panel.tile(got[0]).text.contains("used"))
        #expect(Help.Panel.tile(got[1]).text.contains("Memory"))
        #expect(Help.Panel.tile(got[0]) != Help.Panel.tile(got[1]))

        let unsampled = ClusterDisplay.macTiles(
            cores: 10, memoryBytes: 16 * Self.gib, dataRootUsed: 0, dataRootSize: 0, pods: 4,
            coresUsed: nil, memoryUsed: nil)
        #expect(unsampled[0] == PanelTile(label: "cores used", value: ClusterDisplay.noFigure, detail: "of 10 cores"))
        #expect(unsampled[1] == PanelTile(label: "pod memory used", value: ClusterDisplay.noFigure, detail: "of 16 GB"))
    }
}
