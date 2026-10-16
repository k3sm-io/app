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

/// ResourceName is a Kubernetes object name as the API server accepts it (RFC 1123
/// subdomain): lowercase letters, digits, '-' and '.', starting and ending with a
/// letter or digit, at most 253 characters. Namespaces are the narrower RFC 1123
/// label (no '.', at most 63 characters); accepting the wider form for them too is
/// still safe, since it is a superset of every name the server serves. Every name the app puts on a kubectl
/// command line goes through this, so a name can never carry an option or a path.
public struct ResourceName: Equatable, Sendable, CustomStringConvertible {
    public let value: String

    public init?(_ value: String) {
        guard !value.isEmpty, value.count <= 253 else { return nil }
        let scalars = value.unicodeScalars
        guard let first = scalars.first, let last = scalars.last,
              Self.isAlphanumeric(first), Self.isAlphanumeric(last) else { return nil }
        guard scalars.allSatisfy({ Self.isAlphanumeric($0) || $0 == "-" || $0 == "." }) else { return nil }
        self.value = value
    }

    private static func isAlphanumeric(_ s: Unicode.Scalar) -> Bool {
        (s >= "a" && s <= "z") || (s >= "0" && s <= "9")
    }

    public var description: String { value }
}

/// WorkloadKind is how a pod runs on this Mac, read from its RuntimeClass.
public enum WorkloadKind: Equatable, Sendable {
    /// No RuntimeClass: a native macOS process under the Seatbelt sandbox.
    case nativeProcess
    /// The `vm` RuntimeClass: a Linux container in a lightweight virtual machine.
    case linuxVM
    /// A RuntimeClass this build does not know.
    case other(String)

    init(runtimeClassName: String?) {
        switch runtimeClassName {
        case nil, "": self = .nativeProcess
        case "vm": self = .linuxVM
        case let name?: self = .other(name)
        }
    }
}

/// PodHealth is the one-line reading of a pod's status: what the list shows beside
/// its name, and how severe it is.
public enum PodHealth: Equatable, Sendable {
    /// Every container ready.
    case running
    /// The pod finished and will not run again.
    case completed
    /// The pod is scheduled but a container is not ready; the text is the kubelet's reason when it gives one.
    case waiting(String)
    /// The pod failed; the text is the reason when there is one.
    case failed(String)

    /// The severity word the design colours by: ok, warn, bad or off.
    public var severity: String {
        switch self {
        case .running: return "ok"
        case .completed: return "off"
        case .waiting: return "warn"
        case .failed: return "bad"
        }
    }

    /// The text shown beside the pod.
    public var text: String {
        switch self {
        case .running: return "Running"
        case .completed: return "Completed"
        case .waiting(let reason): return reason.isEmpty ? "Waiting" : reason
        case .failed(let reason): return reason.isEmpty ? "Failed" : reason
        }
    }
}

/// Quantity parses the Kubernetes resource quantities this screen needs: cores
/// (plain or milli) and bytes (binary and decimal suffixes). Anything else is nil.
public enum Quantity {
    /// A CPU quantity as cores: "500m" is 0.5, "2" is 2, and metrics-server's
    /// "250000u" and "1425378643n" are 0.25 and 1.425378643.
    public static func cores(_ text: String) -> Double? {
        let scales: [(String, Double)] = [("n", 1e9), ("u", 1e6), ("m", 1e3)]
        var v: Double?
        if let (suffix, scale) = scales.first(where: { text.hasSuffix($0.0) }) {
            v = Double(text.dropLast(suffix.count)).map { $0 / scale }
        } else {
            v = Double(text)
        }
        guard let v, v.isFinite, v >= 0 else { return nil }
        return v
    }

