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
    /// Whether the console shows the status panel (start, stop, connections,
    /// uninstall): the info button and Settings… open it.
    @Published var statusPanelShown = false
    /// Which section the console shows in its middle column.
    @Published var section: ConsoleSection = .workloads
    /// The console panel's view the user chose (Cluster or This Mac), nil
    /// until they choose; kept in the user defaults across launches.
    /// `PanelMode.effective` decides what is shown.
    @Published var panelMode: PanelMode? = UserDefaults.standard.string(forKey: AppModel.panelModeKey).flatMap(PanelMode.init(rawValue:)) {
        didSet { UserDefaults.standard.set(panelMode?.rawValue, forKey: Self.panelModeKey) }
    }
    static let panelModeKey = "consolePanelMode"
    /// Whether the console shows the inspector (the selected pod's logs,
    /// events and manifest) on the right; the details button toggles it.
    /// Kept in the user defaults across launches; shown until hidden.
    @Published var inspectorShown: Bool = UserDefaults.standard.object(forKey: AppModel.inspectorShownKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(inspectorShown, forKey: Self.inspectorShownKey) }
    }
    static let inspectorShownKey = "consoleInspectorShown"
    /// The console's own state; it polls only while the console is on screen.
    let workloads: WorkloadsModel
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
    /// The last full report that decoded, and when it was read. It alone
    /// carries the daemon's applied state.
    @Published private(set) var lanReport: StatusReport?
    @Published private(set) var lanReadAt: Date?
    /// The last daemons probe that decoded, and when it was read. It carries
    /// the `network` object at the poll rate.
    @Published private(set) var lanProbe: StatusReport?
    @Published private(set) var lanProbeAt: Date?
    /// Whether the most recent read, full or probe, failed.
    @Published private(set) var lanReadFailed = false
    /// Why the installed CLI failed its trust check on the last run, if it did.
    @Published private(set) var lanTrustRefusal: String?

    let payloadVersion: SemanticVersion?
    private let teamID: TeamID?
    private let user: ConsoleUser?
    private let runner: any PrivilegedRunner
    private let environment: [String: String]
    /// The console's report loop; set only while the console is on screen.
    private var reportTask: Task<Void, Never>?
    /// How many `refresh()` calls are running, so a tick never doubles one.
    private var refreshesInFlight = 0

    init(runner: any PrivilegedRunner, environment: [String: String]) {
        self.runner = runner
        self.environment = environment
        self.workloads = WorkloadsModel(environment: environment)
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
    /// and, on a worker, its join target. The full report runs only here:
    /// when the window is shown, and on the console's report loop.
    func refresh() async {
        refreshesInFlight += 1
        defer { refreshesInFlight -= 1 }
        screen = FileManager.default.fileExists(atPath: K3smCLI.installRoot) ? .status : .firstRun
        guard screen == .status else {
            report = nil
            installedVersion = nil
            joinTarget = nil
            return
        }
        report = await fullRead()
        if case .exited(0, let stdout) = await runCLI(K3smCLI.versionArguments) {
            installedVersion = SemanticVersion.fromVersionCommand(String(decoding: stdout, as: UTF8.self))
        }
        joinTarget = role == .agent
            ? AgentJoinTarget.resolve(statusJoinTarget: report?.joinTarget, plist: Self.readPlist)
            : nil
        await refreshLifecycleSupport()
    }

    /// Starts re-reading the full report while the console is on screen, every
    /// `PollSchedule.consoleReportInterval`, one read at a time; a tick that
    /// finds a read in flight skips it. The first read waits one interval,
    /// since showing the window already refreshes. A second start is a no-op.
    func startReportPolling() {
        guard reportTask == nil else { return }
        reportTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: PollSchedule.consoleReportInterval)
                guard !Task.isCancelled, let self else { return }
                if self.refreshesInFlight == 0 {
                    await self.refresh()
                }
            }
        }
    }

    /// Stops the console's report loop when the console leaves the screen.
    func stopReportPolling() {
        reportTask?.cancel()
        reportTask = nil
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
        await fullRead()
    }

    /// Runs the full report through the trust-checked CLI and records it as
    /// the LAN setting's source: a decoded report and its time, or a failed
    /// read, or the trust refusal.
    private func fullRead() async -> StatusReport? {
        let outcome = await runCLI(K3smCLI.reportArguments)
        var decoded: StatusReport?
        switch outcome {
        case .refused(let why):
            lanTrustRefusal = why
        case .exited(_, let stdout):
            lanTrustRefusal = nil
            decoded = try? StatusReport.decode(stdout)
        default:
            lanTrustRefusal = nil
        }
        if let decoded {
            lanReport = decoded
            lanReadAt = Date()
            lanReadFailed = false
        } else {
            lanReadFailed = true
        }
        return decoded
    }

    /// Takes one poll result: a decoded daemons probe becomes the freshest
    /// source of the LAN setting; a failed one marks the read failed.
    func noteProbe(_ report: StatusReport?) {
        if let report {
            lanProbe = report
            lanProbeAt = Date()
            lanReadFailed = false
        } else {
            lanReadFailed = true
        }
    }

    /// The "Allow connections from other devices" checkbox as of `now`.
    func lanToggle(now: Date = Date()) -> LANToggle {
        var blocked: String?
        if running {
            blocked = "Another change is running."
        } else if teamID == nil {
            blocked = "This build of k3sm is not Developer ID signed, so it cannot change this setting. Use `sudo k3sm network lan on` or `off` in Terminal."
        } else if case .disabled(let reason) = availability {
            blocked = reason
        }
        let full = lanReport.flatMap { r in lanReadAt.map { (report: r, at: $0) } }
        let probe = lanProbe.flatMap { r in lanProbeAt.map { (report: r, at: $0) } }
        let source = LANSource.choose(full: full, probe: probe)
        return LANToggle.evaluate(
            report: source?.report, readAt: source?.at, now: now, lastReadFailed: lanReadFailed,
            trustRefusal: lanTrustRefusal, blocked: blocked)
    }

    /// Flips the LAN setting from the menu or the window. The verb comes
    /// from the value the user saw (`LANToggle.clickVerb`); the driver reads
    /// the status live, asks before turning it on, runs the verb's root
    /// script, and reads the status again. The checkbox then shows the value
    /// that read confirms, never the one the click asked for.
    func performLAN(_ verb: LifecycleVerb) {
        guard verb.isLAN, !running else { return }
        let toggle = lanToggle()
        guard toggle.enabled, toggle.clickVerb == verb, let teamID else {
            Self.alert(title: "k3sm cannot change this setting now", text: toggle.disabledReason ?? "Nothing was changed.")
            return
        }
        let expected: LANSetting = verb == .lanOn ? .off : .on
        Task {
            running = true
            outcomeMessage = nil
            let driver = LANDriver(
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
            case .ran(let outcome, let text, let confirmed):
                outcomeMessage = text
                let target: LANSetting = verb == .lanOn ? .on : .off
                if outcome != .cancelled, outcome != .succeeded || confirmed != target {
                    Self.alert(title: LANToggle.title, text: text)
                }
            }
            log.notice("LAN access verb finished")
        }
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
        let proceed = alert.addButton(withTitle: c.verb.title)
        let cancel = alert.addButton(withTitle: "Cancel")
        if c.cancelIsDefault {
            // Return answers Cancel; the verb needs a deliberate click.
            proceed.keyEquivalent = ""
            cancel.keyEquivalent = "\r"
            alert.window.initialFirstResponder = cancel
        }
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
