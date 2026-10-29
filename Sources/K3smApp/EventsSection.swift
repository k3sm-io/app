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

/// WorkloadsTab is the Workloads tab: a header row with the sub-tab switch
/// (`WorkloadsView`) and, at its trailing edge, the events' namespace menu
/// and the tab's bulk actions (`TabHeader.Placement.switchRow`), over the
/// pods or the cluster's events. The events are read only while their
/// sub-tab is chosen (`AppModel.workloadsView`). It observes the pod list
/// too, so a new list re-offers the cleanup.
struct WorkloadsTab: View {
    @ObservedObject var app: AppModel
    @ObservedObject var workloads: WorkloadsModel

    init(app: AppModel) {
        self.app = app
        self.workloads = app.workloads
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: CGFloat(TabHeader.spacing)) {
                Picker("View", selection: $app.workloadsView) {
                    ForEach(WorkloadsView.allCases) { view in
                        Text(view.title).tag(view)
                    }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .help(Help.Workloads.view)
                Spacer()
                if app.workloadsView == .events, let events = app.events {
                    EventsFilter(app: app, loader: events)
                }
                BulkActionsSlot(items: app.bulkActions, section: .workloads, runner: app.actions)
            }
            .tabHeaderRow()
            switch app.workloadsView {
            case .pods: WorkloadsSection(model: app.workloads, runner: app.actions, columns: app.columns) { app.activate($0) }
            case .events:
                if let events = app.events {
                    EventsSection(app: app, loader: events, columns: app.columns)
                } else {
                    Color.clear
                }
            }
        }
    }
}

/// EventsFilter is the Events view's namespace menu: every namespace, or one
/// of those with events (`EventsList.namespaces`).
struct EventsFilter: View {
    @ObservedObject var app: AppModel
    @ObservedObject var loader: TabLoader<[ClusterEvent]>

    var body: some View {
        Picker("Namespace", selection: $app.eventsNamespace) {
            Text("All namespaces").tag(String?.none)
            ForEach(EventsList.namespaces(loader.value ?? [], selected: app.eventsNamespace), id: \.self) { ns in
                Text(verbatim: ns).tag(String?.some(ns))
            }
        }
        .labelsHidden().fixedSize()
        .help(Help.Workloads.namespace)
    }
}

/// EventsColumns is the Events list's layout, from `TableColumns.events`
/// and the widths the user dragged (`ColumnsModel`).
enum EventsColumns {
    static let dot = CGFloat(TableColumns.events.lead)
    static let spacing = CGFloat(TableColumns.events.spacing)

    static func header(_ columns: ColumnsModel) -> some View {
        ColumnHeader(layout: .events, columns: columns, help: [.age: Help.Workloads.eventAge])
    }
}

/// EventsSection is the cluster's events, newest first, at most
/// `EventsList.cap`, in the chosen namespace, decided by `EventsList`.
struct EventsSection: View {
    @ObservedObject var app: AppModel
    @ObservedObject var loader: TabLoader<[ClusterEvent]>
    @ObservedObject var columns: ColumnsModel

    var body: some View {
        VStack(spacing: 0) {
            EventsColumns.header(columns)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    switch loader.load {
                    case .failed(let text): ListNote(text: text)
                    case .unavailable(let reason): ListNote(text: reason)
                    default:
                        if let events = loader.value {
                            let shown = EventsList.visible(events, namespace: app.eventsNamespace)
                            if shown.isEmpty {
                                ListNote(text: EventsList.emptyText(namespace: app.eventsNamespace))
                            }
                            ForEach(shown, id: \.key) { event in
                                EventRow(event: event, widths: columns.widths(.events))
                            }
                        } else {
                            ListNote(text: "Reading the events…")
                        }
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
            }
            TabFooter(load: loader.load)
        }
    }
}

/// EventRow is one event: a dot for a warning, its age, reason and count,
/// the object it is about (with its namespace under it) and the message.
struct EventRow: View {
    let event: ClusterEvent
    let widths: ColumnWidths

    var body: some View {
        HStack(alignment: .top, spacing: EventsColumns.spacing) {
            Circle().fill(Palette.health(event.severity)).frame(width: 9, height: 9).frame(width: EventsColumns.dot)
                .help(Help.Inspector.healthDot)
                .padding(.top, 4)
            Text(verbatim: WorkloadsDisplay.age(event.time)).font(.system(size: 12)).monospacedDigit()
                .foregroundStyle(Palette.ink2).frame(width: widths.cg(.age), alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: event.reason).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                if event.count > 1 {
                    Text(verbatim: "\(event.count) times").font(.system(size: 11)).foregroundStyle(Palette.dimText)
                }
            }
            .frame(width: widths.cg(.reason), alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: NodeNameMask.shownText(event.object)).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                Text(verbatim: event.namespace).font(.system(size: 11)).foregroundStyle(Palette.dimText).lineLimit(1)
            }
            .frame(width: widths.cg(.object), alignment: .leading)
            Text(verbatim: NodeNameMask.shownText(event.message)).font(.system(size: 12)).foregroundStyle(Palette.ink2).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }
}
