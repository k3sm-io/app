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

/// WorkloadsTab is the Workloads tab: a sub-tab switch (`WorkloadsView`)
/// over the pods or the cluster's events. The events are read only while
/// their sub-tab is chosen (`AppModel.workloadsView`).
struct WorkloadsTab: View {
    @ObservedObject var app: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("View", selection: $app.workloadsView) {
                    ForEach(WorkloadsView.allCases) { view in
                        Text(view.title).tag(view)
                    }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                if app.workloadsView == .events, let events = app.events {
                    EventsFilter(app: app, loader: events)
                }
            }
            .padding(.horizontal, 20).padding(.top, 10)
            switch app.workloadsView {
            case .pods: WorkloadsSection(model: app.workloads)
            case .events:
                if let events = app.events {
                    EventsSection(app: app, loader: events)
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
    }
}

/// EventsColumns is the one place the Events list's column widths live.
enum EventsColumns {
    static let dot: CGFloat = 16
    static let age: CGFloat = 50
    static let reason: CGFloat = 130
    static let object: CGFloat = 170
    static let spacing: CGFloat = 12

    static var header: some View {
        HStack(spacing: spacing) {
            Color.clear.frame(width: dot, height: 1)
            Text("Age").frame(width: age, alignment: .leading)
            Text("Reason").frame(width: reason, alignment: .leading)
            Text("Object").frame(width: object, alignment: .leading)
            Text("Message").frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 11.5)).foregroundStyle(Palette.dimText)
        .padding(.horizontal, 20).padding(.top, 10)
    }
}

/// EventsSection is the cluster's events, newest first, at most
/// `EventsList.cap`, in the chosen namespace, decided by `EventsList`.
struct EventsSection: View {
    @ObservedObject var app: AppModel
    @ObservedObject var loader: TabLoader<[ClusterEvent]>

    var body: some View {
        VStack(spacing: 0) {
            EventsColumns.header
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
                                EventRow(event: event)
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

    var body: some View {
        HStack(alignment: .top, spacing: EventsColumns.spacing) {
            Circle().fill(Palette.health(event.severity)).frame(width: 9, height: 9).frame(width: EventsColumns.dot)
                .padding(.top, 4)
            Text(verbatim: WorkloadsDisplay.age(event.time)).font(.system(size: 12)).monospacedDigit()
                .foregroundStyle(Palette.ink2).frame(width: EventsColumns.age, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: event.reason).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                if event.count > 1 {
                    Text(verbatim: "\(event.count) times").font(.system(size: 11)).foregroundStyle(Palette.dimText)
                }
            }
            .frame(width: EventsColumns.reason, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: event.object).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                Text(verbatim: event.namespace).font(.system(size: 11)).foregroundStyle(Palette.dimText).lineLimit(1)
            }
            .frame(width: EventsColumns.object, alignment: .leading)
            Text(verbatim: event.message).font(.system(size: 12)).foregroundStyle(Palette.ink2).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }
}