    /// A memory quantity as bytes: "256Mi", "1Gi", "500M", "1024".
    public static func bytes(_ text: String) -> Int64? {
        let suffixes: [(String, Double)] = [
            ("Ki", 1024), ("Mi", 1024 * 1024), ("Gi", 1024 * 1024 * 1024), ("Ti", 1024 * 1024 * 1024 * 1024),
            ("k", 1e3), ("M", 1e6), ("G", 1e9), ("T", 1e12),
        ]
        for (suffix, scale) in suffixes where text.hasSuffix(suffix) {
            guard let v = Double(text.dropLast(suffix.count)) else { return nil }
            return integral(v * scale)
        }
        guard let v = Double(text) else { return nil }
        return integral(v)
    }

    /// The value as whole bytes, or nil when it is negative, not finite, or
    /// outside Int64. The API server accepts requests such as "1e19" or
    /// "10000000Ti" on any pod, so a plain Int64(_:) conversion would trap here.
    private static func integral(_ v: Double) -> Int64? {
        guard v.isFinite, v >= 0 else { return nil }
        return Int64(exactly: v.rounded(.towardZero))
    }

    /// The sum of the values, or nil when it overflows Int64.
    static func sum(_ values: [Int64]) -> Int64? {
        var total: Int64 = 0
        for v in values {
            let (next, overflow) = total.addingReportingOverflow(v)
            if overflow { return nil }
            total = next
        }
        return total
    }
}

/// Pod is one pod as the workloads screen shows it. Only the fields the screen
/// reads are kept; everything else in the API object is ignored.
public struct Pod: Equatable, Sendable {
    public let name: String
    public let namespace: String
    public let uid: String
    public let image: String
    public let kind: WorkloadKind
    public let phase: String
    public let health: PodHealth
    public let ready: Bool
    public let restarts: Int
    public let ports: [Int]
    /// The owning controller as "Kind name", or nil for a bare pod. Restart is
    /// offered only when an owner will recreate the pod.
    public let owner: String?
    public let created: Date?
    /// Requested cores and bytes, summed over containers; nil when no container
    /// requests them, and the byte total is nil when it does not fit in Int64.
    public let cpuRequest: Double?
    public let memoryRequest: Int64?
    /// The node the pod is bound to (`spec.nodeName`), nil until it is
    /// scheduled or when the API served a name `ResourceName` refuses.
    public let nodeName: String?

    /// The name the kubectl detail calls take, or nil when the API served a name
    /// the app refuses to put on a command line.
    public var resourceName: ResourceName? { ResourceName(name) }
    public var namespaceName: ResourceName? { ResourceName(namespace) }
}

/// Workloads is the decoded output of `kubectl get pods -A -o json`: the pods,
/// sorted by namespace then name. kubectl prints the API's `PodList` for one
/// namespace and its own `List` of `Pod` items across all of them; both decode.
public struct Workloads: Equatable, Sendable {
    public let pods: [Pod]

    public init(pods: [Pod]) {
        self.pods = pods.sorted { ($0.namespace, $0.name) < ($1.namespace, $1.name) }
    }

    /// The namespaces present, in the order the list shows them.
    public var namespaces: [String] {
        var seen: [String] = []
        for p in pods where !seen.contains(p.namespace) { seen.append(p.namespace) }
        return seen
    }

    /// The pods of one namespace, in list order.
    public func pods(in namespace: String) -> [Pod] {
        pods.filter { $0.namespace == namespace }
    }

    /// Decodes a PodList from kubectl's standard output. It throws
    /// `WorkloadsDecodeError` when the bytes are not a pod list this build can read.
    public static func decode(_ data: Data) throws -> Workloads {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // The kind is checked before the items are read, so a list of another
        // kind is refused by name rather than failing on a missing pod field.
        let head: ListKindWire
        do {
            head = try decoder.decode(ListKindWire.self, from: data)
        } catch {
            throw WorkloadsDecodeError.malformed
        }
        switch head.kind {
        case "PodList": break
        case "List" where head.items.allSatisfy({ $0.kind == nil || $0.kind == "Pod" }): break
        default: throw WorkloadsDecodeError.notAPodList(head.kind)
        }
        let list: PodListWire
        do {
            list = try decoder.decode(PodListWire.self, from: data)
        } catch {
            throw WorkloadsDecodeError.malformed
        }
        return Workloads(pods: list.items.map(Pod.init(wire:)))
    }
}

