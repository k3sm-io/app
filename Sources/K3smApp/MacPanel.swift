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

/// MacPanel is the left column: the wordmark pinned at the top, the rest
/// scrolled. With more than one node a switch at the top picks the view: Cluster (the state, a grid of tiles with the
/// cluster's figures, one compact row per node with what its pods request)
/// or This Mac (the machine, the state, tiles with what it uses and the
/// data root, the nodes block, the core grid and the memory meter).
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
        VStack(alignment: .leading, spacing: 14) {
            // The wordmark stays put above the column: scrolling, by hand or
            // by the tour reaching a stop, never carries it out of view.
            Wordmark(flap: app.flap, tour: tour)
                .padding(.top, 44)
                .padding(.horizontal, PanelLayout.edge)
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    content
                        .padding(.horizontal, PanelLayout.edge)
                        .padding(.bottom, 20)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .onReceive(tour.$scrollTarget.compactMap { $0 }) { target in
                    // A tour stop in the panel is scrolled into view before it is lit.
                    withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(target, anchor: .top) }
                    tour.scrollTarget = nil
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(alignment: .topLeading) {
            // Both regions' blocks at their ideal widths, unseen: the widest
            // is the content the panel's natural width holds between its edges.
            PanelMeasure(regions: layoutRegions)
                .fixedSize()
                .hidden()
                .accessibilityHidden(true)
                .onGeometryChange(for: Double.self, of: { Double($0.size.width) }) { width in
                    app.panelMeasured(width)
                }
        }
        .background(Palette.deep)
    }

    /// The column under the wordmark: the figures, or while the set-up flow
    /// fills the content pane (`ConsolePane.setUp`) the "Not installed" state
    /// and a note. It scrolls, so nothing is cut off in a short window.
    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !app.pane.stripShown {
                stateRow
                Footnote(ConsolePane.setUpPanelNote)
            } else {
                figures
            }
        }
    }

    /// The figures once k3sm is installed: the switch, the view, then the daemons.
    @ViewBuilder private var figures: some View {
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

    /// The figures as the 2 by 2 tile grid.
    private func tileGrid(_ tiles: [PanelTile]) -> some View {
        TileGrid {
            ForEach(Array(tiles.enumerated()), id: \.offset) { _, tile in
                Tile(tile: tile).help(Help.Panel.tile(tile))
            }
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
            tileGrid(ClusterDisplay.tiles(for: cluster))
            if let note = cluster.note {
                Footnote(note)
            }
        }
        if cluster.nodes.isEmpty {
            nodesBlock
        } else {
            let bars = clusterBars
            PanelBlock("Nodes", value: cluster.versions ?? "") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(cluster.nodes.enumerated()), id: \.offset) { i, node in
                        clusterNodeRow(node, bars: bars[i])
                        if let note = bars[i].note {
                            Text(verbatim: note).font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
                        }
                    }
                }
                LoadKey(parts: LoadStack.key(bars.flatMap(\.stacks)))
                MetricsNote(state: workloads.metrics)
            }
        }
    }

    /// One node: the readiness dot, the name with a tag on this Mac's, the
    /// role and its running pods, then its CPU and memory bars side by side
    /// (requested and used in one bar each), on the same line when the panel
    /// is wide enough, under it otherwise.
    private func clusterNodeRow(_ node: ClusterNodeRow, bars: NodeBars) -> some View {
        ViewThatFits(in: .horizontal) {
            NodeRowLine(node: node, bars: bars)
            VStack(alignment: .leading, spacing: 6) {
                NodeHeading(node: node)
                HStack(alignment: .top, spacing: PanelLayout.tileSpacing) {
                    SlimMeter(title: "CPU", stack: bars.cpu, help: Help.Panel.nodeCores)
                    SlimMeter(title: "Memory", stack: bars.memory, help: Help.Panel.nodeMemory)
                }
            }
        }
    }

    /// Each Cluster view node row's bars: its pods' requests and its live load.
    private var clusterBars: [NodeBars] {
        cluster.nodes.map { node in
            NodeBars.of(row: node, load: MetricsDisplay.nodeLoad(named: node.name, nodes: workloads.nodes, state: workloads.metrics))
        }
    }

    /// This Mac's view: the machine, the state and the tiles, the nodes
    /// block, the core grid and the memory meter, its sections closer
    /// together than the column's.
    private var thisMacView: some View {
        VStack(alignment: .leading, spacing: 10) {
            thisMacSections
        }
    }

    /// The view's sections: the summary with the tiles, the nodes block,
    /// the live load, then the charts with their notes.
    @ViewBuilder private var thisMacSections: some View {
        VStack(alignment: .leading, spacing: 8) {
            if PanelMode.showsHeading(nodeCount: cluster.nodeCount) {
                Text(verbatim: cluster.title).font(.system(size: 21, weight: .semibold)).foregroundStyle(.white)
            }
            Text(verbatim: Self.machine.line).font(.system(size: 12)).foregroundStyle(.white.opacity(0.62))
            stateRow
            tileGrid(macTiles)
        }
        .id(TourTarget.summary)
        .tourTarget(.summary, tour)
        nodesBlock
        LiveLoadBlock(node: macNode, row: macRow, nodes: workloads.nodes, state: workloads.metrics)
        let cores = coreChart
        let memory = memoryChart
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                CoreGrid(chart: cores)
                    .help(Help.Panel.coreGrid)
                if !cores.legend.isEmpty {
                    Legend(rows: cores.legend)
                }
                Footnote("Squares are performance cores, circles efficiency cores.")
            }
            memoryBlock(memory)
            if cores.sampled || memory.sampled {
                MetricsNote(state: workloads.metrics)
            }
            if let note = MacUsage.note(cores: cores, memory: memory) {
                Footnote(note)
            }
        }
        .id(TourTarget.cores)
        .tourTarget(.cores, tour)
    }

    private func memoryBlock(_ chart: MemoryChart) -> some View {
        PanelBlock("Unified memory", value: memoryHeading) {
            Meter(parts: chart.segments.map { ($0.share, Palette.swatch($0.swatch)) }, total: 1, height: 10)
                .help(Help.Panel.memoryMeter)
            Legend(rows: chart.legend)
        }
    }

    /// The core grid: this Mac's node's measured CPU.
    private var coreChart: CoreChart {
        MacUsage.cores(count: Self.machine.cores, performance: Self.machine.performanceCores, used: coresUsed)
    }

    /// The memory meter: its pods' working sets, and the rest in use.
    private var memoryChart: MemoryChart {
        MacUsage.memory(total: Self.machine.memoryBytes, inUse: workloads.load.memoryUsedBytes, podsUsed: memoryUsed)
    }

    /// The status as one state (`StatusHeadline`): its dot, the word, and a
    /// lock while checks need an administrator; accessibility reads the
    /// whole, with the pod count and the needs-admin count.
    private var stateRow: some View {
        let headline = app.pane.panelHeadline(report: report, podCount: pods.count)
        return HStack(spacing: 7) {
            HStack(spacing: 7) {
                Circle().fill(Palette.rowOnDark(headline.tone)).frame(width: 8, height: 8)
                    .help(Help.Status.dot)
                Text(verbatim: headline.state).font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                if headline.showsLock {
                    Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(.white.opacity(0.62))
                        .help(Help.Status.needsAdmin(headline.needsAdmin, in: .panel))
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: headline.accessibilityLabel))
            .opensClusterTab(app)
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
            cores: Self.machine.cores, memoryBytes: Self.machine.memoryBytes,
            dataRootUsed: workloads.load.dataRootUsedBytes, dataRootSize: workloads.load.dataRootSizeBytes,
            pods: macPods.count, coresUsed: coresUsed, memoryUsed: memoryUsed)
    }

    /// What the panel's regions hold, for `PanelLayout.naturalWidth`: both
    /// the Cluster and the This Mac view while the switch offers both, so the
    /// panel keeps one width across a switch, and This Mac alone otherwise.
    var layoutRegions: [PanelContent] {
        PanelMode.showsSwitch(nodeCount: cluster.nodeCount) ? [clusterRegion, macRegion] : [macRegion]
    }

    /// The Cluster view's tiles, node rows with their bars, and the nodes block.
    private var clusterRegion: PanelContent {
        PanelContent(tiles: ClusterDisplay.tiles(for: cluster), nodes: cluster.nodes, nodeBars: clusterBars,
                     lines: cluster.nodes.isEmpty ? nodes?.lines ?? [] : [],
                     pairs: [PanelPair("Nodes", cluster.versions ?? "")])
    }

    /// The This Mac view's tiles, the machine line, the nodes block, the live
    /// load, and the core and memory legends with the memory block's heading.
    private var macRegion: PanelContent {
        let legend = (coreChart.legend + memoryChart.legend).map { PanelPair($0.label, $0.value, swatch: true) }
        let load = macNode.flatMap { MetricsDisplay.nodeLoad(named: $0, nodes: workloads.nodes, state: workloads.metrics) }
        let bars = NodeBars.of(row: macRow, load: load)
        return PanelContent(tiles: macTiles, lines: nodes?.lines ?? [],
                            pairs: [PanelPair(Self.machine.line, ""), PanelPair("Nodes", nodes?.heading ?? ""),
                                    PanelPair("Unified memory", memoryHeading)] + legend,
                            loads: bars.hasFigures ? [bars] : [])
    }

    /// The memory block's value: what is in use of this Mac's memory.
    private var memoryHeading: String {
        "\(WorkloadsDisplay.bytes(workloads.load.memoryUsedBytes)) of \(WorkloadsDisplay.bytes(Self.machine.memoryBytes))"
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
    /// This Mac's node, for its usage sample.
    private var macNode: String? { MetricsDisplay.thisMacNode(report: report, nodes: workloads.nodes) }
    /// This Mac's Cluster view row, for what its pods request; nil before the lists are read.
    private var macRow: ClusterNodeRow? { cluster.nodes.first { $0.thisMac } }
    /// The cores the node used and its pods' working sets, nil without a sample.
    private var coresUsed: Double? { MacUsage.cpuUsed(node: macNode, state: workloads.metrics) }
    private var memoryUsed: Int64? { MacUsage.podsMemoryUsed(macPods, node: macNode, state: workloads.metrics) }

    /// The nodes block, re-derived from each report; nil before the first read.
    private var nodes: NodesView? {
        report.map { NodesDisplay.view(report: $0, installed: app.installedVersion) }
    }

    private func nodeRows(_ nodes: NodesView) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(nodes.lines.enumerated()), id: \.offset) { _, line in
                NodeLineRow(line: line)
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
            PanelPairLine(label: title, value: value, heading: true) { EmptyView() }
            content()
        }
    }
}

