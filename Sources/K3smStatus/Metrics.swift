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

/// NodeUsage is one node's sample from metrics-server: the cores and the
/// working-set bytes it used over the sample's window. A quantity that does
/// not parse is unknown (nil), never zero.
public struct NodeUsage: Equatable, Sendable {
    public let name: String
    public let cores: Double?
    public let memoryBytes: Int64?

    public init(name: String, cores: Double?, memoryBytes: Int64?) {
        self.name = name
        self.cores = cores
        self.memoryBytes = memoryBytes
    }
}

/// PodUsage is one pod's sample, summed over the containers metrics-server
/// lists for it: a container whose quantity does not parse is left out of
/// the sum, and a pod with none that parse has no figure.
public struct PodUsage: Equatable, Sendable {
    public let cores: Double
    public let memoryBytes: Int64

    public init(cores: Double, memoryBytes: Int64) {
        self.cores = cores
        self.memoryBytes = memoryBytes
    }
}

/// MetricsSample is one poll of metrics-server: the nodes by name and the
/// pods by `Pod.key` ("namespace/name"). `pods` is nil when the pod read
/// failed though the node read did not.
public struct MetricsSample: Equatable, Sendable {
    public let nodes: [String: NodeUsage]
    public let pods: [String: PodUsage]?

    public init(nodes: [String: NodeUsage], pods: [String: PodUsage]?) {
        self.nodes = nodes
        self.pods = pods
    }
}

/// MetricsReading is what one poll concluded.
public enum MetricsReading: Equatable, Sendable {
    /// The node read decoded (and the pod read, unless `pods` is nil).
    case sampled(MetricsSample)
    /// The cluster serves no metrics API, or its APIService is not
    /// available; the text, already clean, says why.
    case absent(String)
    /// This poll failed for a reason that may pass; the last sample stays.
    case failed(String)
}

/// Metrics decodes metrics-server's node and pod samples, read in one
/// `kubectl get nodes.metrics.k8s.io,pods.metrics.k8s.io` (a `List` of both
/// kinds) or as the two `metrics.k8s.io/v1beta1` lists, and, when the read
/// fails, reads the `v1beta1.metrics.k8s.io` APIService's conditions to say
/// whether the API is absent or only this read failed. Names are kept only
/// when `ResourceName` accepts them; every cluster string is cleaned.
public enum Metrics {
    /// The line when the cluster has no metrics APIService at all.
    public static let notInstalled = "No metrics API: metrics-server is not installed on this cluster."

    /// One poll whose node read exited 0: the node list, and the pod read's
    /// exit and output when it ran.
    public static func sampled(nodes: Data, pods: (exit: Int32, stdout: Data)?) -> MetricsReading {
        let nodeItems: [[String: Any]]
        switch items(nodes, kind: "NodeMetricsList") {
        case .success(let objects): nodeItems = objects
        case .failure(.notAList(let kind)): return .failed("kubectl returned a \(kind), not node metrics")
        case .failure(.malformed): return .failed("the node metrics could not be read")
        }
        var podItems: [[String: Any]]?
        if let pods, pods.exit == 0, case .success(let objects) = items(pods.stdout, kind: "PodMetricsList") {
            podItems = objects
        }
        return .sampled(sample(nodeItems: nodeItems, podItems: podItems))
    }

    /// One poll of the single read (`K3smCLI.metricsArguments`) that exited
    /// 0: a `List` whose items are `NodeMetrics` and `PodMetrics` in any
    /// order. An item of another kind is skipped; a top level of another
    /// kind, or bytes that are not a list, fail the poll.
    public static func sampled(combined: Data) -> MetricsReading {
        switch kinds(combined) {
        case .success(let split): return .sampled(sample(nodeItems: split.nodes, podItems: split.pods))
        case .failure(.notAList(let kind)): return .failed("kubectl returned a \(kind), not a metrics list")
        case .failure(.malformed): return .failed("the metrics could not be read")
        }
    }

    /// One poll of the single read that exited `exit`. At 0 it is
    /// `sampled(combined:)`. Otherwise kubectl may still have printed the
    /// kind it could read: a `List` with node items is a sample whose pods
    /// are unknown, one with only pod items a sample with no nodes. Nil when
    /// nothing parsed, which is when the APIService read decides.
    public static func sampled(combined: Data, exit: Int32) -> MetricsReading? {
        guard exit != 0 else { return sampled(combined: combined) }
        guard case .success(let split) = kinds(combined), !split.nodes.isEmpty || !split.pods.isEmpty else { return nil }
        return .sampled(sample(nodeItems: split.nodes, podItems: split.pods.isEmpty ? nil : split.pods))
    }

