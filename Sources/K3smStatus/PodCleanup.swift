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

/// PodCleanup is the Workloads tab's bulk action: delete every pod that has
/// finished (phase Succeeded or Failed) or was evicted, in one confirmed
/// action, one `kubectl delete pod` per namespace.
public enum PodCleanup {
    /// The pods the cleanup deletes, in list order: phase Succeeded or
    /// Failed, or status reason Evicted, whose names `ResourceName` accepts
    /// and that were listed with a UID. A running, pending or unknown pod is
    /// never selected.
    public static func selection(_ pods: [Pod]) -> [Pod] {
        pods.filter { pod in
            guard pod.namespaceName != nil, pod.resourceName != nil, !pod.uid.isEmpty else { return false }
            return pod.phase == "Succeeded" || pod.phase == "Failed" || pod.reason == "Evicted"
        }
    }

    /// The cleanup request over `pods` as listed now; nil when none is selected.
    public static func request(for pods: [Pod]) -> PodCleanupRequest? {
        var groups: [PodCleanupRequest.Group] = []
        for pod in selection(pods) {
            guard let namespace = pod.namespaceName, let name = pod.resourceName else { continue }
            let target = PodCleanupRequest.Target(pod: name, uid: pod.uid)
            if let i = groups.firstIndex(where: { $0.namespace == namespace }) {
                groups[i].pods.append(target)
            } else {
                groups.append(PodCleanupRequest.Group(namespace: namespace, pods: [target]))
            }
        }
        return groups.isEmpty ? nil : PodCleanupRequest(groups: groups)
    }

    /// The tab's bulk actions over `pods`: the cleanup, when it selects any.
    public static func bulkActions(for pods: [Pod]?) -> [ActionMenuItem] {
        guard let pods, let request = request(for: pods) else { return [] }
        return [ActionMenuItem(request)]
    }

    /// The namespaces as a sentence: "a", "a and b", "a, b and c", and past
    /// four, the first four and how many more.
    public static func namespaceList(_ names: [String]) -> String {
        let shown = names.prefix(4).map(StatusDisplay.clip)
        let more = names.count - shown.count
        if more > 0 { return shown.joined(separator: ", ") + " and \(more) more" }
        switch shown.count {
        case 0: return ""
        case 1: return shown[0]
        default: return shown.dropLast().joined(separator: ", ") + " and " + shown[shown.count - 1]
        }
    }

    static func pods(_ n: Int) -> String { n == 1 ? "1 pod" : "\(n) pods" }
}

/// PodCleanupRequest is the cleanup fixed at the click: each namespace's
/// pods by name and UID as listed then. The pre-check reads every pod's
/// UID, and a selected name that now carries another UID (a pod recreated
/// under the same name since, as a StatefulSet does) refuses the whole
/// cleanup, so it never deletes a pod the user did not see finished.
public struct PodCleanupRequest: Equatable, ConsoleActionRequest {
    public struct Target: Equatable, Sendable {
        public let pod: ResourceName
        public let uid: String
    }

    public struct Group: Equatable, Sendable {
        public let namespace: ResourceName
        public var pods: [Target]
    }

    public let groups: [Group]

    public var id: String { "cleanup:workloads" }
    public var section: ConsoleSection { .workloads }
    public var rowKey: String { ActionMenu.bulkRowKey }
    public var verb: String { "cleanup" }
    public var kind: ActionKind { .delete }

    /// How many pods it deletes.
    public var count: Int { groups.reduce(0) { $0 + $1.pods.count } }

    /// One delete per namespace, in the list's order.
    public var runs: [[String]] {
        groups.map { K3smCLI.deletePodsArguments(namespace: $0.namespace, pods: $0.pods.map(\.pod)) }
    }

    public var arguments: [String] { runs.first ?? [] }

    public var precheckArguments: [String]? { K3smCLI.podUIDsArguments }

    public var confirmation: ActionConfirmation {
        let n = count
        return ActionConfirmation(
            title: "Delete \(PodCleanup.pods(n)) that completed or failed?",
            message: "k3sm deletes \(n == 1 ? "the pod" : "the \(n) pods") in "
                + PodCleanup.namespaceList(groups.map(\.namespace.value))
                + " that completed, failed or were evicted. Their logs and status go with them; running pods are not touched.",
            verbTitle: "Delete completed and failed pods", cancelTitle: "Cancel", destructive: true)
    }

