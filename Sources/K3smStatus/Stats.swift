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

/// StatsNodePoint is one node's metrics sample in the Stats ring: when the
/// poll read it, and the cores and working-set bytes it reported (nil when
/// metrics-server's quantity did not parse, never zero).
public struct StatsNodePoint: Equatable, Sendable {
    public let at: Date
    public let cores: Double?
    public let memoryBytes: Int64?

    public init(at: Date, cores: Double?, memoryBytes: Int64?) {
        self.at = at
        self.cores = cores
        self.memoryBytes = memoryBytes
    }
}

/// StatsRestartPoint is the container restarts one pod-list read found
/// since the read before it, summed over the pods both reads listed.
public struct StatsRestartPoint: Equatable, Sendable {
    public let at: Date
    public let count: Int

    public init(at: Date, count: Int) {
        self.at = at
        self.count = count
    }
}

/// StatsUpdatePoint is the `update` row's state from the time a full status
/// report first showed it until a later one showed another.
public struct StatsUpdatePoint: Equatable, Sendable {
    public let at: Date
    /// The row's state word as printed, clipped ("current", "behind",
    /// "rolling"), with the phase while rolling ("rolling: Pending").
    public let state: String

    public init(at: Date, state: String) {
        self.at = at
        self.state = state
    }
}

/// StatsHistory is what the Stats tab charts over time, kept in memory only
/// and fed by reads the console already makes: a ring of each node's
/// metrics samples (one per metrics poll, `capacity` at most and none older
/// than `window`), the restarts each pod-list read found since the one
/// before, and the managed update row's states over the session. Nothing
/// here reads, and nothing is written to disk; a relaunch starts empty.
public struct StatsHistory: Equatable, Sendable {
    /// One hour at the metrics poll's fast 15 s cadence; slower reads
    /// space their points by their own times.
    public static let capacity = 240
    /// How far back the rings reach, in seconds.
    public static let window: TimeInterval = 3600
    /// The update states kept for the session, oldest dropped first.
    public static let updateCapacity = 240
    /// The row name of the managed update in the status report.
    static let updateRow = "update"

    /// Each node's samples, oldest first.
    public private(set) var nodes: [String: [StatsNodePoint]] = [:]
    /// The restarts found by each read after the first, oldest first.
    public private(set) var restarts: [StatsRestartPoint] = []
    /// How many pod-list reads have been compared: restarts are known only
    /// from the second read on.
    public private(set) var podReads = 0
    /// The update row's states, one point per change, oldest first.
    public private(set) var updates: [StatsUpdatePoint] = []
    /// The last read's restart count per pod, by uid (else its key).
    private var lastRestarts: [String: Int] = [:]

    public init() {}

    /// Records one metrics poll: a sample appends each node's point and
    /// trims every ring; an absent API clears the rings (the charts then say
    /// why); a failed poll changes nothing.
    public mutating func record(_ reading: MetricsReading, at time: Date) {
        switch reading {
        case .sampled(let sample):
            for (name, usage) in sample.nodes {
                nodes[name, default: []].append(StatsNodePoint(at: time, cores: usage.cores, memoryBytes: usage.memoryBytes))
            }
            for name in Array(nodes.keys) {
                let kept = Self.trimmed(nodes[name] ?? [], now: time, capacity: Self.capacity) { $0.at }
                nodes[name] = kept.isEmpty ? nil : kept
            }
        case .absent:
            nodes = [:]
        case .failed:
            break
        }
    }

    /// Records one decoded pod list: for every pod the read before listed
    /// too, the rise in its restart count. A count that fell (the pod's
    /// containers were replaced) adds nothing; a pod new to this read is
    /// the baseline for the next.
    public mutating func record(pods: [Pod], at time: Date) {
        var counts: [String: Int] = [:]
        var found = 0
        for pod in pods {
            let id = pod.uid.isEmpty ? pod.key : pod.uid
            counts[id] = pod.restarts
            if let before = lastRestarts[id], pod.restarts > before {
                found = min(Int.max / 2, found + (pod.restarts - before))
            }
        }
        if podReads > 0 { restarts.append(StatsRestartPoint(at: time, count: found)) }
        podReads += 1
        lastRestarts = counts
        restarts = Self.trimmed(restarts, now: time, capacity: Self.capacity) { $0.at }
    }

    /// Records one decoded full status report's `update` row: a point only
    /// when its state differs from the last one kept. A report without the
    /// row reads "not reported".
    public mutating func record(update report: StatusReport, at time: Date) {
        let state: String
        if let row = report.row(named: Self.updateRow) {
            let word = row.state.isEmpty ? "unknown" : row.state
            let phase = row.wide["phase"] ?? ""
            state = StatusDisplay.clip(row.rowState == .rolling && !phase.isEmpty ? "\(word): \(phase)" : word)
        } else {
            state = "not reported"
        }
        guard updates.last?.state != state else { return }
        updates.append(StatsUpdatePoint(at: time, state: state))
        if updates.count > Self.updateCapacity { updates.removeFirst(updates.count - Self.updateCapacity) }
    }

