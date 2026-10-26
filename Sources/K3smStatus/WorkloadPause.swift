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

/// OwnerRef is one owner reference of an object, the fields Pause reads.
public struct OwnerRef: Equatable, Sendable {
    public let apiVersion: String
    public let kind: String
    public let name: String
    /// "" when the API served none.
    public let uid: String

    public init(apiVersion: String, kind: String, name: String, uid: String) {
        self.apiVersion = apiVersion
        self.kind = kind
        self.name = name
        self.uid = uid
    }

    /// Whether the reference names an `apps/v1` object of `kind`.
    func isApps(_ kind: String) -> Bool {
        apiVersion == "apps/v1" && self.kind == kind
    }
}

/// ControllerKind is a controller kind Pause reads: the two it scales and
/// the ReplicaSet it follows to its Deployment.
public enum ControllerKind: String, Equatable, Sendable, CaseIterable {
    case deployment = "Deployment"
    case statefulSet = "StatefulSet"
    case replicaSet = "ReplicaSet"

    /// The kubectl resource name, as `<resource>/<name>` takes it.
    public var resource: String {
        switch self {
        case .deployment: return "deployment"
        case .statefulSet: return "statefulset"
        case .replicaSet: return "replicaset"
        }
    }

    /// Whether Pause scales it: a Deployment or a StatefulSet. A
    /// ReplicaSet's Deployment would undo a scale of the ReplicaSet itself.
    public var scalable: Bool { self != .replicaSet }
}

/// WorkloadController is one Deployment, StatefulSet or ReplicaSet as Pause
/// reads it. Its strings are API data, clipped wherever they are shown.
public struct WorkloadController: Equatable, Sendable {
    public let kind: ControllerKind
    public let name: String
    public let namespace: String
    public let uid: String
    /// `spec.replicas`; nil when the object carried none.
    public let replicas: Int?
    /// The `WorkloadPause.annotation` value as served, nil when absent.
    public let pausedReplicas: String?
    /// The object's own controller reference (a ReplicaSet's Deployment).
    public let controllerRef: OwnerRef?

    public init(kind: ControllerKind, name: String, namespace: String, uid: String, replicas: Int?,
                pausedReplicas: String?, controllerRef: OwnerRef? = nil) {
        self.kind = kind
        self.name = name
        self.namespace = namespace
        self.uid = uid
        self.replicas = replicas
        self.pausedReplicas = pausedReplicas
        self.controllerRef = controllerRef
    }

    /// The row key of its Pause and Resume: "namespace/Kind/name", which no
    /// pod key ("namespace/name", no '/' in a name) can equal.
    public var key: String { "\(namespace)/\(kind.rawValue)/\(name)" }

    /// Whether Pause recorded a count on it: the annotation is present.
    public var paused: Bool { pausedReplicas != nil }

    /// Whether the record is stale: the annotation is present but the
    /// controller asks for replicas, as after a Pause whose scale step failed.
    public var stale: Bool { paused && (replicas ?? 0) > 0 }

    /// "Deployment web", clipped.
    public var title: String { StatusDisplay.clip("\(kind.rawValue) \(name)") }
}

/// WorkloadControllers is the decoded output of
/// `K3smCLI.controllersArguments`: the `apps/v1` Deployments, StatefulSets
/// and ReplicaSets, items of any other or no API version left out.
public struct WorkloadControllers: Equatable, Sendable {
    public let items: [WorkloadController]

    public init(_ items: [WorkloadController]) {
        self.items = items
    }

    /// Decodes kubectl's `List`; throws `KubeListError` for any other shape.
    public static func decode(_ data: Data) throws -> WorkloadControllers {
        let objects = try KubeList.objects(data, kinds: Set(ControllerKind.allCases.map(\.rawValue)))
        let items: [WorkloadController] = objects.compactMap { object in
            guard object["apiVersion"] as? String == "apps/v1" else { return nil }
            guard let kind = (object["kind"] as? String).flatMap(ControllerKind.init(rawValue:)) else { return nil }
            let metadata = KubeList.dict(object, "metadata")
            let annotations = metadata["annotations"] as? [String: Any] ?? [:]
            let ref = KubeList.array(metadata, "ownerReferences").first { KubeList.bool($0, "controller") == true }.map {
                OwnerRef(apiVersion: KubeList.string($0, "apiVersion") ?? "", kind: KubeList.string($0, "kind") ?? "",
                         name: KubeList.string($0, "name") ?? "", uid: KubeList.string($0, "uid") ?? "")
            }
            return WorkloadController(
                kind: kind, name: KubeList.name(object), namespace: KubeList.namespace(object),
                uid: KubeList.string(metadata, "uid") ?? "", replicas: KubeList.int(KubeList.dict(object, "spec"), "replicas"),
                pausedReplicas: annotations[WorkloadPause.annotation] as? String, controllerRef: ref)
        }
        return WorkloadControllers(items)
    }