    /// The one read's items, split by kind; an item of another kind dropped.
    static func kinds(_ data: Data) -> Result<(nodes: [[String: Any]], pods: [[String: Any]]), ListError> {
        switch items(data, kind: "List") {
        case .failure(let why): return .failure(why)
        case .success(let objects):
            var nodes: [[String: Any]] = []
            var pods: [[String: Any]] = []
            for item in objects {
                switch item["kind"] as? String {
                case "NodeMetrics": nodes.append(item)
                case "PodMetrics": pods.append(item)
                default: continue
                }
            }
            return .success((nodes, pods))
        }
    }

    /// The sample from the node items and, when the pods were read, the pod
    /// items: names `ResourceName` refuses are left out.
    static func sample(nodeItems: [[String: Any]], podItems: [[String: Any]]?) -> MetricsSample {
        var byName: [String: NodeUsage] = [:]
        for item in nodeItems {
            guard let name = name(of: item) else { continue }
            let usage = item["usage"] as? [String: Any] ?? [:]
            byName[name] = NodeUsage(
                name: name, cores: (usage["cpu"] as? String).flatMap(Quantity.cores),
                memoryBytes: (usage["memory"] as? String).flatMap(Quantity.bytes))
        }
        var podUsage: [String: PodUsage]?
        if let podItems {
            var byKey: [String: PodUsage] = [:]
            for item in podItems {
                guard let name = name(of: item) else { continue }
                let metadata = item["metadata"] as? [String: Any] ?? [:]
                guard let namespace = (metadata["namespace"] as? String).flatMap(ResourceName.init)?.value else { continue }
                if let usage = sum(item["containers"]) { byKey["\(namespace)/\(name)"] = usage }
            }
            podUsage = byKey
        }
        return MetricsSample(nodes: byName, pods: podUsage)
    }

    /// One poll whose node read exited `nodesExit` (not 0), with the
    /// APIService read's exit and output (standard error kept) when it ran.
    /// A NotFound APIService is absent; one whose Available condition is not
    /// True is absent with its reason and message; an available API, or an
    /// APIService read that failed some other way, makes this poll a failure.
    public static func unavailable(nodesExit: Int32, apiService: (exit: Int32, stdout: Data)?) -> MetricsReading {
        let readFailed = MetricsReading.failed("the metrics read exited \(nodesExit)")
        guard let apiService else { return readFailed }
        let text = String(decoding: apiService.stdout, as: UTF8.self)
        guard apiService.exit == 0 else {
            if text.contains("(NotFound)") { return .absent(notInstalled) }
            let clean = StatusDisplay.errorText(text)
            return clean.isEmpty ? readFailed : .failed(clean)
        }
        guard let top = (try? JSONSerialization.jsonObject(with: apiService.stdout)) as? [String: Any],
              (top["kind"] as? String) == "APIService" else { return readFailed }
        let status = top["status"] as? [String: Any] ?? [:]
        let conditions = (status["conditions"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        guard let available = conditions.first(where: { ($0["type"] as? String) == "Available" }) else {
            return .absent("The metrics API is not available yet.")
        }
        if (available["status"] as? String) == "True" { return readFailed }
        let why = [available["reason"] as? String, available["message"] as? String]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ": ")
        let line = why.isEmpty ? "The metrics API is unavailable." : "The metrics API is unavailable: \(why)"
        return .absent(StatusDisplay.errorText(line))
    }

    enum ListError: Error { case malformed, notAList(String) }

    /// The objects of a metrics list of `kind`, or why the bytes are not one.
    static func items(_ data: Data, kind: String) -> Result<[[String: Any]], ListError> {
        guard let top = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let got = top["kind"] as? String, let items = top["items"] as? [Any] else { return .failure(.malformed) }
        guard got == kind else { return .failure(.notAList(StatusDisplay.clip(got))) }
        return .success(items.compactMap { $0 as? [String: Any] })
    }

    static func name(of item: [String: Any]) -> String? {
        let metadata = item["metadata"] as? [String: Any] ?? [:]
        return (metadata["name"] as? String).flatMap(ResourceName.init)?.value
    }

    /// The containers' usage summed: cores capped at `WorkloadsDisplay.maxCores`,
    /// bytes saturating at Int64, nil when no container's usage parses.
    static func sum(_ containers: Any?) -> PodUsage? {
        var cores = 0.0
        var bytes: [Int64] = []
        var any = false
        for case let container as [String: Any] in containers as? [Any] ?? [] {
            let usage = container["usage"] as? [String: Any] ?? [:]
            if let c = (usage["cpu"] as? String).flatMap(Quantity.cores) {
                cores = min(WorkloadsDisplay.maxCores, cores + min(WorkloadsDisplay.maxCores, c))
                any = true
            }
            if let b = (usage["memory"] as? String).flatMap(Quantity.bytes) {
                bytes.append(b)
                any = true
            }
        }
        return any ? PodUsage(cores: cores, memoryBytes: Quantity.sum(bytes) ?? .max) : nil
    }
}

/// MetricsState folds the polls: the last sample and when it was read, the
/// absent API's line (the rows hide while it is set), the last failure (the
/// sample stays), and a short ring of node samples for a sparkline. Nothing
/// is stored past the ring.
public struct MetricsState: Equatable, Sendable {
    /// How many node samples the ring keeps: three minutes at 15 s.
    public static let historyLength = 12