/// TileGrid is the panel's figures: always two columns (a 2 by 2 grid for
/// four tiles), each as wide as the widest tile at its ideal width, `spacing`
/// apart (`PanelLayout.tileGridWidth`), a row as tall as its tallest. Its
/// ideal width is that grid; given a width it fills it, a wider one by
/// widening every tile alike, so the grid meets the panel's padding on both
/// sides, a narrower one by narrowing them (each tile shrinks its detail
/// line), so a tile never overlaps its neighbour or reaches an edge.
struct TileGrid: Layout {
    let spacing: Double

    init(spacing: Double = PanelLayout.tileSpacing) {
        self.spacing = spacing
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let columns = PanelLayout.tileColumns(count: subviews.count)
        guard columns > 0 else { return .zero }
        let width = gridWidth(proposal: proposal, subviews: subviews)
        let tile = tileWidth(width, columns: columns)
        var height: CGFloat = 0
        for row in rows(subviews.count, columns: columns) {
            height += row.map { subviews[$0].sizeThatFits(ProposedViewSize(width: tile, height: nil)).height }.max() ?? 0
        }
        let rowCount = rows(subviews.count, columns: columns).count
        return CGSize(width: width, height: height + CGFloat(max(0, rowCount - 1)) * CGFloat(spacing))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let columns = PanelLayout.tileColumns(count: subviews.count)
        guard columns > 0 else { return }
        let tile = tileWidth(bounds.width, columns: columns)
        var y = bounds.minY
        for row in rows(subviews.count, columns: columns) {
            let height = row.map { subviews[$0].sizeThatFits(ProposedViewSize(width: tile, height: nil)).height }.max() ?? 0
            for (column, index) in row.enumerated() {
                let x = bounds.minX + CGFloat(column) * (tile + CGFloat(spacing))
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                                      proposal: ProposedViewSize(width: tile, height: height))
            }
            y += height + CGFloat(spacing)
        }
    }

    /// The grid at its tiles' ideal widths, or the proposed width when there is one.
    private func gridWidth(proposal: ProposedViewSize, subviews: Subviews) -> CGFloat {
        guard let proposed = proposal.width, proposed.isFinite else {
            return CGFloat(PanelLayout.tileGridWidth(subviews.map { Double($0.sizeThatFits(.unspecified).width) }))
        }
        return max(0, proposed)
    }

    private func tileWidth(_ grid: CGFloat, columns: Int) -> CGFloat {
        max(0, (grid - CGFloat(spacing) * CGFloat(columns - 1)) / CGFloat(columns))
    }

    private func rows(_ count: Int, columns: Int) -> [[Int]] {
        stride(from: 0, to: count, by: columns).map { Array($0..<min(count, $0 + columns)) }
    }
}