    /// The controller of `kind` named by `ref` in `namespace`, its UID
    /// matching; a reference with no UID names nothing.
    func find(_ kind: ControllerKind, _ ref: OwnerRef, in namespace: String) -> WorkloadController? {
        items.first { c in
            c.kind == kind && c.namespace == namespace && c.name == ref.name && !ref.uid.isEmpty && c.uid == ref.uid
        }
    }
}

/// ControllerResolution is what Pause makes of a pod's controller.
public enum ControllerResolution: Equatable, Sendable {
    /// A Deployment (followed from the pod's ReplicaSet) or a StatefulSet.
    case controller(WorkloadController)
    /// A DaemonSet runs one pod per node and has no replica count.
    case daemonSet
    /// No controller Pause can scale: a bare pod, a Job, a bare
    /// ReplicaSet, or one the controller read did not list.
    case none
}

/// WorkloadAction is Pause or Resume.
public enum WorkloadAction: String, Sendable, CaseIterable, Identifiable {
    /// Records the replica count on the controller, then scales it to zero.
    case pause
    /// Scales the controller back to the recorded count, then removes it.
    case resume

    public var id: Self { self }

    public var title: String {
        switch self {
        case .pause: return "Pause"
        case .resume: return "Resume"
        }
    }
}

/// WorkloadStep is one of an action's two writes. Pause records the count
/// (`first`) and then scales to zero (`second`); Resume scales back
/// (`first`) and then removes the record (`second`). The second runs only
/// after the first exited 0, so a count is never lost.
public enum WorkloadStep: String, Sendable {
    case first
    case second
}

/// WorkloadActionRequest is one step of Pause or Resume on one controller,
/// fixed when the user asks for it: its kind, names, UID and count come
/// from the controller as it was listed then.
public struct WorkloadActionRequest: Equatable, ConsoleActionRequest {
    public let action: WorkloadAction
    public let step: WorkloadStep
    public let controller: ControllerKind
    public let namespace: ResourceName
    public let name: ResourceName
    public let uid: String
    /// Pause: the replicas it records (and the pre-check expects). Resume:
    /// the count it restores.
    public let count: Int
    /// Resume and a stale Pause's retry: the annotation as read when it was
    /// offered, which the pre-check requires to be unchanged. Nil for a Pause.
    public var recorded: String?
    /// A Pause whose count is already recorded on a controller still asking
    /// for replicas: it only scales to zero again, and asks first.
    public var retry = false

    public var id: String { "workload-\(action.rawValue)-\(step.rawValue):\(rowKey)" }
    public var section: ConsoleSection { .workloads }
    public var rowKey: String { "\(namespace.value)/\(controller.rawValue)/\(name.value)" }
    public var verb: String {
        switch (action, step) {
        case (.pause, .first): return "workload-pause"
        case (.pause, .second): return retry ? "workload-pause-retry" : "workload-pause-scale"
        case (.resume, .first): return "workload-resume"
        case (.resume, .second): return "workload-resume-clear"
        }
    }
    /// Neither removes the controller: each is a change, never on the Delete key.
    public var kind: ActionKind { .change }

    public var arguments: [String] {
        switch (action, step) {
        case (.pause, .first):
            return K3smCLI.recordPausedReplicasArguments(kind: controller, namespace: namespace, name: name, count: count)
        case (.pause, .second):
            return K3smCLI.scaleArguments(kind: controller, namespace: namespace, name: name, replicas: 0)
        case (.resume, .first):
            return K3smCLI.scaleArguments(kind: controller, namespace: namespace, name: name, replicas: count)
        case (.resume, .second):
            return K3smCLI.clearPausedReplicasArguments(kind: controller, namespace: namespace, name: name)
        }
    }

    /// Every step reads the controller's UID and replicas first.
    public var precheckArguments: [String]? {
        K3smCLI.controllerStateArguments(kind: controller, namespace: namespace, name: name)
    }

    /// The first step asks; the second runs on the first's success.
    public var asksFirst: Bool { step == .first || retry }
    public var titleEllipsis: Bool { asksFirst }

