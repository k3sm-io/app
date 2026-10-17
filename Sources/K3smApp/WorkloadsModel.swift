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

/// WorkloadsModel is the Workloads tab's state and the panel's lists: the
/// pod list (the tab's `TabLoader`, created when the console first comes on
/// screen, since the panel's pod figures come from it too),
/// the shared node list (read while the console is on screen, for the panel
/// and the Images tab), the search, the selected pod and its detail. The
/// search and the selection are kept in the user defaults per tab. A change
/// in either loader is published here, so the views observing this model
/// follow both.
@MainActor
final class WorkloadsModel: ObservableObject {
    enum Detail: String, CaseIterable, Identifiable {
        case logs = "Logs", events = "Events", manifest = "Manifest"
        var id: Self { self }
    }

    /// The pod list; nil until the console first comes on screen.
    private(set) var pods: TabLoader<Workloads>?
    /// The shared node list: one read for the panel's nodes and the Images
    /// tab's images, never a second per tab.
    let nodeList: TabLoader<NodeListRead>
    @Published var selected: String? = ConsoleTabs.restoreSelected(
        from: UserDefaults.standard.object(forKey: ConsoleTabs.selectedKey(.workloads))) {
        didSet { UserDefaults.standard.set(selected, forKey: ConsoleTabs.selectedKey(.workloads)) }
    }
    @Published var query = ConsoleTabs.restoreQuery(
        from: UserDefaults.standard.object(forKey: ConsoleTabs.queryKey(.workloads))) {
        didSet { UserDefaults.standard.set(query, forKey: ConsoleTabs.queryKey(.workloads)) }
    }
    /// This Mac's node name, from the last status report; the rows tag it.
    @Published var ownNode: String?
    @Published var detail: Detail = .logs
    @Published private(set) var detailText = ""
    @Published private(set) var detailLoading = false
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
    private var forwarding: [AnyCancellable] = []
    private var metricsPoller: MetricsPoller?

    init(environment: [String: String]) {
        self.environment = environment
        summaries = LogSummaryModel(environment: environment)
        nodeList = TabLoader(
            arguments: K3smCLI.nodesArguments, what: "node list", environment: environment,
            decode: NodeListRead.tabResult(exitCode:stdout:),
            interval: { _ in PollSchedule.visibleInterval })
        nodeList.onRead = { [weak self] in
            self?.load = HostLoad.read()
            self?.onNodesRead?()
        }
        forward(nodeList)
        LocalActions.summarize = { [weak summaries] in summaries?.summarize($0) }
        metricsPoller = MetricsPoller(environment: environment) { [weak self] reading, at in
            self?.metrics.apply(reading, at: at)
            self?.stats.record(reading, at: at)
        }
    }

    /// Starts the metrics poll with the console; `visible` is whether the
    /// window is on screen, asked before every read.
    func startMetrics(visible: @escaping @MainActor () -> Bool) {
        metricsPoller?.start(visible: visible)
    }

    /// Stops the metrics poll; the last sample stays.
    func stopMetrics() {
        metricsPoller?.stop()
    }

    /// Records a full status report's update row for the Stats tab.
    func noteUpdate(_ report: StatusReport, at time: Date) {
        stats.record(update: report, at: time)
    }

    /// The selected pod's live load rows, by `MetricsDisplay.podFacts`.
    func loadFacts(_ pod: Pod) -> [InspectorFact] {
        MetricsDisplay.podFacts(pod, state: metrics)
    }

    /// Creates the pod list's loader, once.
    func podsLoader() -> TabLoader<Workloads> {
        if let pods { return pods }
        let environment = environment
        let loader = TabLoader<Workloads>(
            read: { await WorkloadsRead.read(environment: environment) },
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
        case .logs: arguments = K3smCLI.logsArguments(namespace: ns, pod: name)
        case .events: arguments = K3smCLI.eventsArguments(namespace: ns, pod: name)
        case .manifest: arguments = K3smCLI.manifestArguments(namespace: ns, pod: name)
        }
        detailLoading = true
        detailTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await CLIProcess.run(path: K3smCLI.path, arguments: arguments, environment: self.environment, deadline: .seconds(15), limit: OutputLimit.detail)
            guard !Task.isCancelled else { return }
            self.detailLoading = false
            switch outcome {
            case .exited(let status, let stdout):
                let text = StatusDisplay.body(String(decoding: stdout, as: UTF8.self))
                self.detailText = status == 0 ? (text.isEmpty ? "Nothing recorded." : text) : "k3sm kubectl exited \(status)"
            case .truncated(let stdout):
                // The first OutputLimit.detail bytes, cleaned like a whole
                // read; the run was stopped there instead of read to the end.
                self.detailText = StatusDisplay.body(String(decoding: stdout, as: UTF8.self)) + "\n… cut at \(OutputLimit.detail >> 10) KiB"
            case .missing, .failedToLaunch, .killed, .refused:
                self.detailText = "the k3sm CLI did not answer"
            }
        }
    }
}

/// WorkloadsRead is the Workloads tab's read: the pod list, then, only when
/// that list succeeded, the Deployments, StatefulSets and ReplicaSets, each
/// through `TabLoader.run`. The pods decide the tab's result; the
/// controllers only add Pause and Resume
/// (`Workloads.tabResult(podsExit:podsStdout:controllers:)`), so a
/// controller read that fails leaves them off.
enum WorkloadsRead {
    nonisolated static func read(environment: [String: String]) async -> TabResult<Workloads> {
        let list = await TabLoader<Workloads>.run(arguments: K3smCLI.workloadsArguments, environment: environment)
        guard case .exited(let status, let stdout) = list, status == 0, !Task.isCancelled else {
            return TabLoader<Workloads>.result(of: list, what: "pod list", decode: Workloads.tabResult(exitCode:stdout:))
        }
        var controllers: (exit: Int32, stdout: Data)?
        if case .exited(let code, let out) = await TabLoader<Workloads>.run(
            arguments: K3smCLI.controllersArguments, environment: environment) {
            controllers = (code, out)
        }
        return Workloads.tabResult(podsExit: status, podsStdout: stdout, controllers: controllers)
    }
}
