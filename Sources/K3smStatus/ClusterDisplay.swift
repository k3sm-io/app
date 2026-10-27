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

    /// The requested figure, the text before " of ": "3.5", "3.2 GB".
    public var amount: String { parts.0 }
    /// The text after it, "of 19", or nil when the text has no " of ".
    public var ofTotal: String? { parts.1.map { "of \($0)" } }
    /// The total alone, "19" or "60 GB", or nil when the text has no " of ".
    public var total: String? { parts.1 }

    private var parts: (String, String?) {
        guard let range = text.range(of: " of ") else { return (text, nil) }
        return (String(text[..<range.lowerBound]), String(text[range.upperBound...]))
    }
}

/// PanelTile is one tile of the console panel's grid: a big figure, the
/// small words under it, and an optional "of 19" beside the figure. Every
/// string is clipped.
public struct PanelTile: Equatable, Sendable {
    public let label: String
    public let value: String
    public let detail: String?

    public init(label: String, value: String, detail: String? = nil) {
        self.label = StatusDisplay.clip(label)
        self.value = StatusDisplay.clip(value)
        self.detail = detail.map(StatusDisplay.clip)
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
    /// The running pods bound to this node, nil when the pod list is unknown.
    public let running: Int?

    public init(
        name: String, role: String, ready: String, isReady: Bool, version: String?, thisMac: Bool,
        cores: ClusterUsage?, memory: ClusterUsage?, running: Int? = nil
    ) {
        self.name = name
        self.role = role
        self.ready = ready
        self.isReady = isReady
        self.version = version
        self.thisMac = thisMac
        self.cores = cores
        self.memory = memory
        self.running = running
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
    /// How many nodes the cluster has, as far as the app can tell
    /// (`ClusterDisplay.nodeCount`; 1 when it cannot).
    public let nodeCount: Int
    /// This Mac's node first, then by name; empty when the node list is unknown.
    public let nodes: [ClusterNodeRow]
    /// Requested of the summed allocatable; nil when any node's is unknown.
    public let cores: ClusterUsage?
    public let memory: ClusterUsage?
    /// "versions differ" or "versions: some unknown" when the node rows
    /// show their own versions; nil when the releases agree or are unknown.
    public let versions: String?

    public init(
        title: String, stats: [ClusterStat], note: String?, nodeCount: Int = 1, nodes: [ClusterNodeRow] = [],
        cores: ClusterUsage? = nil, memory: ClusterUsage? = nil, versions: String? = nil
    ) {
        self.title = title
        self.stats = stats
        self.note = note
        self.nodeCount = nodeCount
        self.nodes = nodes
        self.cores = cores
        self.memory = memory
        self.versions = versions
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

    /// The view's heading is shown only when the switch is hidden: the
    /// selected tab already names the view, so a heading would repeat it.
    public static func showsHeading(nodeCount: Int) -> Bool { !showsSwitch(nodeCount: nodeCount) }

    /// The view shown: the user's choice when the switch is shown, Cluster
    /// before any choice; This Mac whenever there is one node.
    public static func effective(chosen: PanelMode?, nodeCount: Int) -> PanelMode {
        showsSwitch(nodeCount: nodeCount) ? (chosen ?? .cluster) : .thisMac
    }
}

/// PodRequests is what a set of pods requests of a host, in cores and bytes.
public struct PodRequests: Equatable, Sendable {
    public let cores: Double
    public let memoryBytes: Int64

    public init(cores: Double, memoryBytes: Int64) {
        self.cores = cores
        self.memoryBytes = memoryBytes
    }
}

/// ClusterShape is what this Mac is in its cluster.
public enum ClusterShape: Equatable, Sendable {
    /// One Mac: this one runs everything.
    case single
    /// This Mac is the server, with workers; `macs` counts all of them.
    case serverWithWorkers(macs: Int)
    /// This Mac is a worker; the control plane runs on another Mac.
    case worker
    /// Not known yet: no report, or the report has no workers list.
    case unknown
}

/// ClusterDisplay turns the status report, the node list and the pod list
/// into the panel's cluster view and its tiles. The title follows `workers` the way
/// `NodesDisplay` does: absent is unknown, empty is no other node. A server
/// with workers is titled "Cluster" and its stats open with the Mac count.
/// With the node list known the stats end with its `VersionAgreement`, and
/// the node rows show a version only when the releases do not all agree. A
/// nil node or pod list is unknown, and the stats then come from the
/// report's `node` and `workloads` rows as printed. The node count, which
/// decides the panel's two views, is `nodeCount`; a node list short of it
/// adds the `othersUnknown` note. Every string is clipped.
public enum ClusterDisplay {
    public static let singleTitle = "This Mac is the cluster"
    public static let unknownTitle = "This Mac"
    public static let workerTitle = "Joined a cluster"
    public static let clusterTitle = "Cluster"
    public static let othersUnknown = "other nodes unknown"

    public static func summary(of report: StatusReport?, nodes: [ClusterNode]?, pods: [Pod]?) -> ClusterSummary {
        let (title, titleNote, macs) = title(report)
        let nodeCount = nodeCount(report: report, nodes: nodes)
        // A node list short of the report's count does not name every node.
        let note = titleNote ?? (nodes.map { $0.count < nodeCount } == true ? othersUnknown : nil)
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
                        showsVersion: agreement.showsPerNode,
                        running: pods.filter { $0.health == .running && $0.nodeName == node.name }.count)
                }
            }
            stats.append(ClusterStat(label: "vm", value: "\(active.filter { $0.kind == .linuxVM }.count)"))
        } else if let report {
            stats += workloadStats(report)
        }
        var versions: String?
        if let nodes {
            let agreement = VersionAgreement.of(nodes.map(\.k3smRelease))
            if let stat = agreement.stat {
                stats.append(stat)
                if agreement.showsPerNode { versions = stat.text }
            }
        }
        return ClusterSummary(
            title: title, stats: stats, note: note, nodeCount: nodeCount, nodes: rows,
            cores: cores, memory: memory, versions: versions)
    }

    /// How many nodes the panel lays out for: the most that the node list
    /// or the report's `workers` (and this Mac) name, and one when neither
    /// is known. Each is a whole read when it succeeds, so a node list with
    /// fewer nodes than the report names was caught short (a watch replay
    /// not yet whole) rather than showing a cluster that shrank, and the
    /// panel keeps its two views; a node that leaves drops out of both.
    public static func nodeCount(report: StatusReport?, nodes: [ClusterNode]?) -> Int {
        max(nodes?.count ?? 0, report?.workers.map { $0.count + 1 } ?? 0, 1)
    }

    /// The Cluster view's tiles, in order: the Mac count (or the nodes
    /// ready, "1/2", whenever not every node is ready, and always when there
    /// is no Mac count), the running pods, then the cores and the memory
    /// requested with their totals beside them. A tile whose source is
    /// unknown is left out.
    public static func tiles(for summary: ClusterSummary) -> [PanelTile] {
        func stat(_ label: String) -> String? { summary.stats.first { $0.label == label }?.value }
        var tiles: [PanelTile] = []
        let ready = stat("nodes ready")
        let parts = ready?.split(separator: "/").map(String.init) ?? []
        let allReady = parts.count == 2 && parts[0] == parts[1]
        if let macs = stat("Macs"), ready == nil || allReady {
            tiles.append(PanelTile(label: "Macs", value: macs))
        } else if let ready {
            tiles.append(PanelTile(label: "nodes ready", value: ready))
        }
        if let running = stat("running") {
            tiles.append(PanelTile(label: "pods running", value: running))
        }
        if let cores = summary.cores {
            tiles.append(PanelTile(label: "cores requested", value: cores.amount, detail: cores.ofTotal))
        }
        if let memory = summary.memory {
            tiles.append(PanelTile(label: "memory requested", value: memory.amount, detail: memory.ofTotal))
        }
        return tiles
    }

    /// The This Mac view's tiles: the cores its node used of its cores
    /// (`MacUsage.cpuUsed`), the memory its pods use of its unified memory
    /// (`MacUsage.podsMemoryUsed`), the data root's volume used of its size,
    /// and how many pods it runs. A use with no sample behind it is
    /// `noFigure`, never zero; a size of zero or less (unread) leaves its
    /// "of" out, the cores tile keeping its unit.
    public static func macTiles(cores: Int, memoryBytes: Int64, dataRootUsed: Int64, dataRootSize: Int64,
                                pods: Int, coresUsed: Double?, memoryUsed: Int64?) -> [PanelTile] {
        [
            PanelTile(label: "cores used", value: coresUsed.map(MetricsDisplay.cores) ?? noFigure,
                      detail: cores > 0 ? "of \(MacUsage.coresText("\(cores)"))" : "cores"),
            PanelTile(label: "pod memory used", value: memoryUsed.map(MetricsDisplay.bytes) ?? noFigure,
                      detail: memoryBytes > 0 ? "of \(bytes(memoryBytes))" : nil),
            PanelTile(label: "data root", value: bytes(dataRootUsed),
                      detail: dataRootSize > 0 ? "of \(bytes(dataRootSize))" : nil),
            PanelTile(label: pods == 1 ? "pod on this Mac" : "pods on this Mac", value: "\(max(0, pods))"),
        ]
    }

    /// A tile's figure while no usage sample stands behind it.
    public static let noFigure = "\u{2013}"

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

    /// What the pods ask of a host: their core requests and their byte
    /// requests, each summed over the pods that state one. The This Mac view
    /// draws its meters from it. A byte sum past Int64 saturates there, and
    /// the core sum saturates at `WorkloadsDisplay.maxCores`, so a pod that
    /// requests more than any Mac has fills the meter instead of stopping the
    /// app. The API server accepts "1e308" cores on any pod; two of them sum
    /// to infinity. A negative or NaN core value counts as nothing.
    public static func requests(of pods: [Pod]) -> PodRequests {
        let bytes = pods.compactMap(\.memoryRequest)
        var cores = 0.0
        for v in pods.compactMap(\.cpuRequest) where v > 0 {
            cores = min(WorkloadsDisplay.maxCores, cores + min(WorkloadsDisplay.maxCores, v))
        }
        return PodRequests(cores: cores, memoryBytes: Quantity.sum(bytes) ?? .max)
    }

    /// The title, its note, and the Mac count for a server with workers.
    static func title(_ report: StatusReport?) -> (String, String?, Int?) {
        switch shape(of: report) {
        case .unknown: return (unknownTitle, report == nil ? nil : othersUnknown, nil)
        case .worker: return (workerTitle, nil, nil)
        case .single: return (singleTitle, nil, nil)
        case .serverWithWorkers(let macs): return (clusterTitle, nil, macs)
        }
    }

    /// shape is the cluster's shape as this Mac's report shows it: no report
    /// or no workers list is unknown, an agent is a worker, and a server is
    /// alone or has workers. The panel's title and the tour's first stop
    /// both follow it.
    public static func shape(of report: StatusReport?) -> ClusterShape {
        guard let report else { return .unknown }
        if NodeRole.detect(in: report) == .agent { return .worker }
        guard let workers = report.workers else { return .unknown }
        return workers.isEmpty ? .single : .serverWithWorkers(macs: workers.count + 1)
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

    static func row(_ node: ClusterNode, pods: [Pod], ownNode: String?, ownRole: String, showsVersion: Bool, running: Int?) -> ClusterNodeRow {
        let ready: String
        switch node.ready {
        case true?: ready = "Ready"
        case false?: ready = "Not ready"
        case nil: ready = "Ready unknown"
        }
        let version = node.k3smRelease?.description ?? node.kubeletVersion.map(StatusDisplay.clip) ?? NodesDisplay.versionUnknown
        return ClusterNodeRow(
            name: NodeNameMask.shown(node.name), role: StatusDisplay.clip(node.role(ownNode: ownNode, ownRole: ownRole)),
            ready: ready, isReady: node.ready == true, version: showsVersion ? version : nil, thisMac: node.name == ownNode,
            cores: coresUsage(pods, allocatable: [node.allocatableMilliCPU]),
            memory: memoryUsage(pods, allocatable: [node.allocatableMemoryBytes]), running: running)
    }

    /// The pods' summed core requests of the summed allocatable, nil when
    /// any allocatable is unknown or there is none.
    static func coresUsage(_ pods: [Pod], allocatable: [Int64?]) -> ClusterUsage? {
        guard !allocatable.isEmpty, allocatable.allSatisfy({ $0 != nil }),
              let milli = Quantity.sum(allocatable.compactMap { $0 }) else { return nil }
        let total = Double(milli) / 1000
        let used = requests(of: pods).cores
        return ClusterUsage(requested: used, allocatable: total, text: "\(WorkloadsDisplay.cores(used)) of \(WorkloadsDisplay.cores(total))")
    }

    /// The pods' summed byte requests of the summed allocatable, nil when
    /// any allocatable is unknown or there is none. The request sum
    /// saturates at Int64 the way `requests(of:)` does, so one hostile
    /// request shows a capped figure instead of blanking the meter.
    static func memoryUsage(_ pods: [Pod], allocatable: [Int64?]) -> ClusterUsage? {
        guard !allocatable.isEmpty, allocatable.allSatisfy({ $0 != nil }),
              let total = Quantity.sum(allocatable.compactMap { $0 }) else { return nil }
        let used = requests(of: pods).memoryBytes
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
