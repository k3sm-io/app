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

/// ClusterStat is one short stat of the console panel's header: a value and
/// the words after it ("3/3" "nodes ready", "6" "running"), both clipped.
public struct ClusterStat: Equatable, Sendable {
    public let label: String
    public let value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }

    /// The stat as one phrase, value first: "3/3 nodes ready".
    public var text: String { "\(value) \(label)" }
}

/// ClusterUsage is what pods request of a node or of the cluster against
/// its allocatable: the two numbers for a meter and the text beside it.
public struct ClusterUsage: Equatable, Sendable {
    public let requested: Double
    public let allocatable: Double
    /// "3.5 of 19" or "3.2 GB of 60 GB".
    public let text: String

    public init(requested: Double, allocatable: Double, text: String) {
        self.requested = requested
        self.allocatable = allocatable
        self.text = text
    }
}

/// ClusterNodeRow is one node of the cluster view, every string clipped.
public struct ClusterNodeRow: Equatable, Sendable {
    public let name: String
    public let role: String
    /// "Ready", "Not ready" or "Ready unknown".
    public let ready: String
    public let isReady: Bool
    /// Nil when every node runs the same release, which the stats then name.
    public let version: String?
    /// True for the node the status report names as this Mac's.
    public let thisMac: Bool
    /// Cores and memory requested by the pods bound to this node, nil when
    /// the node's allocatable is unknown.
    public let cores: ClusterUsage?
    public let memory: ClusterUsage?

    public init(
        name: String, role: String, ready: String, isReady: Bool, version: String?, thisMac: Bool,
        cores: ClusterUsage?, memory: ClusterUsage?
    ) {
        self.name = name
        self.role = role
        self.ready = ready
        self.isReady = isReady
        self.version = version
        self.thisMac = thisMac
        self.cores = cores
        self.memory = memory
    }
}

/// ClusterSummary is the cluster view of the console panel: what this Mac is
/// part of, the cluster stats, one row per node and the cluster meters.
public struct ClusterSummary: Equatable, Sendable {
    public let title: String
    /// In display order; a stat whose source is unknown is left out.
    public let stats: [ClusterStat]
    /// Why the title is vague, or nil.
    public let note: String?
    /// How many nodes the cluster has, as far as the app can tell (1 when
    /// it cannot).
    public let nodeCount: Int
    /// This Mac's node first, then by name; empty when the node list is unknown.
    public let nodes: [ClusterNodeRow]
    /// Requested of the summed allocatable; nil when any node's is unknown.
    public let cores: ClusterUsage?
    public let memory: ClusterUsage?
    /// Running pods per node, "3 on mac-a · 1 on mac-b", nil without both lists.
    public let podsByNode: String?

    public init(
        title: String, stats: [ClusterStat], note: String?, nodeCount: Int = 1, nodes: [ClusterNodeRow] = [],
        cores: ClusterUsage? = nil, memory: ClusterUsage? = nil, podsByNode: String? = nil
    ) {
        self.title = title
        self.stats = stats
        self.note = note
        self.nodeCount = nodeCount
        self.nodes = nodes
        self.cores = cores
        self.memory = memory
        self.podsByNode = podsByNode
    }

    /// The stats joined with " · ", or nil when there are none.
    public var line: String? {
        stats.isEmpty ? nil : stats.map(\.text).joined(separator: " · ")
    }
}

/// PanelMode is which view the console panel shows: the cluster, or this Mac.
public enum PanelMode: String, CaseIterable, Sendable {
    case cluster
    case thisMac

    /// The switch's segment title.
    public var title: String {
        switch self {
        case .cluster: return "Cluster"
        case .thisMac: return "This Mac"
        }
    }

    /// The switch is shown only when there is more than one node.
    public static func showsSwitch(nodeCount: Int) -> Bool { nodeCount > 1 }

    /// The view shown: the user's choice when the switch is shown, Cluster
    /// before any choice; This Mac whenever there is one node.
    public static func effective(chosen: PanelMode?, nodeCount: Int) -> PanelMode {
        showsSwitch(nodeCount: nodeCount) ? (chosen ?? .cluster) : .thisMac
    }
}

