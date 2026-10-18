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
import K3smHost
import K3smStatus
import Synchronization

/// WorkloadsModel is the Workloads tab's state and the panel's lists: the
/// pod list (the tab's `TabLoader`, created when the console first comes on
/// screen, since the panel's pod figures come from it too),
/// the shared node list (read while the console is on screen, for the panel
/// and the Images tab), the search, the selected pod and its detail. The
/// search and the selection are kept in the user defaults per tab. A change
/// in either loader is published here, so the views observing this model
/// follow both. While the console is on screen the pods and the nodes are
/// each followed by a held kubectl watch (`WatchStream`, through
/// `CLIStream`): a loader's read takes the stream's list while it is live,
/// each change the stream publishes is read at once, and a stream that is
/// loading, retrying or degraded leaves the loader on its list poll.
@MainActor
final class WorkloadsModel: ObservableObject {
    /// A pod's reads; the inspector shows `PodDetail.inspectorTabs`, and
    /// the log opens in the log pane.
    typealias Detail = PodDetail

    /// The pod list; nil until the console first comes on screen.
    private(set) var pods: TabLoader<Workloads>?
    /// The shared node list: one read for the panel's nodes and the Images
    /// tab's images, never a second per tab.
    let nodeList: TabLoader<NodeListRead>
    @Published var selected: String? = ConsoleTabs.restoreSelected(
        from: UserDefaults.standard.object(forKey: ConsoleTabs.selectedKey(.workloads))) {
        didSet {
            UserDefaults.standard.set(selected, forKey: ConsoleTabs.selectedKey(.workloads))
        }
    }
    @Published var query = ConsoleTabs.restoreQuery(
        from: UserDefaults.standard.object(forKey: ConsoleTabs.queryKey(.workloads))) {
        didSet { UserDefaults.standard.set(query, forKey: ConsoleTabs.queryKey(.workloads)) }
    }
    /// This Mac's node name, from the last status report; the rows tag it.
    @Published var ownNode: String?
    /// The inspector's detail tab: Events or Manifest (the log is the log pane's).
    @Published var detail: Detail = .events
    @Published private(set) var detailText = ""
    @Published private(set) var detailLoading = false
    /// The log pane's read of a pod's log (`K3smCLI.logsArguments`), the pod
    /// it is of, and whether it is still reading.
    @Published private(set) var logText = ""
    @Published private(set) var logLoading = false
    @Published private(set) var logPodKey: String?
    /// The log pane's followed log (`LogFollowRead`); nil when none was
    /// started. Another log in the pane, or the pane closing, stops it.
    @Published private(set) var follow: LogFollowRead?
    /// The Scale stepper's count and the controller key it was set for: a
    /// stepper on another controller starts at that one's own count.
    @Published private(set) var scaleCount = 1
    @Published private(set) var scaleKey: String?
    /// The host's memory and data-root use, read with every node-list read
    /// so the panel holds no view state (the Command Line Tools have no
    /// SwiftUI macro plugin).
    @Published private(set) var load = HostLoad.read()
    /// The live load from metrics-server: the last sample, kept while the
    /// console is away, and why there is none (`MetricsState`).
    @Published private(set) var metrics = MetricsState()
    /// What the Stats tab charts over time (`StatsHistory`): the metrics
    /// samples, the restarts between pod-list reads and the update row's
    /// states, fed by the reads above and kept in memory only.
    @Published private(set) var stats = StatsHistory()
    /// The Summarize Logs action's runner, whose panel the inspector shows.
    let summaries: LogSummaryModel
    /// Called after each node-list read, for the Images tab's selection.
    var onNodesRead: (@MainActor () -> Void)?
    /// Called after each pod-list read, with whether it succeeded, for the
    /// action runner's report.
    var onPodsRead: (@MainActor (Bool) -> Void)?

    private let environment: [String: String]
    private var detailTask: Task<Void, Never>?
    private var logTask: Task<Void, Never>?
    private var forwarding: [AnyCancellable] = []
    private var metricsPoller: MetricsPoller?
    /// The held watches: started and stopped with the console's reads.
    let podStream: WatchStream
    let nodeStream: WatchStream
    /// The controllers read beside the streamed pod list.
    private let controllersCache = ControllersCache()

