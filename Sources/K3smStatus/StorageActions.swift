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

/// ClaimDeleteRequest is the Delete of one volume claim, fixed when the
/// user asks for it: the names and UID come from the claim as it was listed
/// then, so a later poll or a new selection cannot change what the
/// confirmed delete runs on, and a claim recreated under the same name since
/// is refused by its UID. The pods still mounting it, its volume, the
/// volume's data directory and reclaim policy are fixed then too, for the
/// confirmation's wording.
public struct ClaimDeleteRequest: Equatable, ConsoleActionRequest {
    public let namespace: ResourceName
    public let claim: ResourceName
    /// The claim's selection key, "pvc/namespace/name".
    public let claimKey: String
    /// The claim's UID as listed when the delete was asked for.
    public let uid: String
    /// The bound volume's name, clipped; nil while the claim is unbound.
    public let volume: String?
    /// The bound volume's data directory, clipped; nil when it records none.
    public let path: String?
    /// The bound volume's reclaim policy, clipped; nil when not listed.
    public let reclaimPolicy: String?
    /// The pods still mounting the claim ("name", clipped, in list order);
    /// nil when the pod list has not been read, so it is not known.
    public let mountedBy: [String]?

    public var id: String { "delete-claim:\(claimKey)" }
    public var section: ConsoleSection { .storage }
    public var rowKey: String { claimKey }
    public var verb: String { "delete-claim" }
    public var kind: ActionKind { .delete }

    /// The read run just before the delete, whose output must be `uid`.
    public var precheckArguments: [String]? { K3smCLI.claimUIDArguments(namespace: namespace, claim: claim) }

    public var arguments: [String] { K3smCLI.deleteClaimArguments(namespace: namespace, claim: claim) }

    public var confirmation: ActionConfirmation { StorageActions.confirmation(self) }

    public func precheck(_ run: ActionRun) -> ActionOutcome? { StorageActions.verify(self, run: run) }

    public func report(_ run: ActionRun) -> ActionOutcome { StorageActions.report(self, run: run) }
}

/// VolumeCleanupRequest is the Storage tab's bulk action: delete the volume
/// objects no claim uses (Released, or Available with no claim), fixed when
/// the user asks for it. It removes the PersistentVolume objects only; their
/// data directories stay on disk.
public struct VolumeCleanupRequest: Equatable, ConsoleActionRequest {
    /// One volume to delete, as listed when the cleanup was asked for.
    public struct Volume: Equatable, Sendable {
        public let name: ResourceName
        public let uid: String
        /// Its data directory, clipped; nil when it records none.
        public let path: String?
    }

    public let volumes: [Volume]

    public var id: String { "delete-volumes" }
    public var section: ConsoleSection { .storage }
    public var rowKey: String { ActionMenu.bulkRowKey }
    public var verb: String { "delete-volumes" }
    public var kind: ActionKind { .delete }

    /// Every volume is read first; the cleanup runs only when each one is
    /// still listed with its UID and still unused (`StorageActions.verify`).
    public var precheckArguments: [String]? { K3smCLI.volumesArguments }

    public var arguments: [String] { K3smCLI.deleteVolumesArguments(volumes.map(\.name)) }

    public var confirmation: ActionConfirmation { StorageActions.confirmation(self) }

    public func precheck(_ run: ActionRun) -> ActionOutcome? { StorageActions.verify(self, run: run) }

    public func report(_ run: ActionRun) -> ActionOutcome { StorageActions.report(self, run: run) }
}

/// StorageActions decides what the Storage tab's rows and toolbar offer,
/// builds their requests, words their confirmations and reports their runs.
/// What it says about the data follows k3sm's `local-path` class: its
/// reclaim policy is Retain, so deleting a claim leaves its volume Released
/// with the data directory on the node, and deleting a volume object
/// removes the object while the directory stays. Removing a directory takes
/// root on that node, and the app never does it.
public enum StorageActions {
    /// The bulk action's name, its button and confirmation verb.
    public static let cleanupTitle = "Delete released and unclaimed volumes"
    /// The most names or paths a confirmation lists before "and N more".
    public static let listLimit = 10

    /// The pods still mounting a claim row: in its namespace, mounting it by
    /// name (`Pod.claims`), and not finished (a Succeeded or Failed pod no
    /// longer holds it). Empty for a volume alone or a refused name.
    public static func mountingPods(_ row: StorageRow, in pods: [Pod]) -> [Pod] {
        guard let namespace = row.namespaceName, let claim = row.claimName else { return [] }
        return pods.filter { pod in
            pod.namespace == namespace.value && pod.claims.contains(claim.value)
                && pod.phase != "Succeeded" && pod.phase != "Failed"
        }
    }

