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

import K3smInstall
import K3smStatus
import SwiftUI

/// ImagesSection is the Images tab: the images of the cluster's one
/// registry, from its own read (`k3sm image ls -o json`, `RegistryImages`),
/// each with its short digest, size, the pods using it and the nodes caching
/// it. An unreachable registry is one line with its error; a banner says when
/// images stayed held in a node store, and a note names the nodes whose cache
/// list was cut short. Its header row names this Mac's node and offers Mirror
/// and Prune, each row's menu offers Untag, and its sheets are the Mirror
/// field and the prune's preview (`ImageStoreModel`).
struct ImagesSection: View {
    @ObservedObject var app: AppModel
    @ObservedObject var images: TabLoader<RegistryImageList>
    @ObservedObject var columns: ColumnsModel
    @ObservedObject var store: ImageStoreModel

    var body: some View {
        VStack(spacing: 0) {
            ImagesHeaderRow(app: app, store: store)
            ColumnHeader(layout: .images, columns: columns,
                         help: [.size: Help.Images.size, .pods: Help.Images.pods, .nodes: Help.Images.nodes])
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    content
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
            }
            TabFooter(load: images.load)
        }
        .sheet(isPresented: Binding(get: { store.sheet != nil }, set: { if !$0 { store.closeSheet() } })) {
            switch store.sheet {
            case .pull?: ImagePullSheet(app: app, store: store)
            case .prune(let preview, let node)?: ImagePruneSheet(app: app, store: store, preview: preview, node: node)
            case nil: EmptyView()
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch images.load {
        case .failed(let text): note(text)
        case .unavailable(let reason): note(reason)
        default:
            if let list = images.value {
                listed(list)
            } else {
                note("Reading the registry…")
            }
        }
    }

    @ViewBuilder private func listed(_ list: RegistryImageList) -> some View {
        if let migration = RegistryImages.migrationText(list) {
            Text(verbatim: migration).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Palette.wash))
                .padding(.bottom, 6)
        }
        if let unreachable = RegistryImages.unreachableText(list) {
            note(unreachable)
        } else if list.images.isEmpty {
            note(RegistryImages.emptyText)
        } else {
            ForEach(RegistryImages.visible(list.images, query: app.imagesQuery), id: \.key) { image in
                RegistryImageRow(image: image, selected: app.isSelected(.image(image.key)), widths: columns.widths(.images))
                    .selects(.image(image.key), in: app, extra: untagItems(image))
            }
        }
        if let incomplete = RegistryImages.incompleteText(list) {
            Text(verbatim: incomplete).font(.system(size: 11.5)).foregroundStyle(Palette.dimText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10).padding(.top, 8)
        }
    }

    private func note(_ text: String) -> some View {
        Text(verbatim: text).foregroundStyle(Palette.ink2).padding(20)
    }

    /// The row's context-menu Untag item, which deletes the row's tag from
    /// the cluster registry, enabled only when the inspector's Untag is
    /// (`ImageStoreDriver.untagDisabledReason`).
    private func untagItems(_ image: RegistryImage) -> [RowMenuExtra] {
        let role = app.report.flatMap(NodeRole.detect)
        let reason = ImageStoreDriver.untagDisabledReason(image, role: role, availability: app.availability,
                                                          busy: app.running || store.running)
        return [RowMenuExtra(id: "untag " + image.key, title: "Untag…", enabled: reason == nil) { store.untag(image, role: role) }]
    }
}

/// RegistryImageRow is one registry image: its reference over its short
/// digest, its size, the pods using it, and, quietly, the nodes caching it.
struct RegistryImageRow: View {
    let image: RegistryImage
    let selected: Bool
    let widths: ColumnWidths

    var body: some View {
        HStack(spacing: CGFloat(TableColumns.images.spacing)) {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: image.reference).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                if let digest = image.shortDigest {
                    Text(verbatim: digest).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.dimText)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: WorkloadsDisplay.bytes(image.sizeBytes)).font(.system(size: 12)).monospacedDigit()
                .foregroundStyle(Palette.ink2).frame(width: widths.cg(.size), alignment: .trailing)
            Text(verbatim: image.pods.map(String.init) ?? "").font(.system(size: 12)).monospacedDigit()
                .foregroundStyle(Palette.ink2).frame(width: widths.cg(.pods), alignment: .trailing)
            Text(verbatim: image.cachedOnText).font(.system(size: 11.5)).foregroundStyle(Palette.dimText)
                .lineLimit(1).truncationMode(.middle).frame(width: widths.cg(.nodes), alignment: .leading)
        }
        .padding(.horizontal, 10).frame(height: 44)
        .background(selected ? Palette.tint : Color.clear)
        .overlay(alignment: .leading) {
            if selected { RoundedRectangle(cornerRadius: 2).fill(Palette.blue).frame(width: 3).padding(.vertical, 9) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// TabFooter is a tab's last line: how old its read is, kept current while
/// the tab is on screen, so a re-selected tab says how stale its list is.
struct TabFooter: View {
    let load: TabLoad

    var body: some View {
        if case .loaded(let at) = load {
            TimelineView(.periodic(from: .now, by: 5)) { context in
                Text(verbatim: TabLoad.age(since: at, now: context.date))
                    .font(.system(size: 11)).foregroundStyle(Palette.dimText)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.bottom, 8)
            }
        }
    }
}
