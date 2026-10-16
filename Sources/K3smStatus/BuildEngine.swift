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

/// BuildEngineState is what the build engine is doing, read from its pod:
/// no pod, a pod that is not serving yet, a pod whose engine container is
/// ready, or a pod that failed. Each reason is the kubelet's or the API's
/// word, clipped.
public enum BuildEngineState: Equatable, Sendable {
    case absent
    case pending(String)
    case ready
    case failed(String)

    /// The word the card shows beside its dot.
    public var word: String {
        switch self {
        case .absent: return "Not running"
        case .pending: return "Starting"
        case .ready: return "Ready"
        case .failed: return "Failed"
        }
    }

    /// The severity word the card colours its dot by, as `PodHealth`.
    public var severity: String {
        switch self {
        case .absent: return "off"
        case .pending: return "warn"
        case .ready: return "ok"
        case .failed: return "bad"
        }
    }

    /// The line under the word: the reason, or how to start an absent engine.
    public var detail: String {
        switch self {
        case .absent: return "Start it with k3sm builder up."
        case .pending(let reason): return reason.isEmpty ? "The engine pod is starting." : reason
        case .ready: return "Builds run here."
        case .failed(let reason): return reason.isEmpty ? "The engine pod failed." : reason
        }
    }
}

/// BuildCache is the engine's build-cache claim as the card shows it.
public struct BuildCache: Equatable, Sendable {
    public let name: String
    public let phase: String
    public let capacityBytes: Int64?
}

/// BuildEngine is the Builds tab's card, decided from
/// `K3smCLI.buildEngineArguments`: the pods and claims in the engine's
/// namespace. Only the engine's own objects count, bound by its identity
/// (`isEngine`); any other pod or claim in the namespace is ignored, so a
/// stranger pod never makes the engine look ready. The engine is ready only
/// when its pod runs and its `buildkitd` container reports ready.
public struct BuildEngine: Equatable, Sendable {
    /// The pod, service and claim name the CLI gives the engine by default.
    public static let defaultName = "k3sm-builder"
    /// The engine's container in that pod.
    public static let containerName = "buildkitd"
    /// The labels the CLI puts on every engine object (k3sm's builder spec):
    /// the app name, and the k3sm ownership mark. An object carrying both,
    /// under another name, is still the engine.
    public static let nameLabel = "app.kubernetes.io/name"
    public static let managedLabel = "k3sm.io/managed"
    /// The container waiting reasons that mean the engine will not start by itself.
    static let failingReasons: Set<String> = [
        "CrashLoopBackOff", "ErrImagePull", "ImagePullBackOff", "InvalidImageName",
        "CreateContainerConfigError", "CreateContainerError", "RunContainerError",
    ]

    public let state: BuildEngineState
    /// The engine pod's name and node, clipped; nil without a pod or before it is scheduled.
    public let podName: String?
    public let nodeName: String?
    public let cache: BuildCache?

    /// Decodes kubectl's `List` of pods and claims. It throws
    /// `BuildEngineDecodeError` when the bytes are not a list of those kinds.
    public static func decode(_ data: Data) throws -> BuildEngine {
        guard let top = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let kind = top["kind"] as? String, let items = top["items"] as? [Any] else {
            throw BuildEngineDecodeError.malformed
        }
        let objects = items.compactMap { $0 as? [String: Any] }
        let known: Set<String> = ["Pod", "PersistentVolumeClaim"]
        guard kind == "List", objects.allSatisfy({ known.contains($0["kind"] as? String ?? "") }) else {
            throw BuildEngineDecodeError.notAList(StatusDisplay.clip(kind))
        }
        let pods = objects.filter { $0["kind"] as? String == "Pod" }.sorted { name($0) < name($1) }
        let claims = objects.filter { $0["kind"] as? String == "PersistentVolumeClaim" }.sorted { name($0) < name($1) }
        let pod = pods.first { name($0) == defaultName } ?? pods.first(where: isEngine)
        let claim = claims.first { name($0) == defaultName } ?? claims.first(where: isEngine)
        let spec = pod?["spec"] as? [String: Any] ?? [:]
        return BuildEngine(
            state: pod.map(state(of:)) ?? .absent,
            podName: pod.map { StatusDisplay.clip(name($0)) },
            nodeName: (spec["nodeName"] as? String).flatMap(ResourceName.init)?.value,
            cache: claim.map(cache(of:)))
    }

    /// One engine-list run as a tab result.
    public static func tabResult(exitCode: Int32, stdout: Data) -> TabResult<BuildEngine> {
        guard exitCode == 0 else { return .failed("k3sm kubectl exited \(exitCode)") }
        do {
            return .value(try decode(stdout))
        } catch BuildEngineDecodeError.notAList(let kind) {
            return .failed("kubectl returned a \(kind), not the build engine's pods")
        } catch {
            return .failed("the build engine could not be read")
        }
    }

    /// Whether an object is the engine's: named by the builder's name, or
    /// carrying its name label with k3sm's ownership mark.
    static func isEngine(_ object: [String: Any]) -> Bool {
        if name(object) == defaultName { return true }
        let labels = (object["metadata"] as? [String: Any])?["labels"] as? [String: Any] ?? [:]
        return labels[nameLabel] as? String == defaultName && labels[managedLabel] as? String == "true"
    }

    /// The engine pod's state: ready iff it runs and its `buildkitd`
    /// container is ready; no other container's readiness counts.
    static func state(of pod: [String: Any]) -> BuildEngineState {
        let metadata = pod["metadata"] as? [String: Any] ?? [:]
        let status = pod["status"] as? [String: Any] ?? [:]
        let phase = status["phase"] as? String ?? ""
        let reason = status["reason"] as? String
        let containers = (status["containerStatuses"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        let engine = containers.first { $0["name"] as? String == containerName }
        let state = engine?["state"] as? [String: Any] ?? [:]
        let waiting = (state["waiting"] as? [String: Any])?["reason"] as? String
        let terminated = (state["terminated"] as? [String: Any])?["reason"] as? String
        if metadata["deletionTimestamp"] != nil { return .pending("Stopping") }
        switch phase {
        case "Failed":
            return .failed(StatusDisplay.clip(reason ?? terminated ?? ""))
        case "Succeeded":
            return .failed(StatusDisplay.clip(terminated ?? "Exited"))
        default:
            break
        }
        if phase == "Running", engine?["ready"] as? Bool == true { return .ready }
        if let waiting, failingReasons.contains(waiting) { return .failed(StatusDisplay.clip(waiting)) }
        let conditions = (status["conditions"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        let unscheduled = conditions.first { $0["type"] as? String == "PodScheduled" && $0["status"] as? String == "False" }
        let why = waiting ?? reason ?? unscheduled?["reason"] as? String ?? (phase == "Running" ? "" : phase)
        return .pending(StatusDisplay.clip(why))
    }

    static func cache(of claim: [String: Any]) -> BuildCache {
        let status = claim["status"] as? [String: Any] ?? [:]
        let capacity = status["capacity"] as? [String: Any] ?? [:]
        return BuildCache(
            name: StatusDisplay.clip(name(claim)),
            phase: StatusDisplay.clip(status["phase"] as? String ?? ""),
            capacityBytes: (capacity["storage"] as? String).flatMap(Quantity.bytes))
    }

    private static func name(_ object: [String: Any]) -> String {
        (object["metadata"] as? [String: Any])?["name"] as? String ?? ""
    }
}

/// BuildEngineDecodeError says why kubectl's output could not be read as
/// the engine's pods and claims.
public enum BuildEngineDecodeError: Error, Equatable, Sendable {
    case malformed
    case notAList(String)
}