    public var confirmation: ActionConfirmation {
        let target = StatusDisplay.clip("\(controller.rawValue) \(name.value)")
        let title = "\(action.title) \(StatusDisplay.clip(namespace.value + "/" + name.value))?"
        switch action {
        case .pause where retry:
            return ActionConfirmation(
                title: title,
                message: "\(target) still runs, and the count recorded on it is stale: an earlier Pause recorded it but did not scale. "
                    + "k3sm scales it to zero, keeping the record, and Resume restores \(WorkloadPause.replicas(count)).",
                verbTitle: action.title, cancelTitle: "Cancel", destructive: true)
        case .pause:
            return ActionConfirmation(
                title: title,
                message: "k3sm scales \(target) to zero: its \(WorkloadPause.pods(count)) stop and nothing answers on its Services. "
                    + "The \(controller.rawValue) stays, with the count recorded on it, and Resume restores \(WorkloadPause.replicas(count)).",
                verbTitle: action.title, cancelTitle: "Cancel", destructive: true)
        case .resume:
            return ActionConfirmation(
                title: title,
                message: "k3sm scales \(target) back to \(WorkloadPause.replicas(count)) and removes the recorded count. "
                    + (ModelActions.readableCount(recorded) == nil
                        ? "The recorded count was unreadable, so it restores 1 replica. " : "")
                    + "Its pods start again, maybe on other nodes.",
                verbTitle: action.title, cancelTitle: "Cancel", destructive: false)
        }
    }

    public func precheck(_ run: ActionRun) -> ActionOutcome? {
        WorkloadPause.verify(self, run: run)
    }

    public func report(_ run: ActionRun) -> ActionOutcome {
        WorkloadPause.report(self, run: run)
    }

    /// The second step, after a first step that exited 0.
    public func next(after run: ActionRun) -> (any ConsoleActionRequest)? {
        guard step == .first, case .exited(status: 0, _) = run else { return nil }
        return WorkloadActionRequest(action: action, step: .second, controller: controller, namespace: namespace,
                                     name: name, uid: uid, count: count, recorded: recorded)
    }
}

/// WorkloadPause decides Pause and Resume: which controller a pod's
/// belongs to, which action it offers, the requests, the pre-check and
/// the reports. The count Pause replaces is kept on the controller in
/// `annotation`, so Resume works after a relaunch or from another Mac.
public enum WorkloadPause {
    /// The annotation Pause records the replica count in, and Resume reads
    /// and removes.
    public static let annotation = "k3sm.io/paused-replicas"

    /// The line shown for a pod whose controller is a DaemonSet.
    public static let daemonSetNote = "cannot pause a DaemonSet"

    /// The pod's controller, as `GetControllerOf` and the `apps/v1` kinds
    /// give it: a ReplicaSet followed one step to the Deployment that
    /// controls it, a StatefulSet as it is, a DaemonSet named as such.
    public static func resolve(_ pod: Pod, in controllers: WorkloadControllers?) -> ControllerResolution {
        guard let ref = pod.controllerRef, ref.apiVersion == "apps/v1" else { return .none }
        if ref.kind == "DaemonSet" { return .daemonSet }
        guard let controllers else { return .none }
        switch ref.kind {
        case ControllerKind.statefulSet.rawValue:
            return controllers.find(.statefulSet, ref, in: pod.namespace).map(ControllerResolution.controller) ?? .none
        case ControllerKind.replicaSet.rawValue:
            guard let replicaSet = controllers.find(.replicaSet, ref, in: pod.namespace),
                  let owner = replicaSet.controllerRef, owner.isApps(ControllerKind.deployment.rawValue),
                  let deployment = controllers.find(.deployment, owner, in: pod.namespace) else { return .none }
            return .controller(deployment)
        default:
            return .none
        }
    }

    /// The count Resume restores: the recorded annotation when it is plain
    /// digits from 1 to the int32 ceiling, otherwise 1.
    public static func restoreCount(_ recorded: String?) -> Int {
        ModelActions.restoreCount(recorded)
    }

