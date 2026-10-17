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

/// RolloutKind is a controller kind Rollout Restart runs on: the two Pause
/// scales and the DaemonSet, which has no replica count but rolls its pods
/// the same way.
public enum RolloutKind: String, Equatable, Sendable, CaseIterable {
    case deployment = "Deployment"
    case statefulSet = "StatefulSet"
    case daemonSet = "DaemonSet"

    /// The kubectl resource name, as `<resource>/<name>` takes it.
    public var resource: String {
        switch self {
        case .deployment: return "deployment"
        case .statefulSet: return "statefulset"
        case .daemonSet: return "daemonset"
        }
    }

    init?(_ kind: ControllerKind) {
        switch kind {
        case .deployment: self = .deployment
        case .statefulSet: self = .statefulSet
        case .replicaSet: return nil
        }
    }
}

/// RolloutTarget is the controller a pod's Rollout Restart runs on: its
/// kind, names (only as `ResourceName`) and UID, as listed when it was asked for.
public struct RolloutTarget: Equatable, Sendable {
    public let kind: RolloutKind
    public let namespace: ResourceName
    public let name: ResourceName
    public let uid: String

    /// "namespace/Kind/name", the key `WorkloadController.key` gives a
    /// Deployment or StatefulSet, so the report shows beside Pause's.
    public var key: String { "\(namespace.value)/\(kind.rawValue)/\(name.value)" }

    /// "Deployment web", clipped.
    public var title: String { StatusDisplay.clip("\(kind.rawValue) \(name.value)") }
}

/// ScaleOffer is what the inspector shows for Scale on a pod's controller:
/// the stepper, at the controller's current count, or the line saying why
/// it is not offered now.
public enum ScaleOffer: Equatable, Sendable {
    case scalable(WorkloadController, current: Int)
    case refused(String)
}

/// WorkloadScaleRequest is one Scale of a Deployment or StatefulSet, fixed
/// when the user clicks: its names, UID and the count it had then (`from`),
/// which the pre-check requires to be unchanged, and the count asked for (`to`).
public struct WorkloadScaleRequest: Equatable, ConsoleActionRequest {
    public let controller: ControllerKind
    public let namespace: ResourceName
    public let name: ResourceName
    public let uid: String
    public let from: Int
    public let to: Int

    public var id: String { "controller-scale:\(rowKey)" }
    public var section: ConsoleSection { .workloads }
    public var rowKey: String { "\(namespace.value)/\(controller.rawValue)/\(name.value)" }
    public var verb: String { "controller-scale" }
    public var kind: ActionKind { .change }

    public var arguments: [String] {
        K3smCLI.scaleArguments(kind: controller, namespace: namespace, name: name, replicas: to)
    }

    /// The controller's UID, replicas and Pause record, read just before.
    public var precheckArguments: [String]? {
        K3smCLI.controllerStateArguments(kind: controller, namespace: namespace, name: name)
    }

    private var target: String { StatusDisplay.clip("\(controller.rawValue) \(name.value)") }

    public var confirmation: ActionConfirmation {
        let change = "k3sm scales \(target) from \(WorkloadPause.replicas(from)) to \(WorkloadPause.replicas(to)). "
        let after = to < from
            ? "\(WorkloadPause.pods(from - to).capitalizedFirst) stop\(from - to == 1 ? "s" : "") now."
            : "The new pods start, maybe on other nodes."
        return ActionConfirmation(
            title: "Scale \(StatusDisplay.clip(namespace.value + "/" + name.value))?",
            message: change + after,
            verbTitle: "Scale", cancelTitle: "Cancel", destructive: to < from)
    }

    /// Nil when the controller is still the one confirmed, at the count
    /// confirmed and not paused since; otherwise the line shown instead.
    public func precheck(_ run: ActionRun) -> ActionOutcome? {
        WorkloadControls.verify(verb: "Scale", target: target, run: run) { output in
            let fields = output.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            return fields.first == uid && fields.count > 1 && fields[1] == String(from) && (fields.count < 3 || fields[2].isEmpty)
        }
    }

