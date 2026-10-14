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
    /// The worker's join target: the status report's `joinTarget`, or the
    /// installed plist when the report has none.
    @Published private(set) var joinTarget: Result<ServerAddress, AgentJoinTarget.ReadError>?
    /// The user's confirmation that every worker is updated (server only,
    /// while the status report carries no worker versions).
    @Published var workersConfirmed = false
    /// The uninstall form's purge checkbox.
    @Published var purge = false
    /// Whether the uninstall confirmation is showing. Held here rather than
    /// in view state: the Command Line Tools toolchain has no SwiftUI macro
    /// plugin, so the window uses no `@State`.
    @Published var confirmingUninstall = false
    /// Whether Stop, Start and Restart are offered; nil until first checked.
    @Published private(set) var lifecycleSupport: LifecycleSupport?

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
    /// or the report is unknown. The workers come from the report's `workers`
    /// list; an absent list or a worker without a version rests on the user's
    /// confirmation.
    var updateDecision: UpdateDecision? {
        guard let role, let payloadVersion else { return nil }
        return UpdatePolicy.decide(
            role: role, payload: payloadVersion, installed: installedVersion,
            workers: report?.workers?.map { NodeVersion(name: $0.name, version: $0.k3smRelease) },
            allowDowngrade: false, workersConfirmed: workersConfirmed)
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
    /// The uninstall the window would run.
    var uninstallAction: CopyOutAction { .uninstall(purge: purge) }
    var canUninstall: Bool { canRunPrivileged }

    /// The lifecycle state the window shows, from the last full report.
    var lifecycleState: LifecycleState { LifecycleState(report: report) }

    /// Whether a lifecycle verb may start now. It needs no payload: it runs
    /// the installed CLI, never the app's copy.
    var canRunLifecycle: Bool {
        !running && availability == .enabled && teamID != nil && lifecycleSupport == .available
    }

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
        joinTarget = role == .agent
            ? AgentJoinTarget.resolve(statusJoinTarget: report?.joinTarget, plist: Self.readPlist)
            : nil
        await refreshLifecycleSupport()
    }

    /// Re-detects whether the installed CLI has `k3sm stop`. The CLI is run
    /// (for its version) only after it passes the same root-owned and
    /// signature checks the lifecycle script makes; a developer build has no
    /// Team ID to check against and offers no lifecycle verb.
    func refreshLifecycleSupport() async {
        guard teamID != nil else {
            lifecycleSupport = .unavailable(note: LifecycleSupport.developerBuildNote)
            return
        }
        switch await runCLI(K3smCLI.versionArguments) {
        case .refused:
            // runCLI has already disabled the lifecycle verbs with the reason.
            return
        case .exited(0, let stdout):
            lifecycleSupport = LifecycleSupport.evaluate(
                trust: .trusted, version: SemanticVersion.fromVersionCommand(String(decoding: stdout, as: UTF8.self)))
        default:
            lifecycleSupport = LifecycleSupport.evaluate(trust: .trusted, version: nil)
        }
    }

    /// Reads the full report now, or nil when it cannot be read.
    func readFullReport() async -> StatusReport? {
        guard case .exited(_, let stdout) = await runCLI(K3smCLI.reportArguments) else { return nil }
        return try? StatusReport.decode(stdout)
    }

    /// Runs one lifecycle verb from the menu, the window or the login
    /// notification. `expected` is the state the user acted on. The driver
    /// re-reads the status, asks (naming the verb, with the Stop warning),
    /// re-reads again, and only then shows the administrator prompt.
    func perform(_ verb: LifecycleVerb, expected: LifecycleState) {
        guard !running else { return }
        Task {
            if lifecycleSupport == nil {
                await refreshLifecycleSupport()
            }
            guard canRunLifecycle, let teamID else {
                if case .unavailable(let note) = lifecycleSupport {
                    Self.alert(title: "k3sm cannot \(verb.rawValue) k3sm from the app", text: note)
                } else if case .disabled(let reason) = availability {
                    Self.alert(title: "k3sm cannot \(verb.rawValue) k3sm from the app", text: reason)
                }
                return
            }
            running = true
            outcomeMessage = nil
            let driver = LifecycleDriver(
                teamID: teamID,
                readStatus: { await self.readFullReport() },
                confirm: { Self.confirm($0) },
                runner: runner)
            let result = await driver.perform(verb, expected: expected)
            running = false
            switch result {
            case .declined:
                break
            case .refused(let why):
                outcomeMessage = why
                Self.alert(title: "Nothing was changed", text: why)
            case .ran(let outcome, let text):
                outcomeMessage = text
                if outcome != .succeeded, outcome != .cancelled {
                    Self.alert(title: verb.title, text: text)
                }
            }
            log.notice("lifecycle verb finished")
            await refresh()
        }
    }

    /// Asks before a lifecycle verb, naming it; the Stop warning is shown
    /// as critical.
    private static func confirm(_ c: LifecycleConfirmation) -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = c.title
        alert.informativeText = c.warning.map { $0 + "\n\n" + c.message } ?? c.message
        alert.alertStyle = c.warning == nil ? .informational : .critical
        alert.addButton(withTitle: c.verb.title)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Shows one sentence in an alert.
    static func alert(title: String, text: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
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

    /// Runs the uninstall, keeping the data unless purge is chosen.
    func submitUninstall() {
        guard canUninstall else { return }
        start(uninstallAction, input: nil)
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

    /// Runs the installed CLI unprivileged, after a trust check made just
    /// before this run (never a cached verdict). A refusal runs nothing and
    /// disables the lifecycle verbs with its reason.
    private func runCLI(_ arguments: [String]) async -> CLIOutcome {
        switch await cli.run(arguments) {
        case .ran(let outcome):
            return outcome
        case .refused(let why):
            lifecycleSupport = LifecycleSupport.evaluate(trust: .refused(why), version: nil)
            log.notice("installed k3sm failed its trust check; not run")
            return .refused(why)
        }
    }

    /// The trust-checked CLI every unprivileged run in the window and the
    /// lifecycle flow goes through.
    private var cli: TrustedCLI<CLIOutcome> {
        let teamID = teamID
        let environment = environment
        return TrustedCLI(
            check: { await Task.detached { SelfCheck.installedCLITrust(team: teamID) }.value },
            execute: { arguments in
                await CLIProcess.run(path: K3smCLI.path, arguments: arguments, environment: environment, deadline: PollSchedule.killDeadline)
            })
    }

    /// Reads the installed worker's LaunchDaemon plist, the join target's
    /// fallback source.
    private static func readPlist() -> Data? {
        FileManager.default.contents(atPath: AgentJoinTarget.plistPath)
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