    public private(set) var sample: MetricsSample?
    public private(set) var sampledAt: Date?
    /// Why there are no metrics, when the API is absent or unavailable.
    public private(set) var absent: String?
    /// The last poll's failure, cleared by the next sample.
    public private(set) var lastError: String?
    /// When the last poll finished, whatever it read.
    public private(set) var readAt: Date?
    /// Each node's last samples, oldest first.
    public private(set) var history: [String: [NodeUsage]] = [:]

    public init() {}

    public mutating func apply(_ reading: MetricsReading, at time: Date) {
        readAt = time
        switch reading {
        case .sampled(let next):
            sample = next
            sampledAt = time
            absent = nil
            lastError = nil
            for (name, usage) in next.nodes {
                history[name, default: []].append(usage)
                if history[name]!.count > Self.historyLength { history[name]!.removeFirst() }
            }
            history = history.filter { next.nodes[$0.key] != nil }
        case .absent(let why):
            sample = nil
            sampledAt = nil
            history = [:]
            lastError = nil
            absent = StatusDisplay.errorText(why)
        case .failed(let why):
            lastError = StatusDisplay.errorText(why)
        }
    }
}

/// MetricsStep is the metrics poll's next move.
public enum MetricsStep: Equatable, Sendable {
    case read
    case wait(Duration)
}

/// MetricsDemand is how much the shown view wants the live load: `fast`
/// while it charts or lists it row by row (the caller decides which views
/// those are), `slow` while it only shows it in passing, `off` while nothing
/// is on screen.
public enum MetricsDemand: Equatable, Sendable {
    case off
    case slow
    case fast
}

/// MetricsSchedule is the metrics poll's cadence, sized for the view: under
/// the Normal profile a read at most every 15 s while the demand is fast
/// (the slowest list cadence, so a poll never costs more than the tabs'
/// own), every 60 s while it is slow or the API is absent (Low power doubles
/// each), and none while it is off. One loop makes every read and awaits
/// each, so no two are ever in flight.
public enum MetricsSchedule {
    /// The current `PollProfile`'s fast and slow cadences, and its retry
    /// while metrics-server is absent.
    public static var interval: Duration { PollSchedule.intervals.metrics }
    public static var slowInterval: Duration { PollSchedule.intervals.metricsSlow }
    public static var absentInterval: Duration { PollSchedule.intervals.metricsAbsent }
    /// How soon a poll with no demand looks again.
    public static let hiddenRecheck: Duration = .seconds(5)

    /// The cadence for `demand` in `intervals`, nil while it is off.
    public static func interval(for demand: MetricsDemand, in intervals: PollIntervals) -> Duration? {
        switch demand {
        case .off: nil
        case .slow: intervals.metricsSlow
        case .fast: intervals.metrics
        }
    }

    /// The next move: wait while the demand is off; read when nothing has
    /// been read or the demand's interval (the absent retry, when longer)
    /// has passed since the last read; otherwise wait out the rest of it.
    /// The interval is the current demand's, so a rise reads at once when
    /// the last read is older than the new interval, and a fall waits out
    /// the longer one. A last read in the future (the clock moved back)
    /// waits one whole interval. `unit` is the caller's jitter draw for this
    /// wait (`PollJitter`), drawn once after each read and passed in
    /// unchanged until the next, so the interval is `PollJitter.spread` of
    /// the profile's; at 0 it is exact. The recheck while off is not spread.
    public static func step(
        demand: MetricsDemand, lastRead: Date?, now: Date, absent: Bool, unit: Double = 0,
        intervals: PollIntervals = PollSchedule.intervals
    ) -> MetricsStep {
        guard let base = interval(for: demand, in: intervals) else { return .wait(hiddenRecheck) }
        guard let lastRead else { return .read }
        let due = PollJitter.spread(absent ? max(base, intervals.metricsAbsent) : base, unit: unit)
        let dueSeconds = Double(due.components.seconds) + Double(due.components.attoseconds) / 1e18
        let elapsed = now.timeIntervalSince(lastRead)
        guard elapsed >= 0 else { return .wait(due) }
        if elapsed >= dueSeconds { return .read }
        return .wait(.milliseconds(Int64(((dueSeconds - elapsed) * 1000).rounded(.up))))
    }
}
