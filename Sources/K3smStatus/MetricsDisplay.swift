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

/// LoadBar is one live meter: the share of allocatable used, for the bar
/// (0 to 1; nil when the allocatable is unknown), the whole percentage, and
/// the text beside it ("1.43 of 19 cores · 8%", "12 GB of 60 GB · 20%").
/// Usage past allocatable fills the bar and shows its real percentage.
/// `amount` and `total` are the two figures alone ("1.43" and "19"), for
/// the panel's stacked bars (`LoadStack`).
public struct LoadBar: Equatable, Sendable {
    public let fraction: Double?
    public let percent: Int?
    public let text: String
    public let amount: String
    public let total: String?

    public init(fraction: Double?, percent: Int?, text: String, amount: String? = nil, total: String? = nil) {
        self.fraction = fraction
        self.percent = percent
        self.text = text
        self.amount = amount ?? text
        self.total = total
    }

    /// Cores used of the node's allocatable cores.
    public static func cores(used: Double, allocatable: Double?) -> LoadBar {
        let amount = MetricsDisplay.cores(used)
        guard let allocatable, allocatable > 0 else {
            return LoadBar(fraction: nil, percent: nil, text: "\(amount) cores", amount: amount)
        }
        let total = MetricsDisplay.cores(allocatable)
        return bar(used / allocatable, text: "\(amount) of \(total) cores", amount: amount, total: total)
    }

    /// Bytes used of the node's allocatable memory.
    public static func memory(used: Int64, allocatable: Int64?) -> LoadBar {
        let amount = MetricsDisplay.bytes(used)
        guard let allocatable, allocatable > 0 else { return LoadBar(fraction: nil, percent: nil, text: amount, amount: amount) }
        let total = MetricsDisplay.bytes(allocatable)
        return bar(Double(used) / Double(allocatable), text: "\(amount) of \(total)", amount: amount, total: total)
    }

    private static func bar(_ share: Double, text: String, amount: String, total: String) -> LoadBar {
        guard share.isFinite, share >= 0 else {
            return LoadBar(fraction: nil, percent: nil, text: text, amount: amount, total: total)
        }
        let percent = Int(min(share * 100, 1_000_000).rounded())
        return LoadBar(fraction: min(1, share), percent: percent, text: "\(text) · \(percent)%", amount: amount, total: total)
    }
}

/// NodeLoad is a node's live load as its row shows it.
public enum NodeLoad: Equatable, Sendable {
    /// The last sample carries no figure for this node.
    case noSample
    case sampled(cpu: LoadBar, memory: LoadBar)

    public var text: String {
        switch self {
        case .noSample: return MetricsDisplay.noMetricsYet
        case .sampled(let cpu, let memory): return "\(cpu.text), \(memory.text)"
        }
    }
}

/// MetricsDisplay turns the metrics state into what the panel and the pod
/// inspector show: per-node bars joined with the node list's allocatable,
/// a pod's usage, the sample's age, and the one line that says why the
/// rows are hidden. A node or pod the sample does not carry reads
/// "no metrics yet", never zero.
public enum MetricsDisplay {
    public static let noMetricsYet = "no metrics yet"

    /// A node's load, or nil when the rows are hidden: before the first
    /// sample, or while the API is absent.
    public static func nodeLoad(named name: String, nodes: [ClusterNode]?, state: MetricsState) -> NodeLoad? {
        guard state.absent == nil, let sample = state.sample else { return nil }
        guard let usage = sample.nodes[name], let cores = usage.cores, let bytes = usage.memoryBytes else { return .noSample }
        let node = nodes?.first { $0.name == name }
        return .sampled(
            cpu: .cores(used: cores, allocatable: node?.allocatableMilliCPU.map { Double($0) / 1000 }),
            memory: .memory(used: bytes, allocatable: node?.allocatableMemoryBytes))
    }

    /// The node's CPU share of allocatable over the ring, oldest first,
    /// for a sparkline; empty without an allocatable or while hidden.
    public static func sparkline(named name: String, nodes: [ClusterNode]?, state: MetricsState) -> [Double] {
        guard state.absent == nil, state.sample != nil,
              let milli = nodes?.first(where: { $0.name == name })?.allocatableMilliCPU, milli > 0 else { return [] }
        let total = Double(milli) / 1000
        return (state.history[name] ?? []).compactMap { $0.cores.map { min(1, $0 / total) } }
    }

    /// The node the This Mac view's load is for: the one the report names,
    /// else the only node of the list.
    public static func thisMacNode(report: StatusReport?, nodes: [ClusterNode]?) -> String? {
        if let report, let own = ClusterDisplay.ownNodeName(report) { return own }
        if let nodes, nodes.count == 1 { return nodes[0].name }
        return nil
    }

    /// The pod inspector's rows: its CPU (with its share of the request when
    /// it has one), its memory and the sample's age; "no metrics yet" when
    /// the sample does not carry the pod; nothing while the rows are hidden
    /// or the pod read failed.
    public static func podFacts(_ pod: Pod, state: MetricsState, now: Date = Date()) -> [InspectorFact] {
        guard state.absent == nil, let pods = state.sample?.pods, let at = state.sampledAt else { return [] }
        guard let usage = pods[pod.key] else { return [InspectorFact("Load", noMetricsYet)] }
        var cpu = "\(cores(usage.cores)) cores"
        if let request = pod.cpuRequest, request > 0 {
            cpu += " · \(Int(min(usage.cores / request * 100, 1_000_000).rounded()))% of request"
        }
        return [
            InspectorFact("CPU used", cpu),
            InspectorFact("Memory used", bytes(usage.memoryBytes)),
            InspectorFact("Sampled", age(since: at, now: now)),
        ]
    }

    /// The line under the live rows: the sample's age and the last read's
    /// failure. Nil before any read and while the API is absent: the bars
    /// then draw only what pods request, and their key says so.
    public static func note(_ state: MetricsState, now: Date = Date()) -> String? {
        if state.absent != nil { return nil }
        guard let at = state.sampledAt else {
            return state.lastError.map { "No metrics yet. The read failed: \($0)" }
        }
        var line = "Used, from metrics-server, \(age(since: at, now: now))."
        if let error = state.lastError { line += " The last read failed: \(error)" }
        return line
    }

    /// How old a sample is: "just now", "12 s ago", "3 min ago", "2 h ago".
    public static func age(since time: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(time))
        switch seconds {
        case ..<5: return "just now"
        case ..<60: return "\(Int(seconds)) s ago"
        case ..<3600: return "\(Int(seconds / 60)) min ago"
        default: return "\(Int(seconds / 3600)) h ago"
        }
    }

    /// Cores used: three decimals under 0.1, two under 10, one under 100,
    /// whole above; capped like the request figures.
    public static func cores(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return "0" }
        if value >= WorkloadsDisplay.maxCores { return "\(Int(WorkloadsDisplay.maxCores))+" }
        if value == value.rounded() { return String(Int(value)) }
        switch value {
        case ..<0.1: return String(format: "%.3f", value)
        case ..<10: return String(format: "%.2f", value)
        case ..<100: return String(format: "%.1f", value)
        default: return String(format: "%.0f", value)
        }
    }

    /// Bytes used, as the request figures show them; zero is "0 MB".
    public static func bytes(_ value: Int64) -> String {
        value > 0 ? WorkloadsDisplay.bytes(value) : "0 MB"
    }
}