    /// The Delete request for a claim row, or nil for a volume alone, a
    /// claim whose names `ResourceName` refuses, or one listed without a
    /// UID. `pods` is the pod list, nil while it has not been read.
    public static func deleteRequest(for row: StorageRow, pods: [Pod]?) -> ClaimDeleteRequest? {
        guard let namespace = row.namespaceName, let claim = row.claimName, !row.uid.isEmpty else { return nil }
        return ClaimDeleteRequest(
            namespace: namespace, claim: claim, claimKey: row.key, uid: row.uid,
            volume: row.volume, path: row.path, reclaimPolicy: row.reclaimPolicy,
            mountedBy: pods.map { mountingPods(row, in: $0).map { StatusDisplay.clip($0.name) } })
    }

    /// A row's actions as its context menu, the inspector and the Delete key
    /// show them: Delete for a claim, nothing for a volume alone.
    public static func menu(for row: StorageRow, pods: [Pod]?) -> ActionMenu {
        ActionMenu(deleteRequest(for: row, pods: pods).map { [$0] } ?? [])
    }

    /// Whether a volume is unused: Released (its claim was deleted), or
    /// Available with no claim reserving it.
    public static func cleanable(phase: String, claimed: Bool) -> Bool {
        phase == "Released" || (phase == "Available" && !claimed)
    }

    /// The volumes the cleanup would delete, in list order: rows of volumes
    /// alone that are unused, with a name `ResourceName` accepts and a UID.
    public static func cleanable(_ rows: [StorageRow]) -> [VolumeCleanupRequest.Volume] {
        rows.compactMap { row in
            guard row.claim == nil, cleanable(phase: row.phase, claimed: row.claimed),
                  let name = row.volumeName, !row.uid.isEmpty else { return nil }
            return VolumeCleanupRequest.Volume(name: name, uid: row.uid, path: row.path)
        }
    }

    /// The cleanup request over the tab's rows, or nil when no volume is unused.
    public static func cleanupRequest(_ rows: [StorageRow]) -> VolumeCleanupRequest? {
        let volumes = cleanable(rows)
        return volumes.isEmpty ? nil : VolumeCleanupRequest(volumes: volumes)
    }

    // MARK: - the claim delete

    /// The question before a claim's delete: the pods still mounting it, and
    /// what happens to its volume and data.
    public static func confirmation(_ request: ClaimDeleteRequest) -> ActionConfirmation {
        var lines: [String] = []
        switch request.mountedBy {
        case nil:
            lines.append("The pod list has not been read, so whether a pod still mounts this claim is not known.")
        case let pods? where pods.isEmpty:
            lines.append("No listed pod mounts it.")
        case let pods?:
            let those = pods.count == 1 ? "that pod is" : "those pods are"
            lines.append("It is still mounted by \(listed(pods)). Kubernetes keeps the claim, as Terminating, until \(those) gone.")
        }
        if let volume = request.volume {
            switch request.reclaimPolicy {
            case "Retain"?:
                let at = request.path.map { " in \($0)" } ?? ""
                lines.append("Its volume, \(volume), stays behind as Released, and the data stays on the node's disk\(at), "
                    + "because its storage class retains volumes. Deleting the volume later removes only the object; the data directory stays.")
            case let policy?:
                lines.append("Its volume, \(volume), has the reclaim policy \(policy), so Kubernetes deletes the volume too; "
                    + "whether its data on disk goes with it is up to the volume's provisioner.")
            case nil:
                lines.append("Its volume, \(volume), was not listed, so what happens to its data is not known here.")
            }
        } else {
            lines.append("It is not bound to a volume, so it holds no data.")
        }
        return ActionConfirmation(
            title: "Delete claim \(StatusDisplay.clip(request.namespace.value + "/" + request.claim.value))?",
            message: lines.joined(separator: " "),
            verbTitle: "Delete", cancelTitle: "Cancel", destructive: true)
    }

    /// What the UID read just before the delete says: nil when the claim is
    /// still the one confirmed, so the delete runs; otherwise the line shown
    /// instead, and nothing runs.
    public static func verify(_ request: ClaimDeleteRequest, run: ActionRun) -> ActionOutcome? {
        let changed = ActionOutcome.refused("Delete refused: the claim changed since you clicked; nothing was deleted.")
        switch run {
        case .exited(status: 0, let output):
            let read = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return read == request.uid ? nil : changed
        case .exited(let status, let output):
            let raw = String(decoding: output, as: UTF8.self)
            if raw.contains("(NotFound)") { return changed }
            return checkFailed(status: status, output: raw)
        case .noAnswer:
            return .failed("Delete failed: the k3sm CLI did not answer the claim check; nothing was deleted.")
        case .missing, .refused:
            return report(request, run: run)
        }
    }

    /// The line shown after a claim's delete. CLI text passes `StatusDisplay.errorText`.
    public static func report(_ request: ClaimDeleteRequest, run: ActionRun) -> ActionOutcome {
        if case .exited(status: 0, _) = run {
            if let pods = request.mountedBy, !pods.isEmpty {
                return .succeeded("Delete asked: the claim stays Terminating until the pods mounting it are gone.")
            }
            let data = request.reclaimPolicy == "Retain" ? " Its data stays on the node's disk." : ""
            return .succeeded("Delete asked for the claim.\(data)")
        }
        return failure(run, what: "the claim")
    }

