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
/// its state against the cluster's target, and live load, decided by
/// `NodesList`, under the version summary line (`NodeVersions.summary`)
/// and, on the server's app while a node is behind, the header's Update
/// (`NodeUpdateControl.header`). A row selects its node for the inspector
/// and offers its Cordon or Uncordon as a context menu, with Update for a
/// node behind (`NodeUpdateControl.decide`). Every Update runs the one
/// update plan through `AppModel.performUpdate`.
struct NodesSection: View {
    @ObservedObject var app: AppModel
    @ObservedObject var workloads: WorkloadsModel
    @ObservedObject var columns: ColumnsModel

    private var nodeList: TabLoader<NodeListRead> { workloads.nodeList }

    var body: some View {
        VStack(spacing: 0) {
            if let nodes = workloads.nodes, let summary = NodeVersions.decide(nodes, report: app.report).summary {
                HStack(spacing: 10) {
                    Text(verbatim: StatusDisplay.clip(summary)).font(.system(size: 12)).foregroundStyle(Palette.ink2)
                        .lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(Help.Nodes.versionSummary)
                    if let control = NodeUpdateControl.header(nodes, versions: NodeVersions.decide(nodes, report: app.report),
                                                              report: app.report, plan: app.updatePlan) {
                        Button(NodeUpdateControl.title) { app.performUpdate() }
                            .controlSize(.small)
                            .disabled(!control.enabled || app.running)
                            .help(Help.Nodes.updateBehind(control))
                    }
                }
                .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 2)
            }
            ColumnHeader(layout: .nodes, columns: columns,
                         help: [.status: Help.Nodes.status, .version: Help.Nodes.version, .load: Help.Nodes.load])
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
                let widths = columns.widths(.nodes)
                let versions = NodeVersions.decide(nodes, report: app.report)
                let plan = app.updatePlan
                ForEach(NodesList.visible(rows, query: app.nodesQuery), id: \.key) { row in
                    ListRow(selected: app.isSelected(.node(row.key))) {
                        ObjectColumns.title(row.name, under: row.role)
                        Text(verbatim: row.status).font(.system(size: 12))
                            .foregroundStyle(row.ready ? Palette.ink2 : Palette.warn).lineLimit(1)
                            .frame(width: widths.cg(.status), alignment: .leading)
                        ObjectColumns.cell(row.version, width: widths.cg(.version))
                        ObjectColumns.cell(row.load, width: widths.cg(.load))
                    }
                    .selects(.node(row.key), in: app, extra: updateItem(row.key, nodes: nodes, versions: versions, plan: plan))
                }
            } else {
                ListNote(text: NodesList.readingText)
            }
        }
    }

    /// A behind node's Update in its context menu, or none.
    private func updateItem(_ key: String, nodes: [ClusterNode], versions: NodeVersions, plan: UpdatePlan) -> [RowMenuExtra] {
        guard let node = nodes.first(where: { $0.name == key }),
              let control = NodeUpdateControl.decide(node, versions: versions, report: app.report, plan: plan) else { return [] }
        return [RowMenuExtra(id: "update", title: NodeUpdateControl.title, enabled: control.enabled && !app.running) {
            app.performUpdate()
        }]
    }
}

/// NodeInspector is the Nodes tab's inspector: the selected node's facts,
/// its Cordon or Uncordon and Drain on the shared action seam, this Mac's
/// own Update, Restart and Stop or the line saying where another Mac's are
/// (`NodeLifecycleOffer`), its live load, conditions, taints and the pods on
/// it, from `InspectorDetails.node`; rebuilt every 5 s so the sample's and
/// the conditions' ages stay current.
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
                        if let offer = lifecycleOffer() {
                            NodeLifecycleBlock(app: app, offer: offer)
                            if !offer.actions.contains(.update), let control = updateControl() {
                                NodeUpdateBlock(app: app, control: control)
                            }
                        }
                        NodeInspectorSections(content: body)
                    }
                }
                .background(Palette.surface)
            } else {
                RowInspector(content: nil, empty: InspectorDetails.emptyText(.nodes))
            }
        }
    }

    private func lifecycleOffer() -> NodeLifecycleOffer? {
        guard let key = app.selection.selection(in: .nodes)?.key, let nodes = workloads.nodes,
              let node = nodes.first(where: { $0.name == key }) else { return nil }
        return NodeLifecycleOffer.decide(node, nodes: nodes, report: app.report, plan: app.updatePlan)
    }

    private func updateControl() -> NodeUpdateControl? {
        guard let key = app.selection.selection(in: .nodes)?.key, let nodes = workloads.nodes,
              let node = nodes.first(where: { $0.name == key }) else { return nil }
        return NodeUpdateControl.decide(node, versions: NodeVersions.decide(nodes, report: app.report), report: app.report,
                                        plan: app.updatePlan)
    }

    private func content(now: Date) -> NodeInspectorBody? {
        guard let key = app.selection.selection(in: .nodes)?.key, let nodes = workloads.nodes,
              let node = nodes.first(where: { $0.name == key }) else { return nil }
        return InspectorDetails.node(node, nodes: nodes, report: app.report, pods: workloads.workloads?.pods,
                                     metrics: workloads.metrics, now: now)
    }
}

/// NodeLifecycleBlock is this Mac's own Update, Restart and Stop, each
/// through the path the rest of the app uses: Update is
/// `AppModel.performUpdate` over the one update plan (enabled as the
/// Settings Updates pane's Update Now is), Restart and Stop are
/// `AppModel.perform` (the menu's confirmation, with Stop's warning, and the
/// administrator prompt). Under them, the offer's line.
struct NodeLifecycleBlock: View {
    @ObservedObject var app: AppModel
    let offer: NodeLifecycleOffer

    var body: some View {
        let plan = app.updatePlan
        let control = UpdateNowControl.decide(plan: plan, report: app.lanReport)
        VStack(alignment: .leading, spacing: 6) {
            if !offer.actions.isEmpty {
                HStack(spacing: 8) {
                    ForEach(offer.actions) { action in
                        Button(action.title) { run(action) }
                            .disabled(action == .update ? (!control.enabled || app.running) : !app.canRunLifecycle)
                            .help(Help.Nodes.lifecycle(action, update: control, plan: plan))
                    }
                }
            }
            if offer.actions.contains(.update), let line = plan.line ?? control.reason {
                note(line)
            }
            if let line = offer.note { note(line) }
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
    }

    private func run(_ action: NodeLifecycleAction) {
        switch action {
        case .update: app.performUpdate()
        case .restart: app.perform(.restart, expected: .running)
        case .stop: app.perform(.stop, expected: .running)
        }
    }

    private func note(_ text: String) -> some View {
        Text(verbatim: StatusDisplay.clip(text)).font(.system(size: 11.5)).foregroundStyle(Palette.ink2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// NodeUpdateBlock is a behind node's Update in its inspector, on the
/// server's app: `AppModel.performUpdate` over the one update plan, with the
/// plan's line (what it moves) or why it is disabled under it.
struct NodeUpdateBlock: View {
    @ObservedObject var app: AppModel
    let control: NodeUpdateControl

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(NodeUpdateControl.title) { app.performUpdate() }
                .disabled(!control.enabled || app.running)
                .help(Help.Nodes.updateNode(control))
            if let line = control.reason ?? app.updatePlan.line {
                Text(verbatim: StatusDisplay.clip(line)).font(.system(size: 11.5)).foregroundStyle(Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
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
