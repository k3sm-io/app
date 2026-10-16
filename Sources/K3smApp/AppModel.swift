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
    /// The console panel's width as the user last dragged it, kept in the
    /// user defaults across launches and clamped on read
    /// (`PanelLayout.restoreWidth`); the split view clamps it again to what
    /// the panel's content could use (`PanelLayout.widthRange`).
    @Published var consolePanelWidth: Double = PanelLayout.restoreWidth(
        from: UserDefaults.standard.object(forKey: PanelLayout.widthKey)) {
        didSet { UserDefaults.standard.set(consolePanelWidth, forKey: PanelLayout.widthKey) }
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
    @Published private(set) var lanReport: StatusReport? {
        didSet { syncUpdateReader() }
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
            case .images: return self.workloads.nodeList.load
            case .builds: return self.builds?.load
            case .services: return self.services?.load
            case .storage: return self.storage?.load
            case .models: return self.models?.load
            }
        }
        waitingObservations.append(workloads.objectWillChange.sink { [weak self] _ in
            MainActor.assumeIsolated { self?.waiting.changed() }
        })
        // A decoded node list keeps the Images selection only while the
        // image it names is still listed, as each pod-list read does for
        // the Workloads selection.
        workloads.onNodesRead = { [weak self] in
            guard let self else { return }
            self.actions.tabRead(.images, succeeded: !self.workloads.nodeList.load.failedOrUnavailable)
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
            } else if section == .images {
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
        let next: Screen = FileManager.default.fileExists(atPath: K3smCLI.installRoot) ? .status : .firstRun
        if next != screen {
            screen = next
            statusPanelShown = false
        }
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
        case .images: return workloads.nodeList.value.flatMap { InspectorDetails.keys(images: $0.images) }
        case .builds:
            guard let history = buildHistory?.value else { return nil }
            return InspectorDetails.keys(engine: builds?.value, history: history)
        case .services: return services?.value.map { Set($0.map(\.key)) }
        case .storage: return storage?.value.map { Set($0.map(\.key)) }
        case .models: return models?.value.map { Set($0.map(\.key)) }
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
    /// Images, which renders the shared node list.
    private func loader(for section: ConsoleSection) -> (any TabLoading)? {
        if let existing = loaders[section] { return existing }
        let made: (any TabLoading)?
        switch section {
        case .workloads:
            let pods = workloads.podsLoader()
            pods.interval = { [weak self] _ in PollSchedule.podsInterval(selected: self?.section == .workloads) }
            made = pods
        case .images:
            made = nil
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

    /// The bulk actions the selected tab's toolbar offers. The slot is there
    /// for every tab; Workloads offers the cleanup (`PodCleanup`) while it
    /// shows its pods, Storage its volume cleanup while a volume is unused,
    /// and Builds the build engine's (`BuildActions.toolbar`).
    var bulkActions: [ActionMenuItem] {
        switch section {
        case .workloads:
            return workloadsView == .pods ? PodCleanup.bulkActions(for: workloads.workloads?.pods) : []
        case .storage:
            return storage?.value.flatMap(StorageActions.cleanupRequest).map { [ActionMenuItem($0)] } ?? []
        case .builds: return BuildActions.toolbar(builds?.value)
        case .images, .services, .models: return []
        }
    }

    /// One row's actions: what its context menu, its inspector body and the
    /// Delete key offer, the one function per kind every tab reads (the
    /// build engine's actions are the Builds toolbar's; a build row offers
    /// its own). A tab's actions arrive as a case here.
    func rowMenu(_ row: ConsoleRow) -> ActionMenu {
        switch row {
        case .pod(let key):
            return workloads.workloads?.pods.first { $0.key == key }.map(PodActions.menu(for:)) ?? .empty
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
        case .image:
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

    /// The managed update the menu and the console offer, from the last full
    /// report's `update` row and the progress. A privileged action: disabled
    /// with the reason on a developer build, without the administrator
    /// rights, while another change runs, or when the installed CLI failed
    /// its trust check.
    var updateOffer: UpdateOffer {
        var blocked: String?
        if running {
            blocked = "Another change is running."
        } else if case .disabled(let reason) = availability {
            blocked = reason
        } else if let why = lanTrustRefusal {
            blocked = "The app will not run the installed k3sm as root: \(why). Use `sudo k3sm update apply` in Terminal."
        }
        return UpdateOffer.decide(report: lanReport, progress: updateProgress, developerBuild: teamID == nil, blocked: blocked)
    }

    /// Starts or stops the update status read. While a roll is followed it
    /// reads whether or not the window is open, so the menu's "Updating…"
    /// ends when the roll does; while idle it reads only with the console on
    /// screen and an update offered, to find a roll started in Terminal.
    private func syncUpdateReader() {
        let offered: Bool
        if case .available = UpdateOffer.decide(report: lanReport, progress: updateProgress, developerBuild: false, blocked: nil) {
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
        guard updateOffer != .hidden || UpdateOffer.rowRolling(in: lanReport) else { return }
        await updateLoader().refresh()
    }

    /// Runs `k3sm update apply --yes` for the release offered, from the menu
    /// or the console button, through the checked root step.
    func performUpdate() {
        let offer = updateOffer
        guard case .available(let tag, let reason) = offer else { return }
        if let reason {
            Self.alert(title: "k3sm cannot update k3sm from the app", text: reason)
            return
        }
        guard let teamID else { return }
        Task {
            running = true
            outcomeMessage = nil
            updateProgress.applyStarted()
            let result = await updateDriver(teamID).apply(tag: tag)
            running = false
            finishUpdate(result, title: LifecycleVerb.updateApply.title)
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

    /// The Dismiss button: a finished roll leaves the window.
    func dismissUpdate() {
        updateProgress.dismiss()
    }

    /// Whether the panel's Cancel can be clicked, and why not.
    var updateCancelReason: String? {
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
                runner: runner,
                readStartTimeBound: { await self.readStartTimeBound() },
                progress: { self.outcomeMessage = $0 })
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
            case .startedNotSchedulable(let text), .timedOut(let text):
                outcomeMessage = text
                Self.alert(title: verb.title, text: text)
            }
            log.notice("lifecycle verb finished")
            await refresh()
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
