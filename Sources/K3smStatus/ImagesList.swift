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

import Foundation

/// NodeImage is one image the cluster's nodes hold, as the Images tab lists
/// it: every name the nodes report for it, its size, and the nodes holding
/// it. Images are one entry per digest, so a tag on one node and the same
/// digest under another tag on a second node are one row.
public struct NodeImage: Equatable, Sendable {
    /// The row's identity: the digest, or, when no name carries a valid one,
    /// the first name reported (`ImagesList.rowKey`). It always survives
    /// `StatusDisplay.clip` unchanged, so it is safe to show and to store.
    public let key: String
    /// The content digest ("sha256:…"), clipped; nil when no name has one.
    public let digest: String?
    /// The names, tags first, then digest references, each clipped, sorted
    /// and without repeats.
    public let names: [String]
    /// The size a node reports; nil when none reports a usable one.
    public let sizeBytes: Int64?
    /// The nodes holding it, by name, sorted.
    public let nodes: [String]
    /// Its tags on each node, by node name: the names reported without a
    /// digest that pass `ImageRef`, unclipped and sorted, so Untag names
    /// exactly what the node holds and never a clipped look-alike.
    public internal(set) var tags: [String: [ImageRef]] = [:]

    /// The name the row shows: the first tag, else the first name.
    public var title: String {
        names.first { !$0.contains("@") } ?? names.first ?? key
    }

    /// The nodes as the row shows them: one or two names, else a count.
    public var nodesText: String {
        nodes.count <= 2 ? nodes.joined(separator: ", ") : "\(nodes.count) nodes"
    }
}

/// ImagesReading is what the node list says about images: no node reports
/// them (the field is absent on every node), or the images reported.
public enum ImagesReading: Equatable, Sendable {
    case notReported
    case listed([NodeImage])
}

/// ImagesList reads `status.images` from the node list the console already
/// reads (`K3smCLI.nodesArguments`), the list a kubelet reports: each entry
/// `names` and `sizeBytes`. Nothing is invented: a node without the field
/// contributes nothing, and when no node has it the tab says so.
public enum ImagesList {
    /// The tab's line when no node reports its images.
    public static let notReportedText = "No node reports its images yet."
    /// The tab's line when the nodes report an empty image list.
    public static let emptyText = "No images on the cluster's nodes."

    /// The images of a node list's objects, grouped by digest and sorted by
    /// the name they show.
    static func read(_ objects: [[String: Any]]) -> ImagesReading {
        var reported = false
        var order: [String] = []
        var groups: [String: (digest: String?, names: Set<String>, size: Int64?, nodes: Set<String>, tags: [String: Set<String>])] = [:]
        for object in objects {
            let metadata = object["metadata"] as? [String: Any] ?? [:]
            guard let raw = metadata["name"] as? String, let node = ResourceName(raw) else { continue }
            let status = object["status"] as? [String: Any] ?? [:]
            guard let entries = status["images"] as? [Any] else { continue }
            reported = true
            for case let entry as [String: Any] in entries {
                let names = (entry["names"] as? [Any] ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty }
                guard let first = names.first else { continue }
                let digest = names.lazy.compactMap(Self.digest(of:)).first
                let key = digest ?? rowKey(first)
                var group = groups[key] ?? (digest, [], nil, [], [:])
                if groups[key] == nil { order.append(key) }
                group.names.formUnion(names.map(StatusDisplay.clip))
                group.size = group.size ?? Self.size(entry["sizeBytes"])
                group.nodes.insert(node.value)
                let refs = names.filter { !$0.contains("@") }.compactMap(ImageRef.init).map(\.value)
                group.tags[node.value, default: []].formUnion(refs)
                groups[key] = group
            }
        }
        guard reported else { return .notReported }
        let images = order.compactMap { key -> NodeImage? in
            guard let g = groups[key] else { return nil }
            let tags = g.names.filter { !$0.contains("@") }.sorted()
            let refs = g.names.filter { $0.contains("@") }.sorted()
            var image = NodeImage(key: key, digest: g.digest, names: tags + refs, sizeBytes: g.size, nodes: g.nodes.sorted())
            image.tags = g.tags.mapValues { $0.sorted().compactMap(ImageRef.init) }.filter { !$0.value.isEmpty }
            return image
        }
        return .listed(images.sorted { ($0.title, $0.key) < ($1.title, $1.key) })
    }

    /// The images the search leaves visible: all for an empty query, else
    /// those with a shown name containing it, case ignored.
    public static func visible(_ images: [NodeImage], query: String) -> [NodeImage] {
        guard !query.isEmpty else { return images }
        return images.filter { image in image.names.contains { $0.localizedCaseInsensitiveContains(query) } }
    }

    /// What a read does to the Images tab's selection: a selected image
    /// still listed stays; one gone from the list, or a list with no images
    /// reported, clears it. Nothing is selected for the user.
    public static func selection(after selected: String?, in reading: ImagesReading) -> String? {
        guard let selected, case .listed(let images) = reading, images.contains(where: { $0.key == selected }) else {
            return nil
        }
        return selected
    }

    /// The digest of a reference "repo@sha256:<64 lowercase hex>", or nil
    /// for anything else after the "@" (any other algorithm, a short or
    /// non-hex value), so a crafted name never keys a row as a digest.
    static func digest(of name: String) -> String? {
        guard let at = name.lastIndex(of: "@") else { return nil }
        let digest = name[name.index(after: at)...]
        let prefix = "sha256:"
        guard digest.hasPrefix(prefix) else { return nil }
        let hex = digest.dropFirst(prefix.count).unicodeScalars
        guard hex.count == 64, hex.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }) else { return nil }
        return String(digest)
    }

    /// The row key for a name without a digest: the name itself when
    /// `StatusDisplay.clip` leaves it unchanged; otherwise its clipped form,
    /// shortened, with a hash of the whole name, so two long names that
    /// share their shown prefix stay two rows.
    static func rowKey(_ name: String) -> String {
        let shown = StatusDisplay.clip(name)
        guard shown != name else { return name }
        let hash = String(fnv1a64(name), radix: 16)
        let room = StatusDisplay.maxLength - 1 - 16
        return String(shown.prefix(room)) + "#" + String(repeating: "0", count: 16 - hash.count) + hash
    }

    /// FNV-1a over the name's UTF-8: a stable, non-cryptographic hash that
    /// only keeps row keys apart; nothing trusts it.
    static func fnv1a64(_ text: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            h ^= UInt64(byte)
            h = h &* 0x0000_0100_0000_01b3
        }
        return h
    }

    /// A size in bytes from JSON, or nil when it is not a whole, non-negative number.
    static func size(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        guard let bytes = Int64(exactly: number.doubleValue), bytes >= 0 else { return nil }
        return bytes
    }
}
