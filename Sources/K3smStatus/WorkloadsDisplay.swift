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

/// WorkloadsReading classifies one run of the workloads list the way `Reading`
/// classifies a status probe: what the window may conclude from the exit and
/// the bytes, so a CLI failure is never shown as an empty cluster.
public enum WorkloadsReading: Equatable, Sendable {
    /// The list decoded; it may be empty, which is a cluster with no pods.
    case listed(Workloads)
    /// The CLI exited non-zero, or its output was not a pod list. The text
    /// carries the list's decoded kind, so it is shown through
    /// `StatusDisplay.errorText`, which also runs on the kind here.
    case cliError(String)
    /// The CLI is not installed at its absolute path.
    case binaryMissing

    /// Classifies a run from its exit status and standard output.
    public static func classify(exitCode: Int32, stdout: Data) -> WorkloadsReading {
        guard exitCode == 0 else {
            return .cliError("k3sm kubectl exited \(exitCode)")
        }
        do {
            return .listed(try Workloads.decode(stdout))
        } catch WorkloadsDecodeError.notAPodList(let kind) {
            return .cliError("kubectl returned a \(StatusDisplay.errorText(kind)), not a pod list")
        } catch {
            return .cliError("the pod list could not be read")
        }
    }
}

/// SelectionChange is what a poll does to the selected pod.
public enum SelectionChange: Equatable, Sendable {
    /// The selected pod is still listed.
    case keep
    /// Select the pod with this key and load its detail.
    case select(String)
    /// Nothing is selected, and the detail is emptied.
    case clear
}

extension Pod {
    /// The selection key: a pod is unique by namespace and name.
    public var key: String { "\(namespace)/\(name)" }
}

/// WorkloadsDisplay turns a pod into the strings the list shows: how it runs,
/// its requests, its age. Every string from the API is clipped like status text.
public enum WorkloadsDisplay {
    /// "Process" or "Linux VM", or the RuntimeClass name verbatim and clipped.
    public static func runsAs(_ kind: WorkloadKind) -> String {
        switch kind {
        case .nativeProcess: return "Process"
        case .linuxVM: return "Linux VM"
        case .other(let name): return StatusDisplay.clip(name)
        }
    }

    /// The most cores a figure shows; a larger or infinite value is shown
    /// as this figure with a "+", and the This Mac sum saturates here.
    public static let maxCores: Double = 1_000_000

    /// Cores as the list shows them: "0.25", "2", "1000000+" at or past
    /// `maxCores`, or "" when nothing (or nothing countable: a negative or
    /// NaN value) was requested. A request is API data: "9223372036854775807"
    /// is 2^63 as a Double, which `Int(_:)` traps on, so no value outside
    /// `maxCores` reaches the conversion.
    public static func cores(_ value: Double?) -> String {
        guard let v = value, v >= 0 else { return "" }
        if v >= maxCores { return "\(Int(maxCores))+" }
        if v == v.rounded() { return String(Int(v)) }
        return String(format: v < 1 ? "%.2f" : "%.1f", v)
    }

    /// Bytes as the list shows them: "256 MB", "1.5 GB", or "" when nothing was requested.
    public static func bytes(_ value: Int64?) -> String {
        guard let b = value, b > 0 else { return "" }
        let gb = Double(b) / 1_073_741_824
        if gb >= 1 { return String(format: gb < 10 ? "%.1f GB" : "%.0f GB", gb) }
        let mb = Double(b) / 1_048_576
        if mb >= 1 { return String(format: "%.0f MB", mb) }
        return String(format: "%.0f KB", Double(b) / 1024)
    }

    /// The pod's age as the list shows it: "12s", "3 min", "5 h", "2 d".
    public static func age(_ created: Date?, now: Date = Date()) -> String {
        guard let created else { return "" }
        let seconds = max(0, now.timeIntervalSince(created))
        switch seconds {
        case ..<60: return "\(Int(seconds))s"
        case ..<3600: return "\(Int(seconds / 60)) min"
        case ..<172_800: return "\(Int(seconds / 3600)) h"
        default: return "\(Int(seconds / 86_400)) d"
        }
    }

    /// The pods the search leaves visible: all of them for an empty query,
    /// otherwise those whose name, image or node, each as the list shows it
    /// (`StatusDisplay.clip`, and the node also by its `nodeLabel`), contains
    /// it, case-insensitively. Matching the shown text means a pod never
    /// matches on a part of its name the list hides, and a query never spans
    /// two fields.
    public static func visible(_ pods: [Pod], query: String, ownNode: String? = nil) -> [Pod] {
        guard !query.isEmpty else { return pods }
        return pods.filter { pod in
            var fields = [pod.name, pod.image]
            if let node = pod.nodeName {
                fields.append(node)
                fields.append(nodeLabel(pod, ownNode: ownNode).text)
            }
            return fields.contains { StatusDisplay.clip($0).localizedCaseInsensitiveContains(query) }
        }
    }

    /// Which Mac a row says its pod runs on: no node yet, this Mac (the node
    /// the status report names as this Mac's), or another node by name,
    /// masked by `mask` when the demo mask is on (`NodeNameMask`).
    public static func nodeLabel(_ pod: Pod, ownNode: String?, mask: [String: String]? = NodeNameMask.current) -> PodNodeLabel {
        guard let node = pod.nodeName else { return .unscheduled }
        if let ownNode, node == ownNode { return .thisMac }
        return .node(NodeNameMask.shown(node, mask: mask))
    }

    /// This Mac's node name from the status report, as the panel reads it;
    /// nil when the report or the name is unknown.
    public static func ownNode(in report: StatusReport?) -> String? {
        report.flatMap(ClusterDisplay.ownNodeName)
    }

    /// What a poll does to the selection. With nothing selected it selects
    /// the first pod of the list; a selected pod still listed stays; a pod
    /// gone from the list, or a list that did not read, clears it.
    public static func selection(after selected: String?, in pods: [Pod]?) -> SelectionChange {
        if selected == nil, let first = pods?.first { return .select(first.key) }
        if let selected, pods?.contains(where: { $0.key == selected }) == true { return .keep }
        return .clear
    }

    /// The list's group header: the namespace and its pod count.
    public static func groupTitle(namespace: String, count: Int) -> String {
        "\(StatusDisplay.clip(namespace)) · \(count) \(count == 1 ? "pod" : "pods")"
    }
}

/// PodNodeLabel is the node column of a workloads row.
public enum PodNodeLabel: Equatable, Sendable {
    /// Not bound to a node yet (a pending pod): a dim dash.
    case unscheduled
    /// Bound to this Mac's node: tagged "this Mac", as the panel tags it.
    case thisMac
    /// Bound to another node, by its clipped name.
    case node(String)

    /// The column's text.
    public var text: String {
        switch self {
        case .unscheduled: return "-"
        case .thisMac: return "this Mac"
        case .node(let name): return name
        }
    }
}