    public func report(_ run: ActionRun) -> ActionOutcome {
        WorkloadControls.report(verb: "Scale", target: target, run: run,
                                done: "Scale asked: \(target) goes from \(WorkloadPause.replicas(from)) to \(WorkloadPause.replicas(to)).")
    }
}

/// RolloutRestartRequest is one Rollout Restart of a pod's controller,
/// fixed when the user asks for it.
public struct RolloutRestartRequest: Equatable, ConsoleActionRequest {
    public let target: RolloutTarget

    public var id: String { "rollout-restart:\(rowKey)" }
    public var section: ConsoleSection { .workloads }
    public var rowKey: String { target.key }
    public var verb: String { "rollout-restart" }
    /// It replaces the pods and keeps the controller: a change.
    public var kind: ActionKind { .change }

    public var arguments: [String] {
        K3smCLI.rolloutRestartArguments(kind: target.kind, namespace: target.namespace, name: target.name)
    }

    /// The controller's UID, read just before.
    public var precheckArguments: [String]? {
        K3smCLI.rolloutUIDArguments(kind: target.kind, namespace: target.namespace, name: target.name)
    }

    public var confirmation: ActionConfirmation {
        ActionConfirmation(
            title: "Rollout restart \(StatusDisplay.clip(target.namespace.value + "/" + target.name.value))?",
            message: "k3sm asks \(target.title) to replace its pods by its update strategy, one at a time by default. "
                + "Each new pod may start on another node; an OnDelete strategy waits until each pod is deleted.",
            verbTitle: "Rollout Restart", cancelTitle: "Cancel", destructive: false)
    }

    public func precheck(_ run: ActionRun) -> ActionOutcome? {
        WorkloadControls.verify(verb: "Rollout Restart", target: target.title, run: run) {
            $0.trimmingCharacters(in: .whitespacesAndNewlines) == target.uid
        }
    }

    public func report(_ run: ActionRun) -> ActionOutcome {
        WorkloadControls.report(verb: "Rollout Restart", target: target.title, run: run,
                                done: "Rollout restart asked: \(target.title) replaces its pods by its update strategy.")
    }
}

/// WorkloadControls decides the inspector's Scale and Rollout Restart on a
/// pod's resolved controller (`WorkloadPause.resolve`): which it offers,
/// the requests, the pre-checks and the reports.
public enum WorkloadControls {
    /// The counts the Scale stepper offers.
    public static let scaleRange = 1...50

    /// The line in place of Scale while the controller carries Pause's record.
    public static let pausedNote = "paused: Resume it first, then scale"
    /// The line in place of Scale while a Pause is half done.
    public static let staleNote = "a Pause is half done: Pause again, then Resume, before scaling"

    /// The controller a pod's Rollout Restart runs on: its resolved
    /// Deployment or StatefulSet, or the DaemonSet its controller reference
    /// names; nil for any other pod, a name `ResourceName` refuses or a
    /// controller with no UID.
    public static func rolloutTarget(for pod: Pod, in controllers: WorkloadControllers?) -> RolloutTarget? {
        switch WorkloadPause.resolve(pod, in: controllers) {
        case .controller(let c):
            guard let kind = RolloutKind(c.kind), !c.uid.isEmpty,
                  let namespace = ResourceName(c.namespace), let name = ResourceName(c.name) else { return nil }
            return RolloutTarget(kind: kind, namespace: namespace, name: name, uid: c.uid)
        case .daemonSet:
            guard let ref = pod.controllerRef, !ref.uid.isEmpty,
                  let namespace = pod.namespaceName, let name = ResourceName(ref.name) else { return nil }
            return RolloutTarget(kind: .daemonSet, namespace: namespace, name: name, uid: ref.uid)
        case .none:
            return nil
        }
    }

    /// The pod's Rollout Restart, or nil when it offers none.
    public static func rolloutRestart(for pod: Pod, in controllers: WorkloadControllers?) -> RolloutRestartRequest? {
        rolloutTarget(for: pod, in: controllers).map(RolloutRestartRequest.init(target:))
    }