    init(environment: [String: String]) {
        self.environment = environment
        summaries = LogSummaryModel(environment: environment)
        let launcher = CLIStream(environment: environment)
        let clock = WatchSystemClock()
        let spacer = WatchRelistSpacer()
        let podStream = WatchStream(kind: .pods, launcher: launcher, clock: clock, spacer: spacer)
        let nodeStream = WatchStream(kind: .nodes, launcher: launcher, clock: clock, spacer: spacer)
        self.podStream = podStream
        self.nodeStream = nodeStream
        nodeList = TabLoader(
            read: {
                await WatchRead.read(
                    stream: nodeStream, decode: { NodeListRead.tabResult(exitCode: 0, stdout: $0) },
                    poll: {
                        let outcome = await TabLoader<NodeListRead>.run(arguments: K3smCLI.nodesArguments, environment: environment)
                        return TabLoader<NodeListRead>.result(of: outcome, what: "node list", decode: NodeListRead.tabResult(exitCode:stdout:))
                    })
            },
            interval: { _ in PollSchedule.fastInterval })
        nodeList.onRead = { [weak self] in
            self?.load = HostLoad.read()
            self?.onNodesRead?()
        }
        forward(nodeList)
        nodeStream.onPublish = { [weak self] in
            Task { await self?.nodeList.refresh() }
        }
        podStream.onPublish = { [weak self] in
            guard let self, let pods = self.pods else { return }
            self.controllersCache.markPush()
            Task { await pods.refresh() }
        }
        LocalActions.summarize = { [weak summaries] in summaries?.summarize($0) }
        metricsPoller = MetricsPoller(environment: environment) { [weak self] reading, at in
            self?.metrics.apply(reading, at: at)
            self?.stats.record(reading, at: at)
        }
    }

    /// Starts the metrics poll with the console; `demand` is what the shown
    /// view asks of the metrics, asked before every move.
    func startMetrics(demand: @escaping @MainActor () -> MetricsDemand) {
        metricsPoller?.start(demand: demand)
    }

    /// Tells the metrics poll the shown view changed, so a rise in demand
    /// reads now rather than after the slower wait.
    func metricsDemandChanged() {
        metricsPoller?.wake()
    }

    /// Stops the metrics poll; the last sample stays.
    func stopMetrics() {
        metricsPoller?.stop()
    }

    /// Starts the pod and node watches with the console's reads: at most
    /// these two are held at once.
    func startStreams() {
        podStream.start()
        nodeStream.start()
    }

    /// Stops both watches, killing their processes; the lists stay.
    func stopStreams() {
        podStream.stop()
        nodeStream.stop()
    }

    /// After a system wake: each running watch is restarted once.
    func wakeStreams() {
        podStream.wake()
        nodeStream.wake()
    }

    /// Records a full status report's update row for the Stats tab, and
    /// hands its `kubeconfig` row to both watches (`WatchCredential`).
    func noteReport(_ report: StatusReport, at time: Date) {
        stats.record(update: report, at: time)
        let credential = WatchCredential.of(report)
        podStream.noteCredential(credential)
        nodeStream.noteCredential(credential)
    }

    /// The selected pod's live load rows, by `MetricsDisplay.podFacts`.
    func loadFacts(_ pod: Pod) -> [InspectorFact] {
        MetricsDisplay.podFacts(pod, state: metrics)
    }

    /// Creates the pod list's loader, once.
    func podsLoader() -> TabLoader<Workloads> {
        if let pods { return pods }
        let environment = environment
        let stream = podStream
        let cache = controllersCache
        let loader = TabLoader<Workloads>(
            read: { await WorkloadsRead.read(environment: environment, stream: stream, cache: cache) },
            interval: { _ in PollSchedule.interval(for: .workloads, engineReady: false) })
        loader.onRead = { [weak self] in
            guard let self else { return }
            self.applySelection()
            let ok = !(self.pods?.load.failedOrUnavailable ?? true)
            if ok, let pods = self.workloads?.pods { self.stats.record(pods: pods, at: self.pods?.readAt ?? Date()) }
            self.onPodsRead?(ok)
        }
        pods = loader
        forward(loader)
        objectWillChange.send()
        return loader
    }

    /// The pod list as the Workloads tab shows it: not read yet (nil), the
    /// CLI missing, a CLI error, or the pods.
    var reading: WorkloadsReading? {
        guard let pods else { return nil }
        switch pods.load {
        case .failed(let text): return .cliError(text)
        case .unavailable: return .binaryMissing
        default: return pods.value.map(WorkloadsReading.listed)
        }
    }

    /// When the pod list was last read.
    var readAt: Date? { pods?.readAt }

