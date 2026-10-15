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

import K3smStatus
import SwiftUI

/// MacPanel is the left column: the machine, what the pods ask of it, the
/// data root, the cluster's nodes and the daemons from the status report.
struct MacPanel: View {
    @ObservedObject var workloads: WorkloadsModel
    let report: StatusReport?
    /// This Mac's installed k3sm, as the window last read it.
    let installed: SemanticVersion?

    private static let machine = HostFacts.read()
    /// The status rows the panel lists, in the report's order.
    private static let daemons: Set<String> = ["netd", "server", "agent", "apiserver", "node", "datastore"]
    /// The state words that read as healthy; anything else is shown in amber.
    private static let healthy: Set<String> = ["running", "ok", "ready", "healthy"]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Wordmark()
                .padding(.top, 44)
            VStack(alignment: .leading, spacing: 4) {
                Text("This Mac is the cluster").font(.system(size: 21, weight: .semibold)).foregroundStyle(.white)
                Text(verbatim: Self.machine.line).font(.system(size: 12)).foregroundStyle(.white.opacity(0.62))
                HStack(spacing: 7) {
                    Circle().fill(report?.verdict == .running ? Palette.okOnDark : .orange).frame(width: 8, height: 8)
                    Text(verbatim: stateLine).font(.system(size: 12)).foregroundStyle(.white)
                }
                .padding(.top, 4)
            }
            PanelBlock("Cores requested by pods", value: "\(WorkloadsDisplay.cores(coresRequested)) of \(Self.machine.cores)") {
                CoreGrid(cores: Self.machine.cores, performance: Self.machine.performanceCores, used: coresRequested)
                Footnote("Squares are performance cores, circles are efficiency cores. Requests, not use.")
            }
            PanelBlock("Unified memory", value: "\(WorkloadsDisplay.bytes(workloads.load.memoryUsedBytes)) of \(WorkloadsDisplay.bytes(Self.machine.memoryBytes))") {
                Meter(parts: [(Double(memoryRequested), Palette.fill), (Double(max(0, workloads.load.memoryUsedBytes - memoryRequested)), Palette.fillDim)], total: Double(Self.machine.memoryBytes))
                Legend(rows: [("Requested by pods", Palette.fill, WorkloadsDisplay.bytes(memoryRequested)), ("macOS and apps", Palette.fillDim, WorkloadsDisplay.bytes(workloads.load.memoryUsedBytes))])
            }
            PanelBlock("Data root", value: "\(WorkloadsDisplay.bytes(workloads.load.dataRootUsedBytes)) of \(WorkloadsDisplay.bytes(workloads.load.dataRootSizeBytes))") {
                Meter(parts: [(Double(workloads.load.dataRootUsedBytes), Palette.fill)], total: Double(workloads.load.dataRootSizeBytes))
                Footnote("\(HostFacts.dataRoot), the volume it sits on")
            }
            if let nodes {
                PanelBlock("Nodes", value: nodes.heading ?? "") {
                    nodeRows(nodes)
                }
            }
            Spacer()
            daemonRows
            Footnote("Start, stop and uninstall are behind the info button.")
        }
        .padding([.horizontal, .bottom], 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.deep)
    }

    private var pods: [Pod] { workloads.workloads?.pods ?? [] }
    private var coresRequested: Double { pods.compactMap(\.cpuRequest).reduce(0, +) }
    private var memoryRequested: Int64 { pods.compactMap(\.memoryRequest).reduce(0, +) }

    private var stateLine: String {
        let count = "\(pods.count) \(pods.count == 1 ? "pod" : "pods")"
        guard let report else { return "Status not read, \(count)" }
        return report.verdict == .running ? "Running, \(count)" : "\(report.verdict.word): \(report.summary)"
    }

    /// The nodes block, re-derived from each report; nil before the first read.
    private var nodes: NodesView? {
        report.map { NodesDisplay.view(report: $0, installed: installed) }
    }

    private func nodeRows(_ nodes: NodesView) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(nodes.lines.enumerated()), id: \.offset) { _, line in
                HStack(spacing: 8) {
                    Text(verbatim: line.name).foregroundStyle(.white.opacity(0.8)).lineLimit(1).truncationMode(.middle)
                    Text(verbatim: line.role).foregroundStyle(.white.opacity(0.55))
                    Spacer()
                    Text(verbatim: line.version).foregroundStyle(.white).monospacedDigit()
                }
                .font(.system(size: 12))
            }
            if let note = nodes.note {
                Footnote(note)
            }
        }
    }

    private var daemonRows: some View {
        VStack(spacing: 5) {
            ForEach((report?.rows ?? []).filter { Self.daemons.contains($0.name) }, id: \.name) { row in
                HStack {
                    Text(verbatim: StatusDisplay.clip(row.name)).foregroundStyle(.white.opacity(0.8))
                    Spacer()
                    Text(verbatim: StatusDisplay.clip(row.state)).foregroundStyle(Self.healthy.contains(row.state) ? Palette.okOnDark : .orange)
                }
                .font(.system(size: 12))
            }
        }
        .padding(.top, 12)
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.12)).frame(height: 1) }
    }
}

/// Wordmark is the k3sm mark and name, under the window controls.
struct Wordmark: View {
    var body: some View {
        HStack(spacing: 9) {
            Butterfly().fill(.white).frame(width: 24, height: 24)
            Text("k3sm").font(.system(size: 19, weight: .semibold)).foregroundStyle(.white)
        }
    }
}

/// PanelBlock is a titled block of the panel with its value on the right.
struct PanelBlock<Content: View>: View {
    let title: String
    let value: String
    @ViewBuilder let content: () -> Content

    init(_ title: String, value: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.value = value
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).foregroundStyle(.white.opacity(0.62))
                Spacer()
                Text(verbatim: value).foregroundStyle(.white).monospacedDigit()
            }
            .font(.system(size: 12, weight: .medium))
            content()
        }
    }
}

/// CoreGrid is one cell per core, squares for performance cores and circles
/// for efficiency cores, filled by how many cores are asked for.
struct CoreGrid: View {
    let cores: Int
    let performance: Int
    let used: Double

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 8), spacing: 5) {
            ForEach(0..<max(cores, 0), id: \.self) { i in
                let fast = i < performance
                let shape = RoundedRectangle(cornerRadius: fast ? 5 : 11)
                ZStack(alignment: .bottom) {
                    shape.fill(Palette.deep2)
                    shape.fill(fast ? Palette.fill : Palette.fillSoft)
                        .frame(height: 22 * max(0, min(1, used - Double(i))))
                }
                .frame(height: 22)
                .clipShape(shape)
            }
        }
    }
}

/// Meter is a bar of parts over a total, on the panel's track.
struct Meter: View {
    let parts: [(Double, Color)]
    let total: Double

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1.5) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    Rectangle().fill(part.1).frame(width: total > 0 ? geo.size.width * part.0 / total : 0)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 12)
        .background(Palette.deep2)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

/// Legend names a meter's parts with their values.
struct Legend: View {
    let rows: [(String, Color, String)]

    var body: some View {
        VStack(spacing: 4) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2).fill(row.1).frame(width: 8, height: 8)
                    Text(row.0).foregroundStyle(.white.opacity(0.8))
                    Spacer()
                    Text(verbatim: row.2).foregroundStyle(.white).monospacedDigit()
                }
                .font(.system(size: 12))
            }
        }
    }
}

/// Footnote is the panel's small print.
struct Footnote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.55))
            .fixedSize(horizontal: false, vertical: true)
    }
}
