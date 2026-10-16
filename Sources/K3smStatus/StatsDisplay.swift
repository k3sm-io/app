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

/// StatsChart is one chart of the Stats tab, in the order the tab draws
/// them: its title and the units line under it. The help tag of each is
/// `Help.Stats.tag(for:)`.
public enum StatsChart: String, CaseIterable, Identifiable, Sendable {
    case cpu
    case memory
    case podsByPhase
    case podsByNode
    case restarts
    case images
    case storage
    case updates

    public var id: Self { self }

    /// The chart's title.
    public var title: String {
        switch self {
        case .cpu: return "CPU by node"
        case .memory: return "Memory by node"
        case .podsByPhase: return "Pods by phase"
        case .podsByNode: return "Pods by node"
        case .restarts: return "Container restarts"
        case .images: return "Images by node"
        case .storage: return "Storage"
        case .updates: return "Managed update"
        }
    }

    /// The chart's units and span, under its title.
    public var unit: String {
        switch self {
        case .cpu, .memory: return "% of allocatable · last hour"
        case .podsByPhase, .podsByNode: return "pods · last read"
        case .restarts: return "restarts per 5 min · last hour"
        case .images: return "GB held · image count · last read"
        case .storage: return "GB · bound claims and free space"
        case .updates: return "update row state · this session"
        }
    }
}

/// StatsChartState is what a chart shows: its series, or the line that says
/// why there is none. A chart is never drawn blank or at zero for want of data.
public enum StatsChartState<Value: Equatable & Sendable>: Equatable, Sendable {
    case ready(Value)
    case empty(String)

    /// The series, nil while the chart shows its empty line.
    public var value: Value? {
        if case .ready(let v) = self { return v }
        return nil
    }
}

/// StatsInput is a tab read as the Stats tab takes it: not read yet, failed
/// with its clean reason, or a value. A failed read that left an earlier
/// value keeps showing that value.
public enum StatsInput<Value: Equatable & Sendable>: Equatable, Sendable {
    case notRead
    case failed(String)
    case value(Value)

    /// A loader's state and value as an input.
    public static func of(load: TabLoad?, value: Value?) -> StatsInput {
        if let value { return .value(value) }
        switch load {
        case .failed(let text)?, .unavailable(let text)?: return .failed(text)
        default: return .notRead
        }
    }
}

/// StatsDisplay decides each Stats chart's state from the history and the
/// reads the console holds, and the lines the tab shows. It reads nothing:
/// every input is a read another part of the console already made.
public enum StatsDisplay {
    public static let noSamplesYet = "No samples yet"
    /// The inspector's line on the Stats tab, which has no rows to select.
    public static let inspectorText = "The charts cover this session's reads, the last hour at most."
    /// The storage chart's line before the first read of the claims, which
    /// the Storage tab's loader makes while Stats or Storage is shown.
    public static let storageNotRead = "Not read yet"

    /// "Metrics unavailable: <reason>".
    public static func metricsUnavailable(_ reason: String) -> String {
        "Metrics unavailable: \(reason)"
    }

    /// A usage chart (CPU or memory): its lines, or why there are none: the
    /// metrics API absent, the reads failing before any sample, or no sample
    /// with an allocatable to measure against yet.
    public static func usage(_ series: [StatsNodeSeries], metrics: MetricsState) -> StatsChartState<[StatsNodeSeries]> {
        if let absent = metrics.absent { return .empty(metricsUnavailable(absent)) }
        if !series.isEmpty { return .ready(series) }
        if metrics.sample == nil, let error = metrics.lastError { return .empty(metricsUnavailable(error)) }
        return .empty(noSamplesYet)
    }

    /// The CPU chart.
    public static func cpu(_ history: StatsHistory, metrics: MetricsState, nodes: [ClusterNode]?) -> StatsChartState<[StatsNodeSeries]> {
        usage(StatsSeries.cpu(history, nodes: nodes), metrics: metrics)
    }

    /// The memory chart.
    public static func memory(_ history: StatsHistory, metrics: MetricsState, nodes: [ClusterNode]?) -> StatsChartState<[StatsNodeSeries]> {
        usage(StatsSeries.memory(history, nodes: nodes), metrics: metrics)
    }

