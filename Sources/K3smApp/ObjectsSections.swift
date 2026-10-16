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

/// ListNote is a tab's one line in place of its rows: reading, failed,
/// unavailable or empty. The text is the decoder's or `TabLoad`'s, already clean.
struct ListNote: View {
    let text: String

    var body: some View {
        Text(verbatim: text).foregroundStyle(Palette.ink2).padding(20)
    }
}

/// ListRow is the look every console row shares: 44 pt, the tint and the
/// blue bar when selected, as the pod and image rows have them.
struct ListRow<Content: View>: View {
    let selected: Bool
    let content: () -> Content

    init(selected: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.selected = selected
        self.content = content
    }

    var body: some View {
        HStack(spacing: ObjectColumns.spacing, content: content)
            .padding(.horizontal, 10).frame(minHeight: 44)
            .background(selected ? Palette.tint : Color.clear)
            .overlay(alignment: .leading) {
                if selected { RoundedRectangle(cornerRadius: 2).fill(Palette.blue).frame(width: 3).padding(.vertical, 9) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

extension View {
    /// Makes a console row select `row` on a click, and offer its actions
    /// (`AppModel.rowMenu`, the list its inspector shows) as a context menu.
    func selects(_ row: ConsoleRow, in app: AppModel) -> some View {
        contentShape(Rectangle()).onTapGesture { app.select(row) }
            .modifier(RowActionsMenu(menu: app.rowMenu(row), runner: app.actions) { app.select(row) })
    }
}

/// ObjectColumns is the one place the Services, Storage and Models lists'
/// column widths live.
enum ObjectColumns {
    static let spacing: CGFloat = 12
    static let dot: CGFloat = 16
    static let type: CGFloat = 80
    static let address: CGFloat = 100
    static let ports: CGFloat = 130
    static let hosts: CGFloat = 150
    static let volume: CGFloat = 150
    static let capacity: CGFloat = 66
    static let phase: CGFloat = 80
    static let replicas: CGFloat = 54

    static func header(_ columns: [(String, CGFloat?, Alignment)]) -> some View {
        HStack(spacing: spacing) {
            ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                if let width = column.1 {
                    Text(column.0).frame(width: width, alignment: column.2)
                } else {
                    Text(column.0).frame(maxWidth: .infinity, alignment: column.2)
                }
            }
        }
        .font(.system(size: 11.5)).foregroundStyle(Palette.dimText)
        .padding(.horizontal, 20).padding(.top, 10)
    }

    /// A name over its namespace, the first column of every row.
    static func title(_ name: String, under: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: name).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
            Text(verbatim: under).font(.system(size: 11)).foregroundStyle(Palette.dimText).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func cell(_ text: String, width: CGFloat, alignment: Alignment = .leading, mono: Bool = false) -> some View {
        Text(verbatim: text.isEmpty ? "-" : text)
            .font(.system(size: 12, design: mono ? .monospaced : .default)).monospacedDigit()
            .foregroundStyle(Palette.ink2).lineLimit(1).truncationMode(.middle)
            .frame(width: width, alignment: alignment)
    }
}

/// ServicesSection is the Services tab: every Service with its type, cluster
/// IP, ports and the hosts Ingresses route to it, decided by `ServicesList`.
struct ServicesSection: View {
    @ObservedObject var app: AppModel
    @ObservedObject var loader: TabLoader<[ServiceRow]>

    var body: some View {
        VStack(spacing: 0) {
            ObjectColumns.header([("Service", nil, .leading), ("Type", ObjectColumns.type, .leading),
                                  ("Cluster IP", ObjectColumns.address, .leading), ("Ports", ObjectColumns.ports, .leading),
                                  ("Hosts", ObjectColumns.hosts, .leading)])
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    switch loader.load {
                    case .failed(let text): ListNote(text: text)
                    case .unavailable(let reason): ListNote(text: reason)
                    default:
                        if let rows = loader.value {
                            if rows.isEmpty {
                                ListNote(text: ServicesList.emptyText)
                            }
                            ForEach(ServicesList.visible(rows, query: app.servicesQuery), id: \.key) { row in
                                ListRow(selected: app.isSelected(.service(row.key))) {
                                    ObjectColumns.title(row.name, under: row.namespace)
                                    ObjectColumns.cell(row.type, width: ObjectColumns.type)
                                    ObjectColumns.cell(row.clusterIP, width: ObjectColumns.address, mono: true)
                                    ObjectColumns.cell(row.portsText, width: ObjectColumns.ports)
                                    ObjectColumns.cell(row.hostsText, width: ObjectColumns.hosts)
                                }
                                .selects(.service(row.key), in: app)
                            }
                        } else {
                            ListNote(text: "Reading the services…")
                        }
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
            }
            TabFooter(load: loader.load)
        }
    }
}

/// StorageSection is the Storage tab: this Mac's data volume card on top,
/// then every claim with its volume, capacity and phase, and the volumes no
/// claim holds, decided by `StorageList` and `DataVolume`.
struct StorageSection: View {
    @ObservedObject var app: AppModel
    @ObservedObject var claims: TabLoader<[StorageRow]>
    @ObservedObject var volume: TabLoader<DataVolume>

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    card.padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 6)
                    ObjectColumns.header([("Claim", nil, .leading), ("Volume", ObjectColumns.volume, .leading),
                                          ("Capacity", ObjectColumns.capacity, .trailing), ("Phase", ObjectColumns.phase, .leading)])
                        .padding(.horizontal, -10)
                    LazyVStack(alignment: .leading, spacing: 0) { rows }
                        .padding(.vertical, 8)
                }
                .padding(.horizontal, 10)
            }
            TabFooter(load: claims.load)
        }
    }

    @ViewBuilder private var rows: some View {
        switch claims.load {
        case .failed(let text): ListNote(text: text)
        case .unavailable(let reason): ListNote(text: reason)
        default:
            if let rows = claims.value {
                if rows.isEmpty {
                    ListNote(text: StorageList.emptyText)
                }
                ForEach(StorageList.visible(rows, query: app.storageQuery), id: \.key) { row in
                    ListRow(selected: app.isSelected(.claim(row.key))) {
                        ObjectColumns.title(row.claim ?? "no claim", under: row.namespace ?? (row.storageClass ?? ""))
                        ObjectColumns.cell(row.volume ?? "", width: ObjectColumns.volume, mono: true)
                        ObjectColumns.cell(WorkloadsDisplay.bytes(row.capacityBytes), width: ObjectColumns.capacity, alignment: .trailing)
                        ObjectColumns.cell(row.phase, width: ObjectColumns.phase)
                    }
                    .selects(.claim(row.key), in: app)
                }
            } else {
                ListNote(text: "Reading the volume claims…")
            }
        }
    }

    @ViewBuilder private var card: some View {
        switch volume.load {
        case .failed(let text): DataVolumeCard(word: "Unknown", severity: "off", detail: text, facts: [])
        case .unavailable(let reason): DataVolumeCard(word: "Unknown", severity: "off", detail: reason, facts: [])
        default:
            if let v = volume.value {
                DataVolumeCard(word: v.word, severity: v.severity, detail: v.detail, facts: v.facts)
            } else {
                DataVolumeCard(word: "", severity: "off", detail: "Reading the data volume…", facts: [])
            }
        }
    }
}

