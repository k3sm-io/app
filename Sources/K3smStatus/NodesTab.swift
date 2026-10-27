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

/// NodeRow is one row of the Nodes tab: the node's name and role, its
/// readiness with a cordon mark, its k3sm release with its state against
/// the cluster's target (`NodeVersions`) and its live load, each already
/// clipped. Its key is the node name (a `ResourceName`).
public struct NodeRow: Equatable, Sendable {
    public let key: String
    public let name: String
    public let role: String
    /// "Ready", "Not ready" or "Ready unknown", with " · cordoned" when it
    /// takes no new pods.
    public let status: String
    /// Whether the node reports Ready.
    public let ready: Bool
    /// The k3sm release its kubelet runs (else the kubelet version) and its
    /// state in plain words: "0.1.7 · behind", or the state alone.
    public let version: String
    /// The release's state against the cluster's target.
    public let versionState: NodeVersionState
    /// "8% CPU · 20% memory", "no metrics yet", or "" while metrics are hidden.
    public let load: String
}

/// NodesList decides the Nodes tab: one row per node of the shared node
/// list, this Mac's first, then by name; the search over name and role;
/// and this Mac's node and role from the status report, for the role word.
public enum NodesList {
    public static let emptyText = "The cluster lists no nodes."
    public static let readingText = "Reading the node list…"

    /// This Mac's node name and role word, as the panel reads them.
    public static func own(report: StatusReport?) -> (node: String?, role: String) {
        let node = report.flatMap(ClusterDisplay.ownNodeName)
        let role = report.map { NodeRole.detect(in: $0)?.rawValue ?? StatusDisplay.clip($0.role) } ?? ""
        return (node, role)
    }

    /// The rows, this Mac's node first.
    public static func rows(_ nodes: [ClusterNode], report: StatusReport?, metrics: MetricsState) -> [NodeRow] {
        let (ownNode, ownRole) = own(report: report)
        let ordered = nodes.filter { $0.name == ownNode } + nodes.filter { $0.name != ownNode }
        let versions = NodeVersions.decide(nodes, report: report)
        return ordered.map { node in
            NodeRow(key: node.name, name: NodeNameMask.shown(node.name),
                    role: NodesDisplay.roleWord(node.role(ownNode: ownNode, ownRole: ownRole)),
                    status: statusText(node), ready: node.ready == true, version: versions.columnText(node),
                    versionState: versions.state(of: node.name),
                    load: loadText(MetricsDisplay.nodeLoad(named: node.name, nodes: nodes, state: metrics)))
        }
    }

    /// The rows whose name or role holds the query, case-insensitively.
    public static func visible(_ rows: [NodeRow], query: String) -> [NodeRow] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return rows }
        return rows.filter { $0.name.lowercased().contains(q) || $0.role.lowercased().contains(q) }
    }

    /// The node names a read lists, for `ConsoleSelection`: nil before a read.
    public static func keys(_ nodes: [ClusterNode]?) -> Set<String>? {
        nodes.map { Set($0.map(\.name)) }
    }

    /// "Ready", "Not ready" or "Ready unknown", with " · cordoned".
    public static func statusText(_ node: ClusterNode) -> String {
        let ready: String
        switch node.ready {
        case true?: ready = "Ready"
        case false?: ready = "Not ready"
        case nil: ready = "Ready unknown"
        }
        return node.unschedulable ? ready + " · cordoned" : ready
    }

    /// The k3sm release, else the kubelet version as printed, else "".
    static func versionText(_ node: ClusterNode) -> String {
        if let release = node.k3smRelease { return release.description }
        return node.kubeletVersion.map(StatusDisplay.clip) ?? ""
    }

    /// A row's load: each share of allocatable, or the figures when the
    /// allocatable is unknown; "" while metrics are hidden.
    static func loadText(_ load: NodeLoad?) -> String {
        switch load {
        case nil: return ""
        case .noSample?: return MetricsDisplay.noMetricsYet
        case .sampled(let cpu, let memory)?:
            let c = cpu.percent.map { "\($0)% CPU" } ?? "CPU \(cpu.text)"
            let m = memory.percent.map { "\($0)% memory" } ?? "memory \(memory.text)"
            return "\(c) · \(m)"
        }
    }
}

/// NodeLiveLoad is the node inspector's live block: the CPU and memory
/// bars with the CPU sparkline and the sample's age, or the line saying why
/// there are none ("no metrics yet", or why the metrics API is absent).
public enum NodeLiveLoad: Equatable, Sendable {
    case unsampled(String)
    case sampled(cpu: LoadBar, memory: LoadBar, sparkline: [Double], age: String)
}

/// NodeConditionLine is one condition as the inspector shows it: its type,
/// "True since 3 min ago · KubeletNotReady", and whether it reads healthy.
public struct NodeConditionLine: Equatable, Sendable {
    public let type: String
    public let text: String
    public let healthy: Bool
}

/// NodePodLine is one pod bound to the node: "namespace/name" and its usage
/// now ("0.25 cores · 120 MB", or "no metrics yet").
public struct NodePodLine: Equatable, Sendable {
    public let name: String
    public let usage: String
}

/// NodeInspectorBody is the node inspector's content: the header and facts
/// (role, readiness, scheduling, versions, addresses, capacity and
/// allocatable), the live load, the conditions (Ready first, then as the
/// node lists them), the taints, and the pods on the node that have not
/// finished (nil until the pod list has been read).
public struct NodeInspectorBody: Equatable, Sendable {
    public let header: InspectorBody
    public let load: NodeLiveLoad
    public let conditions: [NodeConditionLine]
    public let taints: [String]
    public let pods: [NodePodLine]?
}