    /// The cluster's nodes from the last node-list read; nil when it failed
    /// or its output was not a node list.
    var nodes: [ClusterNode]? {
        nodeList.load.failedOrUnavailable ? nil : nodeList.value?.nodes
    }

    var workloads: Workloads? {
        if case .listed(let w) = reading { return w }
        return nil
    }

    /// The controllers read with the last pod list, for Pause and Resume.
    var controllers: WorkloadControllers? { workloads?.controllers }

    var selectedPod: Pod? {
        guard let selected, let w = workloads else { return nil }
        return w.pods.first { $0.key == selected }
    }

    /// The pods the search leaves visible, by `WorkloadsDisplay.visible`.
    func visible(_ pods: [Pod]) -> [Pod] {
        WorkloadsDisplay.visible(pods, query: query, ownNode: ownNode)
    }

    /// The row's node column, by `WorkloadsDisplay.nodeLabel`.
    func nodeLabel(_ pod: Pod) -> PodNodeLabel {
        WorkloadsDisplay.nodeLabel(pod, ownNode: ownNode)
    }

    func select(_ pod: Pod) {
        selected = pod.key
        loadDetail()
    }

    /// The Scale stepper's count for `controller`, at `current` until the
    /// user moves it (`WorkloadControls.stepperValue`).
    func scaleCount(for controller: WorkloadController, current: Int) -> Int {
        scaleKey == controller.key ? scaleCount : WorkloadControls.stepperValue(current: current)
    }

    /// Whether the user has moved the stepper for `controller`; Scale waits for it.
    func scaleMoved(for controller: WorkloadController) -> Bool { scaleKey == controller.key }

    func setScaleCount(_ count: Int, for controller: WorkloadController) {
        scaleKey = controller.key
        scaleCount = WorkloadControls.stepperValue(current: count)
    }

    /// Starts following one log in the pane, after stopping any follow on screen.
    func startFollow(_ target: LogFollowTarget) {
        follow?.stop(.moved)
        let read = LogFollowRead(target: target)
        read.changed = { [weak self] in self?.objectWillChange.send() }
        follow = read
        let environment = environment
        read.start { arguments, onOutput in
            let outcome = await CLIProcess.run(
                path: K3smCLI.path, arguments: arguments, environment: environment,
                deadline: PollSchedule.logFollowDeadline, limit: OutputLimit.detail, onOutput: onOutput)
            switch outcome {
            case .exited(let status, _): return .exited(status)
            case .truncated: return .limit
            case .killed, .failedToLaunch: return .timedOut
            case .missing: return .missing
            case .refused(let why): return .refused(why)
            }
        }
    }

    /// Stops the follow on screen, keeping its lines and its line saying why.
    func stopFollow() {
        follow?.stop(.user)
    }

    /// Stops the follow and clears it: the pane goes back to its read.
    func endFollow(_ reason: LogFollow.StopReason) {
        follow?.stop(reason)
        follow = nil
    }

    /// The follow the log pane shows for the pod `podKey`.
    func shownFollow(podKey: String) -> LogFollowRead? {
        guard let follow, follow.target.podKey == podKey else { return nil }
        return follow
    }

    /// The listed pod with `key`, if it is still listed.
    func pod(key: String) -> Pod? {
        workloads?.pods.first { $0.key == key }
    }

    /// Reads `pod`'s log for the log pane, through the fixed argument list,
    /// replacing the pane's last read.
    func loadLog(_ pod: Pod) {
        logTask?.cancel()
        logPodKey = pod.key
        guard let ns = pod.namespaceName, let name = pod.resourceName else {
            logText = ""
            logLoading = false
            return
        }
        logLoading = true
        let arguments = K3smCLI.logsArguments(namespace: ns, pod: name)
        logTask = Task { [weak self] in
            guard let self else { return }
            let text = await self.read(arguments)
            guard !Task.isCancelled else { return }
            self.logLoading = false
            self.logText = text
        }
    }

    /// Ends the log pane's pod log: its read and any follow.
    func closeLog() {
        logTask?.cancel()
        logTask = nil
        logLoading = false
        logText = ""
        logPodKey = nil
        endFollow(.closed)
    }

    /// The selected pod's actions, by `PodActions.menu`: the list the
    /// inspector, the row's context menu and the Delete key share.
    var selectedMenu: ActionMenu {
        selectedPod.map { PodActions.menu(for: $0, controllers: controllers) } ?? .empty
    }