/// ClusterDisplay turns the status report, the node list and the pod list
/// into the panel's cluster view. The title follows `workers` the way
/// `NodesDisplay` does: absent is unknown, empty is no other node. A server
/// with workers is titled "Cluster" and its stats open with the Mac count.
/// With the node list known the stats end with its `VersionAgreement`, and
/// the node rows show a version only when the releases do not all agree. A
/// nil node or pod list is unknown, and the stats then come from the
/// report's `node` and `workloads` rows as printed. Every string is clipped.
public enum ClusterDisplay {
    public static let singleTitle = "This Mac is the cluster"
    public static let unknownTitle = "This Mac"
    public static let workerTitle = "Joined a cluster"
    public static let clusterTitle = "Cluster"
    public static let othersUnknown = "other nodes unknown"

    public static func summary(of report: StatusReport?, nodes: [ClusterNode]?, pods: [Pod]?) -> ClusterSummary {
        let (title, note, macs) = title(report)
        let nodeCount = nodes?.count ?? report?.workers.map { $0.count + 1 } ?? 1
        let ownNode = report.flatMap(ownNodeName)
        let ownRole = report.map { NodeRole.detect(in: $0)?.rawValue ?? StatusDisplay.clip($0.role) } ?? ""
        let active = (pods ?? []).filter { $0.phase != "Succeeded" && $0.phase != "Failed" }

        var stats: [ClusterStat] = []
        if let macs {
            stats.append(ClusterStat(label: "Macs", value: "\(macs)"))
        }
        if let nodes {
            stats.append(ClusterStat(label: "nodes ready", value: "\(nodes.filter { $0.ready == true }.count)/\(nodes.count)"))
        } else if let report {
            stats += nodeStats(report)
        }
        var cores: ClusterUsage?
        var memory: ClusterUsage?
        var rows: [ClusterNodeRow] = []
        var podsByNode: String?
        if let pods {
            stats.append(ClusterStat(label: "running", value: "\(pods.filter { $0.health == .running }.count)"))
            if let nodes {
                let order = ordered(nodes, ownNode: ownNode)
                let bound = active.filter { $0.nodeName != nil }
                cores = coresUsage(bound, allocatable: nodes.map(\.allocatableMilliCPU))
                memory = memoryUsage(bound, allocatable: nodes.map(\.allocatableMemoryBytes))
                if let cores { stats.append(ClusterStat(label: "cores requested", value: cores.text)) }
                if let memory { stats.append(ClusterStat(label: "memory requested", value: memory.text)) }
                let agreement = VersionAgreement.of(order.map(\.k3smRelease))
                rows = order.map { node in
                    row(node, pods: active.filter { $0.nodeName == node.name }, ownNode: ownNode, ownRole: ownRole,
                        showsVersion: agreement.showsPerNode)
                }
                podsByNode = order.map { node in
                    "\(pods.filter { $0.health == .running && $0.nodeName == node.name }.count) on \(StatusDisplay.clip(node.name))"
                }.joined(separator: " · ")
            }
            stats.append(ClusterStat(label: "vm", value: "\(active.filter { $0.kind == .linuxVM }.count)"))
        } else if let report {
            stats += workloadStats(report)
        }
        if let nodes, let stat = VersionAgreement.of(nodes.map(\.k3smRelease)).stat {
            stats.append(stat)
        }
        return ClusterSummary(
            title: title, stats: stats, note: note, nodeCount: nodeCount, nodes: rows,
            cores: cores, memory: memory, podsByNode: podsByNode)
    }

    /// The pods the This Mac view counts: not finished, and bound to this
    /// Mac's node (the report's own node from the `node` row). In a cluster
    /// of one node a pod with no node name counts too, and so does every pod
    /// when the report does not name the node; in a larger cluster neither does.
    public static func thisMacPods(_ pods: [Pod], report: StatusReport?, nodeCount: Int) -> [Pod] {
        let own = report.flatMap(ownNodeName)
        let single = nodeCount <= 1
        return pods.filter { pod in
            guard pod.phase != "Succeeded", pod.phase != "Failed" else { return false }
            guard let node = pod.nodeName else { return single }
            guard let own else { return single }
            return node == own
        }
    }

    /// The title, its note, and the Mac count for a server with workers.
    static func title(_ report: StatusReport?) -> (String, String?, Int?) {
        guard let report else { return (unknownTitle, nil, nil) }
        if NodeRole.detect(in: report) == .agent { return (workerTitle, nil, nil) }
        guard let workers = report.workers else { return (unknownTitle, othersUnknown, nil) }
        return workers.isEmpty ? (singleTitle, nil, nil) : (clusterTitle, nil, workers.count + 1)
    }