/// Tile is one figure: the value large, its "of" beside it (or under it
/// when the two do not fit), and the label small and lowercase below, inside
/// `PanelLayout.tilePadding` at the sides and `verticalPadding` above and below.
struct Tile: View {
    let tile: PanelTile
    /// Tighter than the sides: the height does not set the panel's width.
    static let verticalPadding: CGFloat = 7

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    value
                    detail.fixedSize()
                }
                VStack(alignment: .leading, spacing: 1) {
                    value
                    // Under the value, a detail wider than a narrow column
                    // shrinks, then shortens, rather than push the tile out.
                    detail.minimumScaleFactor(0.8).truncationMode(.tail)
                }
            }
            Text(verbatim: tile.label).font(.system(size: 11)).foregroundStyle(.white.opacity(0.62)).lineLimit(1)
        }
        .padding(.horizontal, CGFloat(PanelLayout.tilePadding))
        .padding(.vertical, Self.verticalPadding)
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
                .foregroundStyle(.white.opacity(0.62)).lineLimit(1)
        }
    }
}

/// NodeRowLine is a Cluster view node row on one line: the heading, then
/// both bars, each `PanelLayout.stackMeterWidth` wide.
struct NodeRowLine: View {
    let node: ClusterNodeRow
    let bars: NodeBars

