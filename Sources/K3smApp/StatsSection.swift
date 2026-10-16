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

/// StatsSection is the Stats tab: one navy tile per `StatsChart`, two
/// across when the column has room, each with its title, its units and its
/// help tag, and either its chart or the line `StatsDisplay` gives for why
/// there is none. It makes no read of its own kind: the series come from
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

    var body: some View {
        TimelineView(.periodic(from: .now, by: Self.tick)) { context in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)], alignment: .leading, spacing: 14) {
                    ForEach(StatsChart.allCases) { chart in
                        StatsTile(chart: chart) { tileContent(chart, now: context.date) }
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 16)
            }
        }
        .background(Palette.surface)
    }

    private var pods: StatsInput<[Pod]> {
        StatsInput.of(load: workloads.pods?.load, value: workloads.pods?.value?.pods)
    }

    @ViewBuilder
    private func tileContent(_ chart: StatsChart, now: Date) -> some View {
        let history = workloads.stats
        switch chart {
        case .cpu:
            StatsUsageChart(state: StatsDisplay.cpu(history, metrics: workloads.metrics, nodes: workloads.nodes))
        case .memory:
            StatsUsageChart(state: StatsDisplay.memory(history, metrics: workloads.metrics, nodes: workloads.nodes))
        case .podsByPhase:
            StatsBucketChart(state: StatsDisplay.pods(pods, StatsSeries.podsByPhase), byLabel: true)
        case .podsByNode:
            StatsBucketChart(state: StatsDisplay.pods(pods, StatsSeries.podsByNode), byLabel: false)
        case .restarts:
            StatsRestartsChart(state: StatsDisplay.restarts(history, pods: pods, now: now))
        case .images:
            StatsImagesChart(state: StatsDisplay.images(
                StatsInput.of(load: workloads.nodeList.load, value: workloads.nodeList.value?.images)))
        case .storage:
            StatsStorageChart(state: StatsDisplay.storage(
                StatsInput.of(load: app.storage?.load, value: app.storage?.value), volume: app.dataVolume?.value))
        case .updates:
            StatsUpdateChart(state: StatsDisplay.updates(history, now: now))
        }
    }
}

/// StatsTile is one chart's tile in the navy panel's look: the title and
/// its units over the chart, on the panel's raised navy, drawn in the dark
/// appearance so the axes and legends read on it.
struct StatsTile<Content: View>: View {
    let chart: StatsChart
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: chart.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                Text(verbatim: chart.unit).font(.system(size: 11)).foregroundStyle(.white.opacity(0.62))
            }
            content()
                .frame(maxWidth: .infinity, minHeight: StatsSection.plotHeight, alignment: .topLeading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.deepRaised))
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .combine)
        .help(Help.Stats.tag(for: chart))
    }
}

/// StatsEmptyLine is a chart's line in place of its plot: why there is
/// nothing to draw, never a blank or a zero.
struct StatsEmptyLine: View {
    let text: String

    var body: some View {
        Text(verbatim: StatusDisplay.clip(text)).font(.system(size: 12)).foregroundStyle(.white.opacity(0.62))
            .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: StatsSection.plotHeight, alignment: .center)
            .multilineTextAlignment(.center)
    }
}

/// StatsCaption is the short line under a chart.
struct StatsCaption: View {
    let text: String

    var body: some View {
        Text(verbatim: StatusDisplay.clip(text)).font(.system(size: 11)).monospacedDigit()
            .foregroundStyle(.white.opacity(0.62)).lineLimit(1).truncationMode(.tail)
    }
}

/// Axis marks in the panel's colours: faint grid lines, dim labels.
private struct StatsAxes: ViewModifier {
    func body(content: Content) -> some View {
        content
            .chartXAxis {
                AxisMarks { _ in
                    AxisGridLine().foregroundStyle(Color.white.opacity(0.10))
                    AxisValueLabel().foregroundStyle(Color.white.opacity(0.62))
                }
            }
            .chartYAxis {
                AxisMarks { _ in
                    AxisGridLine().foregroundStyle(Color.white.opacity(0.10))
                    AxisValueLabel().foregroundStyle(Color.white.opacity(0.62))
                }
            }
    }
}

/// The colours for `names`, in turn from `Palette.chartSeries`.
private func seriesColors(_ count: Int) -> [Color] {
    (0..<max(1, count)).map { Palette.chartSeries[$0 % Palette.chartSeries.count] }
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
/// each bar's end; by phase it colours each phase as the lists do.
struct StatsBucketChart: View {
    let state: StatsChartState<[StatsBucket]>
    let byLabel: Bool

    var body: some View {
        switch state {
        case .empty(let why): StatsEmptyLine(text: why)
        case .ready(let buckets):
            Chart {
                ForEach(buckets, id: \.label) { bucket in
                    BarMark(x: .value("Pods", bucket.count), y: .value("Label", bucket.label))
                        .foregroundStyle(byLabel ? Self.phaseColor(bucket.label) : Palette.fill)
                        .annotation(position: .trailing) {
                            Text(verbatim: "\(bucket.count)").font(.system(size: 10)).monospacedDigit()
                                .foregroundStyle(.white.opacity(0.8))
                        }
                }
            }
            .modifier(StatsAxes())
            .frame(height: StatsSection.plotHeight)
        }
    }

    private static func phaseColor(_ phase: String) -> Color {
        switch phase {
        case "Running": return Palette.okOnDark
        case "Pending": return Palette.warnOnDark
        case "Succeeded": return Palette.fillSoft
        case "Failed": return Palette.bad
        default: return Palette.unknown
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
                            .foregroundStyle(Palette.vm)
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
                    BarMark(x: .value("GB", StatsDisplay.gigabytes(node.bytes)), y: .value("Node", node.node))
                        .foregroundStyle(Palette.fill)
                        .annotation(position: .trailing) {
                            Text(verbatim: StatsDisplay.imagesLine(node)).font(.system(size: 10)).monospacedDigit()
                                .foregroundStyle(.white.opacity(0.8))
                        }
                }
            }
            .modifier(StatsAxes())
            .frame(height: StatsSection.plotHeight)
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
                    BarMark(x: .value("GB", StatsDisplay.gigabytes(split.boundBytes)), y: .value("Kind", "Bound"))
                        .foregroundStyle(Palette.fill)
                    if let free = split.availableBytes {
                        BarMark(x: .value("GB", StatsDisplay.gigabytes(free)), y: .value("Kind", "Free"))
                            .foregroundStyle(Palette.fillDim)
                    }
                }
                .modifier(StatsAxes())
                .frame(height: StatsSection.plotHeight)
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
                        AxisGridLine().foregroundStyle(Color.white.opacity(0.10))
                        AxisValueLabel().foregroundStyle(Color.white.opacity(0.62))
                    }
                }
                .frame(height: StatsSection.plotHeight)
                StatsCaption(text: "now: \(spans.last?.state ?? "")")
            }
        }
    }
}
