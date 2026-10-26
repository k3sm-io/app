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

import Charts
import K3smStatus
import SwiftUI

/// StatsSection is the Stats tab: one card per `StatsChart` (light by day,
/// the site's dark palette by night, following the app's appearance), two
/// across when the column has room, each with its label, its help tag, the
/// headline figure `StatsHeadline` decides when the chart has one, and
/// either its chart or the line `StatsDisplay` gives for why there is none. It makes no read of its own kind: the series come from
/// `StatsHistory` (fed by the metrics poll, the pod list and the status
/// report), the shared node list, and the Storage tab's loader, which
/// `AppModel` runs while Stats is shown. It is in the
/// view tree only while its tab is on screen, so nothing is drawn
/// otherwise; the time-based charts redraw every `StatsSection.tick`.
struct StatsSection: View {
    @ObservedObject var app: AppModel
    @ObservedObject var workloads: WorkloadsModel

    /// How often the time axes move on: the metrics poll's cadence.
    static let tick: TimeInterval = 15
    /// One chart's plot height.
    static let plotHeight: CGFloat = 150
    /// Every card's height, so a row of cards lines up.
    static let cardHeight: CGFloat = 290

    var body: some View {
        TimelineView(.periodic(from: .now, by: Self.tick)) { context in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 18, alignment: .top)], alignment: .leading, spacing: 18) {
                    ForEach(StatsChart.allCases) { chart in
                        tile(chart, now: context.date)
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 16)
            }
        }
        .background(Palette.statsPage)
    }

    private var pods: StatsInput<[Pod]> {
        StatsInput.of(load: workloads.pods?.load, value: workloads.pods?.value?.pods)
    }

    @ViewBuilder
    private func tile(_ chart: StatsChart, now: Date) -> some View {
        let history = workloads.stats
        switch chart {
        case .cpu:
            StatsTile(chart: chart) {
                StatsUsageChart(state: StatsDisplay.cpu(history, metrics: workloads.metrics, nodes: workloads.nodes))
            }
        case .memory:
            StatsTile(chart: chart) {
                StatsUsageChart(state: StatsDisplay.memory(history, metrics: workloads.metrics, nodes: workloads.nodes))
            }
        case .podsByPhase:
            let state = StatsDisplay.pods(pods, StatsSeries.podsByPhase)
            StatsTile(chart: chart, headline: StatsHeadline.running(state)) {
                StatsBucketChart(state: state, byLabel: true)
            }
        case .podsByNode:
            let state = StatsDisplay.pods(pods, StatsSeries.podsByNode)
            StatsTile(chart: chart, headline: StatsHeadline.nodes(state)) {
                StatsBucketChart(state: state, byLabel: false)
            }
        case .restarts:
            let state = StatsDisplay.restarts(history, pods: pods, now: now)
            StatsTile(chart: chart, headline: StatsHeadline.restarts(state)) {
                StatsRestartsChart(state: state)
            }
        case .images:
            StatsTile(chart: chart) {
                StatsImagesChart(state: StatsDisplay.images(
                    StatsInput.of(load: workloads.nodeList.load, value: workloads.nodeList.value?.images)))
            }
        case .storage:
            let state = StatsDisplay.storage(
                StatsInput.of(load: app.storage?.load, value: app.storage?.value), volume: app.dataVolume?.value)
            StatsTile(chart: chart, headline: StatsHeadline.storage(state)) {
                StatsStorageChart(state: state)
            }
        case .updates:
            StatsTile(chart: chart) {
                StatsUpdateChart(state: StatsDisplay.updates(history, now: now))
            }
        }
    }
}

private struct StatsSymbolKey: EnvironmentKey {
    static let defaultValue = "chart.bar"
}

extension EnvironmentValues {
    /// The card's symbol, so its empty state can draw it large.
    var statsSymbol: String {
        get { self[StatsSymbolKey.self] }
        set { self[StatsSymbolKey.self] = newValue }
    }
}

/// StatsTile is one chart's card: its label (`StatsCardLabel`: the symbol,
/// title and units), the headline figure `StatsHeadline` decides when the
/// chart has one, then the chart. Light cards by day, the site's dark
/// palette by night; it follows the app's appearance. The symbol sits beside
/// the title that names it and the whole card carries the chart's help tag,
/// so no part of it needs a tag of its own.
struct StatsTile<Content: View>: View {
    let chart: StatsChart
    var headline: StatsHeadline? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        let label = StatsCardLabel.of(chart)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: label.symbolName).font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Palette.statsAccent).frame(width: 20)
                    .accessibilityHidden(true)
                Text(verbatim: label.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.primary)
            }
            Text(verbatim: label.unit).font(.system(size: 11.5)).foregroundStyle(Palette.statsMuted)
            if let headline {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: headline.figure).font(.system(size: 36, weight: .bold)).monospacedDigit()
                        .foregroundStyle(Palette.statsNumber)
                    Text(verbatim: headline.caption).font(.system(size: 12.5)).foregroundStyle(Palette.statsMuted)
                }
            }
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .frame(maxWidth: .infinity, minHeight: StatsSection.cardHeight, maxHeight: StatsSection.cardHeight, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Palette.statsCard))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.statsLine))
        .environment(\.statsSymbol, label.symbolName)
        .accessibilityElement(children: .combine)
        .help(Help.Stats.tag(for: chart))
    }
}

