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
    /// The row's identity: the digest, or the first name reported when no
    /// name carries one. Clipped, so it is safe to show and to store.
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
    public static let notReportedText = "This node does not report its images yet."
    /// The tab's line when the nodes report an empty image list.
    public static let emptyText = "No images on the cluster's nodes."

    /// The images of a node list's objects, grouped by digest and sorted by
    /// the name they show.
    static func read(_ objects: [[String: Any]]) -> ImagesReading {
        var reported = false
        var order: [String] = []
        var groups: [String: (digest: String?, names: Set<String>, size: Int64?, nodes: Set<String>)] = [:]
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
                let key = StatusDisplay.clip(digest ?? first)
                var group = groups[key] ?? (digest.map(StatusDisplay.clip), [], nil, [])
                if groups[key] == nil { order.append(key) }
                group.names.formUnion(names.map(StatusDisplay.clip))
                group.size = group.size ?? Self.size(entry["sizeBytes"])
                group.nodes.insert(node.value)
                groups[key] = group
            }
        }
        guard reported else { return .notReported }
        let images = order.compactMap { key -> NodeImage? in
            guard let g = groups[key] else { return nil }
            let tags = g.names.filter { !$0.contains("@") }.sorted()
            let refs = g.names.filter { $0.contains("@") }.sorted()
            return NodeImage(key: key, digest: g.digest, names: tags + refs, sizeBytes: g.size, nodes: g.nodes.sorted())
        }
        return .listed(images.sorted { ($0.title, $0.key) < ($1.title, $1.key) })
    }

    /// The images the search leaves visible: all for an empty query, else
    /// those with a shown name containing it, case ignored.
    public static func visible(_ images: [NodeImage], query: String) -> [NodeImage] {
        guard !query.isEmpty else { return images }
        return images.filter { image in image.names.contains { $0.localizedCaseInsensitiveContains(query) } }
    }

    /// The digest of a reference "repo@sha256:…", or nil without one.
    static func digest(of name: String) -> String? {
        guard let at = name.lastIndex(of: "@") else { return nil }
        let digest = name[name.index(after: at)...]
        return digest.isEmpty ? nil : String(digest)
    }

    /// A size in bytes from JSON, or nil when it is not a whole, non-negative number.
    static func size(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        guard let bytes = Int64(exactly: number.doubleValue), bytes >= 0 else { return nil }
        return bytes
    }
}