    /// A pods chart from the pod list, bucketed by `buckets`.
    public static func pods(_ input: StatsInput<[Pod]>, _ buckets: ([Pod]) -> [StatsBucket]) -> StatsChartState<[StatsBucket]> {
        switch input {
        case .notRead: return .empty(noSamplesYet)
        case .failed(let why): return .empty("Pod list unavailable: \(why)")
        case .value(let pods): return pods.isEmpty ? .empty("No pods") : .ready(buckets(pods))
        }
    }

    /// The restarts chart: known from the second pod-list read on; a window
    /// with none says so rather than drawing empty bars.
    public static func restarts(_ history: StatsHistory, pods: StatsInput<[Pod]>, now: Date) -> StatsChartState<[StatsTimeBucket]> {
        guard history.podReads >= 2 else {
            if case .failed(let why) = pods { return .empty("Pod list unavailable: \(why)") }
            return .empty(noSamplesYet)
        }
        let buckets = StatsSeries.restarts(history, now: now)
        return StatsSeries.restartTotal(buckets) == 0 ? .empty("No restarts in the last hour") : .ready(buckets)
    }

    /// The images chart from the shared node list.
    public static func images(_ input: StatsInput<ImagesReading>) -> StatsChartState<[StatsImageNode]> {
        switch input {
        case .notRead: return .empty(noSamplesYet)
        case .failed(let why): return .empty("Node list unavailable: \(why)")
        case .value(let reading):
            guard let nodes = StatsSeries.images(reading) else { return .empty("No node reports the images it holds") }
            return nodes.isEmpty ? .empty("No images on any node") : .ready(nodes)
        }
    }

    /// The storage chart from the Storage tab's loader's last reads.
    public static func storage(_ rows: StatsInput<[StorageRow]>, volume: DataVolume?) -> StatsChartState<StatsStorage> {
        switch rows {
        case .notRead: return .empty(storageNotRead)
        case .failed(let why): return .empty("Storage unavailable: \(why)")
        case .value(let list):
            let split = StatsSeries.storage(list, volume: volume)
            if split.boundClaims == 0, split.availableBytes == nil { return .empty("No bound claims") }
            return .ready(split)
        }
    }

    /// The update chart: the row's states this session.
    public static func updates(_ history: StatsHistory, now: Date) -> StatsChartState<[StatsUpdateSpan]> {
        let spans = StatsSeries.updateSpans(history, now: now)
        return spans.isEmpty ? .empty(noSamplesYet) : .ready(spans)
    }

    /// The restarts chart's line: "3 restarts in the last hour".
    public static func restartsLine(_ buckets: [StatsTimeBucket]) -> String {
        let total = StatsSeries.restartTotal(buckets)
        return "\(total) restart\(total == 1 ? "" : "s") in the last hour"
    }

    /// An image bar's label: "5 images · 1.2 GB", or without the size when
    /// the node reports none.
    public static func imagesLine(_ node: StatsImageNode) -> String {
        let count = "\(node.count) image\(node.count == 1 ? "" : "s")"
        guard let bytes = node.bytes, bytes > 0 else { return count }
        return "\(count) · \(WorkloadsDisplay.bytes(bytes))"
    }

    /// The storage chart's line: "12 GB bound in 3 claims · 30 GB free · 40% of free".
    public static func storageLine(_ split: StatsStorage) -> String {
        let bound = split.boundBytes > 0 ? WorkloadsDisplay.bytes(split.boundBytes) : "0 GB"
        var line = "\(bound) bound in \(split.boundClaims) claim\(split.boundClaims == 1 ? "" : "s")"
        if let free = split.availableBytes {
            line += " · \(free > 0 ? WorkloadsDisplay.bytes(free) : "0 GB") free"
            if let percent = split.boundPercentOfAvailable { line += " · \(percent)% of free" }
        } else {
            line += " · free space not read"
        }
        return line
    }

    /// The latest point of each line, for the line under a usage chart:
    /// "studio 12% · laptop 40%".
    public static func latestLine(_ series: [StatsNodeSeries]) -> String {
        series.compactMap { s in s.points.last.map { "\(s.node) \(Int($0.percent.rounded()))%" } }.joined(separator: " · ")
    }

    /// Bytes as gigabytes, for a chart's axis.
    public static func gigabytes(_ bytes: Int64?) -> Double {
        guard let bytes, bytes > 0 else { return 0 }
        return Double(bytes) / 1_073_741_824
    }
}