    /// The request for one action's first step on a controller, or nil when
    /// it does not offer it: Pause for a Deployment or StatefulSet asking for
    /// replicas with no recorded count, and for one whose record is stale
    /// (still asking for replicas) the retry of Pause's scale step alone;
    /// Resume for one carrying a record and scaled to zero; nothing for a
    /// ReplicaSet, a name `ResourceName` refuses or a controller listed
    /// without a UID.
    public static func request(_ action: WorkloadAction, for controller: WorkloadController) -> WorkloadActionRequest? {
        guard controller.kind.scalable, !controller.uid.isEmpty,
              let namespace = ResourceName(controller.namespace), let name = ResourceName(controller.name) else { return nil }
        let count: Int
        switch action {
        case .pause:
            guard let replicas = controller.replicas, replicas > 0 else { return nil }
            if controller.paused {
                // A stale record: only the scale step again, keeping the count.
                return WorkloadActionRequest(action: .pause, step: .second, controller: controller.kind, namespace: namespace,
                                             name: name, uid: controller.uid, count: restoreCount(controller.pausedReplicas),
                                             recorded: controller.pausedReplicas, retry: true)
            }
            count = replicas
        case .resume:
            guard controller.paused, controller.replicas == 0 else { return nil }
            count = restoreCount(controller.pausedReplicas)
        }
        return WorkloadActionRequest(action: action, step: .first, controller: controller.kind, namespace: namespace,
                                     name: name, uid: controller.uid, count: count,
                                     recorded: action == .resume ? controller.pausedReplicas : nil)
    }

    /// The actions a controller offers: Pause or Resume, never both.
    public static func available(for controller: WorkloadController) -> [WorkloadAction] {
        WorkloadAction.allCases.filter { request($0, for: controller) != nil }
    }

    /// The requests a pod offers through its resolved controller.
    public static func requests(for pod: Pod, in controllers: WorkloadControllers?) -> [WorkloadActionRequest] {
        guard case .controller(let c) = resolve(pod, in: controllers) else { return [] }
        return WorkloadAction.allCases.compactMap { request($0, for: c) }
    }

    /// A paused controller's row menu: its Resume, or the Pause retry when its
    /// record is stale.
    public static func menu(for controller: WorkloadController) -> ActionMenu {
        ActionMenu(available(for: controller).compactMap { request($0, for: controller) })
    }

    /// The line the inspector shows in place of Pause: "cannot pause a
    /// DaemonSet" for a DaemonSet's pod, nil otherwise.
    public static func note(for pod: Pod, in controllers: WorkloadControllers?) -> String? {
        resolve(pod, in: controllers) == .daemonSet ? daemonSetNote : nil
    }

    /// The pod's controller as the inspector shows it: "Deployment web, 3
    /// replicas", or "Deployment web, paused; Resume restores 3 replicas";
    /// nil when the pod resolves to none.
    public static func controllerFact(for pod: Pod, in controllers: WorkloadControllers?) -> String? {
        guard case .controller(let c) = resolve(pod, in: controllers) else { return nil }
        if c.stale { return "\(c.title), record stale: \(replicas(c.replicas ?? 0)) running, \(replicas(restoreCount(c.pausedReplicas))) recorded; Pause again to finish" }
        if c.paused { return "\(c.title), paused; Resume restores \(replicas(restoreCount(c.pausedReplicas)))" }
        return c.replicas.map { "\(c.title), \(replicas($0))" } ?? c.title
    }

    /// Whether the pod's row shows the paused badge: its controller carries
    /// the recorded count.
    public static func paused(_ pod: Pod, in controllers: WorkloadControllers?) -> Bool {
        if case .controller(let c) = resolve(pod, in: controllers) { return c.paused }
        return false
    }

    /// Whether the pod's controller carries a stale record: shown as "stale"
    /// in place of the paused badge.
    public static func stale(_ pod: Pod, in controllers: WorkloadControllers?) -> Bool {
        if case .controller(let c) = resolve(pod, in: controllers) { return c.stale }
        return false
    }

    /// The row key of the pod's resolved controller, nil when it has none.
    public static func controllerKey(for pod: Pod, in controllers: WorkloadControllers?) -> String? {
        if case .controller(let c) = resolve(pod, in: controllers) { return c.key }
        return nil
    }

    /// The paused Deployments and StatefulSets of one namespace, by name:
    /// the rows that hold Resume once their pods are gone. A search keeps
    /// those whose clipped title contains it.
    public static func pausedControllers(in workloads: Workloads, namespace: String, query: String = "") -> [WorkloadController] {
        (workloads.controllers?.items ?? [])
            .filter { $0.kind.scalable && $0.paused && $0.namespace == namespace }
            .filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
            .sorted { ($0.name, $0.kind.rawValue) < ($1.name, $1.kind.rawValue) }
    }

    /// The namespaces the list shows: the pods' in list order, then those
    /// holding only paused controllers, by name.
    public static func namespaces(in workloads: Workloads) -> [String] {
        var seen = workloads.namespaces
        let paused = Set((workloads.controllers?.items ?? []).filter { $0.kind.scalable && $0.paused }.map(\.namespace))
        for ns in paused.sorted() where !seen.contains(ns) { seen.append(ns) }
        return seen
    }

