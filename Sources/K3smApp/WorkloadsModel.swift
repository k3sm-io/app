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

import Combine
import Foundation
import K3smStatus

/// WorkloadsModel is the console's state: the last pod and node lists, the
/// search, the selected pod and its detail, polled serially through the one
/// CLI seam while the console is on screen, the way StatusPoller polls the
/// visibility probe. `PollGate` keeps the list reads serial: a refresh during
/// a poll runs once more after it, and a start after a stop waits for the
/// stopped loop to end.
@MainActor
final class WorkloadsModel: ObservableObject {
    enum Detail: String, CaseIterable, Identifiable {
        case logs = "Logs", events = "Events", manifest = "Manifest"
        var id: Self { self }
    }

    @Published private(set) var reading: WorkloadsReading?
    @Published private(set) var readAt: Date?
    /// The cluster's nodes from the last poll; nil when the read failed or
    /// its output was not a node list.
    @Published private(set) var nodes: [ClusterNode]?
    @Published var selected: String?          // a Pod.key
    @Published var query = ""
    @Published var detail: Detail = .logs
    @Published private(set) var detailText = ""
    @Published private(set) var detailLoading = false
    /// The host's memory and data-root use, read with every poll so the panel
    /// holds no view state (the Command Line Tools have no SwiftUI macro plugin).
    @Published private(set) var load = HostLoad.read()

    private let environment: [String: String]
    private var task: Task<Void, Never>?
    /// The loop `stop()` cancelled, until the next `start()` waits for it.
    private var stopping: Task<Void, Never>?
    private var gate = PollGate()
    private var detailTask: Task<Void, Never>?

    init(environment: [String: String]) {
        self.environment = environment
    }

    var workloads: Workloads? {
        if case .listed(let w) = reading { return w }
        return nil
    }

    var selectedPod: Pod? {
        guard let selected, let w = workloads else { return nil }
        return w.pods.first { $0.key == selected }
    }

    /// The pods the search leaves visible, by `WorkloadsDisplay.visible`.
    func visible(_ pods: [Pod]) -> [Pod] {
        WorkloadsDisplay.visible(pods, query: query)
    }

    func select(_ pod: Pod) {
        selected = pod.key
        loadDetail()
    }

    /// Starts polling while the tab is shown; a second start is a no-op. The
    /// new loop first waits for a stopped one to end, so two loops never
    /// overlap.
    func start() {
        guard task == nil else { return }
        let previous = stopping
        stopping = nil
        task = Task { [weak self] in
            await previous?.value
            while !Task.isCancelled {
                guard let self else { return }
                await self.poll()
                try? await Task.sleep(for: PollSchedule.visibleInterval)
            }
        }
    }

    /// Stops polling when the tab leaves the screen. The cancelled run kills
    /// its CLI child; the next `start()` waits for it.
    func stop() {
        guard let task else { return }
        task.cancel()
        stopping = task
        self.task = nil
    }

    /// Reads the lists now, or, with a poll in flight, once more after it.
    func refresh() async {
        await poll()
    }

    /// One run through the gate, repeated while a refresh asked for another.
    /// A cancelled run still drains the gate so it is never left held.
    private func poll() async {
        guard gate.begin() else { return }
        repeat {
            if !Task.isCancelled {
                await pollOnce()
            }
        } while gate.finish()
    }

    private func pollOnce() async {
        let outcome = await CLIProcess.run(
            path: K3smCLI.path,
            arguments: K3smCLI.workloadsArguments,
            environment: environment,
            deadline: PollSchedule.listDeadline,
            limit: OutputLimit.list
        )
        guard !Task.isCancelled else { return }
        switch outcome {
        case .missing:
            reading = .binaryMissing
        case .failedToLaunch, .killed, .refused:
            reading = .cliError("the k3sm CLI did not answer")
        case .truncated:
            reading = .cliError("the pod list is larger than \(OutputLimit.list >> 20) MiB")
        case .exited(let status, let stdout):
            reading = WorkloadsReading.classify(exitCode: status, stdout: stdout)
        }
        let nodesOutcome = await CLIProcess.run(
            path: K3smCLI.path,
            arguments: K3smCLI.nodesArguments,
            environment: environment,
            deadline: PollSchedule.listDeadline,
            limit: OutputLimit.list
        )
        guard !Task.isCancelled else { return }
        if case .exited(0, let stdout) = nodesOutcome {
            nodes = try? Nodes.decode(stdout)
        } else {
            nodes = nil
        }
        load = HostLoad.read()
        readAt = Date()
        switch WorkloadsDisplay.selection(after: selected, in: workloads?.pods) {
        case .keep:
            break
        case .select(let key):
            selected = key
            loadDetail()
        case .clear:
            selected = nil
            detailText = ""
        }
    }

    /// Loads the selected pod's logs, events or manifest through the fixed
    /// argument lists; the names were validated by the decoder.
    func loadDetail() {
        detailTask?.cancel()
        guard let pod = selectedPod, let ns = pod.namespaceName, let name = pod.resourceName else {
            detailText = ""
            return
        }
        let arguments: [String]
        switch detail {
        case .logs: arguments = K3smCLI.logsArguments(namespace: ns, pod: name)
        case .events: arguments = K3smCLI.eventsArguments(namespace: ns, pod: name)
        case .manifest: arguments = K3smCLI.manifestArguments(namespace: ns, pod: name)
        }
        detailLoading = true
        detailTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await CLIProcess.run(path: K3smCLI.path, arguments: arguments, environment: self.environment, deadline: .seconds(15), limit: OutputLimit.detail)
            guard !Task.isCancelled else { return }
            self.detailLoading = false
            switch outcome {
            case .exited(let status, let stdout):
                let text = StatusDisplay.body(String(decoding: stdout, as: UTF8.self))
                self.detailText = status == 0 ? (text.isEmpty ? "Nothing recorded." : text) : "k3sm kubectl exited \(status)"
            case .truncated(let stdout):
                // The first OutputLimit.detail bytes, cleaned like a whole
                // read; the run was stopped there instead of read to the end.
                self.detailText = StatusDisplay.body(String(decoding: stdout, as: UTF8.self)) + "\n… cut at \(OutputLimit.detail >> 10) KiB"
            case .missing, .failedToLaunch, .killed, .refused:
                self.detailText = "the k3sm CLI did not answer"
            }
        }
    }
}