/// DataVolumeCard is this Mac's data volume at a glance, in the look of the
/// Builds tab's engine card: its state with a dot, the line under it, the facts.
struct DataVolumeCard: View {
    let word: String
    let severity: String
    let detail: String
    let facts: [(String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Data volume").font(.system(size: 14, weight: .semibold))
                Spacer()
                if !word.isEmpty {
                    Circle().fill(Palette.health(severity)).frame(width: 9, height: 9)
                    Text(verbatim: word).font(.system(size: 12, weight: .medium))
                }
            }
            Text(verbatim: detail).font(.system(size: 12)).foregroundStyle(Palette.ink2).lineLimit(2)
            ForEach(Array(facts.enumerated()), id: \.offset) { _, fact in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(verbatim: fact.0).font(.system(size: 11.5)).foregroundStyle(Palette.dimText).frame(width: 64, alignment: .leading)
                    Text(verbatim: fact.1).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: 460, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.wash))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.line))
    }
}

/// ModelsSection is the Models tab: every MLXModel with its model, phase,
/// replicas and endpoint, decided by `ModelsList`. A cluster that does not
/// serve the MLX API shows the unavailable line, not a failure.
struct ModelsSection: View {
    @ObservedObject var app: AppModel
    @ObservedObject var loader: TabLoader<[ModelRow]>

    var body: some View {
        VStack(spacing: 0) {
            ObjectColumns.header([("", ObjectColumns.dot, .leading), ("Model", nil, .leading),
                                  ("Phase", ObjectColumns.phase, .leading), ("Ready", ObjectColumns.replicas, .trailing),
                                  ("Endpoint", ObjectColumns.hosts, .leading)])
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    switch loader.load {
                    case .failed(let text): ListNote(text: text)
                    case .unavailable(let reason): ListNote(text: reason)
                    default:
                        if let rows = loader.value {
                            if rows.isEmpty {
                                ListNote(text: ModelsList.emptyText)
                            }
                            ForEach(ModelsList.visible(rows, query: app.modelsQuery), id: \.key) { row in
                                ListRow(selected: app.isSelected(.model(row.key))) {
                                    Circle().fill(Palette.health(row.severity)).frame(width: 9, height: 9).frame(width: ObjectColumns.dot)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(verbatim: row.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                        Text(verbatim: row.model.isEmpty ? row.namespace : "\(row.namespace) · \(row.model)")
                                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.dimText)
                                            .lineLimit(1).truncationMode(.middle)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    ObjectColumns.cell(row.phase, width: ObjectColumns.phase)
                                    ObjectColumns.cell(row.replicasText, width: ObjectColumns.replicas, alignment: .trailing)
                                    ObjectColumns.cell(row.endpoint ?? "", width: ObjectColumns.hosts, mono: true)
                                }
                                .selects(.model(row.key), in: app)
                            }
                        } else {
                            ListNote(text: "Reading the models…")
                        }
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
            }
            TabFooter(load: loader.load)
        }
    }
}