    /// The UID read: nil when no selected name carries another UID now (a
    /// pod already gone is no reason to stop); otherwise the line shown,
    /// and nothing is deleted.
    public func precheck(_ run: ActionRun) -> ActionOutcome? {
        switch run {
        case .exited(status: 0, let output):
            var listed: [String: String] = [:]
            for line in String(decoding: output, as: UTF8.self).split(separator: "\n") {
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                if parts.count == 2 { listed[String(parts[0])] = String(parts[1]) }
            }
            for group in groups {
                for target in group.pods {
                    if let uid = listed[group.namespace.value + "/" + target.pod.value], uid != target.uid {
                        return .refused("Cleanup refused: a pod changed since you clicked; nothing was deleted. Look again and retry.")
                    }
                }
            }
            return nil
        case .exited(let status, let output):
            let text = StatusDisplay.errorText(String(decoding: output, as: UTF8.self))
            return .failed("Cleanup failed; nothing was deleted. " + (text.isEmpty ? "k3sm kubectl exited \(status)" : "kubectl said: \(text)"))
        case .noAnswer:
            return .failed("Cleanup failed: the k3sm CLI did not answer the pod check; nothing was deleted.")
        case .missing, .refused:
            return report(runs: [run])
        }
    }

    public func report(_ run: ActionRun) -> ActionOutcome {
        report(runs: [run])
    }

    /// One line for every namespace's run: how many were deleted, how many
    /// were already gone, and where and why any were not. A non-zero exit
    /// is read pod by pod, by kubectl's own `pod "<name>" deleted` and
    /// `pods "<name>" not found` lines; any other text is quoted through
    /// `errorText`.
    public func report(runs: [ActionRun]) -> ActionOutcome {
        for run in runs {
            switch run {
            case .missing: return .failed("Cleanup failed: k3sm is not installed on this Mac.")
            case .refused(let why):
                return .failed("Cleanup failed: the installed k3sm failed the app's check (\(StatusDisplay.errorText(why))), so it was not run.")
            default: continue
            }
        }
        var deleted = 0, gone = 0
        var failedIn: [String] = []
        var reason = ""
        for (i, group) in groups.enumerated() {
            let run = i < runs.count ? runs[i] : .noAnswer
            switch run {
            case .exited(status: 0, _):
                deleted += group.pods.count
            case .exited(let status, let output):
                let raw = String(decoding: output, as: UTF8.self)
                let lines = raw.split(separator: "\n").map(String.init)
                var failedHere = false
                for target in group.pods {
                    let name = target.pod.value
                    if lines.contains(where: { $0.hasPrefix("pod \"\(name)\" deleted") }) {
                        deleted += 1
                    } else if lines.contains(where: { $0.contains("pods \"\(name)\" not found") }) {
                        gone += 1
                    } else {
                        failedHere = true
                    }
                }
                if failedHere {
                    failedIn.append(group.namespace.value)
                    if reason.isEmpty {
                        let rest = lines.filter { !$0.hasPrefix("pod \"") && !$0.contains("(NotFound)") }.joined(separator: "\n")
                        let text = StatusDisplay.errorText(rest)
                        reason = text.isEmpty ? "k3sm kubectl exited \(status)" : "kubectl said: \(text)"
                    }
                }
            case .noAnswer, .missing, .refused:
                failedIn.append(group.namespace.value)
                if reason.isEmpty { reason = "the k3sm CLI did not answer; refresh to see what was deleted" }
            }
        }
        let goneText = gone == 0 ? "" : " \(PodCleanup.pods(gone)) \(gone == 1 ? "was" : "were") already gone."
        if failedIn.isEmpty {
            return .succeeded("Deleted \(PodCleanup.pods(deleted)) that completed or failed." + goneText)
        }
        return .failed("Deleted \(deleted) of \(PodCleanup.pods(count))." + goneText
            + " Not all deleted in \(PodCleanup.namespaceList(failedIn)): \(reason)")
    }
}
