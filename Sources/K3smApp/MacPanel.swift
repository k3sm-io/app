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

/// MacPanel is the left column, scrolled. With more than one node a switch
/// at the top picks the view: Cluster (the cluster's stats, its nodes with
/// what their pods request, the cluster's cores and memory) or This Mac (the
/// machine, what the pods ask of it, the data root, the nodes block). Both
/// end with the daemons from the status report.
struct MacPanel: View {
    @ObservedObject var app: AppModel
    @ObservedObject var workloads: WorkloadsModel

    private static let machine = HostFacts.read()
    /// The status rows the panel lists, in the report's order.
    private static let daemons: Set<String> = ["netd", "server", "agent", "apiserver", "node", "datastore"]
    /// The state words that read as healthy; anything else is shown in amber.
    private static let healthy: Set<String> = ["running", "ok", "ready", "healthy"]

    private var report: StatusReport? { app.report }

    var body: some View {
        ScrollView(.vertical) {
            content
                .padding([.horizontal, .bottom], 20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.deep)
    }

    /// The column, top to bottom: the switch, the view, then the daemons. It
    /// scrolls, so nothing is cut off in a short window.
    private var content: some View {
        VStack(alignment: .leading, spacing: 18) {
            Wordmark(flap: app.flap)
                .padding(.top, 44)
            if PanelMode.showsSwitch(nodeCount: cluster.nodeCount) {
                HStack(spacing: 18) {
                    ForEach(PanelMode.allCases, id: \.self) { m in
                        Button(m.title) { app.panelMode = m }
                            .buttonStyle(PanelTabStyle(selected: mode == m))
                            .accessibilityAddTraits(mode == m ? .isSelected : [])
                    }
                    Spacer(minLength: 0)
                }
                .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.12)).frame(height: 1) }
            }
            if mode == .cluster {
                clusterView
            } else {
                thisMacView
            }
            daemonRows
            Footnote("Start, stop and uninstall are behind the info button.")
        }
    }

    /// The cluster view: title and stats, one row per node, the cluster meters.
    @ViewBuilder private var clusterView: some View {
        VStack(alignment: .leading, spacing: 4) {
            if PanelMode.showsHeading(nodeCount: cluster.nodeCount) {
                Text(verbatim: cluster.title).font(.system(size: 21, weight: .semibold)).foregroundStyle(.white)
            }
            if let line = cluster.line {
                Text(verbatim: line).font(.system(size: 12)).foregroundStyle(.white.opacity(0.8)).monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let note = cluster.note {
                Footnote(note)
            }
            stateRow.padding(.top, 4)
        }
        if cluster.nodes.isEmpty {
            nodesBlock
        } else {
            PanelBlock("Nodes", value: "\(cluster.nodes.filter(\.isReady).count)/\(cluster.nodes.count) ready") {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(cluster.nodes.enumerated()), id: \.offset) { _, node in
                        clusterNodeRow(node)
                    }
                    if let line = cluster.podsByNode {
                        Footnote("Running pods: \(line)")
                    }
                }
            }
        }
        if let cores = cluster.cores {
            PanelBlock("Cores requested", value: cores.text) {
                Meter(parts: [(cores.requested, Palette.fill)], total: cores.allocatable)
                Footnote("Requests of the cores the nodes offer to pods, not use.")
            }
        }
        if let memory = cluster.memory {
            PanelBlock("Memory requested", value: memory.text) {
                Meter(parts: [(memory.requested, Palette.fill)], total: memory.allocatable)
            }
        }
    }

    private func clusterNodeRow(_ node: ClusterNodeRow) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Circle().fill(node.isReady ? Palette.okOnDark : .orange).frame(width: 7, height: 7)
                Text(verbatim: node.thisMac ? "\(node.name) (this Mac)" : node.name)
                    .foregroundStyle(.white).lineLimit(1).truncationMode(.middle)
                Spacer()
                if let version = node.version {
                    Text(verbatim: version).foregroundStyle(.white.opacity(0.8)).monospacedDigit()
                }
            }
            .font(.system(size: 12, weight: .medium))
            Text(verbatim: "\(node.role) · \(node.ready)").font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
            if let cores = node.cores {
                usageRow("Cores", cores)
            }
            if let memory = node.memory {
                usageRow("Memory", memory)
            }
        }
    }

    private func usageRow(_ title: String, _ usage: ClusterUsage) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).foregroundStyle(.white.opacity(0.62))
                Spacer()
                Text(verbatim: usage.text).foregroundStyle(.white.opacity(0.8)).monospacedDigit()
            }
            .font(.system(size: 11))
            Meter(parts: [(usage.requested, Palette.fill)], total: usage.allocatable, height: 6)
        }
    }

    /// This Mac's view: the machine, the nodes block, the three meters.
    @ViewBuilder private var thisMacView: some View {
        VStack(alignment: .leading, spacing: 4) {
            if PanelMode.showsHeading(nodeCount: cluster.nodeCount) {
                Text(verbatim: cluster.title).font(.system(size: 21, weight: .semibold)).foregroundStyle(.white)
            }
            Text(verbatim: Self.machine.line).font(.system(size: 12)).foregroundStyle(.white.opacity(0.62))
            stateRow.padding(.top, 4)
        }
        nodesBlock
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
    }

    private var stateRow: some View {
        HStack(spacing: 7) {
            Circle().fill(report?.verdict == .running ? Palette.okOnDark : .orange).frame(width: 8, height: 8)
            Text(verbatim: stateLine).font(.system(size: 12)).foregroundStyle(.white)
        }
    }

    /// The nodes block from the status report: this Mac, then `workers`.
    @ViewBuilder private var nodesBlock: some View {
        if let nodes {
            PanelBlock("Nodes", value: nodes.heading ?? "") {
                nodeRows(nodes)
            }
        }
    }

    /// The cluster view, re-derived from the report and the two lists.
    private var cluster: ClusterSummary {
        ClusterDisplay.summary(of: report, nodes: workloads.nodes, pods: workloads.workloads?.pods)
    }

    /// The view shown: the user's choice, by `PanelMode.effective`.
    private var mode: PanelMode { PanelMode.effective(chosen: app.panelMode, nodeCount: cluster.nodeCount) }

    private var pods: [Pod] { workloads.workloads?.pods ?? [] }
    /// The pods on this Mac, for the This Mac meters.
    private var macPods: [Pod] { ClusterDisplay.thisMacPods(pods, report: report, nodeCount: cluster.nodeCount) }
    private var coresRequested: Double { macPods.compactMap(\.cpuRequest).reduce(0, +) }
    private var memoryRequested: Int64 { macPods.compactMap(\.memoryRequest).reduce(0, +) }

    private var stateLine: String {
        let count = "\(pods.count) \(pods.count == 1 ? "pod" : "pods")"
        guard let report else { return "Status not read, \(count)" }
        return report.verdict == .running ? "Running, \(count)" : "\(report.verdict.word): \(report.summary)"
    }

    /// The nodes block, re-derived from each report; nil before the first read.
    private var nodes: NodesView? {
        report.map { NodesDisplay.view(report: $0, installed: app.installedVersion) }
    }

    private func nodeRows(_ nodes: NodesView) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(nodes.lines.enumerated()), id: \.offset) { _, line in
                HStack(spacing: 8) {
                    Text(verbatim: line.name).foregroundStyle(.white.opacity(0.8)).lineLimit(1).truncationMode(.middle)
                    Text(verbatim: line.role).foregroundStyle(.white.opacity(0.55))
                    Spacer()
                    if let version = line.version {
                        Text(verbatim: version).foregroundStyle(.white).monospacedDigit()
                    }
                }
                .font(.system(size: 12))
            }
            if let versions = nodes.versions {
                Text(verbatim: versions).font(.system(size: 12)).foregroundStyle(.white.opacity(0.8)).monospacedDigit()
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
    @ObservedObject var flap: FlapModel

    var body: some View {
        HStack(spacing: 9) {
            FlappingButterfly(angle: flap.angle).frame(width: 24, height: 24)
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
    var height: CGFloat = 12

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1.5) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    Rectangle().fill(part.1).frame(width: total > 0 ? geo.size.width * part.0 / total : 0)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: height)
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

/// PanelTabStyle is a tab in the panel's tab strip: full-white text and a
/// 2 pt white underline on the strip's hairline when selected, dimmer text
/// and no underline otherwise. No fill, no outline.
struct PanelTabStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(selected ? Color.white : Color.white.opacity(0.55))
            .padding(.bottom, 8)
            .overlay(alignment: .bottom) { Rectangle().fill(selected ? Color.white : Color.clear).frame(height: 2) }
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// FlappingButterfly is the mark with each wing hinged at the body: the left
/// and right halves turn about the vertical centre line by `angle` degrees in
/// opposite directions, in perspective, so the wings swing toward the viewer.
/// At 0 it draws exactly the flat mark.
struct FlappingButterfly: View {
    let angle: Double

    var body: some View {
        ZStack {
            wing(left: true).rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), anchor: .center, perspective: 0.5)
            wing(left: false).rotation3DEffect(.degrees(-angle), axis: (x: 0, y: 1, z: 0), anchor: .center, perspective: 0.5)
        }
        .accessibilityHidden(true)
    }

    /// wing is the half of the mark on the left (`left`) or right of the
    /// centre line.
    private func wing(left: Bool) -> some View {
        Butterfly().fill(.white).mask {
            HStack(spacing: 0) {
                Rectangle().opacity(left ? 1 : 0)
                Rectangle().opacity(left ? 0 : 1)
            }
        }
    }
}
