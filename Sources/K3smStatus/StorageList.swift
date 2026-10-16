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

/// StorageRow is one row of the Storage tab: a claim with the volume bound
/// to it, or a volume no listed claim holds (a released or available one).
/// Every string is clipped.
public struct StorageRow: Equatable, Sendable {
    /// "pvc/<namespace>/<name>" for a claim, "pv/<name>" for a volume alone.
    public let key: String
    /// The claim's namespace and name; nil for a volume no claim holds.
    public let namespace: String?
    public let claim: String?
    /// The bound volume's name; nil while the claim is unbound.
    public let volume: String?
    /// The capacity the claim was given, else its volume's, else what it requests.
    public let capacityBytes: Int64?
    /// The claim's phase, or the volume's for a volume alone; "" when unset.
    public let phase: String
    public let storageClass: String?
    /// The access modes ("ReadWriteOnce", …): the claim's granted ones, else
    /// those it asks for; a volume alone's own. Clipped, in the API's order.
    public let accessModes: [String]
}

/// StorageList decodes `K3smCLI.storageArguments`, kubectl's `List` of
/// claims and volumes, into the Storage tab's rows: every claim, sorted by
/// namespace and name, with its volume, then every volume no listed claim
/// holds, by name.
public enum StorageList {
    /// The tab's line when the cluster has no claim and no volume.
    public static let emptyText = "No volume claims or volumes on the cluster."

    /// The rows. It throws `KubeListError` when the bytes are not a list of
    /// claims and volumes.
    public static func decode(_ data: Data) throws -> [StorageRow] {
        let objects = try KubeList.objects(data, kinds: ["PersistentVolumeClaim", "PersistentVolume"])
        let volumes = objects.filter { $0["kind"] as? String == "PersistentVolume" }
        var byName: [String: [String: Any]] = [:]
        for volume in volumes { byName[KubeList.name(volume)] = volume }
        var held: Set<String> = []
        var rows: [StorageRow] = []
        for claim in objects where claim["kind"] as? String == "PersistentVolumeClaim" {
            let namespace = KubeList.namespace(claim)
            let name = KubeList.name(claim)
            let spec = KubeList.dict(claim, "spec")
            let status = KubeList.dict(claim, "status")
            let volumeName = KubeList.string(spec, "volumeName")
            if let volumeName { held.insert(volumeName) }
            let volume = volumeName.flatMap { byName[$0] }
            let capacity = quantity(KubeList.dict(status, "capacity"))
                ?? volume.flatMap { quantity(KubeList.dict(KubeList.dict($0, "spec"), "capacity")) }
                ?? quantity(KubeList.dict(KubeList.dict(spec, "resources"), "requests"))
            rows.append(StorageRow(
                key: "pvc/" + StatusDisplay.clip("\(namespace)/\(name)"),
                namespace: StatusDisplay.clip(namespace),
                claim: StatusDisplay.clip(name),
                volume: volumeName.map(StatusDisplay.clip),
                capacityBytes: capacity,
                phase: StatusDisplay.clip(KubeList.string(status, "phase") ?? ""),
                storageClass: KubeList.string(spec, "storageClassName").map(StatusDisplay.clip),
                accessModes: Self.modes(status["accessModes"]) ?? Self.modes(spec["accessModes"]) ?? []))
        }
        rows.sort { ($0.namespace ?? "", $0.claim ?? "") < ($1.namespace ?? "", $1.claim ?? "") }
        var alone: [StorageRow] = []
        for volume in volumes {
            let name = KubeList.name(volume)
            let spec = KubeList.dict(volume, "spec")
            let ref = KubeList.dict(spec, "claimRef")
            let refKey = "\(KubeList.string(ref, "namespace") ?? "")/\(KubeList.string(ref, "name") ?? "")"
            // A volume whose claim is listed is that claim's row already.
            let listed = held.contains(name) || rows.contains { "pvc/" + StatusDisplay.clip(refKey) == $0.key }
            guard !listed else { continue }
            alone.append(StorageRow(
                key: "pv/" + StatusDisplay.clip(name),
                namespace: nil, claim: nil,
                volume: StatusDisplay.clip(name),
                capacityBytes: quantity(KubeList.dict(spec, "capacity")),
                phase: StatusDisplay.clip(KubeList.string(KubeList.dict(volume, "status"), "phase") ?? ""),
                storageClass: KubeList.string(spec, "storageClassName").map(StatusDisplay.clip),
                accessModes: Self.modes(spec["accessModes"]) ?? []))
        }
        return rows + alone.sorted { ($0.volume ?? "") < ($1.volume ?? "") }
    }

    /// One list run as a tab result.
    public static func tabResult(exitCode: Int32, stdout: Data) -> TabResult<[StorageRow]> {
        KubeList.tabResult(exitCode: exitCode, stdout: stdout, what: "volume claim list", decode: decode)
    }