    var body: some View {
        HStack(alignment: .center, spacing: PanelLayout.tileSpacing) {
            NodeHeading(node: node)
            SlimMeter(title: "CPU", stack: bars.cpu, help: Help.Panel.nodeCores)
                .frame(width: PanelLayout.stackMeterWidth(bars.cpu))
            SlimMeter(title: "Memory", stack: bars.memory, help: Help.Panel.nodeMemory)
                .frame(width: PanelLayout.stackMeterWidth(bars.memory))
        }
    }
}

/// NodeHeading is a node row's first part: the dot, the name, the tag, the
/// role and the pods.
struct NodeHeading: View {
    let node: ClusterNodeRow

    var body: some View {
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
}

/// SlimMeter is one resource's 5 pt `StackedBar`, requested as the light
/// band and used solid, with its figure lines under it, dim and monospaced,
/// the first led by the title when `titled`; an empty track when neither
/// share is known.
struct SlimMeter: View {
    let title: String
    let stack: LoadStack
    let help: HelpTag
    var titled = false

    var body: some View {
        let lines = titled ? stack.lines(titled: title) : stack.lines
        VStack(alignment: .leading, spacing: 3) {
            StackedBar(stack: stack)
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array((lines.isEmpty ? [" "] : lines).enumerated()), id: \.offset) { _, line in
                    Text(verbatim: line).font(.system(size: 10)).monospacedDigit()
                        .foregroundStyle(.white.opacity(0.62)).lineLimit(1).minimumScaleFactor(0.8)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(title) \(lines.isEmpty ? "unknown" : lines.joined(separator: ", "))"))
        .help(help)
    }
}

/// NodeLineRow is one line of the nodes block: the name, the role, and the
/// version on the right.
struct NodeLineRow: View {
    let line: NodeLine

    var body: some View {
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
}

/// PanelPairLine is a panel line with a label on the left and its value on
/// the right, at 12 pt: a block's heading (`heading`, medium and dimmer) or
/// a legend row, which leads with its swatch.
struct PanelPairLine<Leading: View>: View {
    let label: String
    let value: String
    let heading: Bool
    @ViewBuilder let leading: () -> Leading