    private func forward(_ loader: some ObservableObject) {
        forwarding.append(loader.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() })
    }

    /// What a pod-list read does to the selection, by `WorkloadsDisplay.selection`.
    private func applySelection() {
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
        case .logs:
            // The log is the log pane's read (`loadLog`), never the inspector's.
            detailText = ""
            return
        case .events: arguments = K3smCLI.eventsArguments(namespace: ns, pod: name)
        case .manifest: arguments = K3smCLI.manifestArguments(namespace: ns, pod: name)
        }
        detailLoading = true
        detailTask = Task { [weak self] in
            guard let self else { return }
            let text = await self.read(arguments)
            guard !Task.isCancelled else { return }
            self.detailLoading = false
            self.detailText = text
        }
    }

    /// One pod read's text: the output cleaned for display, cut at
    /// `OutputLimit.detail`, or the line saying why there is none.
    private func read(_ arguments: [String]) async -> String {
        let outcome = await CLIProcess.run(path: K3smCLI.path, arguments: arguments, environment: environment, deadline: .seconds(15), limit: OutputLimit.detail)
        switch outcome {
        case .exited(let status, let stdout):
            let text = StatusDisplay.body(String(decoding: stdout, as: UTF8.self))
            return status == 0 ? (text.isEmpty ? "Nothing recorded." : text) : "k3sm kubectl exited \(status)"
        case .truncated(let stdout):
            // The first OutputLimit.detail bytes, cleaned like a whole
            // read; the run was stopped there instead of read to the end.
            return StatusDisplay.body(String(decoding: stdout, as: UTF8.self)) + "\n… cut at \(OutputLimit.detail >> 10) KiB"
        case .missing, .failedToLaunch, .killed, .refused:
            return "the k3sm CLI did not answer"
        }
    }
}

/// WorkloadsRead is the Workloads tab's read: the pod list, then, only when
/// that list succeeded, the Deployments, StatefulSets and ReplicaSets, each
/// through `TabLoader.run`. The pods decide the tab's result; the
/// controllers only add Pause and Resume
/// (`Workloads.tabResult(podsExit:podsStdout:controllers:)`), so a
/// controller read that fails leaves them off. While the pod watch is live
/// the pod list is the stream's and no pod list is run; the controllers
/// stay on the loader's timer, and a read the stream asked for reuses the
/// last controllers rather than running them again.
enum WorkloadsRead {
    nonisolated static func read(environment: [String: String], stream: WatchStream, cache: ControllersCache) async -> TabResult<Workloads> {
        let pushed = cache.takePush()
        if await stream.currentList() != nil {
            var controllers = pushed ? cache.last : nil
            if controllers == nil, case .exited(let code, let out) = await TabLoader<Workloads>.run(
                arguments: K3smCLI.controllersArguments, environment: environment) {
                controllers = (code, out)
                cache.store(code, out)
            }
            // The list is taken after the controllers read, so it is the newest.
            if let list = await stream.liveList {
                return Workloads.tabResult(podsExit: 0, podsStdout: list, controllers: controllers)
            }
        }
        let list = await TabLoader<Workloads>.run(arguments: K3smCLI.workloadsArguments, environment: environment)
        guard case .exited(let status, let stdout) = list, status == 0, !Task.isCancelled else {
            let result = TabLoader<Workloads>.result(of: list, what: "pod list", decode: Workloads.tabResult(exitCode:stdout:))
            return WatchRead.fallback(result, state: await stream.state)
        }
        var controllers: (exit: Int32, stdout: Data)?
        if case .exited(let code, let out) = await TabLoader<Workloads>.run(
            arguments: K3smCLI.controllersArguments, environment: environment) {
            controllers = (code, out)
        }
        return Workloads.tabResult(podsExit: status, podsStdout: stdout, controllers: controllers)
    }
}

/// ControllersCache keeps the last controllers read beside the streamed pod
/// list, and whether the next pod read was asked for by the stream.
final class ControllersCache: Sendable {
    private struct State {
        var push = false
        var last: (exit: Int32, stdout: Data)?
    }
    private let state = Mutex(State())

    func markPush() { state.withLock { $0.push = true } }

    /// Whether the read now starting was the stream's; the flag is cleared.
    func takePush() -> Bool {
        state.withLock { s in
            defer { s.push = false }
            return s.push
        }
    }

    var last: (exit: Int32, stdout: Data)? { state.withLock { $0.last } }

    func store(_ exit: Int32, _ stdout: Data) { state.withLock { $0.last = (exit, stdout) } }
}
