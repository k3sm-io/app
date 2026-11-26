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
import K3smInstall
import OSLog

/// The existing Aqua app performs enrolled rollouts as its login user. Every deployment gets its
/// own task so a large download cannot stop another app's readiness heartbeat.
@MainActor
final class DesktopRollout {
    private var timer: Task<Void, Never>?
    private var workers: [URL: Task<Void, Never>] = [:]
    private let logger = Logger(subsystem: "io.k3sm.app", category: "desktop-rollout")

    func start() {
        guard timer == nil, let home = InstalledCLI.home(),
              let script = Bundle.main.url(forResource: "reconcile", withExtension: "sh", subdirectory: "desktop-rollout")
        else { return }
        let root = URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/io.k3sm.app/desktop-rollout")
        let configs = root.appendingPathComponent("enrollments")
        let revisions = root.appendingPathComponent("revisions")
        timer = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let files = (try? FileManager.default.contentsOfDirectory(at: configs, includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles])) ?? []
                for file in files where file.pathExtension == "json" && workers[file] == nil {
                    workers[file] = Task { [weak self] in
                        guard let self else { return }
                        defer { self.workers[file] = nil }
                        guard await Task.detached(operation: { InstalledCLI.trust(team: TeamIDPin.teamID) }).value == .trusted
                        else { return }
                        let outcome = await CLIProcess.run(path: "/bin/bash", arguments: [script.path, file.path, revisions.path],
                            environment: InstalledCLI.environment(), deadline: .seconds(900), limit: 16384)
                        if case .exited(let status, _) = outcome, status == 0 { return }
                        if !Task.isCancelled { self.logger.error("Desktop rollout reconciliation failed") }
                    }
                }
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    func stop() {
        timer?.cancel()
        for worker in workers.values { worker.cancel() }
    }
}
