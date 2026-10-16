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

/// BuildsSection is the Builds tab: one card for the build engine, decided by
/// `BuildEngine`, with the last engine action's line under it, and the build
/// history below it (`k3sm build ls`, newest first, decided by
/// `BuildHistory`). The card and every history row are selectable; a row's
/// context menu is its `BuildActions.menu`, and the engine's actions
/// (`BuildActions.toolbar`) are on the tab's header row, right-aligned.
struct BuildsSection: View {
    @ObservedObject var app: AppModel
    @ObservedObject var loader: TabLoader<BuildEngine>
    @ObservedObject var history: TabLoader<[BuildRecord]>
    @ObservedObject var runner: ActionRunner

    var body: some View {
        VStack(spacing: 0) {
            TabHeaderRow(items: app.bulkActions, section: .builds, runner: runner)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    card
                    if let report = runner.report(section: .builds, rowKey: InspectorDetails.engineRow) {
                        Text(verbatim: report.text)
                            .font(.system(size: 12))
                            .foregroundStyle(report.failed ? Palette.bad : Palette.ink2)
                            .frame(maxWidth: 460, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    } else if runner.busy, runner.report?.rowKey == InspectorDetails.engineRow {
                        Text("running…").font(.system(size: 12)).foregroundStyle(Palette.dimText)
                    }
                    Text("Build history").font(.system(size: 14, weight: .semibold)).padding(.top, 6)
                    rows
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            TabFooter(load: history.load)
        }
    }

    @ViewBuilder private var card: some View {
        switch loader.load {
        case .failed(let text): note(text)
        case .unavailable(let reason): note(reason)
        default:
            if let engine = loader.value {
                let row = ConsoleRow.build(InspectorDetails.engineRow)
                EngineCard(engine: engine, selected: app.isSelected(row))
                    .selects(row, in: app)
            } else {
                note("Reading the build engine…")
            }
        }
    }

    @ViewBuilder private var rows: some View {
        switch history.load {
        case .failed(let text): note(text)
        case .unavailable(let reason): note(reason)
        default:
            if let records = history.value {
                if records.isEmpty {
                    note(BuildHistory.emptyText)
                } else {
                    VStack(spacing: 0) {
                        ObjectColumns.header([("Image", nil, .leading), ("Status", BuildColumns.status, .leading),
                                              ("Started", BuildColumns.started, .leading), ("Duration", BuildColumns.duration, .trailing)],
                                             help: ["Duration": Help.Builds.duration])
                            .padding(.horizontal, -10)
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(records, id: \.key) { record in
                                BuildRow(record: record, selected: app.isSelected(.build(record.key)))
                                    .selects(.build(record.key), in: app)
                            }
                        }
                    }
                }
            } else {
                note("Reading the build history…")
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(verbatim: text).font(.system(size: 13)).foregroundStyle(Palette.ink2)
    }
}

/// BuildColumns is the build history's column widths.
enum BuildColumns {
    static let status: CGFloat = 96
    static let started: CGFloat = 132
    static let duration: CGFloat = 70
}

/// BuildRow is one recorded build: its image over its record id, platform
/// and route, its status with a dot, when it started and how long it ran.
/// Every string was clipped by the decoder.
struct BuildRow: View {
    let record: BuildRecord
    let selected: Bool

    var body: some View {
        ListRow(selected: selected) {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: record.title).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(verbatim: [record.key, record.platform, record.engine].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(Palette.dimText).lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                Circle().fill(Palette.health(record.status.severity)).frame(width: 8, height: 8)
                Text(verbatim: record.status.word).font(.system(size: 12)).foregroundStyle(Palette.ink2).lineLimit(1)
            }
            .frame(width: BuildColumns.status, alignment: .leading)
            ObjectColumns.cell(BuildHistory.started(record.startedAt), width: BuildColumns.started)
            ObjectColumns.cell(BuildHistory.duration(record.duration()), width: BuildColumns.duration, alignment: .trailing)
        }
    }
}

/// EngineCard is the build engine at a glance: its state with a dot, the
/// reason line, then the pod, its node and the cache claim, outlined in the
/// selection blue while it is the tab's selected row. Every string was
/// clipped by the decoder.
struct EngineCard: View {
    let engine: BuildEngine
    var selected = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Build engine").font(.system(size: 14, weight: .semibold))
                Spacer()
                Circle().fill(Palette.health(engine.state.severity)).frame(width: 9, height: 9)
                Text(verbatim: engine.state.word).font(.system(size: 12, weight: .medium))
            }
            Text(verbatim: engine.state.detail).font(.system(size: 12)).foregroundStyle(Palette.ink2).lineLimit(2)
            if let pod = engine.podName {
                fact("Pod", pod)
            }
            if let node = engine.nodeName {
                fact("Node", node)
            }
            if let cache = engine.cache {
                fact("Cache", [cache.name, cache.phase, WorkloadsDisplay.bytes(cache.capacityBytes)]
                    .filter { !$0.isEmpty }.joined(separator: " · "))
            }
        }
        .padding(16)
        .frame(maxWidth: 460, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Palette.tint : Palette.wash))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Palette.blue : Palette.line, lineWidth: selected ? 1.5 : 1))
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).font(.system(size: 11.5)).foregroundStyle(Palette.dimText).frame(width: 44, alignment: .leading)
            Text(verbatim: value).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
        }
    }
}
