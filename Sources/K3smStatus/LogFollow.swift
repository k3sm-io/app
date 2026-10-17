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

/// LogFollowTarget is one log the inspector follows: a pod, and the
/// container when the pod has several, each only as a `ResourceName`.
public struct LogFollowTarget: Equatable, Sendable, Identifiable {
    public let namespace: ResourceName
    public let pod: ResourceName
    /// Nil for a pod of one container, which kubectl picks itself.
    public let container: ResourceName?
    /// The pod's selection key, "namespace/name".
    public let podKey: String
    /// The pod's UID as listed when Follow was clicked.
    public let uid: String

    public var id: String { "follow:\(podKey):\(container?.value ?? "")" }

    /// The button's or the menu item's title.
    public var title: String { container.map { "Follow \($0.value)" } ?? "Follow" }

    /// The CLI arguments the follow runs.
    public var arguments: [String] {
        K3smCLI.followLogsArguments(namespace: namespace, pod: pod, container: container)
    }
}

/// LogFollow decides the inspector's Follow: which logs a pod offers, and
/// the line under the pane.
public enum LogFollow {
    /// How a follow stands.
    public enum End: Equatable, Sendable {
        /// Still reading.
        case reading
        /// kubectl exited: 0 when the container stopped writing for good.
        case exited(Int32)
        /// The output passed `OutputLimit.detail`.
        case limit
        /// The run passed `PollSchedule.logFollowDeadline`, or could not start.
        case timedOut
        /// The app stopped it.
        case stopped(StopReason)
        case missing
        case refused(String)
    }

    /// Why the app stopped a follow.
    public enum StopReason: Equatable, Sendable {
        /// The Stop button.
        case user
        /// Another pod, or another detail tab, was selected.
        case moved
        /// The inspector closed.
        case closed
    }

    /// The logs a pod offers to follow: none for a pod not in a phase whose
    /// containers have run (`PodActions.loggedPhases`), with no UID or a name
    /// `ResourceName` refuses; one for a pod of one container; one per
    /// container `ResourceName` accepts for a pod of several.
    public static func targets(for pod: Pod) -> [LogFollowTarget] {
        guard PodActions.loggedPhases.contains(pod.phase), !pod.uid.isEmpty,
              let namespace = pod.namespaceName, let name = pod.resourceName else { return [] }
        if pod.containers.count <= 1 {
            return [LogFollowTarget(namespace: namespace, pod: name, container: nil, podKey: pod.key, uid: pod.uid)]
        }
        return pod.containers.compactMap(ResourceName.init).map {
            LogFollowTarget(namespace: namespace, pod: name, container: $0, podKey: pod.key, uid: pod.uid)
        }
    }

    /// The pane's text: the bytes as UTF-8, block-cleaned (`StatusDisplay.body`).
    public static func text(_ data: Data) -> String {
        StatusDisplay.body(String(decoding: data, as: UTF8.self))
    }

    /// The line under the pane.
    public static func status(_ end: End, target: LogFollowTarget) -> String {
        let what = target.container.map { "container \($0.value)" } ?? "the log"
        switch end {
        case .reading: return "Following \(what): new lines appear as they are written."
        case .exited(0): return "The log ended: the container stopped writing."
        case .exited(let status): return "k3sm kubectl exited \(status). Follow again to retry."
        case .limit: return "Stopped at \(OutputLimit.detail >> 10) KiB, the most the pane holds. Follow again for the newest lines."
        case .timedOut: return "Stopped after \(Int(PollSchedule.logFollowDeadline.components.seconds) / 60) minutes. Follow again to keep reading."
        case .stopped(.user): return "Stopped following."
        case .stopped(.moved): return "Stopped following: another pod or tab was selected."
        case .stopped(.closed): return "Stopped following: the inspector closed."
        case .missing: return "k3sm is not installed on this Mac."
        case .refused(let why): return "The installed k3sm failed the app's check (\(StatusDisplay.errorText(why))), so it was not run."
        }
    }
}

/// LogFollowRun is one run of `kubectl logs -f`: it is handed the argument
/// list and a sink for each chunk of output as it is read, and returns how
/// the run ended. The app's run is `CLIProcess`, whose cancellation handler
/// kills the CLI, so cancelling the task awaiting it ends the follow.
public typealias LogFollowRun = @Sendable (_ arguments: [String], _ onOutput: @escaping @Sendable (Data) -> Void) async -> LogFollow.End

/// LogFollowRead is the inspector's one followed log: the bytes read so
/// far, in order, and how it stands. `stop` cancels the run, which kills
/// the CLI, records why, and a stopped read never starts again.
@MainActor
public final class LogFollowRead {
    public let target: LogFollowTarget
    /// The bytes read so far; the run caps them (`OutputLimit.detail`).
    public private(set) var data = Data()
    public private(set) var end: LogFollow.End = .reading
    /// Called after every change, for a view to re-render.
    public var changed: (@MainActor () -> Void)?
    private var task: Task<Void, Never>?
    private var started = false

    public init(target: LogFollowTarget) {
        self.target = target
    }

    /// Whether the follow is still reading.
    public var reading: Bool { end == .reading }

    public var text: String { LogFollow.text(data) }
    public var status: String { LogFollow.status(end, target: target) }

    /// Starts the follow; a second start, or a start after `stop`, does nothing.
    public func start(_ run: @escaping LogFollowRun) {
        guard !started, reading else { return }
        started = true
        let arguments = target.arguments
        task = Task { [weak self] in
            let end = await run(arguments) { chunk in
                // The main queue keeps the chunks in order.
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.append(chunk) } }
            }
            guard !Task.isCancelled else { return }
            // Let the chunks already queued land before the end is shown.
            await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
            self?.finish(end)
        }
    }

    /// Stops the follow, cancelling its run, which kills the CLI; a follow
    /// that already ended keeps its own line.
    public func stop(_ reason: LogFollow.StopReason) {
        task?.cancel()
        task = nil
        guard reading else { return }
        end = .stopped(reason)
        changed?()
    }

    private func append(_ chunk: Data) {
        guard reading else { return }
        data.append(chunk)
        changed?()
    }

    private func finish(_ end: LogFollow.End) {
        guard reading else { return }
        self.end = end
        task = nil
        changed?()
    }
}
