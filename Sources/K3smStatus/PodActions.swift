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
    /// Deletes any pod; its owner, when it has one that does, recreates it.
    case delete

    public var id: Self { self }

    /// The button's title in the inspector.
    public var title: String {
        switch self {
        case .restart: return "Restart"
        case .delete: return "Delete"
        }
    }
}

/// PodActionRequest is one action on one pod, fixed when the user asks for
/// it: the names and UID come from the pod as it was listed then, so a later
/// poll or a new selection cannot change what the confirmed action runs on,
/// and a pod recreated under the same name since is refused by its UID.
public struct PodActionRequest: Equatable, ConsoleActionRequest {
    public let action: PodAction
    public let namespace: ResourceName
    public let pod: ResourceName
    /// The pod's selection key, "namespace/name".
    public let podKey: String
    /// The pod's UID as listed when the action was asked for.
    public let uid: String
    /// The owner as "Kind name", clipped; nil for a pod without one.
    public let owner: String?

    public var id: String { "\(action.rawValue):\(podKey)" }
    public var section: ConsoleSection { .workloads }
    public var rowKey: String { podKey }
    public var verb: String { action.rawValue }
    /// Restart deletes the pod only for its owner to recreate it: a change,
    /// so it is not on the Delete key. Delete is the key's action.
    public var kind: ActionKind {
        switch action {
        case .restart: return .change
        case .delete: return .delete
        }
    }

    /// The read run just before the action, whose output must be `uid`.
    public var verifyArguments: [String] {
        K3smCLI.podUIDArguments(namespace: namespace, pod: pod)
    }

    /// Every pod action reads the pod's UID first (`PodActions.verify`).
    public var precheckArguments: [String]? { verifyArguments }

    public func precheck(_ run: ActionRun) -> ActionOutcome? {
        PodActions.verify(self, run: run)
    }

    public func report(_ run: ActionRun) -> ActionOutcome {
        PodActions.report(self, run: run)
    }

    /// The CLI arguments the action runs.
    public var arguments: [String] {
        switch action {
        case .restart, .delete: return K3smCLI.deletePodArguments(namespace: namespace, pod: pod)
        }
    }

    /// Whether the pod's owner is a controller that recreates a deleted pod.
    public var recreated: Bool {
        PodActions.ownerKind(owner).map(PodActions.recreatingOwnerKinds.contains) ?? false
    }

