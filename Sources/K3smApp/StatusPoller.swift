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

/// StatusPoller runs the visibility probe strictly serially: the next run
/// starts only after the previous one exits (or is killed at the deadline),
/// then waits 15 s while the item is visible or 60 s while hidden, each wait
/// spread by `PollJitter`. A launchd state change touches no file, so no
/// record watch sees a daemon crash: this probe stays its only detector.
@MainActor
final class StatusPoller {
    private let environment: [String: String]
    private let onReading: @MainActor (Reading, StatusReport?) -> Void
    private var task: Task<Void, Never>?

    /// Whether the status item is currently shown; picks the cadence.
    var itemVisible = false

    init(environment: [String: String], onReading: @escaping @MainActor (Reading, StatusReport?) -> Void) {
        self.environment = environment
        self.onReading = onReading
    }

    /// Starts polling, if not already running.
    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollOnce()
                let wait = PollSchedule.interval(visible: self.itemVisible)
                try? await Task.sleep(for: PollJitter.spread(wait, unit: PollJitter.draw()))
            }
        }
    }

    /// Stops polling; a run in flight finishes and its result is dropped.
    func stop() {
        task?.cancel()
        task = nil
    }

    private func pollOnce() async {
        let outcome = await CLIProcess.run(
            path: K3smCLI.path,
            arguments: K3smCLI.probeArguments,
            environment: environment,
            deadline: PollSchedule.killDeadline,
            limit: OutputLimit.status
        )
        guard !Task.isCancelled else { return }
        switch outcome {
        case .missing:
            onReading(.binaryMissing, nil)
        case .failedToLaunch, .killed, .refused, .truncated:
            onReading(.cliError, nil)
        case .exited(let status, let stdout):
            onReading(Reading.classify(exitCode: status, stdout: stdout), try? StatusReport.decode(stdout))
        }
    }
}
