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

/// ImagesSection is the Images tab: the images the cluster's nodes report,
/// one row per digest, from the shared node list (no read of its own). When
/// no node reports its images the tab says so in one line; nothing is
/// invented in their place.
struct ImagesSection: View {
    @ObservedObject var app: AppModel
    @ObservedObject var workloads: WorkloadsModel

    private var nodeList: TabLoader<NodeListRead> { workloads.nodeList }

    var body: some View {
        VStack(spacing: 0) {
            ImageColumns.header
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    content
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
            }
            TabFooter(load: nodeList.load)
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
                ForEach(ImagesList.visible(images, query: app.imagesQuery), id: \.key) { image in
                    ImageRow(image: image, selected: app.isSelected(.image(image.key)))
                        .selects(.image(image.key), in: app)
                }
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(verbatim: text).foregroundStyle(Palette.ink2).padding(20)
    }
}

/// ImageColumns is the one place the Images list's column widths live.
enum ImageColumns {
    static let size: CGFloat = 66
    static let nodes: CGFloat = 140
    static let spacing: CGFloat = 12

    static var header: some View {
        HStack(spacing: spacing) {
            Text("Image").frame(maxWidth: .infinity, alignment: .leading)
            Text("Size").frame(width: size, alignment: .trailing)
            Text("Nodes").frame(width: nodes, alignment: .leading)
        }
        .font(.system(size: 11.5)).foregroundStyle(Palette.dimText)
        .padding(.horizontal, 20).padding(.top, 10)
    }
}

/// ImageRow is one image: its name over its digest, its size, its nodes.
struct ImageRow: View {
    let image: NodeImage
    let selected: Bool

    var body: some View {
        HStack(spacing: ImageColumns.spacing) {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: image.title).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                if let digest = image.digest {
                    Text(verbatim: digest).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.dimText)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: WorkloadsDisplay.bytes(image.sizeBytes)).font(.system(size: 12)).monospacedDigit()
                .foregroundStyle(Palette.ink2).frame(width: ImageColumns.size, alignment: .trailing)
            Text(verbatim: image.nodesText).font(.system(size: 11.5)).foregroundStyle(Palette.dimText)
                .lineLimit(1).truncationMode(.middle).frame(width: ImageColumns.nodes, alignment: .leading)
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