extension InspectorDetails {
    /// A node: its facts, live load, conditions, taints and pods. `report`
    /// names this Mac's node and role; `pods` is the pod list, nil before it
    /// is read; `metrics` is the live sample. Nothing is invented: a field
    /// the list did not carry says "not reported".
    public static func node(_ node: ClusterNode, nodes: [ClusterNode], report: StatusReport?, pods: [Pod]?,
                            metrics: MetricsState, now: Date = Date()) -> NodeInspectorBody {
        let (ownNode, ownRole) = NodesList.own(report: report)
        let role = NodesDisplay.roleWord(node.role(ownNode: ownNode, ownRole: ownRole))
        var facts = [InspectorFact("Role", role)]
        facts.append(InspectorFact("Status", NodesList.statusText(node).components(separatedBy: " · ")[0]))
        facts.append(InspectorFact("Scheduling", node.unschedulable ? "cordoned: no new pods" : "takes new pods"))
        facts.append(InspectorFact("Kubelet", node.kubeletVersion.map(StatusDisplay.clip) ?? "not reported", mono: true))
        let versions = NodeVersions.decide(nodes, report: report)
        facts.append(InspectorFact("k3sm", versions.inspectorText(node), help: Help.Nodes.versionFact))
        facts.append(InspectorFact("Latest", versions.latestText, help: Help.Nodes.latestFact))
        // A Hostname address equal to a node's name is that name, so the
        // demo mask covers it; every other address stays as it is.
        let addresses = node.addresses.map { a -> String in
            let shown = NodeNameMask.shownAddress(a.address)
            return a.type.isEmpty ? shown : "\(shown) (\(a.type))"
        }
        facts.append(InspectorFact("Addresses", addresses.isEmpty ? "not reported" : addresses.joined(separator: ", "), mono: true))
        facts.append(InspectorFact("Capacity", resources(milliCPU: node.capacityMilliCPU, bytes: node.capacityMemoryBytes,
                                                         pods: node.capacityPods)))
        facts.append(InspectorFact("Allocatable", resources(milliCPU: node.allocatableMilliCPU, bytes: node.allocatableMemoryBytes,
                                                            pods: node.allocatablePods)))
        let header = InspectorBody(kind: "Node", title: NodeNameMask.shown(node.name), subtitle: ownNode == node.name ? NodesDisplay.thisMac : nil,
                                   facts: facts)
        let ordered = node.conditions.filter { $0.type == "Ready" } + node.conditions.filter { $0.type != "Ready" }
        let conditions = ordered.map { condition -> NodeConditionLine in
            var text = condition.status
            if let at = condition.lastTransition { text += " since " + since(at, now: now) }
            if let reason = condition.reason { text += " · " + reason }
            return NodeConditionLine(type: condition.type, text: text, healthy: condition.healthy)
        }
        let onNode = pods.map { list in
            list.filter { $0.nodeName == node.name && $0.phase != "Succeeded" && $0.phase != "Failed" }
                .sorted { $0.key < $1.key }
                .map { NodePodLine(name: StatusDisplay.clip($0.key), usage: podUsage($0, metrics: metrics)) }
        }
        return NodeInspectorBody(header: header, load: liveLoad(node, nodes: nodes, metrics: metrics, now: now),
                                 conditions: conditions, taints: node.taints.map(\.text), pods: onNode)
    }

    /// The live block: the bars, sparkline and age when the sample carries
    /// the node; "no metrics yet" when it does not or nothing was sampled;
    /// the absent API's line while there is none.
    static func liveLoad(_ node: ClusterNode, nodes: [ClusterNode], metrics: MetricsState, now: Date) -> NodeLiveLoad {
        if let absent = metrics.absent { return .unsampled(absent) }
        guard case .sampled(let cpu, let memory)? = MetricsDisplay.nodeLoad(named: node.name, nodes: nodes, state: metrics),
              let at = metrics.sampledAt else { return .unsampled(MetricsDisplay.noMetricsYet) }
        return .sampled(cpu: cpu, memory: memory, sparkline: MetricsDisplay.sparkline(named: node.name, nodes: nodes, state: metrics),
                        age: "sampled " + MetricsDisplay.age(since: at, now: now))
    }

    /// One pod's usage now, or "no metrics yet".
    static func podUsage(_ pod: Pod, metrics: MetricsState) -> String {
        guard metrics.absent == nil, let usage = metrics.sample?.pods?[pod.key] else { return MetricsDisplay.noMetricsYet }
        return "\(MetricsDisplay.cores(usage.cores)) cores · \(MetricsDisplay.bytes(usage.memoryBytes))"
    }

    /// "20 cores · 64 GB · 110 pods", leaving out what was not reported.
    static func resources(milliCPU: Int64?, bytes: Int64?, pods: Int?) -> String {
        var parts: [String] = []
        if let milliCPU { parts.append("\(WorkloadsDisplay.cores(Double(milliCPU) / 1000)) cores") }
        let memory = WorkloadsDisplay.bytes(bytes)
        if !memory.isEmpty { parts.append(memory) }
        if let pods { parts.append("\(pods) pods") }
        return parts.isEmpty ? "not reported" : parts.joined(separator: " · ")
    }

    /// How long ago a condition changed: "just now", "3 min ago", "2 h ago", "5 d ago".
    static func since(_ time: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(time)
        guard seconds >= 86_400 else { return MetricsDisplay.age(since: time, now: now) }
        return "\(Int(seconds / 86_400)) d ago"
    }
}