/// StatsEmptyLine is a chart's line in place of its plot: why there is
/// nothing to draw, never a blank or a zero.
struct StatsEmptyLine: View {
    let text: String
    @Environment(\.statsSymbol) private var symbol

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 28, weight: .light)).foregroundStyle(Palette.statsEmpty)
                .accessibilityHidden(true)
            Text(verbatim: StatusDisplay.clip(text)).font(.system(size: 12.5)).foregroundStyle(Palette.statsMuted)
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .multilineTextAlignment(.center)
    }
}

/// StatsCaption is the short line under a chart.
struct StatsCaption: View {
    let text: String

    var body: some View {
        Text(verbatim: StatusDisplay.clip(text)).font(.system(size: 11)).monospacedDigit()
            .foregroundStyle(Palette.statsMuted).lineLimit(1).truncationMode(.tail)
    }
}

/// Axis marks in the panel's colours: faint grid lines, dim labels.
private struct StatsAxes: ViewModifier {
    func body(content: Content) -> some View {
        content
            .chartXAxis {
                AxisMarks { _ in
                    AxisGridLine().foregroundStyle(Palette.statsLine)
                    AxisValueLabel().foregroundStyle(Palette.statsMuted)
                }
            }
            .chartYAxis {
                AxisMarks { _ in
                    AxisGridLine().foregroundStyle(Palette.statsLine)
                    AxisValueLabel().foregroundStyle(Palette.statsMuted)
                }
            }
    }
}

/// StatsBars lays out a horizontal bar chart: thin rounded bars, a row
/// height per bar instead of one bar filling the plot, the row labels on
/// the left and no value axis. Every bar is named, a lone bar included:
/// the headline gives one figure (the Running count, the node count), not
/// the phase or the node a single bar stands for.
struct StatsBars: ViewModifier {
    static let thickness: CGFloat = 12
    static let row: CGFloat = 30
    let rows: Int

    func body(content: Content) -> some View {
        content
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisValueLabel().foregroundStyle(Palette.statsMuted)
                }
            }
            .frame(height: CGFloat(max(1, rows)) * Self.row)
    }
}

/// The first `count` colours (at least one), in turn from
/// `Palette.statsSeries`.
private func seriesColors(_ count: Int) -> [Color] {
    (0..<max(1, count)).map { Palette.statsSeries[$0 % Palette.statsSeries.count] }
}

/// StatsUsageChart is a node's CPU or memory share over the last hour, one
/// line per node, with each node's latest share under it.
struct StatsUsageChart: View {
    let state: StatsChartState<[StatsNodeSeries]>

    var body: some View {
        switch state {
        case .empty(let why): StatsEmptyLine(text: why)
        case .ready(let series):
            let names = series.map(\.node)
            let top = max(100, series.flatMap { $0.points.map(\.percent) }.max() ?? 0)
            VStack(alignment: .leading, spacing: 6) {
                Chart {
                    ForEach(series, id: \.node) { line in
                        ForEach(line.points, id: \.at) { point in
                            LineMark(x: .value("Time", point.at), y: .value("Percent", point.percent))
                                .foregroundStyle(by: .value("Node", line.node))
                                .interpolationMethod(.monotone)
                        }
                    }
                }
                .chartYScale(domain: 0...top)
                .chartForegroundStyleScale(domain: names, range: seriesColors(names.count))
                .chartLegend(names.count > 1 ? .visible : .hidden)
                .modifier(StatsAxes())
                .frame(height: StatsSection.plotHeight)
                StatsCaption(text: StatsDisplay.latestLine(series))
            }
        }
    }
}

/// StatsBucketChart is a count per label as horizontal bars, the count at
/// each bar's end; by phase it colours each phase as the lists do, and a
/// phase the lists do not name in `statsMuted`, a mark colour, not the
/// decorative `statsEmpty`.
struct StatsBucketChart: View {
    let state: StatsChartState<[StatsBucket]>
    let byLabel: Bool

    var body: some View {
        switch state {
        case .empty(let why): StatsEmptyLine(text: why)
        case .ready(let buckets):
            Chart {
                ForEach(buckets, id: \.label) { bucket in
                    BarMark(x: .value("Pods", bucket.count), y: .value("Label", bucket.label), height: .fixed(StatsBars.thickness))
                        .foregroundStyle(byLabel ? Self.phaseColor(bucket.label) : Palette.statsBar)
                        .clipShape(Capsule())
                        .annotation(position: .trailing) {
                            Text(verbatim: "\(bucket.count)").font(.system(size: 11)).monospacedDigit()
                                .foregroundStyle(Palette.statsMuted)
                        }
                }
            }
            .modifier(StatsBars(rows: buckets.count))
        }
    }

