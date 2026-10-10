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

import AppKit
import Combine
import K3smInstall
import K3smStatus

/// AppModel is the window's state: which screen it shows, the last full
/// report, the first-run form, and a running root step with its log.
@MainActor
final class AppModel: ObservableObject {
    enum Screen: Equatable {
        /// No /Library/k3sm: offer to start or join a cluster.
        case firstRun
        /// k3sm is installed: show its status.
        case status
    }

    enum FirstRunChoice: String, CaseIterable, Identifiable {
        case start = "Start a cluster on this Mac"
        case join = "Join a cluster"
        var id: Self { self }
    }

    /// How long the log tail waits between reads while a step runs.
    private static let tailInterval: Duration = .seconds(1)
    /// The most log text the window keeps.
    private static let tailBytes = 16 * 1024

    @Published private(set) var screen: Screen = .firstRun
    @Published private(set) var report: StatusReport?
    @Published private(set) var installedVersion: SemanticVersion?
    @Published private(set) var availability: PrivilegedAvailability
    @Published var loginItemNeedsApproval = false
    @Published private(set) var running = false
    @Published private(set) var logTail = ""
    @Published private(set) var outcomeMessage: String?
    @Published var choice: FirstRunChoice = .start
    @Published var serverText = ""
    @Published var token = ""

    let payloadVersion: SemanticVersion?
    private let teamID: TeamID?
    private let runner: any PrivilegedRunner
    private let environment: [String: String]

    init(runner: any PrivilegedRunner, environment: [String: String]) {
        self.runner = runner
        self.environment = environment
        self.teamID = SelfCheck.teamID()
        self.payloadVersion = SelfCheck.payloadVersion()
        self.availability = SelfCheck.availability()
        // An unfinished or failed earlier run is the first thing the window
        // shows on relaunch.
        let previous = Self.readLog()
        if !previous.isEmpty, CopyOutOutcome(log: previous) != .succeeded {
            logTail = previous
        }
    }

    /// The join form's address problem, if the typed text is not valid.
    var addressError: String? {
        let text = serverText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard choice == .join, !text.isEmpty else { return nil }
        do {
            _ = try ServerAddress(parsing: text)
            return nil
        } catch {
            return error.message
        }
    }

    /// Whether the first-run button is enabled.
    var canSubmit: Bool {
        guard !running, availability == .enabled, payloadVersion != nil else { return false }
        switch choice {
        case .start: return true
        case .join: return addressError == nil && !serverText.isEmpty && !token.isEmpty
        }
    }

    /// Re-reads which screen applies, the full report and the installed
    /// version. The full report runs only here, when the window is shown.
    func refresh() async {
        screen = FileManager.default.fileExists(atPath: K3smCLI.installRoot) ? .status : .firstRun
        guard screen == .status else {
            report = nil
            installedVersion = nil
            return
        }
        if case .exited(_, let stdout) = await runCLI(K3smCLI.reportArguments) {
            report = try? StatusReport.decode(stdout)
        }
        if case .exited(0, let stdout) = await runCLI(K3smCLI.versionArguments) {
            installedVersion = SemanticVersion.fromVersionCommand(String(decoding: stdout, as: UTF8.self))
        }
    }

    /// Runs the first-run choice through the privileged runner.
    func submitFirstRun() {
        guard canSubmit, let teamID, let payloadVersion else { return }
        let action: CopyOutAction
        var input: Data?
        switch choice {
        case .start:
            action = .startServer
        case .join:
            guard let address = try? ServerAddress(parsing: serverText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                return
            }
            action = .join(address)
            input = Data(token.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
            token = ""
        }
        let plan: CopyOutPlan
        do {
            plan = try CopyOutPlan(bundlePath: Bundle.main.bundlePath, payloadVersion: payloadVersion, teamID: teamID, action: action)
        } catch {
            outcomeMessage = "k3sm cannot run from \(Bundle.main.bundlePath). Move it to the Applications folder."
            return
        }
        run(plan, input: input)
    }

    private func run(_ plan: CopyOutPlan, input: Data?) {
        running = true
        outcomeMessage = nil
        logTail = ""
        let script = RootScriptBuilder.render(plan)
        let tail = Task { [weak self] in
            while !Task.isCancelled {
                self?.logTail = Self.readLog()
                try? await Task.sleep(for: Self.tailInterval)
            }
        }
        NSApp.activate()
        Task { [weak self, runner] in
            let outcome = await runner.runAsRoot(script, input: input)
            tail.cancel()
            guard let self else { return }
            self.logTail = Self.readLog()
            self.outcomeMessage = OutcomeSummary.text(outcome, action: plan.action)
            self.running = false
            log.notice("copy-out finished")
            await self.refresh()
        }
    }

    private func runCLI(_ arguments: [String]) async -> CLIOutcome {
        await CLIProcess.run(path: K3smCLI.path, arguments: arguments, environment: environment, deadline: PollSchedule.killDeadline)
    }

    /// Reads the tail of the copy-out log, or "" when it is absent or not
    /// readable by this user.
    private static func readLog() -> String {
        guard let handle = FileHandle(forReadingAtPath: CopyOutPlan.logPath) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
