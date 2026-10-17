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

/// LoadPart is a part of a panel load bar, as the bar's key names it: what
/// pods request (a light band) or what is used now (solid over it).
public enum LoadPart: Equatable, Sendable, CaseIterable {
    case requested
    case used

    /// The key's word for the part.
    public var label: String {
        switch self {
        case .requested: return "Requested"
        case .used: return "Used"
        }
    }
}

/// LoadStack is one resource's bar on the navy panel: the share of the
/// node's allocatable its pods request, drawn as a light band, and the share
/// it uses now, drawn solid over the band from the same start, with the
/// figures under the bar. A part whose share is unknown is nil and is not
/// drawn; neither share is ever below 0 or past the whole bar.
public struct LoadStack: Equatable, Sendable {
    /// The requested share, 0 to 1; nil when it is not known.
    public let requested: Double?
    /// The used share, 0 to 1; nil when it is not known.
    public let used: Double?
    /// The figures, one line per known figure, used first, the total on the
    /// first line: "1.43 used of 19 cores", "3.5 requested". Empty when
    /// neither figure is known.
    public let lines: [String]

    public init(requested: Double?, used: Double?, lines: [String]) {
        self.requested = requested.map(Self.clamp)
        self.used = used.map(Self.clamp)
        self.lines = lines
    }

    /// The figure lines with `title` before the first: "CPU 1.43 used of 19
    /// cores"; nothing when there is no figure.
    public func lines(titled title: String) -> [String] {
        guard let first = lines.first else { return [] }
        return ["\(title) \(first)"] + lines.dropFirst()
    }

    /// The parts the bar draws, in the key's order.
    public var parts: [LoadPart] {
        (requested == nil ? [] : [.requested]) + (used == nil ? [] : [.used])
    }

    /// CPU: the cores pods request of the node (`requested`) and the cores
    /// it used in the last sample (`used`), either nil when unknown.
    public static func cores(requested: ClusterUsage?, used: LoadBar?) -> LoadStack {
        stack(requested: requested, used: used, unit: "cores")
    }

    /// Memory: the bytes pods request of the node and its working set now.
    public static func memory(requested: ClusterUsage?, used: LoadBar?) -> LoadStack {
        stack(requested: requested, used: used, unit: nil)
    }

    /// The key under a block of bars: Requested while any bar draws a
    /// request, Used while any draws use, in that order; nothing when no bar
    /// draws either, so the key never names a part that is not on screen.
    public static func key(_ stacks: [LoadStack]) -> [LoadPart] {
        LoadPart.allCases.filter { part in stacks.contains { $0.parts.contains(part) } }
    }

    private static func stack(requested: ClusterUsage?, used: LoadBar?, unit: String?) -> LoadStack {
        let share = requested.flatMap { usage -> Double? in
            guard usage.allocatable.isFinite, usage.allocatable > 0, usage.requested.isFinite else { return nil }
            return usage.requested / usage.allocatable
        }
        var lines: [String] = []
        if let used { lines.append("\(used.amount) used") }
        if let requested { lines.append("\(requested.amount) requested") }
        if !lines.isEmpty, let total = used?.total ?? requested?.total {
            lines[0] += " of \(total)" + (unit.map { " \($0)" } ?? "")
        }
        return LoadStack(requested: share, used: used?.fraction, lines: lines)
    }

    /// `value` within 0...1; not a number is 0.
    private static func clamp(_ value: Double) -> Double {
        value.isFinite ? max(0, min(1, value)) : 0
    }
}

/// NodeBars is a node's two load bars on the panel, joined from what its
/// pods request (its Cluster view row) and its live load (the metrics
/// sample), with "no metrics yet" under them when the sample does not
/// carry the node.
public struct NodeBars: Equatable, Sendable {
    public let cpu: LoadStack
    public let memory: LoadStack
    public let note: String?

    public init(cpu: LoadStack, memory: LoadStack, note: String? = nil) {
        self.cpu = cpu
        self.memory = memory
        self.note = note
    }

    /// The node's bars from its row's requests (nil: not known) and its
    /// load (nil: the rows are hidden; `noSample`: the sample lacks it).
    public static func of(row: ClusterNodeRow?, load: NodeLoad?) -> NodeBars {
        var cpuUsed: LoadBar?
        var memoryUsed: LoadBar?
        var note: String?
        switch load {
        case .sampled(let cpu, let memory)?:
            cpuUsed = cpu
            memoryUsed = memory
        case .noSample?:
            note = MetricsDisplay.noMetricsYet
        case nil:
            break
        }
        return NodeBars(cpu: .cores(requested: row?.cores, used: cpuUsed),
                        memory: .memory(requested: row?.memory, used: memoryUsed), note: note)
    }

    /// Whether either bar has a figure to show.
    public var hasFigures: Bool { !cpu.lines.isEmpty || !memory.lines.isEmpty }

    /// Both bars, CPU first.
    public var stacks: [LoadStack] { [cpu, memory] }
}
