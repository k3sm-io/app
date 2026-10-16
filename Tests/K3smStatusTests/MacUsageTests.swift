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
        let requested: Double
        let used: Double?
        let wantUsed: [Double?]
        let wantRequested: [Double]
        let legend: [UsageLegendRow]
        var testDescription: String { name }
    }

    static let coreCases: [CoreCase] = [
        CoreCase(name: "used above requests", requested: 0.6, used: 1.8,
                 wantUsed: [1, 0.8, 0, 0], wantRequested: [0.6, 0, 0, 0],
                 legend: [UsageLegendRow("Used", "1.80 cores", .used), UsageLegendRow("Requested", "0.60 cores", .requested)]),
        CoreCase(name: "used below requests", requested: 3.5, used: 0.25,
                 wantUsed: [0.25, 0, 0, 0], wantRequested: [1, 1, 1, 0.5],
                 legend: [UsageLegendRow("Used", "0.25 cores", .used), UsageLegendRow("Requested", "3.5 cores", .requested)]),
        CoreCase(name: "no sample: requests only", requested: 1, used: nil,
                 wantUsed: [nil, nil, nil, nil], wantRequested: [1, 0, 0, 0],
                 legend: [UsageLegendRow("Requested", "1 core", .requested)]),
        CoreCase(name: "past the grid: every cell full, the real figure kept", requested: 9, used: 12,
                 wantUsed: [1, 1, 1, 1], wantRequested: [1, 1, 1, 1],
                 legend: [UsageLegendRow("Used", "12 cores", .used), UsageLegendRow("Requested", "9 cores", .requested)]),
        CoreCase(name: "an idle sample is zero use, not no sample", requested: 0, used: 0,
                 wantUsed: [0, 0, 0, 0], wantRequested: [0, 0, 0, 0],
                 legend: [UsageLegendRow("Used", "0 cores", .used), UsageLegendRow("Requested", "0 cores", .requested)]),
    ]

    @Test("the core grid fills what is used and outlines what is requested", arguments: coreCases)
    func coreGrid(_ c: CoreCase) {
        let got = MacUsage.cores(count: 4, performance: 2, requested: c.requested, used: c.used)
        #expect(got.cells.map(\.performance) == [true, true, false, false])
        #expect(Self.close(got.cells.map(\.used), c.wantUsed), "\(got.cells.map(\.used))")
        #expect(Self.close(got.cells.map(\.requested), c.wantRequested), "\(got.cells.map(\.requested))")
        #expect(got.legend == c.legend)
        #expect(got.sampled == (c.used != nil))
    }

    @Test("a hostile or missing core count draws no cells and no NaN")
    func coreGridHostile() {
        let got = MacUsage.cores(count: -3, performance: 8, requested: .nan, used: .infinity)
        #expect(got.cells.isEmpty)
        #expect(got.legend.last == UsageLegendRow("Requested", "0 cores", .requested))
    }

    struct MemoryCase: Sendable, CustomTestStringConvertible {
        let name: String
        let inUse: Int64
        let requested: Int64
        let podsUsed: Int64?
        let segments: [ChartSegment]
        let requestShare: Double
        let legend: [UsageLegendRow]
        var testDescription: String { name }
    }

    static let memoryCases: [MemoryCase] = [
        MemoryCase(name: "used above requests", inUse: 10 * gib, requested: 1 * gib, podsUsed: 2 * gib,
                   segments: [ChartSegment(share: 2.0 / 16, swatch: .used), ChartSegment(share: 8.0 / 16, swatch: .system)],
                   requestShare: 1.0 / 16,
                   legend: [UsageLegendRow("Used by pods", "2.0 GB", .used), UsageLegendRow("Requested by pods", "1.0 GB", .requested),
                            UsageLegendRow("macOS and apps", "8.0 GB", .system)]),
        MemoryCase(name: "used below requests", inUse: 10 * gib, requested: 4 * gib, podsUsed: 512 * mib,
                   segments: [ChartSegment(share: 0.5 / 16, swatch: .used), ChartSegment(share: 9.5 / 16, swatch: .system)],
                   requestShare: 4.0 / 16,
                   legend: [UsageLegendRow("Used by pods", "512 MB", .used), UsageLegendRow("Requested by pods", "4.0 GB", .requested),
                            UsageLegendRow("macOS and apps", "9.5 GB", .system)]),
        MemoryCase(name: "no sample: an empty stretch under the request, then the rest in use", inUse: 10 * gib, requested: 4 * gib, podsUsed: nil,
                   segments: [ChartSegment(share: 4.0 / 16, swatch: .unknown), ChartSegment(share: 6.0 / 16, swatch: .system)],
                   requestShare: 4.0 / 16,
                   legend: [UsageLegendRow("Requested by pods", "4.0 GB", .requested), UsageLegendRow("macOS and apps", "6.0 GB", .system)]),
        MemoryCase(name: "no pods: an idle sample draws no pod segment", inUse: 10 * gib, requested: 0, podsUsed: 0,
                   segments: [ChartSegment(share: 10.0 / 16, swatch: .system)],
                   requestShare: 0,
                   legend: [UsageLegendRow("Used by pods", "0 MB", .used), UsageLegendRow("Requested by pods", "0 GB", .requested),
                            UsageLegendRow("macOS and apps", "10 GB", .system)]),
        MemoryCase(name: "more in use than the Mac has: the bar fills, never past it", inUse: 20 * gib, requested: 32 * gib, podsUsed: 6 * gib,
                   segments: [ChartSegment(share: 6.0 / 16, swatch: .used), ChartSegment(share: 10.0 / 16, swatch: .system)],
                   requestShare: 1,
                   legend: [UsageLegendRow("Used by pods", "6.0 GB", .used), UsageLegendRow("Requested by pods", "32 GB", .requested),
                            UsageLegendRow("macOS and apps", "14 GB", .system)]),
    ]

    @Test("the memory meter: pods' use, then macOS and apps, the request outlined", arguments: memoryCases)
    func memoryMeter(_ c: MemoryCase) {
        let got = MacUsage.memory(total: 16 * Self.gib, inUse: c.inUse, requested: c.requested, podsUsed: c.podsUsed)
        #expect(got.segments.map(\.swatch) == c.segments.map(\.swatch))
        #expect(Self.close(got.segments.map(\.share), c.segments.map(\.share)), "\(got.segments)")
        #expect(abs(got.requestShare - c.requestShare) < 1e-9)
        #expect(got.legend == c.legend)
        #expect(got.sampled == (c.podsUsed != nil))
        #expect(got.segments.map(\.share).reduce(0, +) <= 1 + 1e-9)
    }

    @Test("an unread machine size draws an empty meter with its legend")
    func memoryUnread() {
        let got = MacUsage.memory(total: 0, inUse: 0, requested: Self.gib, podsUsed: nil)
        #expect(got.segments.isEmpty)
        #expect(got.requestShare == 0)
        #expect(got.legend.first == UsageLegendRow("Requested by pods", "1.0 GB", .requested))
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

    @Test("the note under the charts says which show requests only")
    func note() {
        let cores = { (used: Double?) in MacUsage.cores(count: 2, performance: 1, requested: 1, used: used) }
        let memory = { (used: Int64?) in MacUsage.memory(total: 16, inUse: 8, requested: 1, podsUsed: used) }
        #expect(MacUsage.note(cores: cores(1), memory: memory(1)) == nil)
        #expect(MacUsage.note(cores: cores(nil), memory: memory(nil)) == MacUsage.noSample)
        #expect(MacUsage.note(cores: cores(1), memory: memory(nil)) == "No memory usage sample: memory shows requests only.")
        #expect(MacUsage.note(cores: cores(nil), memory: memory(1)) == "No CPU usage sample: cores show requests only.")
    }

    @Test("the request tiles show what is used beside them, with their own help tag")
    func tilesWithUse() {
        let got = ClusterDisplay.macTiles(
            requests: PodRequests(cores: 0.6, memoryBytes: 3 * Self.gib), cores: 10, memoryBytes: 16 * Self.gib,
            dataRootUsed: 120 * Self.gib, dataRootSize: 500 * Self.gib, pods: 4, coresUsed: 1.8, memoryUsed: 300 * Self.mib)
        #expect(got[0] == PanelTile(label: "cores requested", value: "0.60", detail: "of 10", used: "1.80 used"))
        #expect(got[0].detailLine == "of 10 · 1.80 used")
        #expect(got[1].detailLine == "of 16 GB · 300 MB used")
        #expect(got[2].used == nil && got[2].detailLine == "of 500 GB")
        #expect(Help.Panel.tile(got[0]).text.contains("used"))
        #expect(Help.Panel.tile(got[0]) != Help.Panel.tile(PanelTile(label: "cores requested", value: "0.60", detail: "of 10")))
        #expect(Help.Panel.tile(got[1]).text.contains("Memory"))
        #expect(PanelLayout.tileWidth(got[0]) > PanelLayout.tileWidth(PanelTile(label: "cores requested", value: "0.60", detail: "of 10")))

        let unsampled = ClusterDisplay.macTiles(
            requests: PodRequests(cores: 0.6, memoryBytes: 3 * Self.gib), cores: 10, memoryBytes: 16 * Self.gib,
            dataRootUsed: 0, dataRootSize: 0, pods: 4)
        #expect(unsampled[0].used == nil && unsampled[1].used == nil)
        #expect(unsampled[0].detailLine == "of 10")
    }
}