/// WorkloadsDecodeError says why kubectl's output could not be read as a pod list.
public enum WorkloadsDecodeError: Error, Equatable, Sendable {
    /// The output is not JSON, or lacks a required field.
    case malformed
    /// The output is a Kubernetes object of another kind, or a list of other kinds.
    case notAPodList(String)
}

// MARK: - the wire shape, private to the decoder

struct ListKindWire: Decodable {
    struct Item: Decodable { let kind: String? }
    let kind: String
    let items: [Item]
}

struct PodListWire: Decodable {
    let kind: String
    let items: [PodWire]
}

struct PodWire: Decodable {
    let kind: String?
    struct Metadata: Decodable {
        struct Owner: Decodable { let kind: String; let name: String }
        let name: String
        let namespace: String?
        let uid: String?
        let creationTimestamp: Date?
        let ownerReferences: [Owner]?
    }
    struct Spec: Decodable {
        struct Container: Decodable {
            struct Port: Decodable { let containerPort: Int }
            struct Resources: Decodable { let requests: [String: String]? }
            let image: String?
            let ports: [Port]?
            let resources: Resources?
        }
        let runtimeClassName: String?
        let nodeName: String?
        let containers: [Container]
    }
    struct Status: Decodable {
        struct ContainerStatus: Decodable {
            struct State: Decodable {
                struct Reason: Decodable { let reason: String? }
                let waiting: Reason?
                let terminated: Reason?
            }
            let ready: Bool
            let restartCount: Int
            let state: State?
        }
        let phase: String?
        let reason: String?
        let containerStatuses: [ContainerStatus]?
    }
    let metadata: Metadata
    let spec: Spec
    let status: Status?

    private enum CodingKeys: String, CodingKey { case kind, metadata, spec, status }
}

extension Pod {
    init(wire: PodWire) {
        name = wire.metadata.name
        namespace = wire.metadata.namespace ?? "default"
        uid = wire.metadata.uid ?? ""
        image = wire.spec.containers.first?.image ?? ""
        kind = WorkloadKind(runtimeClassName: wire.spec.runtimeClassName)
        phase = wire.status?.phase ?? ""
        ports = wire.spec.containers.flatMap { ($0.ports ?? []).map(\.containerPort) }
        if let o = wire.metadata.ownerReferences?.first { owner = "\(o.kind) \(o.name)" } else { owner = nil }
        created = wire.metadata.creationTimestamp
        let cpu = wire.spec.containers.compactMap { $0.resources?.requests?["cpu"] }.compactMap(Quantity.cores)
        cpuRequest = cpu.isEmpty ? nil : cpu.reduce(0, +)
        let mem = wire.spec.containers.compactMap { $0.resources?.requests?["memory"] }.compactMap(Quantity.bytes)
        memoryRequest = mem.isEmpty ? nil : Quantity.sum(mem)
        nodeName = wire.spec.nodeName.flatMap(ResourceName.init)?.value
        let statuses = wire.status?.containerStatuses ?? []
        ready = !statuses.isEmpty && statuses.allSatisfy(\.ready)
        restarts = statuses.reduce(0) { total, status in
            let (next, overflow) = total.addingReportingOverflow(status.restartCount)
            return overflow ? Int.max : next
        }
        let waitingReason = statuses.compactMap { $0.state?.waiting?.reason }.first ?? ""
        let terminatedReason = statuses.compactMap { $0.state?.terminated?.reason }.first ?? ""
        switch phase {
        case "Running" where ready: health = .running
        case "Succeeded": health = .completed
        case "Failed": health = .failed(wire.status?.reason ?? terminatedReason)
        default: health = .waiting(waitingReason.isEmpty ? (wire.status?.reason ?? "") : waitingReason)
        }
    }
}