    /// The rows the search leaves visible: all for an empty query, else those
    /// whose namespace, claim or volume contains it, case ignored.
    public static func visible(_ rows: [StorageRow], query: String) -> [StorageRow] {
        guard !query.isEmpty else { return rows }
        return rows.filter { row in
            [row.namespace, row.claim, row.volume].compactMap { $0 }.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    /// An `accessModes` array, each string clipped; nil when it is absent,
    /// mistyped or empty, so a claim's empty status falls back to its spec.
    private static func modes(_ value: Any?) -> [String]? {
        let modes = (value as? [Any] ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty }.map(StatusDisplay.clip)
        return modes.isEmpty ? nil : modes
    }

    /// The `storage` quantity of a capacity or requests map, as bytes.
    private static func quantity(_ map: [String: Any]) -> Int64? {
        (map["storage"] as? String).flatMap(Quantity.bytes)
    }
}

/// DataVolume is the Storage tab's card, decoded from
/// `K3smCLI.dataVolumeArguments` (`k3sm datavol status -o json`): the APFS
/// volume the data root lives on, as this Mac records it. A field that is
/// absent or mistyped is unknown; only a top level that is not an object
/// fails the read.
public struct DataVolume: Equatable, Sendable {
    /// Whether a data volume is recorded on this Mac (`record` is an object).
    public let recorded: Bool
    public let name: String?
    public let mountpoint: String?
    /// The volume's quota; 0 when it has none and can grow to fill its container.
    public let quotaBytes: Int64?
    public let encrypted: Bool?
    public let mounted: Bool
    public let totalBytes: Int64?
    public let availBytes: Int64?
    /// The volume's own usage, only when k3sm says which probe measured it
    /// (`usedSource` "statfs" or "apfs"); nil otherwise, never a guess.
    public let usedBytes: Int64?
    /// The pre-migration copy beside the data root, when one is present.
    public let preVolumeBytes: Int64?

    /// Decodes the report. It throws `KubeListError.malformed` when the
    /// bytes are not a JSON object.
    public static func decode(_ data: Data) throws -> DataVolume {
        guard let top = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw KubeListError.malformed
        }
        let record = top["record"] as? [String: Any]
        let statfs = top["statfs"] as? [String: Any]
        let pre = KubeList.dict(top, "preVolume")
        let source = statfs.flatMap { KubeList.string($0, "usedSource") }
        return DataVolume(
            recorded: record != nil,
            name: record.flatMap { KubeList.string($0, "name") }.map(StatusDisplay.clip),
            mountpoint: record.flatMap { KubeList.string($0, "mountpoint") }.map(StatusDisplay.clip),
            quotaBytes: record.flatMap { KubeList.bytes($0, "quotaBytes") },
            encrypted: record.flatMap { KubeList.bool($0, "encrypted") },
            mounted: KubeList.bool(top, "mounted") ?? false,
            totalBytes: statfs.flatMap { KubeList.bytes($0, "totalBytes") },
            availBytes: statfs.flatMap { KubeList.bytes($0, "availBytes") },
            usedBytes: source == "statfs" || source == "apfs" ? statfs.flatMap { KubeList.bytes($0, "usedBytes") } : nil,
            preVolumeBytes: KubeList.bool(pre, "present") == true ? KubeList.bytes(pre, "bytes") ?? 0 : nil)
    }

    /// One `datavol status` run as a tab result.
    public static func tabResult(exitCode: Int32, stdout: Data) -> TabResult<DataVolume> {
        guard exitCode == 0 else { return .failed("k3sm datavol status exited \(exitCode)") }
        guard let volume = try? decode(stdout) else { return .failed("the data volume report could not be read") }
        return .value(volume)
    }

    /// The word beside the card's dot.
    public var word: String {
        guard recorded else { return "None" }
        return mounted ? "Mounted" : "Not mounted"
    }

    /// The severity word the card colours its dot by, as `PodHealth`.
    public var severity: String {
        guard recorded else { return "off" }
        return mounted ? "ok" : "bad"
    }

    /// The line under the word.
    public var detail: String {
        guard recorded else { return "No data volume is recorded on this Mac; the data root is a plain directory." }
        return mounted ? "The data root is on its own volume." : "The data root's volume is not mounted."
    }

    /// The card's facts, in order, each a label and a value; a fact k3sm did
    /// not report is left out.
    public var facts: [(String, String)] {
        guard recorded else { return [] }
        var out: [(String, String)] = []
        if let name { out.append(("Volume", name)) }
        if let mountpoint { out.append(("Mount", mountpoint)) }
        if let quotaBytes {
            out.append(("Quota", quotaBytes == 0 ? "none" : WorkloadsDisplay.bytes(quotaBytes)))
        }
        if let usedBytes, let totalBytes {
            out.append(("Used", "\(WorkloadsDisplay.bytes(usedBytes)) of \(WorkloadsDisplay.bytes(totalBytes))"))
        }
        if let availBytes { out.append(("Free", WorkloadsDisplay.bytes(availBytes))) }
        if let encrypted { out.append(("Encrypted", encrypted ? "yes" : "no")) }
        if let preVolumeBytes {
            let size = WorkloadsDisplay.bytes(preVolumeBytes)
            out.append(("Old copy", size.isEmpty ? "the pre-volume copy is still there" : "the pre-volume copy is still there (\(size))"))
        }
        return out
    }
}
