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

/// StatsCardLabel is what a Stats card shows above its chart: an SF Symbol,
/// the chart's title and its units line. The symbol is decided here, one per
/// `StatsChart`, and pinned by a test; the title and units are the chart's
/// own. The card's empty state draws the same symbol large over the line
/// that says why there is nothing to draw.
public struct StatsCardLabel: Equatable, Sendable {
    /// The chart the card draws.
    public let chart: StatsChart
    /// The SF Symbol's system name, drawn before the title.
    public let symbolName: String
    /// The card's title.
    public let title: String
    /// The card's units and span, under its title.
    public let unit: String

    public init(chart: StatsChart, symbolName: String, title: String, unit: String) {
        self.chart = chart
        self.symbolName = symbolName
        self.title = title
        self.unit = unit
    }

    /// The label of `chart`'s card.
    public static func of(_ chart: StatsChart) -> StatsCardLabel {
        StatsCardLabel(chart: chart, symbolName: symbolName(for: chart), title: chart.title, unit: chart.unit)
    }

    /// Each chart's symbol: what the chart counts, not how it is drawn.
    public static func symbolName(for chart: StatsChart) -> String {
        switch chart {
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .podsByPhase: return "shippingbox"
        case .podsByNode: return "square.stack.3d.up"
        case .restarts: return "arrow.clockwise"
        case .images: return "square.3.layers.3d"
        case .storage: return "internaldrive"
        case .updates: return "arrow.down.circle"
        }
    }
}

/// StatsHeadline is a Stats card's headline figure: the figure in large
/// type and the caption that says what it counts, for a chart whose data
/// has one ("3" over "running"). Four charts carry one (`charts`); the
/// others show their chart alone. A chart whose state is its empty line has
/// no headline: the line says why, and the card never shows a zero in
/// place of data it does not have. Nothing here is cluster-supplied: the
/// figures are counts and sizes, the captions fixed words.
public struct StatsHeadline: Equatable, Sendable {
    /// The figure, formatted for display ("42", "3", "118 GB").
    public let figure: String
    /// What the figure counts ("running", "node carries every pod").
    public let caption: String

    public init(figure: String, caption: String) {
        self.figure = figure
        self.caption = caption
    }

    /// The charts that carry a headline, in the tab's order.
    public static let charts: [StatsChart] = [.podsByPhase, .podsByNode, .restarts, .storage]

    /// Pods by phase: how many pods are Running. Zero is data when the list
    /// has pods and none runs.
    public static func running(_ state: StatsChartState<[StatsBucket]>) -> StatsHeadline? {
        guard case .ready(let buckets) = state else { return nil }
        let running = buckets.first { $0.label == "Running" }?.count ?? 0
        return StatsHeadline(figure: "\(running)", caption: "running")
    }

    /// Pods by node: how many nodes carry pods, and what they carry: "1 node
    /// carries every pod", or "3 nodes carry 12 pods".
    public static func nodes(_ state: StatsChartState<[StatsBucket]>) -> StatsHeadline? {
        guard case .ready(let buckets) = state else { return nil }
        let pods = buckets.reduce(0) { $0 + $1.count }
        let caption = buckets.count == 1 ? "node carries every pod" : "nodes carry \(pods) pod\(pods == 1 ? "" : "s")"
        return StatsHeadline(figure: "\(buckets.count)", caption: caption)
    }

    /// Restarts: the hour's total. The chart is ready only when there was
    /// one, so the figure is never zero; an hour without restarts is the
    /// chart's empty line.
    public static func restarts(_ state: StatsChartState<[StatsTimeBucket]>) -> StatsHeadline? {
        guard case .ready(let buckets) = state else { return nil }
        return StatsHeadline(figure: "\(StatsSeries.restartTotal(buckets))", caption: "in the last hour")
    }

    /// Storage: the data volume's free space, as the lists size bytes
    /// ("158 GB", "1.2 GB", "512 MB"); none until the volume's report
    /// was read.
    public static func storage(_ state: StatsChartState<StatsStorage>) -> StatsHeadline? {
        guard case .ready(let split) = state, let free = split.availableBytes else { return nil }
        let figure = free > 0 ? WorkloadsDisplay.bytes(free) : "0 GB"
        return StatsHeadline(figure: figure, caption: "free on the data root")
    }
}
