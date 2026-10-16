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

/// ConsoleInspector is the right column, following the active tab: the
/// pod inspector (`Inspector`) on Workloads, the node inspector
/// (`NodeInspector`) on Nodes, and on every other tab the
/// selected row's facts (`InspectorDetails`) or the line asking for a
/// selection. A tab change shows the new tab's own selection
/// (`ConsoleSelection`), never the row of the tab just left. Each body
/// shows its row's actions (`AppModel.rowMenu`) and asks them of the shared
/// `ActionRunner`, whose one confirmation the console shows.
struct ConsoleInspector: View {
    @ObservedObject var app: AppModel

    var body: some View {
        switch app.section {
        case .workloads:
            Inspector(model: app.workloads, runner: app.actions)
        case .nodes:
            NodeInspector(app: app, workloads: app.workloads)
        case .images:
            ImageInspector(app: app, workloads: app.workloads)
        case .builds:
            if let builds = app.builds, let history = app.buildHistory {
                BuildsInspector(app: app, engine: builds, history: history)
            } else {
                RowInspector(content: nil, empty: InspectorDetails.emptyText(.builds))
            }
        case .services:
            if let services = app.services {
                LoaderInspector(app: app, loader: services, section: .services) { rows, key in
                    rows.first { $0.key == key }.map(InspectorDetails.service)
                }
            } else {
                RowInspector(content: nil, empty: InspectorDetails.emptyText(.services))
            }
        case .storage:
            if let storage = app.storage {
                StorageInspector(app: app, loader: storage, workloads: app.workloads)
            } else {
                RowInspector(content: nil, empty: InspectorDetails.emptyText(.storage))
            }
        case .models:
            if let models = app.models {
                LoaderInspector(app: app, loader: models, section: .models) { rows, key in
                    rows.first { $0.key == key }.map(InspectorDetails.model)
                }
            } else {
                RowInspector(content: nil, empty: InspectorDetails.emptyText(.models))
            }
        case .stats:
            RowInspector(content: nil, empty: InspectorDetails.emptyText(.stats))
        }
    }
}

/// ImageInspector is the Images tab's inspector: the selected image from the
/// shared node list, with the pods using it once the pod list has been read.
struct ImageInspector: View {
    @ObservedObject var app: AppModel
    @ObservedObject var workloads: WorkloadsModel

    var body: some View {
        RowInspector(content: content, empty: InspectorDetails.emptyText(.images),
                     actions: content == nil ? nil : RowActions.selected(.images, app: app))
    }

    private var content: InspectorBody? {
        guard let key = app.selection.selection(in: .images)?.key,
              case .listed(let images)? = workloads.nodeList.value?.images,
              let image = images.first(where: { $0.key == key }) else { return nil }
        return InspectorDetails.image(image, pods: workloads.workloads?.pods)
    }
}

/// StorageInspector is the Storage tab's inspector: the selected claim or
/// volume from the tab's read, with the pods mounting a claim once the pod
/// list has been read, so it observes that list too.
struct StorageInspector: View {
    @ObservedObject var app: AppModel
    @ObservedObject var loader: TabLoader<[StorageRow]>
    @ObservedObject var workloads: WorkloadsModel

    var body: some View {
        RowInspector(content: content, empty: InspectorDetails.emptyText(.storage),
                     actions: content == nil ? nil : RowActions.selected(.storage, app: app))
    }

    private var content: InspectorBody? {
        guard let key = app.selection.selection(in: .storage)?.key,
              let row = loader.value?.first(where: { $0.key == key }) else { return nil }
        return InspectorDetails.claim(row, pods: workloads.workloads?.pods)
    }
}

/// BuildsInspector is the Builds tab's inspector over its two reads: the
/// engine card's facts, or the selected recorded build's.
struct BuildsInspector: View {
    @ObservedObject var app: AppModel
    @ObservedObject var engine: TabLoader<BuildEngine>
    @ObservedObject var history: TabLoader<[BuildRecord]>

    var body: some View {
        RowInspector(content: content, empty: InspectorDetails.emptyText(.builds),
                     actions: content == nil ? nil : RowActions.selected(.builds, app: app))
    }

    private var content: InspectorBody? {
        guard let key = app.selection.selection(in: .builds)?.key else { return nil }
        if key == InspectorDetails.engineRow { return engine.value.map(InspectorDetails.build) }
        return history.value?.first { $0.key == key }.map { InspectorDetails.buildRecord($0) }
    }
}

/// LoaderInspector is a tab's inspector over its own read: the selected
/// row's body, found in the loader's last value by `details`.
struct LoaderInspector<Value: Sendable>: View {
    @ObservedObject var app: AppModel
    @ObservedObject var loader: TabLoader<Value>
    let section: ConsoleSection
    let details: (Value, String) -> InspectorBody?

    var body: some View {
        RowInspector(content: content, empty: InspectorDetails.emptyText(section),
                     actions: content == nil ? nil : RowActions.selected(section, app: app))
    }

    private var content: InspectorBody? {
        guard let key = app.selection.selection(in: section)?.key, let value = loader.value else { return nil }
        return details(value, key)
    }
}

/// RowInspector lays out one `InspectorBody`: the kind over the row's name
/// and namespace, then its facts, in the pod inspector's look; or the
/// tab's empty line. Every value is clipped again on the way to the screen.
struct RowInspector: View {
    let content: InspectorBody?
    let empty: String
    /// The row's actions and last action's line, under the heading.
    var actions: RowActions?
    /// Whether it fills the column (false inside the node inspector's scroll).
    var fillsHeight = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let content {
                heading(content)
                if let actions { actions }
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 7) {
                    ForEach(Array(content.facts.enumerated()), id: \.offset) { _, fact in
                        GridRow {
                            Text(verbatim: fact.label).font(.system(size: 12.5)).foregroundStyle(Palette.dimText)
                                .frame(width: 86, alignment: .leading)
                            Text(verbatim: StatusDisplay.clip(fact.value))
                                .font(.system(size: fact.mono ? 11.5 : 12.5, design: fact.mono ? .monospaced : .default))
                                .textSelection(.enabled)
                                .help(optional: fact.help)
                        }
                    }
                }
                .padding(.horizontal, 18).padding(.vertical, 12)
                if fillsHeight { Spacer() }
            } else {
                Text(verbatim: empty).foregroundStyle(Palette.ink2).padding(18)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil, alignment: .topLeading)
        .background(Palette.surface)
    }

    private func heading(_ content: InspectorBody) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: content.kind).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Palette.dimText)
            Text(verbatim: StatusDisplay.clip(content.title)).font(.system(size: 16, weight: .semibold))
                .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            if let subtitle = content.subtitle {
                Text(verbatim: StatusDisplay.clip(subtitle)).font(.system(size: 12.5)).foregroundStyle(Palette.ink2)
            }
        }
        .padding(18)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
    }
}
