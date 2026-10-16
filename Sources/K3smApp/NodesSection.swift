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

/// NodesSection is the Nodes tab: every node of the shared node list (no
/// read of its own), this Mac's first, with its role, readiness, release and
/// live load, decided by `NodesList`. A row selects its node for the
/// inspector and offers its Cordon or Uncordon as a context menu.
struct NodesSection: View {
    @ObservedObject var app: AppModel
    @ObservedObject var workloads: WorkloadsModel

    private var nodeList: TabLoader<NodeListRead> { workloads.nodeList }

    var body: some View {
        VStack(spacing: 0) {
            ObjectColumns.header([("Node", nil, .leading), ("Status", NodeColumns.status, .leading),
                                  ("Version", NodeColumns.version, .leading), ("Load", NodeColumns.load, .leading)],
                                 help: ["Status": Help.Nodes.status, "Version": Help.Nodes.version, "Load": Help.Nodes.load])
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) { content }
                    .padding(.horizontal, 10).padding(.vertical, 8)
            }
            TabFooter(load: nodeList.load)
        }
    }

    @ViewBuilder private var content: some View {
        switch nodeList.load {
        case .failed(let text): ListNote(text: text)
        case .unavailable(let reason): ListNote(text: reason)
        default:
            if let nodes = workloads.nodes {
                if nodes.isEmpty { ListNote(text: NodesList.emptyText) }
                let rows = NodesList.rows(nodes, report: app.report, metrics: workloads.metrics)
                ForEach(NodesList.visible(rows, query: app.nodesQuery), id: \.key) { row in
                    ListRow(selected: app.isSelected(.node(row.key))) {
                        ObjectColumns.title(row.name, under: row.role)
                        Text(verbatim: row.status).font(.system(size: 12))
                            .foregroundStyle(row.ready ? Palette.ink2 : Palette.warn).lineLimit(1)
                            .frame(width: NodeColumns.status, alignment: .leading)
                        ObjectColumns.cell(row.version, width: NodeColumns.version)
                        ObjectColumns.cell(row.load, width: NodeColumns.load)
                    }
                    .selects(.node(row.key), in: app)
                }
            } else {
                ListNote(text: NodesList.readingText)
            }
        }
    }
}

/// NodeColumns is the one place the Nodes list's column widths live.
enum NodeColumns {
    static let status: CGFloat = 130
    static let version: CGFloat = 90
    static let load: CGFloat = 160
}

/// NodeInspector is the Nodes tab's inspector: the selected node's facts and
/// its Cordon or Uncordon, its live load, conditions, taints and the pods
/// on it, from `InspectorDetails.node`; rebuilt every 5 s so the sample's
/// and the conditions' ages stay current.
struct NodeInspector: View {
    @ObservedObject var app: AppModel
    @ObservedObject var workloads: WorkloadsModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            if let body = content(now: context.date) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        RowInspector(content: body.header, empty: "", actions: RowActions.selected(.nodes, app: app),
                                     fillsHeight: false)
                        NodeInspectorSections(content: body)
                    }
                }
                .background(Palette.surface)
            } else {
                RowInspector(content: nil, empty: InspectorDetails.emptyText(.nodes))
            }
        }
    }

    private func content(now: Date) -> NodeInspectorBody? {
        guard let key = app.selection.selection(in: .nodes)?.key, let nodes = workloads.nodes,
              let node = nodes.first(where: { $0.name == key }) else { return nil }
        return InspectorDetails.node(node, nodes: nodes, report: app.report, pods: workloads.workloads?.pods,
                                     metrics: workloads.metrics, now: now)
    }
}

/// NodeInspectorSections is the node inspector below its facts: the live
/// load, the conditions, the taints and the pods, each under its heading.
struct NodeInspectorSections: View {
    let content: NodeInspectorBody

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            section("Load now") {
                switch content.load {
                case .unsampled(let text):
                    Text(verbatim: StatusDisplay.clip(text)).font(.system(size: 12)).foregroundStyle(Palette.ink2)
                case .sampled(let cpu, let memory, let sparkline, let age):
                    HStack(alignment: .bottom, spacing: 10) {
                        bar("CPU", cpu).help(Help.Nodes.liveCPU)
                        bar("Memory", memory).help(Help.Nodes.liveMemory)
                        if sparkline.count > 1 {
                            Sparkline(points: sparkline).frame(width: 40, height: 16)
                                .accessibilityLabel(Text(verbatim: "CPU over the last samples"))
                                .help(Help.Nodes.sparkline)
                        }
                    }
                    Text(verbatim: age).font(.system(size: 11)).foregroundStyle(Palette.dimText)
                }
            }
            section("Conditions") {
                if content.conditions.isEmpty { none("not reported") }
                ForEach(Array(content.conditions.enumerated()), id: \.offset) { _, line in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: StatusDisplay.clip(line.type)).font(.system(size: 12.5, weight: .medium))
                        Text(verbatim: StatusDisplay.clip(line.text)).font(.system(size: 11.5))
                            .foregroundStyle(line.healthy ? Palette.ink2 : Palette.warn).textSelection(.enabled)
                    }
                }
            }
            section("Taints") {
                if content.taints.isEmpty { none("none") }
                ForEach(Array(content.taints.enumerated()), id: \.offset) { _, taint in
                    Text(verbatim: StatusDisplay.clip(taint)).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                }
            }
            section("Pods") {
                if let pods = content.pods {
                    if pods.isEmpty { none("no pod runs here") }
                    ForEach(Array(pods.enumerated()), id: \.offset) { _, pod in
                        HStack(spacing: 8) {
                            Text(verbatim: StatusDisplay.clip(pod.name)).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(verbatim: StatusDisplay.clip(pod.usage)).font(.system(size: 11)).monospacedDigit()
                                .foregroundStyle(Palette.dimText).lineLimit(1)
                                .help(Help.Nodes.podUsage)
                        }
                    }
                } else {
                    none("Reading the pod list…")
                }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Palette.dimText)
            content()
        }
    }

    private func none(_ text: String) -> some View {
        Text(verbatim: text).font(.system(size: 12)).foregroundStyle(Palette.ink2)
    }

    /// A 5 pt bar of the share used, with "CPU 1.43 of 19 cores · 8%" under it.
    private func bar(_ title: String, _ bar: LoadBar) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Meter(parts: [(bar.fraction ?? 0, Palette.fill)], total: 1, track: Palette.wash)
            Text(verbatim: "\(title) \(bar.text)").font(.system(size: 10.5)).monospacedDigit()
                .foregroundStyle(Palette.ink2).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
