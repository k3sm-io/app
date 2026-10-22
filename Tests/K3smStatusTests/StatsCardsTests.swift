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

/// The Stats cards: each card's label and each chart's headline figure,
/// its absence included.
@Suite("the Stats cards")
struct StatsCardsTests {
    @Test func cardLabelHasItsShape() {
        let label = StatsCardLabel(chart: .cpu, symbolName: "cpu", title: "CPU by node", unit: "% of allocatable")
        let chart: StatsChart = label.chart
        let symbol: String = label.symbolName
        let title: String = label.title
        let unit: String = label.unit
        _ = (chart, symbol, title, unit)
    }

    @Test func headlineHasItsShape() {
        let headline = StatsHeadline(figure: "42", caption: "pods running")
        let figure: String = headline.figure
        let caption: String = headline.caption
        _ = (figure, caption)
    }

    @Test("every chart's card carries the chart's title and units and its own symbol")
    func cardLabels() {
        let symbols: [StatsChart: String] = [
            .cpu: "cpu", .memory: "memorychip", .podsByPhase: "shippingbox", .podsByNode: "square.stack.3d.up",
            .restarts: "arrow.clockwise", .images: "square.3.layers.3d", .storage: "internaldrive", .updates: "arrow.down.circle",
        ]
        for chart in StatsChart.allCases {
            let label = StatsCardLabel.of(chart)
            #expect(label.chart == chart)
            #expect(label.title == chart.title)
            #expect(label.unit == chart.unit)
            #expect(label.symbolName == symbols[chart])
            #expect(label.symbolName == StatsCardLabel.symbolName(for: chart))
        }
        #expect(Set(StatsChart.allCases.map(StatsCardLabel.symbolName(for:))).count == StatsChart.allCases.count)
    }

    @Test("four charts carry a headline, in the tab's order")
    func headlineCharts() {
        #expect(StatsHeadline.charts == [.podsByPhase, .podsByNode, .restarts, .storage])
        #expect(StatsHeadline.charts.allSatisfy { StatsChart.allCases.contains($0) })
    }

    @Test("pods by phase: the Running count, zero when pods exist and none runs, none without pods")
    func runningHeadline() {
        let mixed = StatsChartState.ready([StatsBucket("Running", 3), StatsBucket("Pending", 1)])
        #expect(StatsHeadline.running(mixed) == StatsHeadline(figure: "3", caption: "running"))
        let none = StatsChartState.ready([StatsBucket("Pending", 2)])
        #expect(StatsHeadline.running(none) == StatsHeadline(figure: "0", caption: "running"))
        #expect(StatsHeadline.running(.empty("No pods")) == nil)
    }

    @Test("pods by node: one node carries every pod; more say how many pods they carry")
    func nodesHeadline() {
        let one = StatsChartState.ready([StatsBucket("studio", 3)])
        #expect(StatsHeadline.nodes(one) == StatsHeadline(figure: "1", caption: "node carries every pod"))
        let two = StatsChartState.ready([StatsBucket("studio", 3), StatsBucket("laptop", 4)])
        #expect(StatsHeadline.nodes(two) == StatsHeadline(figure: "2", caption: "nodes carry 7 pods"))
        let single = StatsChartState.ready([StatsBucket("studio", 1), StatsBucket("laptop", 0)])
        #expect(StatsHeadline.nodes(single) == StatsHeadline(figure: "2", caption: "nodes carry 1 pod"))
        #expect(StatsHeadline.nodes(.empty(StatsDisplay.noSamplesYet)) == nil)
    }

    @Test("restarts: the hour's total when there were any; none for an hour without")
    func restartsHeadline() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let buckets = [StatsTimeBucket(start: t0, count: 2), StatsTimeBucket(start: t0.addingTimeInterval(300), count: 3)]
        #expect(StatsHeadline.restarts(.ready(buckets)) == StatsHeadline(figure: "5", caption: "in the last hour"))
        #expect(StatsHeadline.restarts(.empty("No restarts in the last hour")) == nil)
    }

    @Test("storage: the volume's free space as the lists size it; none until it was read")
    func storageHeadline() {
        let gib: Int64 = 1_073_741_824
        let read = StatsChartState.ready(StatsStorage(boundBytes: 10 * gib, boundClaims: 2, availableBytes: 158 * gib))
        #expect(StatsHeadline.storage(read) == StatsHeadline(figure: "158 GB", caption: "free on the data root"))
        let small = StatsChartState.ready(StatsStorage(boundBytes: 0, boundClaims: 0, availableBytes: 512 * 1_048_576))
        #expect(StatsHeadline.storage(small) == StatsHeadline(figure: "512 MB", caption: "free on the data root"))
        let full = StatsChartState.ready(StatsStorage(boundBytes: gib, boundClaims: 1, availableBytes: 0))
        #expect(StatsHeadline.storage(full) == StatsHeadline(figure: "0 GB", caption: "free on the data root"))
        let unread = StatsChartState.ready(StatsStorage(boundBytes: gib, boundClaims: 1, availableBytes: nil))
        #expect(StatsHeadline.storage(unread) == nil)
        #expect(StatsHeadline.storage(.empty(StatsDisplay.storageNotRead)) == nil)
    }
}
