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
import K3smHost
import K3smInstall
import K3smStatus

/// AppModel is the window's state: which screen it shows, the last full
/// report, the guided first run, the update and uninstall choices, and a
/// running root step with its log.
@MainActor
final class AppModel: ObservableObject {
    enum Screen: Equatable {
        /// Nothing installed (`HealthState.showsFirstRun`): offer to start
        /// or join a cluster.
        case firstRun
        /// k3sm is installed, healthy or not: show its status.
        case status
    }

    /// How long the log tail waits between reads while a step runs.
    private static let tailInterval: Duration = .seconds(1)
    /// The most log text the window keeps.
    private static let tailBytes = 16 * 1024

    @Published private(set) var screen: Screen = .firstRun
    /// What the startup health check found on the last `refresh()`
    /// (`HealthClassifier`); nil until the first one finishes. It picks the
    /// screen; the console shows its line.
    @Published private(set) var health: HealthState?
    /// The guided panel on screen (a sheet over the console), the plan it
    /// was opened for; nil while it is closed. It keeps that plan while its
    /// step runs, so the finished line stays after the state changes.
    @Published private(set) var guidedPanel: GuidedPlan?
    /// The guided panel's step: idle, running, or how it ended.
    @Published private(set) var guidedRun: GuidedRun = .idle
    /// Whether the console shows the status panel (start, stop, connections,
    /// uninstall): the info button and Show Status open it. A change of screen
    /// closes it, so a Show Status chosen on the first-run screen does not open
    /// the popover by itself once the install finishes.
    @Published var statusPanelShown = false
    /// Which tab the console shows in its middle column, kept in the user
    /// defaults across launches (`ConsoleTabs.restore` reads it back). While
    /// the console is on screen, choosing a tab stops the one left and starts
    /// the one chosen; the pod list is the exception, kept reading at
    /// `PollSchedule.backgroundInterval` while another tab is selected, since
    /// the navy panel's pod figures come from it.
    @Published var section: ConsoleSection = ConsoleTabs.restore(
        from: UserDefaults.standard.object(forKey: ConsoleTabs.sectionKey)) {
        didSet {
            UserDefaults.standard.set(section.rawValue, forKey: ConsoleTabs.sectionKey)
            // The inspector follows the tab: the new tab's own selection, or
            // nothing, never the row of the tab just left.
            selection.switchTo(section, present: presentKeys(section))
            // The tab on screen times its label mark differently.
            waiting.changed()
            guard section != oldValue, consoleShown else { return }
            if oldValue != .workloads { loaders[oldValue]?.stop() }
            let chosen = loader(for: section)
            if section == .workloads {
                // Restarted, so it reads now and then at the tab's cadence
                // rather than finishing its background wait.
                chosen?.stop()
            }
            chosen?.start()
            syncEvents()
        }
    }
    /// The Workloads tab's sub-tab (its pods or the cluster's events), kept
    /// in the user defaults. The events are read only while this is Events,
    /// Workloads is the selected tab and the console is on screen.
    @Published var workloadsView: WorkloadsView = WorkloadsView.restore(
        from: UserDefaults.standard.object(forKey: WorkloadsView.key)) {
        didSet {
            UserDefaults.standard.set(workloadsView.rawValue, forKey: WorkloadsView.key)
            syncEvents()
            waiting.changed()
        }
    }
    /// The Events view's namespace filter, nil for every namespace; kept in
    /// the user defaults.
    @Published var eventsNamespace: String? = WorkloadsView.restoreNamespace(
        from: UserDefaults.standard.object(forKey: WorkloadsView.namespaceKey)) {
        didSet { UserDefaults.standard.set(eventsNamespace ?? "", forKey: WorkloadsView.namespaceKey) }
    }
    /// The search text of the Services, Storage and Models tabs, kept in the
    /// user defaults like the Workloads tab's.
    @Published var servicesQuery = ConsoleTabs.restoreQuery(
        from: UserDefaults.standard.object(forKey: ConsoleTabs.queryKey(.services))) {
        didSet { UserDefaults.standard.set(servicesQuery, forKey: ConsoleTabs.queryKey(.services)) }
    }
    @Published var storageQuery = ConsoleTabs.restoreQuery(
        from: UserDefaults.standard.object(forKey: ConsoleTabs.queryKey(.storage))) {
        didSet { UserDefaults.standard.set(storageQuery, forKey: ConsoleTabs.queryKey(.storage)) }
    }
    @Published var modelsQuery = ConsoleTabs.restoreQuery(
        from: UserDefaults.standard.object(forKey: ConsoleTabs.queryKey(.models))) {
        didSet { UserDefaults.standard.set(modelsQuery, forKey: ConsoleTabs.queryKey(.models)) }
    }
    /// The Nodes tab's search, kept in the user defaults like the Workloads tab's.
    @Published var nodesQuery = ConsoleTabs.restoreQuery(
        from: UserDefaults.standard.object(forKey: ConsoleTabs.queryKey(.nodes))) {
        didSet { UserDefaults.standard.set(nodesQuery, forKey: ConsoleTabs.queryKey(.nodes)) }
    }
    /// The Images tab's search, kept in the user defaults like the Workloads tab's.
    @Published var imagesQuery = ConsoleTabs.restoreQuery(
        from: UserDefaults.standard.object(forKey: ConsoleTabs.queryKey(.images))) {
        didSet { UserDefaults.standard.set(imagesQuery, forKey: ConsoleTabs.queryKey(.images)) }
    }
    /// The selected row of every tab and the active one (`ConsoleSelection`),
    /// what the inspector shows. Each tab's row but Workloads' is kept in the
    /// user defaults here; the Workloads row mirrors `WorkloadsModel.selected`,
    /// which keeps its own.
    @Published private(set) var selection = ConsoleSelection.restore(
        active: ConsoleTabs.restore(from: UserDefaults.standard.object(forKey: ConsoleTabs.sectionKey)),
        stored: { UserDefaults.standard.object(forKey: ConsoleTabs.selectedKey($0)) }) {
        didSet {
            for tab in ConsoleSection.allCases where tab != .workloads {
                let key = selection.selection(in: tab)?.key
                if key != oldValue.selection(in: tab)?.key {
                    UserDefaults.standard.set(key, forKey: ConsoleTabs.selectedKey(tab))
                }
            }
        }
    }
    /// Mirrors the pod selection into `selection`.
    private var podSelection: AnyCancellable?
    /// The Builds tab's engine read and its history read (`k3sm build ls`);
    /// each nil until the tab is first selected.
    @Published private(set) var builds: TabLoader<BuildEngine>?
    @Published private(set) var buildHistory: TabLoader<[BuildRecord]>?
    /// The build log sheet on screen; nil when none is.
    @Published private(set) var buildLog: BuildLogModel?
    /// The one log sheet's read: opening a log or closing the sheet stops the last.
    private let buildLogs = BuildLogSlot()
    /// The Services, Storage (its claim list and the data volume card) and
    /// Models reads, and the Workloads tab's Events read; each nil until
    /// its tab (or sub-tab) is first selected.
    @Published private(set) var services: TabLoader<[ServiceRow]>?
    @Published private(set) var storage: TabLoader<[StorageRow]>?
    @Published private(set) var dataVolume: TabLoader<DataVolume>?
    @Published private(set) var models: TabLoader<[ModelRow]>?
    @Published private(set) var events: TabLoader<[ClusterEvent]>?
    /// Each tab's loader, created on the tab's first selection. Images has
    /// none: it renders the shared node list.
    private var loaders: [ConsoleSection: any TabLoading] = [:]
    /// Whether the console is on screen, so a tab change starts its loader.
    private var consoleShown = false
    /// The console panel's view the user chose (Cluster or This Mac), nil
    /// until they choose; kept in the user defaults across launches.
    /// `PanelMode.effective` decides what is shown.
    @Published var panelMode: PanelMode? = UserDefaults.standard.string(forKey: AppModel.panelModeKey).flatMap(PanelMode.init(rawValue:)) {
        didSet { UserDefaults.standard.set(panelMode?.rawValue, forKey: Self.panelModeKey) }
    }
    static let panelModeKey = AppPreferences.panelModeKey
    /// Whether the console shows the inspector (the selected pod's logs,
    /// events and manifest) on the right; the details button toggles it.
    /// Kept in the user defaults across launches; shown until hidden.
    @Published var inspectorShown: Bool = UserDefaults.standard.object(forKey: AppModel.inspectorShownKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(inspectorShown, forKey: Self.inspectorShownKey) }
    }
    static let inspectorShownKey = AppPreferences.inspectorShownKey
    /// The console panel's width as the user last dragged it, or nil while
    /// the panel is auto-sized to its natural width (`PanelLayout.shownWidth`).
    /// Kept in the user defaults across launches (removed while auto) and
    /// clamped on read (`PanelLayout.restoreWidth`); the split view clamps it
    /// again to what the panel's content could use (`PanelLayout.widthRange`).
    @Published var consolePanelWidth: Double? = PanelLayout.restoreWidth(
        from: UserDefaults.standard.object(forKey: PanelLayout.widthKey)) {
        didSet {
            // A width narrower than the natural width lasts the session only.
            if let natural = consolePanelNatural,
               let saved = PanelLayout.persisted(consolePanelWidth, natural: natural) {
                UserDefaults.standard.set(saved, forKey: PanelLayout.widthKey)
            } else {
                UserDefaults.standard.removeObject(forKey: PanelLayout.widthKey)
            }
        }
    }
    /// The natural width the panel's width was last judged against, and
    /// whether the width is one dragged in this session (kept unsaved).
    private var consolePanelNatural: Double?
    private var consolePanelDragged = false

    /// A divider drag: the width stays for the session, saved only if it is
    /// not narrower than the natural width.
    func panelDragged(_ width: Double, natural: Double) {
        consolePanelNatural = natural
        let stored = PanelLayout.dragged(width, natural: natural)
        consolePanelDragged = stored != nil
        consolePanelWidth = stored
    }

    /// Judges the kept width against the natural width: a saved width
    /// narrower than it, or a session width it has grown past, is replaced
    /// by auto-sizing and the saved key cleared. Reset Window Layout sets nil.
    func reconcilePanelWidth(natural: Double) {
        let previous = consolePanelNatural
        consolePanelNatural = natural
        guard let width = consolePanelWidth else { return }
        if PanelLayout.replacesWidth(width, natural: natural, previousNatural: previous, session: consolePanelDragged) {
            consolePanelDragged = false
            consolePanelWidth = nil
        }
    }
    /// The widest block of the console panel's content as the panel last
    /// measured it (`PanelMeasure`), without its edges; nil before the first
    /// layout, when `PanelLayout.naturalWidth` estimates instead. Not kept.
    @Published private(set) var consolePanelMeasured: Double?

    /// Records a measured content width, only when it moved by a point or
    /// more, so a re-render that measures the same does not publish again.
    func panelMeasured(_ width: Double) {
        guard width.isFinite, width > 0 else { return }
        if let current = consolePanelMeasured, abs(current - width) < 1 { return }
        consolePanelMeasured = width
    }
    /// Whether the console panel is collapsed: a double-click on the divider
    /// and View > Hide Panel (Command-Option-L) toggle it. Kept across launches.
    @Published var consolePanelCollapsed: Bool = PanelLayout.restoreCollapsed(
        from: UserDefaults.standard.object(forKey: PanelLayout.collapsedKey)) {
        didSet { UserDefaults.standard.set(consolePanelCollapsed, forKey: PanelLayout.collapsedKey) }
    }
    /// The console's own state; it polls only while the console is on screen.
    let workloads: WorkloadsModel
    /// Every tab's writes: the one confirmation, the run and its report.
    let actions: ActionRunner
    /// The wordmark butterfly's wing beat, played while the console is up.
    let flap = FlapModel()
    /// Every tab's table column widths, as the user dragged them.
    let columns = ColumnsModel()
    /// Each tab's waiting butterfly, from the tabs' reads.
    let waiting = WaitingModel()
    /// Forwards the loaders' changes to `waiting`.
    private var waitingObservations: [AnyCancellable] = []
    /// The guided tour. It reads and sets the console layout it shows its
    /// stops in (the tab, the panel, its mode and the inspector) and puts the
    /// user's layout back when it ends.
    private(set) lazy var tour = TourModel(layout: TourLayoutAccess(
        read: { [unowned self] in
            Tour.Layout(section: section, workloadsView: workloadsView, panelCollapsed: consolePanelCollapsed, panelMode: panelMode, inspectorShown: inspectorShown)
        },
        apply: { [unowned self] layout in
            section = layout.section
            workloadsView = layout.workloadsView
            consolePanelCollapsed = layout.panelCollapsed
            panelMode = layout.panelMode
            inspectorShown = layout.inspectorShown
        },
        shape: { [unowned self] in ClusterDisplay.shape(of: report) }))
    @Published private(set) var report: StatusReport? {
        didSet { workloads.ownNode = WorkloadsDisplay.ownNode(in: report) }
    }
    @Published private(set) var installedVersion: SemanticVersion?
    @Published private(set) var availability: PrivilegedAvailability
    @Published var loginItemNeedsApproval = false
    @Published private(set) var running = false
    @Published private(set) var logTail = ""
    @Published private(set) var outcomeMessage: String?
    /// The first run's path (start or join) and its step (`FirstRunFlow`).
    @Published var choice: FirstRunPath = .start
    @Published private(set) var firstRunStep: FirstRunStep = .choose {
        didSet { if firstRunStep != oldValue { syncInstallWatch() } }
    }
    /// How the first run's install ended; nil before it ends.
    @Published private(set) var firstRunOutcome: FirstRunOutcome?
    /// Whether a developer build's install was opened in Terminal.
    @Published private(set) var firstRunInTerminal = false
    /// A developer build's wait for an install on the review step
    /// (`InstallWatch`): the butterfly's flight and the check at each
    /// arrival. Nil while the window does not wait.
    @Published private(set) var installWatch: InstallWatch?
    /// The loop that runs a check at each arrival.
    private var installWatchTask: Task<Void, Never>?
    /// Whether the window is on screen (the main window controller says).
    private var windowVisible = false
    /// The join step's one field: a pasted join command, or the address and
    /// token. Each change is read at once (`JoinCommandParser`); a paste that
    /// parses fills the address and token and empties the field, so the
    /// token stays only in `token`. Neither is ever logged.
    @Published var joinPaste = "" {
        didSet { readJoinPaste() }
    }
    /// Why the join field's text is not a join command; nil while it is
    /// empty or parsed.
    @Published private(set) var joinPasteError: String?
    /// The address read from the paste, checked again by `ServerAddress`.
    @Published private(set) var serverText = ""
    /// The token read from the paste; handed to the root step on stdin and
    /// cleared when the install starts.
    @Published private(set) var token = ""
    /// The worker's join target: the status report's `joinTarget`, or the
    /// installed plist when the report has none.
    @Published private(set) var joinTarget: Result<ServerAddress, AgentJoinTarget.ReadError>?
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
    @Published private(set) var lanReport: StatusReport? {
        didSet {
            syncUpdateReader()
            // The Stats tab's update chart follows the row in each report.
            if let lanReport { workloads.noteUpdate(lanReport, at: Date()) }
        }
    }
    @Published private(set) var lanReadAt: Date?
    /// The last daemons probe that decoded, and when it was read. It carries
    /// the `network` object at the poll rate.
    @Published private(set) var lanProbe: StatusReport?
    @Published private(set) var lanProbeAt: Date?
    /// Whether the most recent read, full or probe, failed.
    @Published private(set) var lanReadFailed = false
    /// Why the installed CLI failed its trust check on the last run, if it did.
    @Published private(set) var lanTrustRefusal: String?
    /// The managed update as the app follows it (`UpdateProgress`).
    @Published private(set) var updateProgress = UpdateProgress() {
        didSet { syncUpdateReader() }
    }
    /// The `k3sm update status -o json` read, created on first need and run
    /// only while `UpdateProgress.readsStatus` says so.
    private var updateStatus: TabLoader<UpdateStatus>?

    let payloadVersion: SemanticVersion?
    /// The version the app shows for itself.
    let appVersion: AppVersion
    /// The k3sm in the bundle's payload, for a Terminal install; nil when
    /// the bundle carries none.
    private let payloadCLI: TerminalScript.Payload?
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
        let teamID = SelfCheck.teamID()
        self.teamID = teamID
        self.workloads = WorkloadsModel(environment: environment)
        self.actions = ActionRunner(environment: environment, teamID: teamID)
        self.user = SelfCheck.consoleUser()
        self.payloadVersion = SelfCheck.payloadVersion()
        self.appVersion = SelfCheck.appVersion()
        self.payloadCLI = SelfCheck.payloadCLI()
        var availability = SelfCheck.availability()
        if availability == .enabled, user == nil {
            availability = .disabled(reason: "k3sm could not read a non-root account name for this user, so it cannot install k3sm.")
        }
        self.availability = availability
        // The shared node list follows the selected tab's cadence.
        workloads.nodeList.interval = { [weak self] _ in
            guard let self else { return PollSchedule.visibleInterval }
            return PollSchedule.interval(for: self.section, engineReady: self.engineReady)
        }
        // The waiting butterflies follow each tab's own read: the pod list,
        // the shared node list (Images) and the engine read (Builds).
        waiting.load = { [weak self] section in
            guard let self else { return nil }
            switch section {
            case .workloads:
                return self.workloadsView == .events ? self.events?.load : self.workloads.pods?.load
            case .nodes, .images: return self.workloads.nodeList.load
            case .builds: return self.builds?.load
            case .services: return self.services?.load
            case .storage: return self.storage?.load
            case .models: return self.models?.load
            case .stats: return nil
            }
        }
        waiting.selected = { [weak self] in self?.section }
        waitingObservations.append(workloads.objectWillChange.sink { [weak self] _ in
            MainActor.assumeIsolated { self?.waiting.changed() }
        })
        // A decoded node list keeps the Nodes and Images selections only
        // while the node or image each names is still listed, as each
        // pod-list read does for the Workloads selection.
        workloads.onNodesRead = { [weak self] in
            guard let self else { return }
            let failed = self.workloads.nodeList.load.failedOrUnavailable
            self.retainSelection(.nodes)
            self.actions.tabRead(.nodes, succeeded: !failed)
            self.actions.tabRead(.images, succeeded: !failed)
            guard let read = self.workloads.nodeList.value,
                  let selected = self.selection.selection(in: .images) else { return }
            if ImagesList.selection(after: selected.key, in: read.images) == nil { self.selection.clear(.images) }
        }
        // The Workloads tab's row is the pod `WorkloadsModel` selects.
        podSelection = workloads.$selected.sink { [weak self] key in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let key {
                    self.selection.select(.pod(key), in: .workloads)
                } else {
                    self.selection.clear(.workloads)
                }
            }
        }
        // An action's report follows its tab's reads, and the tab is read
        // again after each action on one of its rows.
        workloads.onPodsRead = { [weak self] ok in self?.actions.tabRead(.workloads, succeeded: ok) }
        actions.refresh = { [weak self] section in
            guard let self else { return }
            if let loader = self.loader(for: section) {
                await loader.refresh()
            } else if section == .images || section == .nodes {
                await self.workloads.nodeList.refresh()
            }
        }
        // The Builds tab's Show Log opens the log sheet.
        LocalActions.showBuildLog = { [weak self] target in self?.showBuildLog(target) }
        // An unfinished or failed earlier run is the first thing the window
        // shows on relaunch.
        let previous = Self.readLog()
        if !previous.isEmpty, CopyOutOutcome(log: previous) != .succeeded {
            logTail = previous
        }
    }

    /// The join step's address problem, if the pasted address is not valid.
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

    /// The join address the paste gave, when it is valid.
    var joinAddress: ServerAddress? {
        try? ServerAddress(parsing: serverText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Whether the join step has an address and a token to go on with.
    var joinReady: Bool { joinAddress != nil && !token.isEmpty }

    /// Whether Continue is enabled on the current first-run step.
    var firstRunCanContinue: Bool {
        guard FirstRunFlow.next(after: firstRunStep, path: choice) != nil else { return false }
        return firstRunStep != .join || joinReady
    }

    /// The review step for the current path (`FirstRunFlow.review`).
    var firstRunReview: FirstRunReview {
        let address = choice == .join ? joinAddress : nil
        return FirstRunFlow.review(path: choice, server: address?.description, serverArgument: address?.argument,
                                   developerBuild: teamID == nil, payload: payloadVersion, payloadCLI: payloadCLI)
    }

    /// Why the review step's install button is disabled, nil when it can run.
    var firstRunInstallDisabledReason: String? {
        if running { return "Another change is running." }
        if case .disabled(let reason) = availability { return reason }
        if payloadVersion == nil { return "This build of the app carries no k3sm release, so it cannot install one." }
        if choice == .join && !joinReady { return "Paste the address and token first." }
        return nil
    }

    /// Reads the join field. Any new text first forgets the last paste's
    /// address and token; text that parses fills them and empties the field.
    private func readJoinPaste() {
        guard !joinPaste.isEmpty else { return }
        serverText = ""
        token = ""
        switch JoinCommandParser.parse(joinPaste) {
        case .success(let paste):
            serverText = paste.server
            token = paste.token
            joinPasteError = addressError
            joinPaste = ""
        case .failure(let error):
            joinPasteError = error.message
        }
    }

    /// Forgets the pasted address and token.
    func clearJoinPaste() {
        joinPaste = ""
        serverText = ""
        token = ""
        joinPasteError = nil
    }

    /// Continue: the next step of the first run.
    func firstRunContinue() {
        guard firstRunCanContinue, let next = FirstRunFlow.next(after: firstRunStep, path: choice) else { return }
        firstRunStep = next
    }

    /// Back: the step before, which keeps what was entered.
    func firstRunBack() {
        guard !running, let previous = FirstRunFlow.previous(before: firstRunStep, path: choice) else { return }
        firstRunStep = previous
    }

    /// Install in Terminal, a developer build's install: opens the review's
    /// script in Terminal. The review's install watch, already running,
    /// sees k3sm come up and moves to the finished step.
    func firstRunInstallInTerminal() {
        guard firstRunStep == .review, teamID == nil, let script = firstRunReview.terminalScript,
              MenuActions.openInTerminal(script) else { return }
        firstRunInTerminal = true
    }

    /// The window came on screen or went away; the install watch runs only
    /// while it is shown.
    func setWindowVisible(_ visible: Bool) {
        windowVisible = visible
        syncInstallWatch()
    }

    /// Check Again on the first run: with the install watch running, lands
    /// the butterfly and checks now (never beside a running check), and the
    /// next flight starts when it returns; otherwise a plain refresh.
    func checkAgain() {
        guard installWatch != nil else {
            Task { await refresh() }
            return
        }
        if installWatch?.checkNow(now: Self.uptime) == true {
            Task { await runInstallCheck() }
        }
    }

    private static var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Starts or stops the install watch to match `InstallWatch.waits`.
    private func syncInstallWatch() {
        let wanted = InstallWatch.waits(developerBuild: teamID == nil, firstRunShown: screen == .firstRun,
                                        step: firstRunStep, windowVisible: windowVisible)
        if wanted, installWatchTask == nil {
            installWatch = InstallWatch(now: Self.uptime)
            installWatchTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self, let arrival = self.installWatch?.arrival else {
                        try? await Task.sleep(for: .milliseconds(100))
                        continue
                    }
                    let wait = max(0, arrival - Self.uptime)
                    if wait > 0 { try? await Task.sleep(for: .seconds(min(wait, 0.25))) }
                    guard !Task.isCancelled else { return }
                    if self.installWatch?.arrive(now: Self.uptime) == true {
                        await self.runInstallCheck()
                    }
                }
            }
        } else if !wanted, installWatchTask != nil {
            installWatchTask?.cancel()
            installWatchTask = nil
            installWatch = nil
            firstRunInTerminal = false
        }
    }

    /// One check: the health check read again, then the next flight, or the
    /// finished step once k3sm is up (the console opens on it).
    private func runInstallCheck() async {
        await refresh()
        guard installWatch != nil else { return }
        if installWatch?.end(state: health, now: Self.uptime) == true {
            firstRunOutcome = .succeeded
            firstRunStep = .finished
            // The step change ended the watch (and cancelled this loop), so the
            // screen follows the health check again on a read of its own.
            Task { await self.refresh() }
        }
    }

    /// Try Again: back to the review, or for a join to the join step, since
    /// the token went to the failed run.
    func firstRunTryAgain() {
        guard !running else { return }
        firstRunOutcome = nil
        firstRunStep = FirstRunFlow.retryStep(for: choice)
    }

    /// Puts the first run back on its first step, as a new install begins.
    private func resetFirstRun() {
        firstRunStep = .choose
        firstRunOutcome = nil
        clearJoinPaste()
    }

    /// The installed role, from the full report.
    var role: NodeRole? {
        report.flatMap(NodeRole.detect(in:))
    }

    /// What the update plan reads (`UpdatePlanFacts`): the last full report,
    /// the managed update's progress, the two versions, the node list, the
    /// worker's join target, and whether a root step may run now.
    var updatePlanFacts: UpdatePlanFacts {
        var refusal: String?
        if running {
            refusal = "Another change is running."
        } else if case .disabled(let reason) = availability {
            refusal = reason
        }
        let managedRefusal = lanTrustRefusal.map {
            "The app will not run the installed k3sm as root: \($0). Use `sudo k3sm update apply` in Terminal."
        }
        var joinTargetReadable = true
        if case .failure = joinTarget { joinTargetReadable = false }
        return UpdatePlanFacts(
            report: lanReport ?? report, progress: updateProgress, installed: installedVersion, payload: payloadVersion,
            nodes: workloads.nodes, joinTargetReadable: joinTargetReadable, developerBuild: teamID == nil,
            refusal: refusal, managedRefusal: managedRefusal)
    }

    /// The one update plan every Update control reads: the status item's
    /// menu, the console strip's button, the popover's version line, the
    /// Settings Updates pane, the node inspector and the guided panel.
    var updatePlan: UpdatePlan { UpdatePlan.decide(updatePlanFacts) }

    /// The app-carried update's copy-out for the plan's payload path, or nil
    /// when the plan is not that path. `UpdatePolicy`, the root step's own
    /// rollout rule, must agree (a worker any time, a server only with no
    /// other node), and a worker needs the address it joins, read now when
    /// the window has not read it.
    private var payloadUpdateAction: CopyOutAction? {
        let facts = updatePlanFacts
        guard case .payload(let payload) = UpdatePlan.decide(facts), let role = facts.role else { return nil }
        let decision = UpdatePolicy.decide(
            role: role, payload: payload, installed: facts.installed,
            workers: (lanReport ?? report)?.workers?.map { NodeVersion(name: $0.name, version: $0.k3smRelease) },
            allowDowngrade: false)
        guard decision.verdict == .offer else { return nil }
        switch role {
        case .server: return .update(.server)
        case .agent:
            let target = joinTarget
                ?? AgentJoinTarget.resolve(statusJoinTarget: (lanReport ?? report)?.joinTarget, plist: Self.readPlist)
            guard case .success(let server) = target else { return nil }
            return .update(.agent(joinServer: server))
        }
    }
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

    /// The banner and guided panel for the current health state
    /// (`GuidedSteps`), nil when healthy or before the first check. A build
    /// with no Team ID pin cannot run the root step, so its plan shows the
    /// Terminal command instead.
    var guidedPlan: GuidedPlan? {
        health.flatMap {
            GuidedSteps.plan(for: $0, rootStep: teamID != nil, role: role, payload: payloadVersion, payloadCLI: payloadCLI)
        }
    }

    /// Why the guided panel's Update cannot run, from the one update plan;
    /// nil when it can.
    var guidedUpdateReason: String? {
        let plan = updatePlan
        if plan.isEnabled { return nil }
        return plan.disabledReason ?? UpdatePlan.nothingToUpdate
    }

    /// Why the guided panel's primary button is disabled, nil when it can run.
    func guidedDisabledReason(_ action: GuidedAction) -> String? {
        if running { return "Another change is running." }
        guard action.needsRootStep else { return nil }
        if case .disabled(let reason) = availability { return reason }
        switch action {
        case .start, .restart:
            if case .unavailable(let note) = lifecycleSupport { return note }
        case .update:
            return guidedUpdateReason
        case .repair:
            return repairRefusal?.text
        case .refresh:
            break
        }
        return nil
    }

    /// Why Repair cannot run now (`RepairPolicy`), nil when it can.
    var repairRefusal: RepairRefusal? {
        RepairPolicy.refusal(health: health, rootStep: teamID != nil, payload: payloadVersion)
    }

    /// Opens the guided panel for the current state.
    func openGuided() {
        guard let plan = guidedPlan else { return }
        if !guidedRun.isRunning { guidedRun = .idle }
        guidedPanel = plan
        Task { await refreshLifecycleSupport() }
    }

    /// Closes the guided panel. A running step keeps running; its outcome
    /// still reaches the status popover.
    func closeGuided() {
        guidedPanel = nil
    }

    /// Runs a guided panel step through the existing path: Start and Restart
    /// through `perform` (the lifecycle driver's confirmation and the checked
    /// root step), Update through the one update plan, Repair through the
    /// same copy-out after its own confirmation, Refresh through `refresh`.
    func runGuided(_ action: GuidedAction) {
        guard !guidedRun.isRunning, !running else { return }
        if let reason = guidedDisabledReason(action) {
            guidedRun = .finished(action, succeeded: false, message: reason)
            return
        }
        guidedRun = .running(action)
        let finish: (Bool?, String) -> Void = { [weak self] succeeded, message in
            guard let self else { return }
            // nil: the user answered no at the confirmation; nothing ran.
            self.guidedRun = succeeded.map { .finished(action, succeeded: $0, message: message) } ?? .idle
        }
        switch action {
        case .start: perform(.start, expected: .stopped, finished: finish)
        case .restart: perform(.restart, expected: .running, finished: finish)
        case .update:
            performUpdate(finished: finish)
        case .repair:
            guard let payloadVersion else {
                finish(false, RepairRefusal.payloadUnknown.text)
                return
            }
            // No: nothing ran, and the panel goes back to idle.
            guard Self.confirmRepair(RepairConfirmation(payload: payloadVersion, role: role)) else {
                finish(nil, "")
                return
            }
            start(.repair, input: nil, finished: finish)
        case .refresh:
            Task {
                await refresh()
                if health == .statusUnreadable {
                    finish(false, HealthState.statusUnreadable.line ?? "")
                } else {
                    finish(true, health?.line ?? "k3sm's status reads again.")
                }
            }
        }
    }

    /// Re-reads which screen applies, the full report, the installed version
    /// and, on a worker, its join target. The full report runs only here:
    /// when the window is shown, and on the console's report loop. The
    /// screen follows the health check (`HealthClassifier`) over the file
    /// facts, the trust check, the report and the versions: the first run
    /// only when nothing is installed, the console for every other state.
    func refresh() async {
        refreshesInFlight += 1
        defer { refreshesInFlight -= 1 }
        let files = await Task.detached { SelfCheck.installFiles() }.value
        var trust: HealthFacts.CLITrust = .unchecked
        var read: StatusReport?
        if files.rootExists {
            read = await fullRead()
            trust = lanTrustRefusal.map { .refused($0) } ?? .trusted
            if case .exited(0, let stdout) = await runCLI(K3smCLI.versionArguments) {
                installedVersion = SemanticVersion.fromVersionCommand(String(decoding: stdout, as: UTF8.self))
            }
        }
        let state = HealthClassifier.classify(HealthFacts(
            installRootExists: files.rootExists, cliPresent: files.cliPresent, cliTrust: trust, report: read,
            payloadVersion: payloadVersion, installedVersion: files.rootExists ? installedVersion : nil))
        if state != health { health = state }
        // While the install watch runs, the first run holds the screen until
        // the watch decides k3sm is up, so a half-started install does not
        // flash the console.
        let next: Screen = state.showsFirstRun || installWatchTask != nil ? .firstRun : .status
        if next != screen {
            screen = next
            syncInstallWatch()
            statusPanelShown = false
            if next == .firstRun, !running { resetFirstRun() }
        }
        guard screen == .status else {
            report = nil
            installedVersion = nil
            joinTarget = nil
            return
        }
        report = read
        joinTarget = role == .agent
            ? AgentJoinTarget.resolve(statusJoinTarget: report?.joinTarget, plist: Self.readPlist)
            : nil
        await refreshLifecycleSupport()
    }

    /// Selects a row on its own tab, for the inspector.
    func select(_ row: ConsoleRow) {
        selection.select(row, in: row.section)
    }

    /// Whether `row` is its tab's selected row.
    func isSelected(_ row: ConsoleRow) -> Bool {
        selection.selection(in: row.section) == row
    }

    /// The keys a tab's last read listed, nil while it has nothing decoded
    /// (a tab not read yet keeps its stored row until its read). Workloads
    /// is nil: `WorkloadsModel` decides its selection.
    private func presentKeys(_ section: ConsoleSection) -> Set<String>? {
        switch section {
        case .workloads: return nil
        case .nodes: return NodesList.keys(workloads.nodes)
        case .images: return workloads.nodeList.value.flatMap { InspectorDetails.keys(images: $0.images) }
        case .builds:
            guard let history = buildHistory?.value else { return nil }
            return InspectorDetails.keys(engine: builds?.value, history: history)
        case .services: return services?.value.map { Set($0.map(\.key)) }
        case .storage: return storage?.value.map { Set($0.map(\.key)) }
        case .models: return models?.value.map { Set($0.map(\.key)) }
        case .stats: return []
        }
    }

    /// What a tab's read does to its selection: kept while its row is
    /// listed, cleared otherwise, a failed read included.
    private func retainSelection(_ section: ConsoleSection) {
        selection.retain(section, present: presentKeys(section) ?? [])
    }

    /// Whether the last engine read found it ready.
    private var engineReady: Bool { builds?.value?.state == .ready }

    /// The loader behind a tab, created on its first selection; nil for
    /// Nodes and Images, which render the shared node list. Stats has the
    /// Storage tab's loader (its claims and data volume reads); its other
    /// charts render what the other reads fetched.
    private func loader(for section: ConsoleSection) -> (any TabLoading)? {
        if let existing = loaders[section] { return existing }
        let made: (any TabLoading)?
        switch section {
        case .workloads:
            let pods = workloads.podsLoader()
            pods.interval = { [weak self] _ in PollSchedule.podsInterval(selected: self?.section == .workloads) }
            made = pods
        case .nodes, .images:
            made = nil
        case .stats:
            // The Storage tab's own loader, the same reads at the same
            // cadence, so the storage chart fills while Stats is shown; it
            // starts and stops with Stats like any tab's loader.
            made = loader(for: .storage)
        case .builds:
            let engine = observed(TabLoader(
                arguments: K3smCLI.buildEngineArguments, what: "build engine list", environment: environment,
                decode: BuildEngine.tabResult(exitCode:stdout:),
                interval: { PollSchedule.interval(for: .builds, engineReady: $0?.state == .ready) }))
            let history = TabLoader(
                arguments: K3smCLI.buildHistoryArguments, what: "build history", environment: environment,
                decode: BuildHistory.tabResult(exitCode:stdout:),
                interval: { [weak self] _ in PollSchedule.interval(for: .builds, engineReady: self?.engineReady ?? false) })
            builds = reportedBuilds(engine)
            buildHistory = reportedBuilds(history)
            made = TabLoaderGroup([engine, history])
        case .services:
            let environment = environment
            let list = observed(TabLoader<[ServiceRow]>(
                read: { await ServicesRead.read(environment: environment) },
                interval: { _ in PollSchedule.interval(for: .services, engineReady: false) }))
            services = reported(list, .services)
            made = list
        case .storage:
            let claims = observed(TabLoader(
                arguments: K3smCLI.storageArguments, what: "volume claim list", environment: environment,
                decode: StorageList.tabResult(exitCode:stdout:),
                interval: { _ in PollSchedule.interval(for: .storage, engineReady: false) }))
            let volume = TabLoader(
                arguments: K3smCLI.dataVolumeArguments, what: "data volume report", environment: environment,
                decode: DataVolume.tabResult(exitCode:stdout:),
                interval: { _ in PollSchedule.interval(for: .storage, engineReady: false) })
            storage = reported(claims, .storage)
            dataVolume = volume
            made = TabLoaderGroup([claims, volume])
        case .models:
            let environment = environment
            let list = observed(TabLoader<[ModelRow]>(
                read: { await Self.readModels(environment: environment) },
                interval: { _ in PollSchedule.interval(for: .models, engineReady: false) }))
            models = reported(list, .models)
            made = list
        }
        loaders[section] = made
        return made
    }

    /// Hands a tab loader's finished reads to the tab's selection
    /// (`retainSelection`) and to the action runner, whose report clears on
    /// its tab's next good read.
    private func reported<Value>(_ loader: TabLoader<Value>, _ section: ConsoleSection) -> TabLoader<Value> {
        loader.onRead = { [weak self, weak loader] in
            guard let self, let loader else { return }
            self.retainSelection(section)
            self.actions.tabRead(section, succeeded: !loader.load.failedOrUnavailable)
        }
        return loader
    }

    /// The Builds tab's two reads hand their finished reads on like
    /// `reported`, but a read keeps or clears the tab's selection only once
    /// both have decoded (`presentKeys`), or when it failed, so a history
    /// row restored at launch is not cleared by the engine's first read.
    private func reportedBuilds<Value>(_ loader: TabLoader<Value>) -> TabLoader<Value> {
        loader.onRead = { [weak self, weak loader] in
            guard let self, let loader else { return }
            let failed = loader.load.failedOrUnavailable
            if failed || self.presentKeys(.builds) != nil { self.retainSelection(.builds) }
            self.actions.tabRead(.builds, succeeded: !failed)
        }
        return loader
    }

    /// The bulk actions the selected tab's header row offers (`TabHeader`):
    /// Workloads the cleanup (`PodCleanup`) while it shows its pods, Storage
    /// its volume cleanup while a volume is unused, and Builds the build
    /// engine's (`BuildActions.toolbar`); the other tabs none.
    var bulkActions: [ActionMenuItem] {
        switch section {
        case .workloads:
            return workloadsView == .pods ? PodCleanup.bulkActions(for: workloads.workloads?.pods) : []
        case .storage:
            return storage?.value.flatMap(StorageActions.cleanupRequest).map { [ActionMenuItem($0)] } ?? []
        case .builds: return BuildActions.toolbar(builds?.value)
        case .nodes, .images, .services, .models, .stats: return []
        }
    }

    /// One row's actions: what its context menu, its inspector body and the
    /// Delete key offer, the one function per kind every tab reads (the
    /// build engine's actions are the Builds header row's; a build row offers
    /// its own). A tab's actions arrive as a case here.
    func rowMenu(_ row: ConsoleRow) -> ActionMenu {
        switch row {
        case .pod(let key):
            return workloads.workloads?.pods.first { $0.key == key }.map(PodActions.menu(for:)) ?? .empty
        case .node(let key):
            return workloads.nodes?.first { $0.name == key }.map(NodeActions.menu(for:)) ?? .empty
        case .service(let key):
            return services?.value?.first { $0.key == key }.map(ServiceActions.menu(for:)) ?? .empty
        case .model(let key):
            return models?.value?.first { $0.key == key }.map(ModelActions.menu(for:)) ?? .empty
        case .claim(let key):
            let pods = workloads.workloads?.pods
            return storage?.value?.first { $0.key == key }.map { StorageActions.menu(for: $0, pods: pods) } ?? .empty
        case .build(let key):
            guard key != InspectorDetails.engineRow,
                  let record = buildHistory?.value?.first(where: { $0.key == key }) else { return .empty }
            return BuildActions.menu(for: record)
        case .image, .stat:
            return .empty
        }
    }

    /// Opens a recorded build's log sheet, replacing any other
    /// (`LocalAction.showBuildLog`, through `LocalActions`).
    func showBuildLog(_ target: BuildLogTarget) {
        let log = BuildLogModel(read: buildLogs.open(target))
        buildLog = log
        log.start(environment: environment, teamID: teamID)
    }

    /// Closes the log sheet and stops its read.
    func closeBuildLog() {
        buildLogs.close()
        buildLog = nil
    }

    /// The selected row's actions on the selected tab (the Workloads tab's
    /// only while it shows its pods).
    var selectedRowMenu: ActionMenu {
        if section == .workloads, workloadsView != .pods { return .empty }
        return selection.current.map(rowMenu) ?? .empty
    }

    /// The Delete key on the selected row: asks for its delete action
    /// (`ActionMenu.deleteKeyItem`, never a Restart) behind the same
    /// confirmation, when it offers one. Returns whether it
    /// did, so the key is consumed only then.
    func deleteKey() -> Bool {
        guard screen == .status, !actions.busy, actions.pending == nil,
              let item = selectedRowMenu.deleteKeyItem else { return false }
        actions.ask(item.request)
        return true
    }

    /// Forwards a loader's changes to the waiting butterflies.
    private func observed<Value>(_ loader: TabLoader<Value>) -> TabLoader<Value> {
        waitingObservations.append(loader.objectWillChange.sink { [weak self] _ in
            MainActor.assumeIsolated { self?.waiting.changed() }
        })
        return loader
    }

    /// The Models tab's read: the list, and, only when it fails, discovery,
    /// so a cluster without the MLX API reads as unavailable rather than
    /// failed (`ModelsList.tabResult`).
    private nonisolated static func readModels(environment: [String: String]) async -> TabResult<[ModelRow]> {
        let list = await TabLoader<[ModelRow]>.run(arguments: K3smCLI.modelsArguments, environment: environment)
        guard case .exited(let status, let stdout) = list, ModelsList.needsDiscovery(listExit: status), !Task.isCancelled else {
            return TabLoader<[ModelRow]>.result(of: list, what: "model list") {
                ModelsList.tabResult(listExit: $0, listStdout: $1, discovery: nil)
            }
        }
        var discovery: (exit: Int32, stdout: Data)?
        if case .exited(let code, let out) = await TabLoader<[ModelRow]>.run(
            arguments: K3smCLI.modelsDiscoveryArguments, environment: environment) {
            discovery = (code, out)
        }
        return ModelsList.tabResult(listExit: status, listStdout: stdout, discovery: discovery)
    }

    /// One read of the cluster's MLXModels, for the demo tour's
    /// `waitFor modelReady`: nil when the read failed or the API is absent.
    func readModelsOnce() async -> [ModelRow]? {
        if case .value(let rows) = await Self.readModels(environment: environment) { return rows }
        return nil
    }

    /// The Events read, created on the sub-tab's first selection.
    private func eventsLoader() -> TabLoader<[ClusterEvent]> {
        if let events { return events }
        let made = observed(TabLoader(
            arguments: K3smCLI.eventsArguments, what: "event list", environment: environment,
            decode: EventsList.tabResult(exitCode:stdout:),
            interval: { _ in PollSchedule.eventsInterval }))
        events = made
        return made
    }

    /// Whether the events are read: only while the console is on screen
    /// with Workloads selected and its Events sub-tab chosen.
    private var eventsWanted: Bool {
        consoleShown && section == .workloads && workloadsView == .events
    }

    /// Starts or stops the Events read to match `eventsWanted`.
    private func syncEvents() {
        if eventsWanted {
            eventsLoader().start()
        } else {
            events?.stop()
        }
    }

    /// Starts the console's reads when it comes on screen: the shared node
    /// list, the pod list (the panel's figures, at the background cadence
    /// unless Workloads is selected) and the selected tab's loader. A second
    /// start is a no-op.
    func startTabs() {
        consoleShown = true
        syncUpdateReader()
        workloads.nodeList.start()
        workloads.startMetrics { [weak self] in self?.flap.windowVisible() ?? false }
        loader(for: .workloads)?.start()
        loader(for: section)?.start()
        syncEvents()
    }

    /// Stops the console's reads when it leaves the screen; each tab keeps
    /// its last value.
    func stopTabs() {
        consoleShown = false
        syncUpdateReader()
        workloads.nodeList.stop()
        workloads.stopMetrics()
        loaders[.workloads]?.stop()
        loaders[section]?.stop()
        syncEvents()
        waiting.stop()
    }

    // MARK: the managed update

    /// Starts or stops the update status read. While a roll is followed it
    /// reads whether or not the window is open, so the menu's "Updating…"
    /// ends when the roll does; while idle it reads only with the console on
    /// screen and an update offered, to find a roll started in Terminal.
    private func syncUpdateReader() {
        let offered: Bool
        if case .available = UpdateOffer.decide(report: lanReport, progress: updateProgress) {
            offered = consoleShown
        } else {
            offered = false
        }
        if updateProgress.readsStatus(offerShown: offered, rowRolling: UpdateOffer.rowRolling(in: lanReport)) {
            updateLoader().start()
        } else {
            updateStatus?.stop()
        }
    }

    private func updateLoader() -> TabLoader<UpdateStatus> {
        if let updateStatus { return updateStatus }
        let loader = TabLoader(
            arguments: K3smCLI.updateStatusArguments, what: "update status", environment: environment,
            decode: UpdateStatus.tabResult(exitCode:stdout:),
            interval: { _ in PollSchedule.updateStatusInterval })
        loader.onRead = { [weak self] in
            guard let self, let status = self.updateStatus?.value else { return }
            var next = self.updateProgress
            next.read(status)
            if next != self.updateProgress { self.updateProgress = next }
        }
        updateStatus = loader
        return loader
    }

    /// Reads the update status once, when an update is offered, so the menu
    /// finds a roll started in Terminal.
    func refreshUpdateStatus() async {
        guard ManagedUpdateState(report: lanReport, progress: updateProgress) != .nothingNewer
            || UpdateOffer.rowRolling(in: lanReport) else { return }
        await updateLoader().refresh()
    }

    /// Runs the update the one plan decides, from every Update control: the
    /// managed roll through `applyManagedUpdate`, pinned to the latest release
    /// or, for the nodes behind the server (the catch-up), to the server's own
    /// release; the app-carried update of this Mac through the copy-out. A blocked path says why and runs
    /// nothing. `finished`, when given, hears how it ended (nil: the user
    /// answered no and nothing ran).
    func performUpdate(finished: ((Bool?, String) -> Void)? = nil) {
        let plan = updatePlan
        switch plan {
        case .managed(let tag):
            applyManagedUpdate(tag: tag, target: .latest, finished: finished)
        case .catchUp(let tag, _):
            applyManagedUpdate(tag: tag, target: .serverRelease, finished: finished)
        case .payload:
            guard let action = payloadUpdateAction else {
                finished?(false, UpdateBlock.joinTargetUnknownText)
                return
            }
            start(action, input: nil, finished: finished)
        case .blocked(let block):
            if finished == nil, block.path != nil {
                Self.alert(title: "k3sm cannot update k3sm from the app", text: block.sentence)
            }
            finished?(false, block.sentence)
        case .rolling, .none:
            finished?(false, plan.disabledReason ?? UpdatePlan.nothingToUpdate)
        }
    }

    /// Runs `k3sm update apply --yes` for `tag` through the checked root
    /// step, with the update options as stored at the click, guarded by the
    /// check `target` names.
    private func applyManagedUpdate(tag: String, target: UpdateTarget, finished: ((Bool?, String) -> Void)?) {
        guard let teamID else {
            finished?(false, UpdateBlock.managedDeveloperBuild)
            return
        }
        // Read once, at the click; the driver freezes them for the question
        // and the run, so a change in Settings afterwards reaches neither.
        let options = AppPreferences().updateOptions
        Task {
            running = true
            outcomeMessage = nil
            updateProgress.applyStarted()
            let result = await updateDriver(teamID).apply(tag: tag, target: target, options: options)
            running = false
            finishUpdate(result, title: LifecycleVerb.updateApply.title)
            switch result {
            case .declined: finished?(nil, "")
            case .refused(let why): finished?(false, why)
            case .ran(let started, _, let text): finished?(started != .notStarted, text)
            }
            log.notice("update apply finished")
            await refresh()
        }
    }

    /// Runs `k3sm update cancel` from the progress panel, through the
    /// checked root step.
    func cancelUpdate() {
        guard updateProgress.canCancel, !running else { return }
        guard let teamID else {
            Self.alert(title: "k3sm cannot cancel the update from the app", text: UpdateOffer.developerBuildReason)
            return
        }
        if case .disabled(let reason) = availability {
            Self.alert(title: "k3sm cannot cancel the update from the app", text: reason)
            return
        }
        Task {
            running = true
            let result = await updateDriver(teamID).cancel()
            running = false
            finishUpdate(result, title: LifecycleVerb.updateCancel.title)
            log.notice("update cancel finished")
            await updateStatus?.refresh()
        }
    }

    /// Runs `k3sm update abort` from the progress panel, through the checked
    /// root step: while a roll runs, or after it failed.
    func abortUpdate() {
        guard updateProgress.canAbort, !running else { return }
        guard let teamID else {
            Self.alert(title: "k3sm cannot abort the update from the app", text: UpdateOffer.developerBuildReason)
            return
        }
        if case .disabled(let reason) = availability {
            Self.alert(title: "k3sm cannot abort the update from the app", text: reason)
            return
        }
        Task {
            running = true
            let result = await updateDriver(teamID).abort()
            running = false
            if case .ran(_, .succeeded, _) = result { updateProgress.abortFinished(succeeded: true) }
            finishUpdate(result, title: LifecycleVerb.updateAbort.title)
            log.notice("update abort finished")
            await updateStatus?.refresh()
        }
    }

    /// The Dismiss button: a finished roll leaves the window.
    func dismissUpdate() {
        updateProgress.dismiss()
    }

    /// Whether the panel's Cancel and Abort can be clicked, and why not.
    var updateActionReason: String? {
        if teamID == nil { return UpdateOffer.developerBuildReason }
        if case .disabled(let reason) = availability { return reason }
        if running { return "Another change is running." }
        return nil
    }

    private func updateDriver(_ teamID: TeamID) -> UpdateDriver {
        UpdateDriver(
            teamID: teamID,
            readStatus: { await self.readFullReport() },
            confirm: { Self.confirm($0) },
            confirmApply: { Self.confirmApply($0) },
            runner: runner)
    }

    private func finishUpdate(_ result: UpdateDriver.Result, title: String) {
        switch result {
        case .declined:
            updateProgress.applyFinished(.notStarted)
        case .refused(let why):
            updateProgress.applyFinished(.notStarted)
            outcomeMessage = why
            Self.alert(title: "Nothing was changed", text: why)
        case .ran(let started, let outcome, let text):
            updateProgress.applyFinished(started)
            outcomeMessage = text
            if started == .notStarted, outcome != .succeeded, outcome != .cancelled {
                Self.alert(title: title, text: text)
            }
        }
    }

    /// Reads the shared node list and the selected tab now.
    func refreshTabs() async {
        async let nodes: Void = workloads.nodeList.refresh()
        await loader(for: section)?.refresh()
        if eventsWanted { await events?.refresh() }
        await nodes
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

    /// Flips the LAN setting from the window. The verb comes
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
    ///
    /// `finished`, when given, hears how the run ended: true or false with
    /// the step's own message, or nil when the user answered no and nothing
    /// ran (the guided panel's progress line).
    func perform(_ verb: LifecycleVerb, expected: LifecycleState, finished: ((Bool?, String) -> Void)? = nil) {
        guard !running else {
            finished?(false, "Another change is running.")
            return
        }
        Task {
            if lifecycleSupport == nil {
                await refreshLifecycleSupport()
            }
            guard canRunLifecycle, let teamID else {
                var why = "k3sm cannot \(verb.rawValue) k3sm from the app."
                if case .unavailable(let note) = lifecycleSupport {
                    why = note
                    Self.alert(title: "k3sm cannot \(verb.rawValue) k3sm from the app", text: note)
                } else if case .disabled(let reason) = availability {
                    why = reason
                    Self.alert(title: "k3sm cannot \(verb.rawValue) k3sm from the app", text: reason)
                }
                finished?(false, why)
                return
            }
            running = true
            outcomeMessage = nil
            let driver = LifecycleDriver(
                teamID: teamID,
                readStatus: { await self.readFullReport() },
                confirm: { Self.confirm($0) },
                runner: runner,
                readStartTimeBound: { await self.readStartTimeBound() },
                progress: { self.outcomeMessage = $0 })
            let result = await driver.perform(verb, expected: expected)
            running = false
            var ended: (Bool?, String) = (nil, "")
            switch result {
            case .declined:
                break
            case .refused(let why):
                outcomeMessage = why
                ended = (false, why)
                Self.alert(title: "Nothing was changed", text: why)
            case .ran(let outcome, let text):
                outcomeMessage = text
                ended = (outcome == .succeeded, text)
                if outcome != .succeeded, outcome != .cancelled {
                    Self.alert(title: verb.title, text: text)
                }
            case .startedNotSchedulable(let text), .timedOut(let text):
                outcomeMessage = text
                ended = (false, text)
                Self.alert(title: verb.title, text: text)
            }
            log.notice("lifecycle verb finished")
            await refresh()
            finished?(ended.0, ended.1)
        }
    }

    /// Reads the start's time bound from the installed CLI, through the
    /// trust-checked runner. A fallback is logged with its reason, which is
    /// the app's own sentence; the CLI's output is never logged.
    private func readStartTimeBound() async -> StartTimeBound.Reading {
        let reading: StartTimeBound.Reading
        switch await runCLI(K3smCLI.startTimeBoundArguments) {
        case .exited(let status, let stdout):
            reading = StartTimeBound.parse(exitStatus: status, stdout: stdout)
        default:
            reading = StartTimeBound.parse(exitStatus: nil, stdout: Data())
        }
        switch reading {
        case .printed(let seconds):
            log.notice("start time bound: \(seconds, privacy: .public) s from the CLI")
        case .fallback(let reason):
            log.notice("start time bound: \(StartTimeBound.fallbackSeconds, privacy: .public) s fallback: \(reason, privacy: .public)")
        }
        return reading
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
        let cancel = alert.addButton(withTitle: c.cancelTitle)
        if c.cancelIsDefault {
            // Return answers Cancel; the verb needs a deliberate click.
            proceed.keyEquivalent = ""
            cancel.keyEquivalent = "\r"
            alert.window.initialFirstResponder = cancel
        }
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Asks Repair's question: what it does, and that the data is kept.
    private static func confirmRepair(_ c: RepairConfirmation) -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = c.title
        alert.informativeText = c.message
        alert.alertStyle = .informational
        alert.addButton(withTitle: c.proceedTitle)
        alert.addButton(withTitle: c.cancelTitle)
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Asks the apply's question: the release, every option that is not the
    /// default, and, when it offers one, the downgrade checkbox, off each
    /// time the question opens.
    private static func confirmApply(_ c: LifecycleConfirmation) -> UpdateApplyAnswer {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = c.title
        alert.informativeText = c.message
        alert.alertStyle = .informational
        alert.addButton(withTitle: c.verb.title)
        alert.addButton(withTitle: c.cancelTitle)
        var box: NSButton?
        if c.offersDowngrade {
            let checkbox = NSButton(checkboxWithTitle: UpdateOptions.downgradeTitle, target: nil, action: nil)
            checkbox.state = .off
            checkbox.toolTip = Help.Updates.allowDowngrade.text
            checkbox.sizeToFit()
            alert.accessoryView = checkbox
            box = checkbox
        }
        guard alert.runModal() == .alertFirstButtonReturn else { return .declined }
        return .confirmed(allowDowngrade: box?.state == .on)
    }

    /// Shows one sentence in an alert.
    static func alert(title: String, text: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }

    /// Runs the first run's install through the existing path (the
    /// copy-out root step), on the install step, and moves to the finished
    /// step when it ends. A success has already refreshed onto the console.
    func firstRunInstall() {
        guard firstRunStep == .review, firstRunInstallDisabledReason == nil, teamID != nil else { return }
        let action: CopyOutAction
        var input: Data?
        switch choice {
        case .start:
            action = .startServer
        case .join:
            guard let address = joinAddress else { return }
            action = .join(address)
            input = Data(token.utf8)
            token = ""
        }
        firstRunOutcome = nil
        firstRunStep = .install
        start(action, input: input) { [weak self] succeeded, message in
            guard let self else { return }
            self.firstRunOutcome = succeeded == true ? .succeeded : .failed(message)
            self.firstRunStep = .finished
        }
    }

    /// Runs the uninstall, keeping the data unless purge is chosen.
    func submitUninstall() {
        guard canUninstall else { return }
        start(uninstallAction, input: nil)
    }

    /// `finished`, when given, hears whether the copy-out succeeded and the
    /// outcome's sentence (the guided panel's progress line).
    private func start(_ action: CopyOutAction, input: Data?, finished: ((Bool?, String) -> Void)? = nil) {
        guard let teamID, let user, let payloadVersion else {
            finished?(false, UpdateBlock.roleUnknownText)
            return
        }
        let plan: CopyOutPlan
        do {
            plan = try CopyOutPlan(
                bundlePath: Bundle.main.bundlePath, payloadVersion: payloadVersion, teamID: teamID, user: user, action: action)
        } catch {
            outcomeMessage = "k3sm cannot run from \(Bundle.main.bundlePath). Move it to the Applications folder."
            finished?(false, outcomeMessage ?? "")
            return
        }
        run(plan, input: input, finished: finished)
    }

    private func run(_ plan: CopyOutPlan, input: Data?, finished: ((Bool?, String) -> Void)? = nil) {
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
            let text = OutcomeSummary.text(outcome, action: plan.action)
            self.outcomeMessage = text
            self.running = false
            log.notice("copy-out finished")
            await self.refresh()
            finished?(outcome == .succeeded, text)
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
                await CLIProcess.run(path: K3smCLI.path, arguments: arguments, environment: environment, deadline: PollSchedule.killDeadline, limit: OutputLimit.status)
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
