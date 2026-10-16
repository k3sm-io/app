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
/// at the top picks the view: Cluster (the state, a grid of tiles with the
/// cluster's figures, one compact row per node with what its pods request)
/// or This Mac (the machine, the state, tiles with what the pods ask of it
/// and the data root, the nodes block, the core grid and the memory meter).
/// Both end with the daemons from the status report. It is the left pane
/// of the console's split view: wider than its minimum, the tiles take more
/// columns and a node row puts its meters on its own line.
struct MacPanel: View {
    @ObservedObject var app: AppModel
    @ObservedObject var workloads: WorkloadsModel

    private static let machine = HostFacts.read()
    /// The status rows the panel lists, in the report's order.
    private static let daemons: Set<String> = ["netd", "server", "agent", "apiserver", "node", "datastore"]

    private var report: StatusReport? { app.report }
    private var tour: TourModel { app.tour }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                content
                    .padding([.horizontal, .bottom], 20)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .onReceive(tour.$scrollTarget.compactMap { $0 }) { target in
                // A tour stop in the panel is scrolled into view before it is lit.
                withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(target, anchor: .top) }
                tour.scrollTarget = nil
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.deep)
    }

    /// The column, top to bottom: the switch, the view, then the daemons. It
    /// scrolls, so nothing is cut off in a short window.
    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            Wordmark(flap: app.flap, tour: tour)
                .padding(.top, 44)
            if PanelMode.showsSwitch(nodeCount: cluster.nodeCount) {
                HStack(spacing: 18) {
                    ForEach(PanelMode.allCases, id: \.self) { m in
                        Button(m.title) { app.panelMode = m }
                            .buttonStyle(PanelTabStyle(selected: mode == m))
                            .accessibilityAddTraits(mode == m ? .isSelected : [])
                            .help(Help.Panel.mode(m))
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
            interconnectBlock
            daemonRows
            Footnote("Start, stop and uninstall are behind the info button.")
        }
    }

    /// The cluster view: the state above the tiles, then one compact row
    /// per node with what its pods request.
    @ViewBuilder private var clusterView: some View {
        VStack(alignment: .leading, spacing: 10) {
            if PanelMode.showsHeading(nodeCount: cluster.nodeCount) {
                Text(verbatim: cluster.title).font(.system(size: 21, weight: .semibold)).foregroundStyle(.white)
            }
            stateRow
            TileGrid(tiles: ClusterDisplay.tiles(for: cluster), width: shownWidth)
            if let note = cluster.note {
                Footnote(note)
            }
        }
        if cluster.nodes.isEmpty {
            nodesBlock
        } else {
            PanelBlock("Nodes", value: cluster.versions ?? "") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(cluster.nodes.enumerated()), id: \.offset) { _, node in
                        clusterNodeRow(node)
                        if let load = MetricsDisplay.nodeLoad(named: node.name, nodes: workloads.nodes, state: workloads.metrics) {
                            LiveLoadRow(load: load, sparkline: MetricsDisplay.sparkline(named: node.name, nodes: workloads.nodes, state: workloads.metrics))
                        }
                    }
                }
                Footnote("Requested by pods, not used.")
                MetricsNote(state: workloads.metrics)
            }
        }
    }

    /// One node: the readiness dot, the name with a tag on this Mac's, the
    /// role and its running pods, then its cores and memory meters side by
    /// side, on the same line when the panel is wide enough, under it otherwise.
    private func clusterNodeRow(_ node: ClusterNodeRow) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: PanelLayout.tileSpacing) {
                nodeHeading(node)
                slimMeter("Cores", node.cores, help: Help.Panel.nodeCores).frame(width: PanelLayout.meterWidth)
                slimMeter("Memory", node.memory, help: Help.Panel.nodeMemory).frame(width: PanelLayout.meterWidth)
            }
            VStack(alignment: .leading, spacing: 6) {
                nodeHeading(node)
                HStack(spacing: 10) {
                    slimMeter("Cores", node.cores, help: Help.Panel.nodeCores)
                    slimMeter("Memory", node.memory, help: Help.Panel.nodeMemory)
                }
            }
        }
    }

    /// A node row's first part: the dot, the name, the tag, the role and the pods.
    private func nodeHeading(_ node: ClusterNodeRow) -> some View {
        HStack(spacing: 6) {
            Circle().fill(node.isReady ? Palette.okOnDark : Palette.warnOnDark).frame(width: 7, height: 7)
                .accessibilityLabel(Text(verbatim: node.ready))
                .help(Help.Panel.nodeDot)
            Text(verbatim: node.name).font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                .lineLimit(1).truncationMode(.middle)
            if node.thisMac {
                Text("this Mac").font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(.white.opacity(0.14)))
                    .fixedSize()
            }
            Text(verbatim: node.role).font(.system(size: 11)).foregroundStyle(.white.opacity(0.62)).lineLimit(1)
            Spacer(minLength: 4)
            if let running = node.running {
                Text(verbatim: "\(running) \(running == 1 ? "pod" : "pods")").font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(.white.opacity(0.62)).fixedSize()
            }
        }
    }

    /// A 5 pt meter with its value under it, dim and monospaced; an empty
    /// track when the node's allocatable is unknown.
    private func slimMeter(_ title: String, _ usage: ClusterUsage?, help: HelpTag) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Meter(parts: [(usage?.requested ?? 0, Palette.fill)], total: usage?.allocatable ?? 0)
            Text(verbatim: usage?.text ?? " ").font(.system(size: 10)).monospacedDigit()
                .foregroundStyle(.white.opacity(0.62)).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(title) \(usage?.text ?? "unknown")"))
        .help(help)
    }

    /// This Mac's view: the machine, the state and the tiles, the nodes
    /// block, the core grid and the memory meter.
    @ViewBuilder private var thisMacView: some View {
        VStack(alignment: .leading, spacing: 10) {
            if PanelMode.showsHeading(nodeCount: cluster.nodeCount) {
                Text(verbatim: cluster.title).font(.system(size: 21, weight: .semibold)).foregroundStyle(.white)
            }
            Text(verbatim: Self.machine.line).font(.system(size: 12)).foregroundStyle(.white.opacity(0.62))
            stateRow
            TileGrid(tiles: macTiles, width: shownWidth)
        }
        .id(TourTarget.summary)
        .tourTarget(.summary, tour)
        nodesBlock
        LiveLoadBlock(node: MetricsDisplay.thisMacNode(report: report, nodes: workloads.nodes),
                      nodes: workloads.nodes, state: workloads.metrics)
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                CoreGrid(cores: Self.machine.cores, performance: Self.machine.performanceCores, used: coresRequested)
                    .help(Help.Panel.coreGrid)
                Footnote("Squares are performance cores, circles efficiency cores.")
            }
            memoryBlock
        }
        .id(TourTarget.cores)
        .tourTarget(.cores, tour)
    }

    private var memoryBlock: some View {
        PanelBlock("Unified memory", value: "\(WorkloadsDisplay.bytes(workloads.load.memoryUsedBytes)) of \(WorkloadsDisplay.bytes(Self.machine.memoryBytes))") {
            Meter(parts: [(Double(memoryRequested), Palette.fill), (Double(max(0, workloads.load.memoryUsedBytes - memoryRequested)), Palette.fillDim)], total: Double(Self.machine.memoryBytes))
                .help(Help.Panel.memoryMeter)
            Legend(rows: [("Requested by pods", Palette.fill, WorkloadsDisplay.bytes(memoryRequested)), ("macOS and apps", Palette.fillDim, WorkloadsDisplay.bytes(workloads.load.memoryUsedBytes))])
        }
    }

    private var stateRow: some View {
        HStack(spacing: 7) {
            Circle().fill(report?.verdict == .running ? Palette.okOnDark : Palette.warnOnDark).frame(width: 8, height: 8)
                .help(Help.Panel.stateDot)
            Text(verbatim: stateLine).font(.system(size: 12)).foregroundStyle(.white)
            // The pod figures' age, once their read is late or failing.
            TimelineView(.periodic(from: .now, by: 5)) { context in
                if let age = PollSchedule.panelAge(podsReadAt: workloads.readAt, now: context.date) {
                    Text(verbatim: age).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                }
            }
        }
    }

    /// The Interconnect block, only while the full report carries an armed
    /// interconnect (`InterconnectCard`).
    @ViewBuilder private var interconnectBlock: some View {
        if let card = InterconnectCard.card(for: report) {
            PanelBlock("Interconnect", value: card.medium) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: card.nodes).foregroundStyle(.white.opacity(0.8))
                    Text(verbatim: "\(card.segments) · \(card.pods)").foregroundStyle(.white.opacity(0.62))
                    if let outOfRange = card.outOfRange {
                        Text(verbatim: outOfRange).foregroundStyle(.white.opacity(0.62)).lineLimit(1).truncationMode(.tail)
                    }
                    if let warning = card.warning {
                        Footnote(warning)
                    }
                }
                .font(.system(size: 12))
            }
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

    /// This Mac's tiles, from its pods and the machine.
    private var macTiles: [PanelTile] {
        ClusterDisplay.macTiles(
            requests: macRequests, cores: Self.machine.cores, memoryBytes: Self.machine.memoryBytes,
            dataRootUsed: workloads.load.dataRootUsedBytes, dataRootSize: workloads.load.dataRootSizeBytes,
            pods: macPods.count)
    }

    /// What the view shown holds, for `PanelLayout.widthRange`: its tiles,
    /// the Cluster view's node rows and the nodes block's lines.
    var layoutContent: PanelContent {
        switch mode {
        case .cluster:
            return PanelContent(tiles: ClusterDisplay.tiles(for: cluster), nodes: cluster.nodes,
                                lines: cluster.nodes.isEmpty ? nodes?.lines ?? [] : [])
        case .thisMac:
            return PanelContent(tiles: macTiles, lines: nodes?.lines ?? [])
        }
    }

    /// The width the panel is drawn at: the user's, within the content's range.
    private var shownWidth: Double {
        PanelLayout.clamp(app.consolePanelWidth, to: PanelLayout.widthRange(content: layoutContent))
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
    /// What those pods request, by `ClusterDisplay.requests`.
    private var macRequests: PodRequests { ClusterDisplay.requests(of: macPods) }
    private var coresRequested: Double { macRequests.cores }
    private var memoryRequested: Int64 { macRequests.memoryBytes }

    private var stateLine: String { StatusDisplay.panelStateLine(report, podCount: pods.count) }

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
                    Image(systemName: row.rowState.tone.symbolName)
                        .foregroundStyle(Palette.rowOnDark(row.rowState.tone))
                        .accessibilityLabel(Text(verbatim: row.rowState.tone.word))
                    Text(verbatim: StatusDisplay.panelText(row)).foregroundStyle(Palette.rowOnDark(row.rowState.tone))
                        .lineLimit(1).truncationMode(.tail)
                }
                .font(.system(size: 12))
            }
        }
        .padding(.top, 12)
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.12)).frame(height: 1) }
    }
}