    /// What the state read just before a step says: nil when the controller
    /// is still the one confirmed (its UID; for Pause's first step, also the
    /// replicas it records; for Resume's first step and a Pause retry, also
    /// the record as offered, with replicas at 0 for Resume and above 0 for
    /// the retry), so the step runs; otherwise the line shown
    /// instead, and nothing more runs.
    public static func verify(_ request: WorkloadActionRequest, run: ActionRun) -> ActionOutcome? {
        let verb = request.action.title
        let nothing = untouched(request)
        let changed = ActionOutcome.refused("\(verb) refused: \(target(request)) changed since you clicked; \(nothing).")
        switch run {
        case .exited(status: 0, let output):
            // "<uid> <replicas> <recorded>": the record is the rest of the line.
            let fields = String(decoding: output, as: UTF8.self)
                .split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            let live = (replicas: fields.count > 1 ? fields[1] : "", recorded: fields.count > 2 ? fields[2] : "")
            guard fields.first == request.uid else { return changed }
            switch (request.action, request.step) {
            case (.pause, .first):
                if live.replicas != String(request.count) { return changed }
            case (.pause, .second) where request.retry:
                if live.recorded != (request.recorded ?? "") || (Int(live.replicas) ?? 0) <= 0 { return changed }
            case (.resume, .first):
                if live.recorded != (request.recorded ?? "") || live.replicas != "0" { return changed }
            default:
                break
            }
            return nil
        case .exited(let status, let output):
            let raw = String(decoding: output, as: UTF8.self)
            if raw.contains("(NotFound)") { return changed }
            let text = StatusDisplay.errorText(raw)
            return .failed("\(verb) failed; \(nothing). " + (text.isEmpty ? "k3sm kubectl exited \(status)" : "kubectl said: \(text)"))
        case .noAnswer:
            return .failed("\(verb) failed: the k3sm CLI did not answer the controller check; \(nothing).")
        case .missing, .refused:
            return report(request, run: run)
        }
    }

    /// The line shown after a step's run. CLI text passes `StatusDisplay.errorText`.
    public static func report(_ request: WorkloadActionRequest, run: ActionRun) -> ActionOutcome {
        let verb = request.action.title
        let target = target(request)
        switch run {
        case .exited(status: 0, _):
            switch request.action {
            case .pause:
                return .succeeded("Paused \(target): its pods stop, and Resume restores \(replicas(request.count)).")
            case .resume:
                return .succeeded("Resumed \(target): it scales back to \(replicas(request.count)).")
            }
        case .exited(let status, let output):
            let text = StatusDisplay.errorText(String(decoding: output, as: UTF8.self))
            let said = text.isEmpty ? "k3sm kubectl exited \(status)." : "kubectl said: \(text)"
            switch (request.action, request.step) {
            case (.pause, .second):
                return .failed("Pause stopped: the count was recorded on \(target), but it was not scaled to zero. \(said)")
            case (.resume, .second):
                return .failed("Resumed \(target) to \(replicas(request.count)), but the recorded count stays. \(said)")
            case (_, .first):
                return .failed("\(verb) failed; nothing was changed. \(said)")
            }
        case .noAnswer:
            return .failed("\(verb) failed: the k3sm CLI did not answer. Refresh to see whether \(target) changed.")
        case .missing:
            return .failed("\(verb) failed: k3sm is not installed on this Mac.")
        case .refused(let why):
            return .failed("\(verb) failed: the installed k3sm failed the app's check (\(StatusDisplay.errorText(why))), so it was not run.")
        }
    }

    /// What nothing happening means at a step: nothing at all at the first,
    /// the first write only at the second.
    private static func untouched(_ request: WorkloadActionRequest) -> String {
        switch (request.action, request.step) {
        case (_, .first): return "nothing was changed"
        case (.pause, .second): return "the count was recorded but it was not scaled to zero"
        case (.resume, .second): return "it was scaled back but the recorded count stays"
        }
    }

    private static func target(_ request: WorkloadActionRequest) -> String {
        StatusDisplay.clip("\(request.controller.rawValue) \(request.name.value)")
    }

    /// "1 replica", "3 replicas".
    static func replicas(_ count: Int) -> String {
        count == 1 ? "1 replica" : "\(count) replicas"
    }

    /// "1 pod", "3 pods".
    static func pods(_ count: Int) -> String {
        count == 1 ? "1 pod" : "\(count) pods"
    }
}