    /// This Mac's node name: the first word after "a/b nodes ready · " in
    /// the `node` row's detail, when it is a valid node name.
    static func ownNodeName(_ report: StatusReport) -> String? {
        guard !nodeStats(report).isEmpty, let detail = report.row(named: "node")?.detail else { return nil }
        let parts = detail.components(separatedBy: " · ")
        guard parts.count > 1, let word = parts[1].split(separator: " ").first else { return nil }
        return ResourceName(String(word))?.value
    }

    static func ordered(_ nodes: [ClusterNode], ownNode: String?) -> [ClusterNode] {
        nodes.sorted { a, b in
            if (a.name == ownNode) != (b.name == ownNode) { return a.name == ownNode }
            return a.name < b.name
        }
    }

    static func row(_ node: ClusterNode, pods: [Pod], ownNode: String?, ownRole: String, showsVersion: Bool) -> ClusterNodeRow {
        let ready: String
        switch node.ready {
        case true?: ready = "Ready"
        case false?: ready = "Not ready"
        case nil: ready = "Ready unknown"
        }
        let version = node.k3smRelease?.description ?? node.kubeletVersion.map(StatusDisplay.clip) ?? NodesDisplay.versionUnknown
        return ClusterNodeRow(
            name: StatusDisplay.clip(node.name), role: StatusDisplay.clip(node.role(ownNode: ownNode, ownRole: ownRole)),
            ready: ready, isReady: node.ready == true, version: showsVersion ? version : nil, thisMac: node.name == ownNode,
            cores: coresUsage(pods, allocatable: [node.allocatableMilliCPU]),
            memory: memoryUsage(pods, allocatable: [node.allocatableMemoryBytes]))
    }

    /// The pods' summed core requests of the summed allocatable, nil when
    /// any allocatable is unknown or there is none.
    static func coresUsage(_ pods: [Pod], allocatable: [Int64?]) -> ClusterUsage? {
        guard !allocatable.isEmpty, allocatable.allSatisfy({ $0 != nil }),
              let milli = Quantity.sum(allocatable.compactMap { $0 }) else { return nil }
        let total = Double(milli) / 1000
        let used = pods.compactMap(\.cpuRequest).reduce(0, +)
        return ClusterUsage(requested: used, allocatable: total, text: "\(WorkloadsDisplay.cores(used)) of \(WorkloadsDisplay.cores(total))")
    }

    static func memoryUsage(_ pods: [Pod], allocatable: [Int64?]) -> ClusterUsage? {
        guard !allocatable.isEmpty, allocatable.allSatisfy({ $0 != nil }),
              let total = Quantity.sum(allocatable.compactMap { $0 }),
              let used = Quantity.sum(pods.compactMap(\.memoryRequest)) else { return nil }
        return ClusterUsage(requested: Double(used), allocatable: Double(total), text: "\(bytes(used)) of \(bytes(total))")
    }

    static func bytes(_ value: Int64) -> String {
        value > 0 ? WorkloadsDisplay.bytes(value) : "0 GB"
    }

    /// "a/b nodes ready" from the start of the `node` row's detail.
    static func nodeStats(_ report: StatusReport) -> [ClusterStat] {
        guard let row = report.row(named: "node") else { return [] }
        let head = (row.detail.components(separatedBy: " · ").first ?? "").trimmingCharacters(in: .whitespaces)
        let suffix = " nodes ready"
        guard head.hasSuffix(suffix) else { return [] }
        let ratio = head.dropLast(suffix.count).split(separator: "/", omittingEmptySubsequences: false)
        guard ratio.count == 2, ratio.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCIIDigit) }) else { return [] }
        return [ClusterStat(label: "nodes ready", value: StatusDisplay.clip(ratio.joined(separator: "/")))]
    }

    /// One stat per "<count> <words>" part of the `workloads` row's detail,
    /// in the row's order; any other part is left out.
    static func workloadStats(_ report: StatusReport) -> [ClusterStat] {
        guard let row = report.row(named: "workloads") else { return [] }
        return row.detail.components(separatedBy: " · ").compactMap { part in
            let words = part.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
            guard words.count == 2, words[0].allSatisfy(\.isASCIIDigit) else { return nil }
            return ClusterStat(label: StatusDisplay.clip(String(words[1])), value: StatusDisplay.clip(String(words[0])))
        }
    }
}
