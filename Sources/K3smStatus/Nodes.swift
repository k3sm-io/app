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

/// ClusterNode is one node of `kubectl get nodes -o json` as the console
/// shows it. Every field but the name is optional: a field that is absent,
/// of the wrong type or an unparseable quantity is unknown, never a failure.
public struct ClusterNode: Equatable, Sendable {
    /// The node name; the decoder keeps only names `ResourceName` accepts.
    public let name: String
    /// The Ready condition: true for "True", false for any other status, nil
    /// when the node carries no Ready condition.
    public let ready: Bool?
    /// The kubelet version as printed (`v1.36.2+k3sm.0.1.7`).
    public let kubeletVersion: String?
    public let internalIP: String?
    /// True when the node carries `node-role.kubernetes.io/control-plane`.
    /// A node cannot set that label on itself, so only an admin wrote it.
    public let controlPlane: Bool
    public let capacityMilliCPU: Int64?
    public let allocatableMilliCPU: Int64?
    public let capacityMemoryBytes: Int64?
    public let allocatableMemoryBytes: Int64?

    public init(
        name: String, ready: Bool?, kubeletVersion: String? = nil, internalIP: String? = nil, controlPlane: Bool = false,
        capacityMilliCPU: Int64? = nil, allocatableMilliCPU: Int64? = nil,
        capacityMemoryBytes: Int64? = nil, allocatableMemoryBytes: Int64? = nil
    ) {
        self.name = name
        self.ready = ready
        self.kubeletVersion = kubeletVersion
        self.internalIP = internalIP
        self.controlPlane = controlPlane
        self.capacityMilliCPU = capacityMilliCPU
        self.allocatableMilliCPU = allocatableMilliCPU
        self.capacityMemoryBytes = capacityMemoryBytes
        self.allocatableMemoryBytes = allocatableMemoryBytes
    }

    /// The k3sm release inside the kubelet version, as `StatusWorker` reads it.
    public var k3smRelease: SemanticVersion? {
        StatusWorker(name: name, role: "", version: kubeletVersion).k3smRelease
    }

    /// The role word: "server" for a control-plane node; else, for this
    /// Mac's own node, the role the status report gives this Mac; else "agent".
    public func role(ownNode: String?, ownRole: String) -> String {
        if controlPlane { return NodeRole.server.rawValue }
        if let ownNode, ownNode == name, !ownRole.isEmpty { return ownRole }
        return NodeRole.agent.rawValue
    }
}

/// Nodes decodes kubectl's node list: the API's `NodeList`, or kubectl's
/// `List` of `Node` items.
public enum Nodes {
    static let controlPlaneLabel = "node-role.kubernetes.io/control-plane"

    /// Decodes the nodes, sorted by name. It throws `NodesDecodeError` when
    /// the bytes are not a node list; a node without a valid name is left out.
    public static func decode(_ data: Data) throws -> [ClusterNode] {
        nodes(from: try items(data))
    }

    /// The node objects of a node list, before any field is read. It throws
    /// `NodesDecodeError` when the bytes are not a node list.
    static func items(_ data: Data) throws -> [[String: Any]] {
        guard let top = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let kind = top["kind"] as? String, let items = top["items"] as? [Any] else {
            throw NodesDecodeError.malformed
        }
        let objects = items.compactMap { $0 as? [String: Any] }
        switch kind {
        case "NodeList": break
        case "List" where objects.allSatisfy({ $0["kind"] == nil || ($0["kind"] as? String) == "Node" }): break
        default: throw NodesDecodeError.notANodeList(StatusDisplay.clip(kind))
        }
        return objects
    }

    /// The nodes of a node list's objects, sorted by name.
    static func nodes(from objects: [[String: Any]]) -> [ClusterNode] {
        objects.compactMap(node(from:)).sorted { $0.name < $1.name }
    }

    static func node(from item: [String: Any]) -> ClusterNode? {
        let metadata = item["metadata"] as? [String: Any] ?? [:]
        guard let raw = metadata["name"] as? String, let name = ResourceName(raw) else { return nil }
        let labels = metadata["labels"] as? [String: Any] ?? [:]
        let status = item["status"] as? [String: Any] ?? [:]
        let conditions = (status["conditions"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        let ready = conditions.first { ($0["type"] as? String) == "Ready" }.map { ($0["status"] as? String) == "True" }
        let info = status["nodeInfo"] as? [String: Any] ?? [:]
        let version = (info["kubeletVersion"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let addresses = (status["addresses"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        let ip = addresses.first { ($0["type"] as? String) == "InternalIP" }?["address"] as? String
        let capacity = status["capacity"] as? [String: Any] ?? [:]
        let allocatable = status["allocatable"] as? [String: Any] ?? [:]
        return ClusterNode(
            name: name.value, ready: ready, kubeletVersion: version, internalIP: ip,
            controlPlane: labels[controlPlaneLabel] != nil,
            capacityMilliCPU: milliCPU(capacity["cpu"]), allocatableMilliCPU: milliCPU(allocatable["cpu"]),
            capacityMemoryBytes: bytes(capacity["memory"]), allocatableMemoryBytes: bytes(allocatable["memory"]))
    }

    /// A CPU quantity as millicores, or nil when it is not a string quantity.
    static func milliCPU(_ value: Any?) -> Int64? {
        guard let text = value as? String, let cores = Quantity.cores(text) else { return nil }
        return Int64(exactly: (cores * 1000).rounded())
    }

    static func bytes(_ value: Any?) -> Int64? {
        guard let text = value as? String else { return nil }
        return Quantity.bytes(text)
    }
}

/// NodesDecodeError says why kubectl's output could not be read as a node list.
public enum NodesDecodeError: Error, Equatable, Sendable {
    case malformed
    case notANodeList(String)
}

/// NodeListRead is one run of the shared node list, read once for both of
/// its readers: the panel's nodes and the Images tab's images.
public struct NodeListRead: Equatable, Sendable {
    public let nodes: [ClusterNode]
    public let images: ImagesReading

    public init(nodes: [ClusterNode], images: ImagesReading) {
        self.nodes = nodes
        self.images = images
    }

    /// Decodes the node list once into the nodes and their images.
    public static func decode(_ data: Data) throws -> NodeListRead {
        let objects = try Nodes.items(data)
        return NodeListRead(nodes: Nodes.nodes(from: objects), images: ImagesList.read(objects))
    }

    /// One node-list run as a tab result: a non-zero exit or a list that is
    /// not a node list is a failure with its reason.
    public static func tabResult(exitCode: Int32, stdout: Data) -> TabResult<NodeListRead> {
        guard exitCode == 0 else { return .failed("k3sm kubectl exited \(exitCode)") }
        do {
            return .value(try decode(stdout))
        } catch NodesDecodeError.notANodeList(let kind) {
            return .failed("kubectl returned a \(kind), not a node list")
        } catch {
            return .failed("the node list could not be read")
        }
    }
}