    // MARK: - the volume cleanup

    /// The question before the cleanup: how many volumes and which, and that
    /// their data directories stay on disk, with the paths they record.
    public static func confirmation(_ request: VolumeCleanupRequest) -> ActionConfirmation {
        let count = request.volumes.count
        let noun = count == 1 ? "volume" : "volumes"
        let names = request.volumes.map { StatusDisplay.clip($0.name.value) }
        var lines = ["k3sm deletes \(count == 1 ? "this volume object" : "these volume objects"): \(listed(names))."]
        let paths = request.volumes.compactMap(\.path)
        let pronoun = count == 1 ? "Its data directory stays" : "Their data directories stay"
        if paths.isEmpty {
            lines.append("\(pronoun) on disk; \(count == 1 ? "the volume records" : "the volumes record") no path.")
        } else {
            let unrecorded = count - paths.count
            let rest = unrecorded == 0 ? "" : "; \(unrecorded) more \(unrecorded == 1 ? "records" : "record") no path"
            lines.append("\(pronoun) on disk: \(listed(paths))\(rest).")
        }
        lines.append("Removing a directory takes root on its node and is not done here.")
        return ActionConfirmation(
            title: "Delete \(count) released or unclaimed \(noun)?",
            message: lines.joined(separator: " "),
            verbTitle: cleanupTitle, cancelTitle: "Cancel", destructive: true)
    }

    /// What the volume read just before the cleanup says: nil when every
    /// volume is still listed with its UID and still unused, so the cleanup
    /// runs; otherwise the line shown instead, and nothing runs.
    public static func verify(_ request: VolumeCleanupRequest, run: ActionRun) -> ActionOutcome? {
        switch run {
        case .exited(status: 0, let output):
            guard let objects = try? KubeList.objects(output, kinds: ["PersistentVolume"]) else {
                return .failed("Delete failed: the volume list could not be read; nothing was deleted.")
            }
            var byName: [String: [String: Any]] = [:]
            for object in objects { byName[KubeList.name(object)] = object }
            let unchanged = request.volumes.allSatisfy { volume in
                guard let object = byName[volume.name.value],
                      KubeList.string(KubeList.dict(object, "metadata"), "uid") == volume.uid else { return false }
                let ref = KubeList.dict(KubeList.dict(object, "spec"), "claimRef")
                let phase = KubeList.string(KubeList.dict(object, "status"), "phase") ?? ""
                return cleanable(phase: phase, claimed: KubeList.string(ref, "name") != nil)
            }
            return unchanged ? nil : .refused("Delete refused: the volumes changed since you clicked; nothing was deleted.")
        case .exited(let status, let output):
            return checkFailed(status: status, output: String(decoding: output, as: UTF8.self))
        case .noAnswer:
            return .failed("Delete failed: the k3sm CLI did not answer the volume check; nothing was deleted.")
        case .missing, .refused:
            return report(request, run: run)
        }
    }

    /// The line shown after the cleanup. CLI text passes `StatusDisplay.errorText`.
    public static func report(_ request: VolumeCleanupRequest, run: ActionRun) -> ActionOutcome {
        if case .exited(status: 0, _) = run {
            let count = request.volumes.count
            let data = count == 1 ? "its data directory stays" : "their data directories stay"
            return .succeeded("Delete asked for \(count) \(count == 1 ? "volume" : "volumes"); \(data) on disk.")
        }
        return failure(run, what: "the volumes")
    }

    // MARK: - shared wording

    /// Names joined for a sentence: "a", "a and b", "a, b and c", and past
    /// `listLimit`, "a, b, … and 4 more".
    public static func listed(_ names: [String]) -> String {
        let shown = Array(names.prefix(listLimit))
        let more = names.count - shown.count
        if more > 0 { return shown.joined(separator: ", ") + " and \(more) more" }
        guard let last = shown.last else { return "" }
        return shown.count == 1 ? last : shown.dropLast().joined(separator: ", ") + " and " + last
    }

    private static func checkFailed(status: Int32, output: String) -> ActionOutcome {
        let text = StatusDisplay.errorText(output)
        return .failed("Delete failed; nothing was deleted. " + (text.isEmpty ? "k3sm kubectl exited \(status)" : "kubectl said: \(text)"))
    }

    private static func failure(_ run: ActionRun, what: String) -> ActionOutcome {
        switch run {
        case .exited(let status, let output):
            let text = StatusDisplay.errorText(String(decoding: output, as: UTF8.self))
            return .failed(text.isEmpty ? "Delete failed: k3sm kubectl exited \(status)" : "Delete failed. kubectl said: \(text)")
        case .noAnswer:
            return .failed("Delete failed: the k3sm CLI did not answer. Refresh to see whether \(what) went.")
        case .missing:
            return .failed("Delete failed: k3sm is not installed on this Mac.")
        case .refused(let why):
            return .failed("Delete failed: the installed k3sm failed the app's check (\(StatusDisplay.errorText(why))), so it was not run.")
        }
    }
}