    /// The row key the pod's controller actions report on: the resolved
    /// controller's, or its DaemonSet's; nil when it has neither.
    public static func controllerKey(for pod: Pod, in controllers: WorkloadControllers?) -> String? {
        WorkloadPause.controllerKey(for: pod, in: controllers) ?? rolloutTarget(for: pod, in: controllers)?.key
    }

    /// What the inspector shows for Scale: the stepper on a Deployment or
    /// StatefulSet that asks for a count and carries no Pause record, the
    /// line saying to Resume first while it does, nothing for a DaemonSet,
    /// any other pod, a name `ResourceName` refuses or a controller with no UID.
    public static func scaleOffer(for pod: Pod, in controllers: WorkloadControllers?) -> ScaleOffer? {
        guard case .controller(let c) = WorkloadPause.resolve(pod, in: controllers), c.kind.scalable, !c.uid.isEmpty,
              ResourceName(c.namespace) != nil, ResourceName(c.name) != nil, let current = c.replicas else { return nil }
        if c.stale { return .refused(staleNote) }
        if c.paused { return .refused(pausedNote) }
        return .scalable(c, current: current)
    }

    /// The stepper's starting value for a controller at `current`, inside `scaleRange`.
    public static func stepperValue(current: Int) -> Int {
        min(max(current, scaleRange.lowerBound), scaleRange.upperBound)
    }

    /// Scale of `controller` to `replicas`, or nil when it is not offered:
    /// a count outside `scaleRange` or the one it has, a ReplicaSet, a
    /// paused controller, a name `ResourceName` refuses or no UID.
    public static func scaleRequest(for controller: WorkloadController, to replicas: Int) -> WorkloadScaleRequest? {
        guard controller.kind.scalable, !controller.paused, !controller.uid.isEmpty, scaleRange.contains(replicas),
              let current = controller.replicas, current != replicas,
              let namespace = ResourceName(controller.namespace), let name = ResourceName(controller.name) else { return nil }
        return WorkloadScaleRequest(controller: controller.kind, namespace: namespace, name: name, uid: controller.uid,
                                    from: current, to: replicas)
    }

    /// The pre-check's verdict for both actions: nil when `matches` accepts
    /// the read's output, otherwise the line shown, and nothing runs.
    static func verify(verb: String, target: String, run: ActionRun, matches: (String) -> Bool) -> ActionOutcome? {
        let changed = ActionOutcome.refused("\(verb) refused: \(target) changed since you clicked; nothing was changed.")
        switch run {
        case .exited(status: 0, let output):
            return matches(String(decoding: output, as: UTF8.self)) ? nil : changed
        case .exited(let status, let output):
            let raw = String(decoding: output, as: UTF8.self)
            if raw.contains("(NotFound)") { return changed }
            let text = StatusDisplay.errorText(raw)
            return .failed("\(verb) failed; nothing was changed. " + (text.isEmpty ? "k3sm kubectl exited \(status)" : "kubectl said: \(text)"))
        case .noAnswer:
            return .failed("\(verb) failed: the k3sm CLI did not answer the controller check; nothing was changed.")
        case .missing, .refused:
            return report(verb: verb, target: target, run: run, done: "")
        }
    }

    /// The line after the run. CLI text passes `StatusDisplay.errorText`.
    static func report(verb: String, target: String, run: ActionRun, done: String) -> ActionOutcome {
        switch run {
        case .exited(status: 0, _):
            return .succeeded(done)
        case .exited(let status, let output):
            let text = StatusDisplay.errorText(String(decoding: output, as: UTF8.self))
            return .failed(text.isEmpty ? "\(verb) failed: k3sm kubectl exited \(status)." : "\(verb) failed. kubectl said: \(text)")
        case .noAnswer:
            return .failed("\(verb) failed: the k3sm CLI did not answer. Refresh to see whether \(target) changed.")
        case .missing:
            return .failed("\(verb) failed: k3sm is not installed on this Mac.")
        case .refused(let why):
            return .failed("\(verb) failed: the installed k3sm failed the app's check (\(StatusDisplay.errorText(why))), so it was not run.")
        }
    }
}

extension String {
    /// The string with its first character uppercased: "2 pods" stays, "a pod" becomes "A pod".
    fileprivate var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