    /// `points` without those older than `window` before `now`, then
    /// without the oldest past `capacity`.
    static func trimmed<Point>(_ points: [Point], now: Date, capacity: Int, at: (Point) -> Date) -> [Point] {
        var kept = points.filter { now.timeIntervalSince(at($0)) <= window }
        if kept.count > capacity { kept.removeFirst(kept.count - capacity) }
        return kept
    }
}

/// StatsUsagePoint is one point of a node's CPU or memory line: when, and
/// the share of the node's allocatable used, in percent.
public struct StatsUsagePoint: Equatable, Sendable {
    public let at: Date
    public let percent: Double

    public init(at: Date, percent: Double) {
        self.at = at
        self.percent = percent
    }
}

/// StatsNodeSeries is one node's line on a usage chart.
public struct StatsNodeSeries: Equatable, Sendable {
    public let node: String
    public let points: [StatsUsagePoint]

    public init(node: String, points: [StatsUsagePoint]) {
        self.node = node
        self.points = points
    }
}

/// StatsBucket is one bar of a count chart: its label and its count.
public struct StatsBucket: Equatable, Sendable {
    public let label: String
    public let count: Int

    public init(_ label: String, _ count: Int) {
        self.label = label
        self.count = count
    }
}

/// StatsTimeBucket is one bar of the restarts chart: the interval starting
/// at `start` and the restarts found in it.
public struct StatsTimeBucket: Equatable, Sendable {
    public let start: Date
    public let count: Int

    public init(start: Date, count: Int) {
        self.start = start
        self.count = count
    }
}

/// StatsImageNode is one node's bar on the images chart: how many images it
/// holds and their summed size (only the sizes it reports; nil when it
/// reports none, or the sum does not fit).
public struct StatsImageNode: Equatable, Sendable {
    public let node: String
    public let count: Int
    public let bytes: Int64?

    public init(node: String, count: Int, bytes: Int64?) {
        self.node = node
        self.count = count
        self.bytes = bytes
    }
}

/// StatsStorage is the storage chart: the capacity of the claims that are
/// Bound, how many there are, and the data volume's free space when its
/// report was read.
public struct StatsStorage: Equatable, Sendable {
    public let boundBytes: Int64
    public let boundClaims: Int
    public let availableBytes: Int64?

    public init(boundBytes: Int64, boundClaims: Int, availableBytes: Int64?) {
        self.boundBytes = boundBytes
        self.boundClaims = boundClaims
        self.availableBytes = availableBytes
    }

    /// The bound capacity as a share of the free space, in whole percent;
    /// nil without a free figure above zero. Past 100 the claims promise
    /// more than the volume has free.
    public var boundPercentOfAvailable: Int? {
        guard let availableBytes, availableBytes > 0 else { return nil }
        return StatsSeries.percent(Double(boundBytes), of: Double(availableBytes)).map { Int($0.rounded()) }
    }
}

/// StatsUpdateSpan is one stretch of the update row's state: from the read
/// that first showed it to the read that showed the next, or to now.
public struct StatsUpdateSpan: Equatable, Sendable {
    public let state: String
    public let start: Date
    public let end: Date

    public init(state: String, start: Date, end: Date) {
        self.state = state
        self.start = start
        self.end = end
    }
}

/// StatsSeries turns the history and the reads the console holds into the
/// Stats tab's series: percentages of allocatable, counts by bucket, sums
/// by node and spans over time. Every function is pure.
public enum StatsSeries {
    /// The restarts chart's bar width, in seconds: twelve bars an hour.
    public static let restartBucket: TimeInterval = 300
    /// The highest percentage a point carries; usage past allocatable shows
    /// as it is, up to this.
    public static let maxPercent = 1000.0
    /// The phases in the order the pods chart draws them; any other phase
    /// follows, sorted.
    public static let phaseOrder = ["Running", "Pending", "Succeeded", "Failed", "Unknown"]
    /// The node bar for pods no node holds yet.
    public static let unscheduled = "unscheduled"

    /// `part` of `whole` in percent, capped at `maxPercent`; nil when the
    /// whole is not above zero or either is not finite.
    public static func percent(_ part: Double, of whole: Double) -> Double? {
        guard part.isFinite, whole.isFinite, whole > 0, part >= 0 else { return nil }
        return min(maxPercent, part / whole * 100)
    }

    /// Each node's CPU used, as a percentage of its allocatable cores, over
    /// the ring. A node without an allocatable figure, or with no point that
    /// carries cores, has no line. Sorted by node name.
    public static func cpu(_ history: StatsHistory, nodes: [ClusterNode]?) -> [StatsNodeSeries] {
        usage(history, nodes: nodes) { node in
            node.allocatableMilliCPU.map { Double($0) / 1000 }
        } used: { $0.cores }
    }

    /// Each node's memory used, as a percentage of its allocatable bytes.
    public static func memory(_ history: StatsHistory, nodes: [ClusterNode]?) -> [StatsNodeSeries] {
        usage(history, nodes: nodes) { node in
            node.allocatableMemoryBytes.map(Double.init)
        } used: { $0.memoryBytes.map(Double.init) }
    }

