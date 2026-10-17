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

/// UsageSwatch is how a chart part is drawn: a fill for what is used and a
/// dim fill for what macOS and other apps use (or, without a pods sample,
/// everything in use).
public enum UsageSwatch: String, Equatable, Sendable {
    case used
    case system
}

/// UsageLegendRow is one row under a This Mac chart: its words, its value
/// and the swatch the chart draws it with.
public struct UsageLegendRow: Equatable, Sendable {
    public let label: String
    public let value: String
    public let swatch: UsageSwatch

    public init(_ label: String, _ value: String, _ swatch: UsageSwatch) {
        self.label = label
        self.value = value
        self.swatch = swatch
    }
}

/// CoreCell is one cell of the core grid: whether it is a performance core
/// and how much of it the node's measured use fills (0 to 1, nil without a
/// sample).
public struct CoreCell: Equatable, Sendable {
    public let performance: Bool
    public let used: Double?

    public init(performance: Bool, used: Double?) {
        self.performance = performance
        self.used = used
    }
}

/// CoreChart is the This Mac core grid: one cell per core, the legend, and
/// whether a usage sample stands behind it.
public struct CoreChart: Equatable, Sendable {
    public let cells: [CoreCell]
    public let legend: [UsageLegendRow]
    public let sampled: Bool

    public init(cells: [CoreCell], legend: [UsageLegendRow], sampled: Bool) {
        self.cells = cells
        self.legend = legend
        self.sampled = sampled
    }
}

/// ChartSegment is one filled stretch of the memory meter, as a share of the
/// machine's memory (0 to 1).
public struct ChartSegment: Equatable, Sendable {
    public let share: Double
    public let swatch: UsageSwatch

    public init(share: Double, swatch: UsageSwatch) {
        self.share = share
        self.swatch = swatch
    }
}

/// MemoryChart is the This Mac unified memory meter: the filled segments
/// left to right, the legend, and whether a usage sample stands behind it.
public struct MemoryChart: Equatable, Sendable {
    public let segments: [ChartSegment]
    public let legend: [UsageLegendRow]
    public let sampled: Bool

    public init(segments: [ChartSegment], legend: [UsageLegendRow], sampled: Bool) {
        self.segments = segments
        self.legend = legend
        self.sampled = sampled
    }
}

/// MacUsage lays out the This Mac view's core grid and memory meter from
/// what metrics-server measured and what the Mac has in use. CPU use is the
/// node's own sample; memory use is the sum of the working sets of this
/// Mac's pods. Without a sample (metrics absent, none read yet, this node
/// not sampled, or the pod read failed) the chart draws no use and
/// `noSample` says so; use is never drawn as zero.
public enum MacUsage {
    /// The line under the charts when no usage sample stands behind them.
    public static let noSample = "No usage sample yet."

    /// The cores this Mac's node used in the last sample, or nil without one.
    public static func cpuUsed(node: String?, state: MetricsState) -> Double? {
        guard state.absent == nil, let node, let usage = state.sample?.nodes[node], let cores = usage.cores,
              cores.isFinite, cores >= 0 else { return nil }
        return min(WorkloadsDisplay.maxCores, cores)
    }

    /// The working sets of `pods` summed, from the last sample, or nil when
    /// the sample does not cover this Mac's node or the pod read failed. A
    /// pod the sample does not carry (one just started) adds nothing; the
    /// sum saturates at Int64.
    public static func podsMemoryUsed(_ pods: [Pod], node: String?, state: MetricsState) -> Int64? {
        guard state.absent == nil, let node, let sample = state.sample, sample.nodes[node] != nil,
              let usage = sample.pods else { return nil }
        return Quantity.sum(pods.compactMap { usage[$0.key]?.memoryBytes }) ?? .max
    }

    /// The core grid: `count` cells, the first `performance` of them
    /// performance cores, the used cores filling them in order from the
    /// first. A figure past the grid fills it; the legend keeps the real
    /// figure. Without a sample the cells are empty and the legend has no row.
    public static func cores(count: Int, performance: Int, used: Double?) -> CoreChart {
        let cells = (0..<max(0, count)).map { i in
            CoreCell(performance: i < performance, used: used.map { share($0 - Double(i)) })
        }
        let legend = used.map { [UsageLegendRow("Used", coresText(MetricsDisplay.cores($0)), .used)] } ?? []
        return CoreChart(cells: cells, legend: legend, sampled: used != nil)
    }

    /// The memory meter over `total` bytes. With a sample: the pods' use,
    /// then the rest of what the Mac has in use (`inUse`) as macOS and apps.
    /// Without one: everything in use as one stretch. Shares never sum past
    /// the whole bar.
    public static func memory(total: Int64, inUse: Int64, podsUsed: Int64?) -> MemoryChart {
        let busy = max(0, inUse)
        func part(_ bytes: Int64) -> Double { total > 0 ? share(Double(bytes) / Double(total)) : 0 }
        guard let podsUsed else {
            let all = ChartSegment(share: part(busy), swatch: .system)
            return MemoryChart(segments: [all].filter { $0.share > 0 },
                               legend: [UsageLegendRow("In use", ClusterDisplay.bytes(busy), .system)], sampled: false)
        }
        let pods = max(0, podsUsed)
        let first = ChartSegment(share: part(pods), swatch: .used)
        let rest = busy > pods ? busy - pods : 0
        let second = ChartSegment(share: min(1 - first.share, part(rest)), swatch: .system)
        let legend = [UsageLegendRow("Used by pods", MetricsDisplay.bytes(pods), .used),
                      UsageLegendRow("macOS and apps", ClusterDisplay.bytes(rest), .system)]
        return MemoryChart(segments: [first, second].filter { $0.share > 0 }, legend: legend, sampled: true)
    }

    /// The line under the charts about their sample: nil when both stand on
    /// one (the sample's age line says how old), `noSample` when neither
    /// does, and which one has none otherwise.
    public static func note(cores: CoreChart, memory: MemoryChart) -> String? {
        switch (cores.sampled, memory.sampled) {
        case (true, true): return nil
        case (false, false): return noSample
        case (true, false): return "No pod memory sample yet."
        case (false, true): return "No CPU usage sample yet."
        }
    }

    /// "1.8 cores", "1 core".
    static func coresText(_ amount: String) -> String {
        amount == "1" ? "1 core" : "\(amount) cores"
    }

    /// `value` within 0...1; not a number is 0.
    static func share(_ value: Double) -> Double {
        value.isFinite ? max(0, min(1, value)) : 0
    }
}
