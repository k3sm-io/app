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

/// UsageSwatch is how a chart part is drawn: a fill for what is used, an
/// outline for what pods request, a dim fill for what macOS and other apps
/// use, and an empty stretch under a request outline whose use is unknown.
public enum UsageSwatch: String, Equatable, Sendable {
    case used
    case requested
    case system
    case unknown
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

/// CoreCell is one cell of the core grid: whether it is a performance core,
/// how much of it the node's measured use fills (0 to 1, nil without a
/// sample) and how much of it the pods' requests outline (0 to 1).
public struct CoreCell: Equatable, Sendable {
    public let performance: Bool
    public let used: Double?
    public let requested: Double

    public init(performance: Bool, used: Double?, requested: Double) {
        self.performance = performance
        self.used = used
        self.requested = requested
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
/// left to right, the share the pods' request outline covers from the left
/// edge, the legend, and whether a usage sample stands behind it.
public struct MemoryChart: Equatable, Sendable {
    public let segments: [ChartSegment]
    public let requestShare: Double
    public let legend: [UsageLegendRow]
    public let sampled: Bool

    public init(segments: [ChartSegment], requestShare: Double, legend: [UsageLegendRow], sampled: Bool) {
        self.segments = segments
        self.requestShare = requestShare
        self.legend = legend
        self.sampled = sampled
    }
}

/// MacUsage lays out the This Mac view's core grid and memory meter from
/// what the pods request and what metrics-server measured. Use is a fill and
/// a request is an outline, so either one stays legible when it passes the
/// other. CPU use is the node's own sample; memory use is the sum of the
/// working sets of this Mac's pods. Without a sample (metrics absent, none
/// read yet, this node not sampled, or the pod read failed) the charts show
/// the requests alone and `noSample` says so; use is never drawn as zero.
public enum MacUsage {
    /// The line under the charts when no usage sample stands behind them.
    public static let noSample = "No usage sample: requests only."

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
    /// performance cores, the used and the requested cores filling and
    /// outlining them in order from the first. A figure past the grid fills
    /// it; the legend keeps the real figure.
    public static func cores(count: Int, performance: Int, requested: Double, used: Double?) -> CoreChart {
        let request = requested.isFinite ? max(0, requested) : 0
        let cells = (0..<max(0, count)).map { i in
            CoreCell(performance: i < performance,
                     used: used.map { share($0 - Double(i)) },
                     requested: share(request - Double(i)))
        }
        var legend: [UsageLegendRow] = []
        if let used { legend.append(UsageLegendRow("Used", coresText(MetricsDisplay.cores(used)), .used)) }
        legend.append(UsageLegendRow("Requested", coresText(WorkloadsDisplay.cores(request)), .requested))
        return CoreChart(cells: cells, legend: legend, sampled: used != nil)
    }

    /// The memory meter over `total` bytes. With a sample: the pods' use,
    /// then the rest of what the Mac has in use (`inUse`) as macOS and apps,
    /// with the request outlined from the left. Without one: an empty
    /// stretch under the request outline, then what is in use beyond the
    /// request as macOS and apps. Shares never sum past the whole bar.
    public static func memory(total: Int64, inUse: Int64, requested: Int64, podsUsed: Int64?) -> MemoryChart {
        let request = max(0, requested)
        let busy = max(0, inUse)
        func part(_ bytes: Int64) -> Double { total > 0 ? share(Double(bytes) / Double(total)) : 0 }
        let first: ChartSegment
        let rest: Int64
        var legend: [UsageLegendRow] = []
        if let podsUsed {
            let pods = max(0, podsUsed)
            first = ChartSegment(share: part(pods), swatch: .used)
            rest = busy > pods ? busy - pods : 0
            legend.append(UsageLegendRow("Used by pods", MetricsDisplay.bytes(pods), .used))
        } else {
            first = ChartSegment(share: part(request), swatch: .unknown)
            rest = busy > request ? busy - request : 0
        }
        legend.append(UsageLegendRow("Requested by pods", ClusterDisplay.bytes(request), .requested))
        legend.append(UsageLegendRow("macOS and apps", ClusterDisplay.bytes(rest), .system))
        let second = ChartSegment(share: min(1 - first.share, part(rest)), swatch: .system)
        return MemoryChart(segments: [first, second].filter { $0.share > 0 }, requestShare: part(request),
                           legend: legend, sampled: podsUsed != nil)
    }

    /// The line under the charts about their sample: nil when both stand on
    /// one (the sample's age line says how old), `noSample` when neither
    /// does, and which one shows requests only otherwise.
    public static func note(cores: CoreChart, memory: MemoryChart) -> String? {
        switch (cores.sampled, memory.sampled) {
        case (true, true): return nil
        case (false, false): return noSample
        case (true, false): return "No memory usage sample: memory shows requests only."
        case (false, true): return "No CPU usage sample: cores show requests only."
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