/// Wordmark is the k3sm mark and name, under the window controls. The
/// pointer entering the mark asks the model for a beat.
struct Wordmark: View {
    @ObservedObject var flap: FlapModel
    @ObservedObject var tour: TourModel

    var body: some View {
        HStack(spacing: 9) {
            // While the tour runs the mark is away guiding it, so its spot is empty.
            FlappingButterfly(angle: flap.angle).frame(width: 24, height: 24)
                .opacity(tour.markAway ? 0 : 1)
                .tourHome(tour)
                .onHover { inside in if inside { flap.poke() } }
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
        VStack(alignment: .leading, spacing: 10) {
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

/// TileGrid is the panel's figures in columns of tiles: two, or every tile
/// in one row once the panel is wide enough (`PanelLayout.columns`).
struct TileGrid: View {
    let tiles: [PanelTile]
    let width: Double

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .topLeading),
                                 count: PanelLayout.columns(width: width, tiles: tiles)),
                  alignment: .leading, spacing: 10) {
            ForEach(Array(tiles.enumerated()), id: \.offset) { _, tile in
                Tile(tile: tile).help(Help.Panel.tile(tile))
            }
        }
    }
}

/// Tile is one figure: the value large, its "of" beside it (or under it
/// when the two do not fit), and the label small and lowercase below.
struct Tile: View {
    let tile: PanelTile

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    value
                    detail
                }
                VStack(alignment: .leading, spacing: 1) {
                    value
                    detail
                }
            }
            Text(verbatim: tile.label).font(.system(size: 11)).foregroundStyle(.white.opacity(0.62)).lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.deepRaised))
        .accessibilityElement(children: .combine)
    }

    private var value: some View {
        Text(verbatim: tile.value).font(.system(size: 20, weight: .semibold)).monospacedDigit()
            .foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.6)
    }

    @ViewBuilder private var detail: some View {
        if let detail = tile.detail {
            Text(verbatim: detail).font(.system(size: 11)).monospacedDigit()
                .foregroundStyle(.white.opacity(0.62)).lineLimit(1).fixedSize()
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
    var height: CGFloat = 5

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
        .clipShape(RoundedRectangle(cornerRadius: height / 2))
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
    var color: Color = .white

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
        Butterfly().fill(color).mask {
            HStack(spacing: 0) {
                Rectangle().opacity(left ? 1 : 0)
                Rectangle().opacity(left ? 0 : 1)
            }
        }
    }
}
