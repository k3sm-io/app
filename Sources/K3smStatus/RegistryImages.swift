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

extension K3smCLI {
    /// `k3sm image ls -o json`: the cluster's one registry and its images,
    /// read without root (cmd/k3sm `imagels.go`, schema version 1).
    public static let imageListArguments = ["image", "ls", "-o", "json"]
}

/// RegistryImage is one image of the cluster's registry, as the Images tab
/// lists it. Every string is clipped; the node names are `ResourceName`s.
public struct RegistryImage: Equatable, Sendable {
    /// The row's identity: the reference, by `ImagesList.rowKey`, so it
    /// survives `StatusDisplay.clip` unchanged and is safe to store.
    public let key: String
    /// The canonical reference ("registry-k3sm:6450/app:v1"), clipped.
    public let reference: String
    public let repository: String
    public let tag: String
    /// The manifest digest, only when it is "sha256:" and 64 lowercase hex.
    public let digest: String?
    /// The platforms the image is built for ("darwin/arm64"), clipped.
    public let platforms: [String]
    /// The size the registry reports; nil when it is not a whole, non-negative number.
    public let sizeBytes: Int64?
    /// How many pods use it, as k3sm counts them; nil when it is not reported.
    public let pods: Int?
    /// The nodes holding a cached copy, by name, in the CLI's order.
    public let cachedOn: [String]
    /// The tag Untag deletes, read from the unclipped reference and digest;
    /// nil when they are not a cluster-registry tag and a sha256 digest.
    public let untag: RegistryTag?

    /// The digest as the row shows it: "sha256:" and its first 12 hex.
    public var shortDigest: String? {
        digest.map { String($0.prefix("sha256:".count + 12)) }
    }

    /// The Cached on cell: one or two node names, else a count; "none" when
    /// no node holds a copy.
    public var cachedOnText: String {
        if cachedOn.isEmpty { return "none" }
        return cachedOn.count <= 2 ? cachedOn.map { NodeNameMask.shown($0) }.joined(separator: ", ") : "\(cachedOn.count) nodes"
    }
}

/// RegistryMigration is what `image ls` says about moving the node stores'
/// images into the registry. The CLI prints null until that move reports;
/// an object is read for its `held` count (a number, or a list whose length
/// counts), and every other key is ignored.
public struct RegistryMigration: Equatable, Sendable {
    /// The entries left held in a node store, not moved; nil when not reported.
    public let held: Int?
}

/// RegistryImageList is one `k3sm image ls -o json` run.
public struct RegistryImageList: Equatable, Sendable {
    /// The registry's name ("registry-k3sm:6450"), clipped.
    public let registryName: String
    public let reachable: Bool
    /// Why the registry could not be read, through `StatusDisplay.errorText`.
    public let error: String?
    /// The images, sorted by reference; empty when the registry is unreachable.
    public let images: [RegistryImage]
    /// The nodes whose cache list was cut short, so a cached-on line may miss them.
    public let cachedOnIncomplete: [String]
    public let migration: RegistryMigration?
}

/// RegistryImagesDecodeError is why an `image ls` run did not read.
public enum RegistryImagesDecodeError: Error, Equatable {
    /// The bytes are not a JSON object with a registry.
    case malformed
    /// The object's `schemaVersion` is not 1 (nil when it is missing or not a number).
    case unsupportedSchema(Int?)
}

/// RegistryImages decodes `K3smCLI.imageListArguments` and words the Images
/// tab's lines.
public enum RegistryImages {
    /// The one schema version this app reads.
    public static let schemaVersion = 1

    /// The tab's line when the registry holds no image.
    public static let emptyText = "The cluster's registry holds no images."

