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

/// ImagesSection is the Images tab: the images the cluster's nodes report,
/// one row per digest, from the shared node list (no read of its own), each
/// with the number of listed pods using it. When no node reports its images
/// the tab says so in one line; nothing is invented in their place. Its
/// header row names this Mac's node and offers Pull and Prune, and its
/// sheets are the Pull field and the prune's preview (`ImageStoreModel`).
struct ImagesSection: View {
    @ObservedObject var app: AppModel
    @ObservedObject var workloads: WorkloadsModel
    @ObservedObject var columns: ColumnsModel
    @ObservedObject var store: ImageStoreModel

    private var nodeList: TabLoader<NodeListRead> { workloads.nodeList }

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
            TabFooter(load: nodeList.load)
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
        switch nodeList.load {
        case .failed(let text): note(text)
        case .unavailable(let reason): note(reason)
        default:
            switch nodeList.value?.images {
            case nil: note("Reading the node list…")
            case .notReported?: note(ImagesList.notReportedText)
            case .listed(let images)? where images.isEmpty: note(ImagesList.emptyText)
            case .listed(let images)?:
                let counts = workloads.workloads.map { ImagesList.podCounts(images, pods: $0.pods) }
                ForEach(ImagesList.visible(images, query: app.imagesQuery), id: \.key) { image in
                    ImageRow(image: image, pods: counts.map { $0[image.key] ?? 0 }, selected: app.isSelected(.image(image.key)),
                             widths: columns.widths(.images))
                        .selects(.image(image.key), in: app, extra: untagItems(image))
                }
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(verbatim: text).foregroundStyle(Palette.ink2).padding(20)
    }

    /// The row's context-menu Untag items: the inspector's buttons, through
    /// the same model and question.
    private func untagItems(_ image: NodeImage) -> [RowMenuExtra] {
        let scope = ImageStoreScope.decide(report: app.report)
        let enabled = ImageStoreDriver.disabledReason(scope: scope, availability: app.availability,
                                                      busy: app.running || store.running) == nil
        return ImageStoreOffer.decide(image, scope: scope).untag.map { reference in
            RowMenuExtra(id: "untag " + reference.value, title: StatusDisplay.clip("Untag \(reference.value)…"), enabled: enabled) {
                store.untag(reference, of: image, scope: scope)
            }
        }
    }
}

/// ImageRow is one image: its name over its digest, its size, the listed
/// pods using it (blank before the pod list is read), its nodes.
struct ImageRow: View {
    let image: NodeImage
    let pods: Int?
    let selected: Bool
    let widths: ColumnWidths

    var body: some View {
        HStack(spacing: CGFloat(TableColumns.images.spacing)) {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: image.title).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                if let digest = image.digest {
                    Text(verbatim: digest).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.dimText)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: WorkloadsDisplay.bytes(image.sizeBytes)).font(.system(size: 12)).monospacedDigit()
                .foregroundStyle(Palette.ink2).frame(width: widths.cg(.size), alignment: .trailing)
            Text(verbatim: ImagesList.podsText(pods)).font(.system(size: 12)).monospacedDigit()
                .foregroundStyle(Palette.ink2).frame(width: widths.cg(.pods), alignment: .trailing)
            Text(verbatim: image.nodesText).font(.system(size: 11.5)).foregroundStyle(Palette.dimText)
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