    var body: some View {
        HStack(spacing: CGFloat(PanelLayout.pairGap)) {
            leading()
            Text(verbatim: label).foregroundStyle(.white.opacity(heading ? 0.62 : 0.8))
            Spacer()
            Text(verbatim: value).foregroundStyle(.white).monospacedDigit()
        }
        .font(.system(size: 12, weight: heading ? .medium : .regular))
    }
}

/// PanelMeasure is every block the panel's natural width covers, for every
/// region in `regions` (`PanelContent`), drawn by the views the panel draws
/// them with; laid out at its ideal size, its width is the widest block, the
/// content the natural width holds between the panel's edges.
struct PanelMeasure: View {
    let regions: [PanelContent]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(regions.enumerated()), id: \.offset) { _, region in
                if !region.tiles.isEmpty {
                    TileGrid {
                        ForEach(Array(region.tiles.enumerated()), id: \.offset) { _, tile in Tile(tile: tile) }
                    }
                }
                ForEach(Array(region.nodes.enumerated()), id: \.offset) { i, node in
                    NodeRowLine(node: node, bars: region.bars(at: i))
                }
                ForEach(Array(region.lines.enumerated()), id: \.offset) { _, line in NodeLineRow(line: line) }
                ForEach(Array(region.pairs.enumerated()), id: \.offset) { _, pair in
                    if pair.value.isEmpty, !pair.swatch {
                        // A line with no value, such as the machine's, is its text alone.
                        Text(verbatim: pair.label).font(.system(size: 12))
                    } else {
                        PanelPairLine(label: pair.label, value: pair.value, heading: !pair.swatch) {
                            if pair.swatch { Color.clear.frame(width: 8, height: 8) }
                        }
                    }
                }
                ForEach(Array(region.loads.enumerated()), id: \.offset) { _, bars in
                    LiveLoadRow(bars: bars)
                }
            }
        }
    }
}

/// CoreGrid is one cell per core, squares for performance cores and circles
/// for efficiency cores: each cell filled from the bottom by the CPU used
/// (`CoreCell.used`).
struct CoreGrid: View {
    let chart: CoreChart
    private let side: CGFloat = 22

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 8), spacing: 5) {
            ForEach(Array(chart.cells.enumerated()), id: \.offset) { _, cell in
                let shape = RoundedRectangle(cornerRadius: cell.performance ? 5 : 11)
                ZStack(alignment: .bottom) {
                    shape.fill(Palette.deep2)
                    if let used = cell.used {
                        Rectangle().fill(cell.performance ? Palette.fill : Palette.fillSoft)
                            .frame(height: side * used)
                    }
                }
                .frame(height: side)
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
    /// The track under the parts: the panel's navy, or the light surface's wash.
    var track: Color = Palette.deep2

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
        .background(track)
        .clipShape(RoundedRectangle(cornerRadius: height / 2))
    }
}

/// Legend names a chart's parts with their values, each behind the fill
/// the chart draws it with.
struct Legend: View {
    let rows: [UsageLegendRow]

    var body: some View {
        VStack(spacing: 4) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                PanelPairLine(label: row.label, value: row.value, heading: false) {
                    swatch(row.swatch).frame(width: 8, height: 8)
                }
            }
        }
    }

    private func swatch(_ kind: UsageSwatch) -> some View {
        RoundedRectangle(cornerRadius: 2).fill(Palette.swatch(kind))
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
            Self.half(left: true, color: color).rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), anchor: .center, perspective: 0.5)
            Self.half(left: false, color: color).rotation3DEffect(.degrees(-angle), axis: (x: 0, y: 1, z: 0), anchor: .center, perspective: 0.5)
        }
        .accessibilityHidden(true)
    }

    /// half is the half of the mark on the left (`left`) or right of the
    /// centre line, in `color`.
    static func half(left: Bool, color: Color) -> some View {
        Butterfly().fill(color).mask {
            HStack(spacing: 0) {
                Rectangle().opacity(left ? 1 : 0)
                Rectangle().opacity(left ? 0 : 1)
            }
        }
    }
}
