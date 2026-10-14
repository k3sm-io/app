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
/// report, the first-run form, the update and uninstall choices, and a
/// running root step with its log.
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
    /// The worker's join target, read from its installed plist on refresh.
    @Published private(set) var joinTarget: Result<ServerAddress, AgentJoinTarget.ReadError>?
    /// The user's confirmation that every worker is updated (server only,
    /// while the status report carries no worker versions).
    @Published var workersConfirmed = false
    /// The uninstall form's purge checkbox; stays off while the app cannot
    /// purge (`CopyOutAction.purgeUnavailableReason`).
    @Published var purge = false
    /// Whether the uninstall confirmation is showing. Held here rather than
    /// in view state: the Command Line Tools toolchain has no SwiftUI macro
    /// plugin, so the window uses no `@State`.
    @Published var confirmingUninstall = false

    let payloadVersion: SemanticVersion?
    private let teamID: TeamID?
    private let user: ConsoleUser?
    private let runner: any PrivilegedRunner
    private let environment: [String: String]

    init(runner: any PrivilegedRunner, environment: [String: String]) {
        self.runner = runner
        self.environment = environment
        self.teamID = SelfCheck.teamID()
        self.user = SelfCheck.consoleUser()
        self.payloadVersion = SelfCheck.payloadVersion()
        var availability = SelfCheck.availability()
        if availability == .enabled, user == nil {
            availability = .disabled(reason: "k3sm could not read a non-root account name for this user, so it cannot install k3sm.")
        }
        self.availability = availability
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

    /// Whether a privileged step may start now.
    private var canRunPrivileged: Bool {
        !running && availability == .enabled && payloadVersion != nil
    }

    /// Whether the first-run button is enabled.
    var canSubmit: Bool {
        guard canRunPrivileged else { return false }
        switch choice {
        case .start: return true
        case .join: return addressError == nil && !serverText.isEmpty && !token.isEmpty
        }
    }

    /// The installed role, from the full report.
    var role: NodeRole? {
        report.flatMap(NodeRole.detect(in:))
    }

    /// The update decision for this Mac, or nil when the role, the payload
    /// or the report is unknown. Worker versions are not in today's status
    /// JSON, so a server update rests on the user's confirmation.
    var updateDecision: UpdateDecision? {
        guard let role, let payloadVersion else { return nil }
        return UpdatePolicy.decide(
            role: role, payload: payloadVersion, installed: installedVersion,
            workers: nil, allowDowngrade: false, workersConfirmed: workersConfirmed)
    }

    /// The update action the window would run, or nil when none is ready.
    var updateAction: CopyOutAction? {
        guard updateDecision?.verdict == .offer else { return nil }
        switch role {
        case .server: return .update(.server)
        case .agent:
            guard case .success(let server) = joinTarget else { return nil }
            return .update(.agent(joinServer: server))
        case nil: return nil
        }
    }

    var canUpdate: Bool { canRunPrivileged && updateAction != nil }
    /// The uninstall the window would run; nil for a purge the app cannot do.
    var uninstallAction: CopyOutAction? { CopyOutAction.uninstall(requestingPurge: purge) }
    var canUninstall: Bool { canRunPrivileged && uninstallAction != nil }

    /// Re-reads which screen applies, the full report, the installed version
    /// and, on a worker, its join target. The full report runs only here,
    /// when the window is shown.
    func refresh() async {
        screen = FileManager.default.fileExists(atPath: K3smCLI.installRoot) ? .status : .firstRun
        guard screen == .status else {
            report = nil
            installedVersion = nil
            joinTarget = nil
            return
        }
        if case .exited(_, let stdout) = await runCLI(K3smCLI.reportArguments) {
            report = try? StatusReport.decode(stdout)
        }
        if case .exited(0, let stdout) = await runCLI(K3smCLI.versionArguments) {
            installedVersion = SemanticVersion.fromVersionCommand(String(decoding: stdout, as: UTF8.self))
        }
        joinTarget = role == .agent ? Self.readJoinTarget() : nil
    }

    /// Runs the first-run choice through the privileged runner.
    func submitFirstRun() {
        guard canSubmit else { return }
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
        start(action, input: input)
    }

    /// Runs the update the window offers.
    func submitUpdate() {
        guard canUpdate, let action = updateAction else { return }
        workersConfirmed = false
        start(action, input: nil)
    }

    /// Runs the uninstall, keeping the data unless purge is chosen and the
    /// app can purge.
    func submitUninstall() {
        guard canUninstall, let action = uninstallAction else { return }
        start(action, input: nil)
    }

    private func start(_ action: CopyOutAction, input: Data?) {
        guard let teamID, let user, let payloadVersion else { return }
        let plan: CopyOutPlan
        do {
            plan = try CopyOutPlan(
                bundlePath: Bundle.main.bundlePath, payloadVersion: payloadVersion, teamID: teamID, user: user, action: action)
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

    /// Reads the installed worker's join target from its plist.
    private static func readJoinTarget() -> Result<ServerAddress, AgentJoinTarget.ReadError> {
        guard let data = FileManager.default.contents(atPath: AgentJoinTarget.plistPath) else {
            return .failure(.notAPlist)
        }
        do {
            return .success(try AgentJoinTarget.read(plist: data))
        } catch {
            return .failure(error)
        }
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