    private static func phaseColor(_ phase: String) -> Color {
        switch phase {
        case "Running": return Palette.statsOk
        case "Pending": return Palette.statsWarn
        case "Succeeded": return Palette.statsBarSoft
        case "Failed": return Palette.bad
        default: return Palette.statsMuted
        }
    }
}

/// StatsRestartsChart is the restarts found in each five minutes of the
/// last hour, with the hour's total under it.
struct StatsRestartsChart: View {
    let state: StatsChartState<[StatsTimeBucket]>

    var body: some View {
        switch state {
        case .empty(let why): StatsEmptyLine(text: why)
        case .ready(let buckets):
            VStack(alignment: .leading, spacing: 6) {
                Chart {
                    ForEach(buckets, id: \.start) { bucket in
                        BarMark(xStart: .value("From", bucket.start),
                                xEnd: .value("To", bucket.start.addingTimeInterval(StatsSeries.restartBucket)),
                                y: .value("Restarts", bucket.count))
                            .foregroundStyle(Palette.statsWarn)
                    }
                }
                .modifier(StatsAxes())
                .frame(height: StatsSection.plotHeight)
                StatsCaption(text: StatsDisplay.restartsLine(buckets))
            }
        }
    }
}

/// StatsImagesChart is each node's images by size, with the count and the
/// size at each bar's end.
struct StatsImagesChart: View {
    let state: StatsChartState<[StatsImageNode]>

    var body: some View {
        switch state {
        case .empty(let why): StatsEmptyLine(text: why)
        case .ready(let nodes):
            Chart {
                ForEach(nodes, id: \.node) { node in
                    BarMark(x: .value("GB", StatsDisplay.gigabytes(node.bytes)), y: .value("Node", node.node), height: .fixed(StatsBars.thickness))
                        .foregroundStyle(Palette.statsBar)
                        .clipShape(Capsule())
                        .annotation(position: .trailing) {
                            Text(verbatim: StatsDisplay.imagesLine(node)).font(.system(size: 10)).monospacedDigit()
                                .foregroundStyle(Palette.statsMuted)
                        }
                }
            }
            .modifier(StatsBars(rows: nodes.count))
        }
    }
}

/// StatsStorageChart is the bound claims' capacity beside the data
/// volume's free space, with both figures under it.
struct StatsStorageChart: View {
    let state: StatsChartState<StatsStorage>

    var body: some View {
        switch state {
        case .empty(let why): StatsEmptyLine(text: why)
        case .ready(let split):
            VStack(alignment: .leading, spacing: 6) {
                Chart {
                    BarMark(x: .value("GB", StatsDisplay.gigabytes(split.boundBytes)), y: .value("Kind", "Bound"), height: .fixed(StatsBars.thickness))
                        .foregroundStyle(Palette.statsBar)
                        .clipShape(Capsule())
                    if let free = split.availableBytes {
                        BarMark(x: .value("GB", StatsDisplay.gigabytes(free)), y: .value("Kind", "Free"), height: .fixed(StatsBars.thickness))
                            .foregroundStyle(Palette.statsBarSoft)
                            .clipShape(Capsule())
                    }
                }
                .modifier(StatsBars(rows: split.availableBytes == nil ? 1 : 2))
                StatsCaption(text: StatsDisplay.storageLine(split))
            }
        }
    }
}

/// StatsUpdateChart is the update row's state over the session, one band
/// per state, coloured by state.
struct StatsUpdateChart: View {
    let state: StatsChartState<[StatsUpdateSpan]>

    var body: some View {
        switch state {
        case .empty(let why): StatsEmptyLine(text: why)
        case .ready(let spans):
            let states = spans.reduce(into: [String]()) { if !$0.contains($1.state) { $0.append($1.state) } }
            VStack(alignment: .leading, spacing: 6) {
                Chart {
                    ForEach(Array(spans.enumerated()), id: \.offset) { _, span in
                        BarMark(xStart: .value("From", span.start), xEnd: .value("To", span.end),
                                y: .value("Row", "update"))
                            .foregroundStyle(by: .value("State", span.state))
                    }
                }
                .chartForegroundStyleScale(domain: states, range: seriesColors(states.count))
                .chartYAxis(.hidden)
                .chartXAxis {
                    AxisMarks { _ in
                        AxisGridLine().foregroundStyle(Palette.statsLine)
                        AxisValueLabel().foregroundStyle(Palette.statsMuted)
                    }
                }
                .frame(height: StatsSection.plotHeight)
                StatsCaption(text: "now: \(spans.last?.state ?? "")")
            }
        }
    }
}
