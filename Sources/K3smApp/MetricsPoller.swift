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
import K3smHost
import K3smStatus

/// MetricsPoller reads metrics-server's node and pod samples while the
/// console is on screen: one loop makes every read and awaits each, so no two
/// are ever in flight, and `MetricsSchedule.step` decides each move (15 s
/// between reads, 60 s while the API is absent, nothing while the window is
/// hidden). The node read comes first; the pod read follows it only when it
/// exited 0, and the APIService read only when it did not. A stop cancels
/// the loop and kills the run in flight; the next start waits for it.
@MainActor
final class MetricsPoller {
    private let environment: [String: String]
    private let onReading: @MainActor (MetricsReading, Date) -> Void
    private var loop: Task<Void, Never>?
    private var stopping: Task<Void, Never>?
    private var lastRead: Date?
    private var absent = false

    init(environment: [String: String], onReading: @escaping @MainActor (MetricsReading, Date) -> Void) {
        self.environment = environment
        self.onReading = onReading
    }

    /// Starts the loop; `visible` says whether the window is on screen now.
    /// A second start is a no-op.
    func start(visible: @escaping @MainActor () -> Bool) {
        guard loop == nil else { return }
        let previous = stopping
        stopping = nil
        loop = Task { [weak self] in
            await previous?.value
            while !Task.isCancelled {
                guard let self else { return }
                switch MetricsSchedule.step(visible: visible(), lastRead: self.lastRead, now: Date(), absent: self.absent) {
                case .read:
                    let reading = await Self.read(environment: self.environment)
                    guard !Task.isCancelled else { return }
                    let now = Date()
                    self.lastRead = now
                    if case .absent = reading { self.absent = true }
                    if case .sampled = reading { self.absent = false }
                    self.onReading(reading, now)
                case .wait(let wait):
                    try? await Task.sleep(for: wait)
                }
            }
        }
    }

    /// Stops the loop; a read in flight is killed and its result dropped.
    func stop() {
        loop?.cancel()
        stopping = loop
        loop = nil
    }

    /// One poll: the node read, then the pod read or the APIService read.
    nonisolated static func read(environment: [String: String]) async -> MetricsReading {
        let nodes = await run(K3smCLI.nodeMetricsArguments, environment: environment, limit: OutputLimit.metrics)
        guard !Task.isCancelled else { return .failed("cancelled") }
        switch nodes {
        case .missing:
            return .failed(TabLoad.notInstalled)
        case .failedToLaunch, .killed, .refused:
            return .failed("the k3sm CLI did not answer")
        case .truncated:
            return .failed("the node metrics are larger than \(OutputLimit.metrics >> 20) MiB")
        case .exited(0, let stdout):
            var pods: (exit: Int32, stdout: Data)?
            if case .exited(let status, let out) = await run(
                K3smCLI.podMetricsArguments, environment: environment, limit: OutputLimit.metrics) {
                pods = (status, out)
            }
            return Metrics.sampled(nodes: stdout, pods: pods)
        case .exited(let status, _):
            // Standard error is kept here so a NotFound can be told apart
            // from an apiserver that did not answer; on success kubectl
            // prints only the object.
            var apiService: (exit: Int32, stdout: Data)?
            if case .exited(let code, let out) = await run(
                K3smCLI.metricsAPIServiceArguments, environment: environment, limit: OutputLimit.status, keepErrors: true) {
                apiService = (code, out)
            }
            return Metrics.unavailable(nodesExit: status, apiService: apiService)
        }
    }

    nonisolated private static func run(
        _ arguments: [String], environment: [String: String], limit: Int, keepErrors: Bool = false
    ) async -> CLIOutcome {
        await CLIProcess.run(
            path: K3smCLI.path, arguments: arguments, environment: environment,
            deadline: PollSchedule.listDeadline, limit: limit, keepErrors: keepErrors)
    }
}