    private static func usage(_ history: StatsHistory, nodes: [ClusterNode]?,
                              allocatable: (ClusterNode) -> Double?, used: (StatsNodePoint) -> Double?) -> [StatsNodeSeries] {
        guard let nodes else { return [] }
        return history.nodes.keys.sorted().compactMap { name in
            guard let node = nodes.first(where: { $0.name == name }), let total = allocatable(node) else { return nil }
            let points = (history.nodes[name] ?? []).compactMap { point in
                used(point).flatMap { percent($0, of: total) }.map { StatsUsagePoint(at: point.at, percent: $0) }
            }
            return points.isEmpty ? nil : StatsNodeSeries(node: NodeNameMask.shown(name), points: points)
        }
    }

    /// The pods by phase: the usual phases first in `phaseOrder`, any other
    /// after them, sorted; an empty phase counts as Unknown. Only phases
    /// some pod is in.
    public static func podsByPhase(_ pods: [Pod]) -> [StatsBucket] {
        var counts: [String: Int] = [:]
        for pod in pods { counts[pod.phase.isEmpty ? "Unknown" : StatusDisplay.clip(pod.phase), default: 0] += 1 }
        let known = phaseOrder.filter { counts[$0] != nil }
        let others = counts.keys.filter { !phaseOrder.contains($0) }.sorted()
        return (known + others).map { StatsBucket($0, counts[$0] ?? 0) }
    }

    /// The pods by the node they are bound to, sorted by name, with the
    /// pods no node holds yet last.
    public static func podsByNode(_ pods: [Pod]) -> [StatsBucket] {
        var counts: [String: Int] = [:]
        var unbound = 0
        for pod in pods {
            if let node = pod.nodeName { counts[NodeNameMask.shown(node), default: 0] += 1 } else { unbound += 1 }
        }
        var buckets = counts.keys.sorted().map { StatsBucket($0, counts[$0] ?? 0) }
        if unbound > 0 { buckets.append(StatsBucket(unscheduled, unbound)) }
        return buckets
    }

    /// The restarts of the last `StatsHistory.window` in `restartBucket`
    /// bars, oldest first, the last ending at `now`. A point outside the
    /// window (or in the future) is left out.
    public static func restarts(_ history: StatsHistory, now: Date) -> [StatsTimeBucket] {
        let count = Int(StatsHistory.window / restartBucket)
        let start = now.addingTimeInterval(-StatsHistory.window)
        var sums = Array(repeating: 0, count: count)
        for point in history.restarts {
            let offset = point.at.timeIntervalSince(start)
            guard offset > 0, offset <= StatsHistory.window else { continue }
            let index = min(count - 1, Int((offset / restartBucket).rounded(.up)) - 1)
            sums[index] = min(Int.max / 2, sums[index] + point.count)
        }
        return sums.enumerated().map { StatsTimeBucket(start: start.addingTimeInterval(Double($0.offset) * restartBucket), count: $0.element) }
    }

    /// The restarts of the whole window.
    public static func restartTotal(_ buckets: [StatsTimeBucket]) -> Int {
        buckets.reduce(0) { min(Int.max / 2, $0 + $1.count) }
    }

    /// Each node's images: how many it holds and their summed reported
    /// size, sorted by node name. Nil when no node reports images.
    public static func images(_ reading: ImagesReading) -> [StatsImageNode]? {
        guard case .listed(let images) = reading else { return nil }
        var counts: [String: Int] = [:]
        var sizes: [String: [Int64]] = [:]
        for image in images {
            for node in image.nodes.map({ NodeNameMask.shown($0) }) {
                counts[node, default: 0] += 1
                if let size = image.sizeBytes, size > 0 { sizes[node, default: []].append(size) }
            }
        }
        return counts.keys.sorted().map { node in
            let bytes = sizes[node].flatMap(Quantity.sum)
            return StatsImageNode(node: node, count: counts[node] ?? 0, bytes: bytes)
        }
    }

    /// The claims that are Bound, their summed capacity (a claim without a
    /// figure adds nothing; the sum saturates), and the data volume's free
    /// space when its report was read.
    public static func storage(_ rows: [StorageRow], volume: DataVolume?) -> StatsStorage {
        let bound = rows.filter { $0.claim != nil && $0.phase == "Bound" }
        let bytes = Quantity.sum(bound.compactMap(\.capacityBytes).filter { $0 > 0 }) ?? .max
        return StatsStorage(boundBytes: bytes, boundClaims: bound.count, availableBytes: volume?.availBytes)
    }

    /// The update row's states as spans, each ending where the next begins
    /// and the last at `now` (never before its own start).
    public static func updateSpans(_ history: StatsHistory, now: Date) -> [StatsUpdateSpan] {
        let points = history.updates
        return points.enumerated().map { index, point in
            let next = index + 1 < points.count ? points[index + 1].at : now
            return StatsUpdateSpan(state: point.state, start: point.at, end: max(point.at, next))
        }
    }
}
