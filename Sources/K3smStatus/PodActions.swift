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

/// PodAction is a change the console can make to one pod. Each one is a
/// single fixed kubectl argument list, asked for behind a confirmation and
/// reported in one line.
public enum PodAction: String, Sendable, CaseIterable, Identifiable {
    /// Deletes a pod that has an owner, which recreates it.
    case restart

    public var id: Self { self }

    /// The button's title in the inspector.
    public var title: String {
        switch self {
        case .restart: return "Restart"
        }
    }
}

/// PodActionConfirmation is the question asked before an action runs.
public struct PodActionConfirmation: Equatable, Sendable {
    public let title: String
    public let message: String
    /// The title of the button that runs the action.
    public let verbTitle: String
    public let cancelTitle: String
    /// Whether the action removes something, so its button is shown as
    /// destructive.
    public let destructive: Bool
}

/// PodActionRequest is one action on one pod, fixed when the user asks for
/// it: the names come from the pod as it was listed then, so a later poll or
/// a new selection cannot change what the confirmed action runs on.
public struct PodActionRequest: Equatable, Sendable, Identifiable {
    public let action: PodAction
    public let namespace: ResourceName
    public let pod: ResourceName
    /// The pod's selection key, "namespace/name".
    public let podKey: String
    /// The owner as "Kind name", clipped; nil for a pod without one.
    public let owner: String?

    public var id: String { "\(action.rawValue):\(podKey)" }

    /// The CLI arguments the action runs.
    public var arguments: [String] {
        switch action {
        case .restart: return K3smCLI.deletePodArguments(namespace: namespace, pod: pod)
        }
    }

    /// The question asked before it runs.
    public var confirmation: PodActionConfirmation {
        switch action {
        case .restart:
            return PodActionConfirmation(
                title: "Restart \(StatusDisplay.clip(pod.value))?",
                message: "k3sm deletes this pod, and its owner, \(owner ?? "its controller"), recreates it. "
                    + "Its containers stop now; the new pod may have a new name and run on another node.",
                verbTitle: action.title, cancelTitle: "Cancel", destructive: true)
        }
    }
}

/// PodActionRun is how one action's CLI run ended, as the report reads it.
public enum PodActionRun: Equatable, Sendable {
    /// The CLI exited; `output` is its standard output and error together.
    case exited(status: Int32, output: Data)
    /// The CLI could not be started, ran past its deadline or wrote past
    /// its limit: whether the change was made is not known.
    case noAnswer
    /// The CLI is not installed.
    case missing
    /// The installed CLI failed its trust check, so nothing ran.
    case refused(String)
}

/// PodActionReport is the one line the inspector shows after an action.
public enum PodActionReport: Equatable, Sendable {
    case succeeded(String)
    case failed(String)

    public var text: String {
        switch self {
        case .succeeded(let t), .failed(let t): return t
        }
    }

    public var failed: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// PodActions decides which actions a pod offers, builds their requests and
/// reports their runs.
public enum PodActions {
    /// The owner kinds whose controller recreates a deleted pod. A Job may
    /// not (a finished one never does), a Node owns a mirror pod its kubelet
    /// keeps, and any other kind is not known to recreate one.
    public static let recreatingOwnerKinds: Set<String> = ["ReplicaSet", "StatefulSet", "DaemonSet"]

    /// The kind in `Pod.owner`'s "Kind name" display string: the text before
    /// the first space, or nil when there is none. A Kubernetes kind and an
    /// object name carry no space, so the split is exact; app#53's decode of
    /// the controller reference replaces this parse.
    public static func ownerKind(_ owner: String?) -> String? {
        guard let owner, let space = owner.firstIndex(of: " "), space != owner.startIndex else { return nil }
        return String(owner[..<space])
    }

    /// The actions offered for a pod, in button order. Restart only for a pod
    /// whose owner recreates it (`recreatingOwnerKinds`), since nothing brings
    /// back a bare pod; nothing for a pod whose name or namespace
    /// `ResourceName` refuses.
    public static func available(for pod: Pod) -> [PodAction] {
        PodAction.allCases.filter { request($0, for: pod) != nil }
    }

    /// The request for one action on a pod, or nil when the pod does not
    /// offer it.
    public static func request(_ action: PodAction, for pod: Pod) -> PodActionRequest? {
        guard let namespace = pod.namespaceName, let name = pod.resourceName else { return nil }
        let owner = pod.owner.map(StatusDisplay.clip)
        switch action {
        case .restart:
            guard let owner, !owner.isEmpty,
                  let kind = ownerKind(pod.owner), recreatingOwnerKinds.contains(kind) else { return nil }
        }
        return PodActionRequest(action: action, namespace: namespace, pod: name, podKey: pod.key, owner: owner)
    }

    /// The line shown after a run. CLI text passes `StatusDisplay.errorText`.
    public static func report(_ request: PodActionRequest, run: PodActionRun) -> PodActionReport {
        let verb = request.action.title
        switch run {
        case .exited(status: 0, _):
            switch request.action {
            case .restart:
                return .succeeded("\(verb) asked: \(request.owner ?? "its controller") recreates the pod.")
            }
        case .exited(let status, let output):
            let text = StatusDisplay.errorText(String(decoding: output, as: UTF8.self))
            return .failed("\(verb) failed: " + (text.isEmpty ? "k3sm kubectl exited \(status)" : text))
        case .noAnswer:
            return .failed("\(verb) failed: the k3sm CLI did not answer. Refresh to see whether the pod was deleted.")
        case .missing:
            return .failed("\(verb) failed: k3sm is not installed on this Mac.")
        case .refused(let why):
            return .failed("\(verb) failed: the installed k3sm failed the app's check (\(StatusDisplay.errorText(why))), so it was not run.")
        }
    }
}