    /// A run's bytes, read strictly at the top (an object, schema version 1,
    /// a registry object) and tolerantly below it: an image without a
    /// reference is skipped, of two with the same key only the first is
    /// kept, a node name `ResourceName` refuses is dropped, and unknown
    /// keys are ignored.
    public static func decode(_ data: Data) throws -> RegistryImageList {
        guard let top = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw RegistryImagesDecodeError.malformed
        }
        let version = number(top["schemaVersion"])
        guard version == Int64(schemaVersion) else {
            throw RegistryImagesDecodeError.unsupportedSchema(version.flatMap { Int(exactly: $0) })
        }
        guard let registry = top["registry"] as? [String: Any] else { throw RegistryImagesDecodeError.malformed }
        let reachable = registry["reachable"] as? Bool ?? false
        let error = (registry["error"] as? String).flatMap { $0.isEmpty ? nil : StatusDisplay.errorText($0) }
        var seen = Set<String>()
        var images: [RegistryImage] = []
        for case let entry as [String: Any] in top["images"] as? [Any] ?? [] {
            guard let image = image(entry), seen.insert(image.key).inserted else { continue }
            images.append(image)
        }
        return RegistryImageList(
            registryName: StatusDisplay.clip(registry["name"] as? String ?? ""),
            reachable: reachable,
            error: error,
            images: sorted(images),
            cachedOnIncomplete: nodes(top["cachedOnIncomplete"]),
            migration: migration(top["migration"]))
    }

    /// One element of `images[]` (or one streamed image line), or nil when
    /// it has no reference. Every string is clipped and unknown keys are
    /// ignored.
    static func image(_ entry: [String: Any]) -> RegistryImage? {
        guard let raw = entry["reference"] as? String, !raw.isEmpty else { return nil }
        let digest = (entry["digest"] as? String).flatMap { ImagesList.digest(of: "x@" + $0) }
        return RegistryImage(
            key: ImagesList.rowKey(raw),
            reference: StatusDisplay.clip(raw),
            repository: StatusDisplay.clip(entry["repository"] as? String ?? ""),
            tag: StatusDisplay.clip(entry["tag"] as? String ?? ""),
            digest: digest,
            platforms: strings(entry["platforms"]).map(StatusDisplay.clip),
            sizeBytes: ImagesList.size(entry["sizeBytes"]),
            pods: number(entry["pods"]).flatMap { $0 >= 0 ? Int(exactly: $0) : nil },
            cachedOn: nodes(entry["cachedOn"]),
            untag: RegistryTag(reference: raw, digest: entry["digest"] as? String))
    }

    /// The images in the tab's order: by reference, then key.
    static func sorted(_ images: [RegistryImage]) -> [RegistryImage] {
        images.sorted { ($0.reference, $0.key) < ($1.reference, $1.key) }
    }

    /// One run as a tab result.
    public static func tabResult(exitCode: Int32, stdout: Data) -> TabResult<RegistryImageList> {
        guard exitCode == 0 else { return .failed("k3sm image ls exited \(exitCode)") }
        do {
            return .value(try decode(stdout))
        } catch RegistryImagesDecodeError.unsupportedSchema(let version) {
            return .failed(unsupportedText(version))
        } catch {
            return .failed("the registry's image list could not be read")
        }
    }

    /// The line for a schema version this app does not read.
    public static func unsupportedText(_ version: Int?) -> String {
        guard let version else { return "k3sm image ls printed no schema version this app reads." }
        return "k3sm image ls printed schema version \(version); this app reads version \(schemaVersion)."
    }

    /// The images the search leaves visible: all for an empty query, else
    /// those whose reference contains it, case ignored.
    public static func visible(_ images: [RegistryImage], query: String) -> [RegistryImage] {
        guard !query.isEmpty else { return images }
        return images.filter { $0.reference.localizedCaseInsensitiveContains(query) }
    }

    /// The keys a read lists, for `ConsoleSelection`; nil before a read decoded.
    public static func keys(_ list: RegistryImageList?) -> Set<String>? {
        list.map { Set($0.images.map(\.key)) }
    }

    /// The one line an unreachable registry shows, with its error.
    public static func unreachableText(_ list: RegistryImageList) -> String? {
        guard !list.reachable else { return nil }
        let name = list.registryName.isEmpty ? "The cluster's registry" : "The registry \(list.registryName)"
        return StatusDisplay.errorText("\(name) could not be reached: \(list.error ?? "no reason given").")
    }

    /// The note when some nodes' cache lists were cut short.
    public static func incompleteText(_ list: RegistryImageList, mask: [String: String]? = NodeNameMask.current) -> String? {
        let nodes = list.cachedOnIncomplete.map { NodeNameMask.shown($0, mask: mask) }
        guard !nodes.isEmpty else { return nil }
        let names = nodes.count <= 3 ? "Nodes " + nodes.joined(separator: ", ") : "\(nodes.count) nodes"
        let text = nodes.count == 1
            ? "Node \(nodes[0]) listed only part of its images, so a Cached on cell may leave it out."
            : "\(names) listed only part of their images, so a Cached on cell may leave them out."
        return StatusDisplay.clip(text)
    }

    /// The banner when the move into the registry left entries held in a node store.
    public static func migrationText(_ list: RegistryImageList) -> String? {
        guard let held = list.migration?.held, held > 0 else { return nil }
        let entries = held == 1 ? "1 image stayed" : "\(held) images stayed"
        return "\(entries) in a node's own store when images moved into the registry; load them again to move them."
    }

    // MARK: Reading

    static func number(_ value: Any?) -> Int64? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return Int64(exactly: n.doubleValue)
    }

    static func strings(_ value: Any?) -> [String] {
        (value as? [Any] ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty }
    }

    static func nodes(_ value: Any?) -> [String] {
        var seen = Set<String>()
        return strings(value).compactMap(ResourceName.init).map(\.value).filter { seen.insert($0).inserted }
    }

    static func migration(_ value: Any?) -> RegistryMigration? {
        guard let object = value as? [String: Any] else { return nil }
        if let list = object["held"] as? [Any] { return RegistryMigration(held: list.count) }
        return RegistryMigration(held: number(object["held"]).flatMap { $0 >= 0 ? Int(exactly: $0) : nil })
    }
}

extension InspectorDetails {
    /// A registry image: its reference, digest, platforms, size, the pods
    /// using it and the nodes caching it.
    public static func registryImage(_ image: RegistryImage, mask: [String: String]? = NodeNameMask.current) -> InspectorBody {
        let size = WorkloadsDisplay.bytes(image.sizeBytes)
        let facts = [
            InspectorFact("Reference", image.reference, mono: true),
            InspectorFact("Digest", image.digest ?? "not reported", mono: true),
            InspectorFact("Platforms", image.platforms.isEmpty ? "not reported" : image.platforms.joined(separator: ", ")),
            InspectorFact("Size", size.isEmpty ? "not reported" : size),
            InspectorFact("Pods", image.pods.map(String.init) ?? "not reported"),
            InspectorFact("Cached on", image.cachedOn.isEmpty ? "no node" : image.cachedOn.map { NodeNameMask.shown($0, mask: mask) }.joined(separator: ", ")),
        ]
        return InspectorBody(kind: "Image", title: image.reference, subtitle: nil, facts: facts)
    }
}