    /// The question asked before it runs.
    public var confirmation: ActionConfirmation {
        switch action {
        case .restart:
            return ActionConfirmation(
                title: "Restart \(StatusDisplay.clip(namespace.value + "/" + pod.value))?",
                message: "k3sm deletes this pod, and its owner, \(owner ?? "its controller"), recreates it. "
                    + "Its containers stop now; the new pod may have a new name and run on another node.",
                verbTitle: action.title, cancelTitle: "Cancel", destructive: true)
        case .delete:
            return ActionConfirmation(
                title: "Delete \(StatusDisplay.clip(namespace.value + "/" + pod.value))?",
                message: "k3sm deletes this pod, and its containers stop now. " + PodActions.afterDelete(owner: owner),
                verbTitle: action.title, cancelTitle: "Cancel", destructive: true)
        }
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
    /// object name carry no space, so the split is exact. The pod list's
    /// decode of the controller reference builds that display string
    /// (`Workloads.swift`), and this parse reads the kind back from it.
    public static func ownerKind(_ owner: String?) -> String? {
        guard let owner, let space = owner.firstIndex(of: " "), space != owner.startIndex else { return nil }
        return String(owner[..<space])
    }

    /// The actions offered for a pod, in button order. Restart only for a pod
    /// whose owner recreates it (`recreatingOwnerKinds`), since nothing brings
    /// back a bare pod; Delete for any pod; nothing for a pod whose name or
    /// namespace `ResourceName` refuses, or that was listed without a UID.
    public static func available(for pod: Pod) -> [PodAction] {
        PodAction.allCases.filter { request($0, for: pod) != nil }
    }

    /// The pod's actions as its context menu, the inspector and the Delete
    /// key show them: one list, built here once, with its local actions.
    /// With the controller read, Pause or Resume of the pod's resolved
    /// controller (`WorkloadPause.requests`) follows Restart, then Rollout
    /// Restart of that controller, or of the pod's DaemonSet
    /// (`WorkloadControls.rolloutRestart`).
    public static func menu(for pod: Pod, controllers: WorkloadControllers? = nil) -> ActionMenu {
        var requests: [any ConsoleActionRequest] = []
        if let restart = request(.restart, for: pod) { requests.append(restart) }
        requests += WorkloadPause.requests(for: pod, in: controllers) as [any ConsoleActionRequest]
        if let rollout = WorkloadControls.rolloutRestart(for: pod, in: controllers) { requests.append(rollout) }
        if let delete = request(.delete, for: pod) { requests.append(delete) }
        return ActionMenu(requests, local: localActions(for: pod))
    }

    /// The local actions a pod offers: Copy Name and Copy Namespace/Name for
    /// any pod whose names `ResourceName` accepts, and Open Shell in
    /// Terminal for a pod in phase Running whose first container's name it
    /// accepts too (the container kubectl itself picks when none is named).
    /// A pod that is not Running has no process to exec into. Summarize
    /// Logs (`summarizeItems`) comes before Open Shell.
    public static func localActions(for pod: Pod) -> [LocalMenuItem] {
        guard let namespace = pod.namespaceName, let name = pod.resourceName else { return [] }
        var items = [
            LocalMenuItem(id: "copy-name", title: "Copy Name", action: .copy(name.value)),
            LocalMenuItem(id: "copy-namespace-name", title: "Copy Namespace/Name", action: .copy(namespace.value + "/" + name.value)),
        ]
        items += summarizeItems(for: pod)
        if pod.phase == "Running", let first = pod.containers.first, let container = ResourceName(first) {
            items.append(LocalMenuItem(id: "open-shell", title: "Open Shell in Terminal",
                                       action: .openShell(PodShell(namespace: namespace, pod: name, container: container))))
        }
        return items
    }

    /// The pod phases whose containers have run, so have a log to read.
    public static let loggedPhases: Set<String> = ["Running", "Succeeded", "Failed"]

    /// Summarize Logs, one item per container whose name `ResourceName`
    /// accepts, for a pod with a UID in a phase whose containers have run
    /// (`loggedPhases`). A pod of one container offers "Summarize Logs";
    /// of several, "Summarize Logs: <container>" each. A container that has
    /// restarted has its previous instance read too.
    public static func summarizeItems(for pod: Pod) -> [LocalMenuItem] {
        guard loggedPhases.contains(pod.phase), !pod.uid.isEmpty,
              let namespace = pod.namespaceName, let name = pod.resourceName else { return [] }
        let containers = pod.containers.compactMap(ResourceName.init)
        return containers.map { container in
            let target = LogSummaryTarget(namespace: namespace, pod: name, container: container, podKey: pod.key, uid: pod.uid,
                                          restarted: (pod.containerRestarts[container.value] ?? 0) > 0)
            let title = pod.containers.count == 1 ? "Summarize Logs" : "Summarize Logs: \(container.value)"
            return LocalMenuItem(id: "summarize-logs:\(container.value)", title: title, action: .summarizeLogs(target))
        }
    }

    /// What follows a delete, by the pod's owner: a controller that
    /// recreates its pods (`recreatingOwnerKinds`) brings it back; an owner
    /// of another kind may not; nothing brings back a pod without one.
    /// `owner` is `Pod.owner` already clipped.
    public static func afterDelete(owner: String?) -> String {
        guard let owner, !owner.isEmpty else {
            return "Nothing recreates it; this pod is gone for good."
        }
        if let kind = ownerKind(owner), recreatingOwnerKinds.contains(kind) {
            return "Its owner, \(owner), recreates it, maybe under a new name and on another node."
        }
        return "Its owner, \(owner), may not recreate it."
    }

    /// The request for one action on a pod, or nil when the pod does not
    /// offer it.
    public static func request(_ action: PodAction, for pod: Pod) -> PodActionRequest? {
        guard let namespace = pod.namespaceName, let name = pod.resourceName, !pod.uid.isEmpty else { return nil }
        let owner = pod.owner.map(StatusDisplay.clip)
        switch action {
        case .restart:
            guard let owner, !owner.isEmpty,
                  let kind = ownerKind(pod.owner), recreatingOwnerKinds.contains(kind) else { return nil }
        case .delete:
            break
        }
        return PodActionRequest(action: action, namespace: namespace, pod: name, podKey: pod.key, uid: pod.uid, owner: owner)
    }

    /// What the UID read just before the action says: nil when the pod is
    /// still the one confirmed, so the action runs; otherwise the line shown
    /// instead, and nothing runs. A pod that is gone or carries another UID
    /// changed since the click.
    public static func verify(_ request: PodActionRequest, run: ActionRun) -> ActionOutcome? {
        let verb = request.action.title
        let changed = ActionOutcome.refused("\(verb) refused: the pod changed since you clicked; nothing was deleted.")
        switch run {
        case .exited(status: 0, let output):
            let read = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return read == request.uid ? nil : changed
        case .exited(let status, let output):
            let raw = String(decoding: output, as: UTF8.self)
            if raw.contains("(NotFound)") { return changed }
            let text = StatusDisplay.errorText(raw)
            return .failed("\(verb) failed; nothing was deleted. " + (text.isEmpty ? "k3sm kubectl exited \(status)" : "kubectl said: \(text)"))
        case .noAnswer:
            return .failed("\(verb) failed: the k3sm CLI did not answer the pod check; nothing was deleted.")
        case .missing, .refused:
            return report(request, run: run)
        }
    }

    /// The line shown after a run. CLI text passes `StatusDisplay.errorText`.
    public static func report(_ request: PodActionRequest, run: ActionRun) -> ActionOutcome {
        let verb = request.action.title
        switch run {
        case .exited(status: 0, _):
            switch request.action {
            case .restart:
                return .succeeded("\(verb) asked: \(request.owner ?? "its controller") recreates the pod.")
            case .delete:
                return .succeeded(request.recreated
                    ? "\(verb) asked: \(request.owner ?? "its controller") recreates the pod."
                    : "\(verb) asked: nothing recreates this pod.")
            }
        case .exited(let status, let output):
            let text = StatusDisplay.errorText(String(decoding: output, as: UTF8.self))
            return .failed(text.isEmpty ? "\(verb) failed: k3sm kubectl exited \(status)" : "\(verb) failed. kubectl said: \(text)")
        case .noAnswer:
            return .failed("\(verb) failed: the k3sm CLI did not answer. Refresh to see whether the pod was deleted.")
        case .missing:
            return .failed("\(verb) failed: k3sm is not installed on this Mac.")
        case .refused(let why):
            return .failed("\(verb) failed: the installed k3sm failed the app's check (\(StatusDisplay.errorText(why))), so it was not run.")
        }
    }
}
