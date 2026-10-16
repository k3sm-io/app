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
import K3smInstall
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
    /// The action waiting on its confirmation; the inspector's sheet shows
    /// while it is set.
    @Published var pendingAction: PodActionRequest?
    /// The action running now; the inspector's buttons wait for it.
    @Published private(set) var runningAction: PodActionRequest?
    /// The last action's line, for the pod it ran on.
    @Published private(set) var actionReport: (podKey: String, report: PodActionReport)?
    /// Called after each node-list read, for the Images tab's selection.
    var onNodesRead: (@MainActor () -> Void)?

    private let environment: [String: String]
    private let teamID: TeamID?
    private var detailTask: Task<Void, Never>?
    private var forwarding: [AnyCancellable] = []

    init(environment: [String: String], teamID: TeamID?) {
        self.environment = environment
        self.teamID = teamID
        nodeList = TabLoader(
            arguments: K3smCLI.nodesArguments, what: "node list", environment: environment,
            decode: NodeListRead.tabResult(exitCode:stdout:),
            interval: { _ in PollSchedule.visibleInterval })
        nodeList.onRead = { [weak self] in
            self?.load = HostLoad.read()
            self?.onNodesRead?()
        }
        forward(nodeList)
    }

    /// Creates the pod list's loader, once.
    func podsLoader() -> TabLoader<Workloads> {
        if let pods { return pods }
        let loader = TabLoader(
            arguments: K3smCLI.workloadsArguments, what: "pod list", environment: environment,
            decode: Workloads.tabResult(exitCode:stdout:),
            interval: { _ in PollSchedule.interval(for: .workloads, engineReady: false) })
        loader.onRead = { [weak self] in self?.applySelection() }
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

    /// The actions the selected pod offers, by `PodActions.available`.
    var selectedActions: [PodAction] {
        selectedPod.map(PodActions.available(for:)) ?? []
    }

    /// The last action's line when it ran on the selected pod.
    var selectedReport: PodActionReport? {
        guard let actionReport, actionReport.podKey == selected else { return nil }
        return actionReport.report
    }

    /// Asks for an action on the selected pod: the request is fixed now and
    /// the confirmation sheet shows it.
    func ask(_ action: PodAction) {
        guard runningAction == nil, let pod = selectedPod else { return }
        pendingAction = PodActions.request(action, for: pod)
    }

    /// Runs the confirmed action: the pod's UID is read first and the action
    /// runs only when it is still the UID confirmed (`PodActions.verify`);
    /// the installed CLI is checked just before each run, each run keeps
    /// kubectl's error text for the report, and the pod list is read again
    /// after it, whatever the outcome.
    func runPendingAction() {
        guard runningAction == nil, let request = pendingAction else { return }
        pendingAction = nil
        runningAction = request
        actionReport = nil
        let environment = environment
        let teamID = teamID
        let cli = TrustedCLI<CLIOutcome>(
            check: { await Task.detached { SelfCheck.installedCLITrust(team: teamID) }.value },
            execute: { arguments in
                await CLIProcess.run(
                    path: K3smCLI.path, arguments: arguments, environment: environment,
                    deadline: PollSchedule.listDeadline, limit: OutputLimit.status, keepErrors: true)
            })
        Task { [weak self] in
            let report: PodActionReport
            if let refusal = PodActions.verify(request, run: Self.actionRun(await cli.run(request.verifyArguments))) {
                report = refusal
            } else {
                report = PodActions.report(request, run: Self.actionRun(await cli.run(request.arguments)))
            }
            log.notice("console: \(request.action.rawValue, privacy: .public) \(report.failed ? "failed" : "asked", privacy: .public)")
            guard let self else { return }
            self.runningAction = nil
            self.actionReport = (request.podKey, report)
            await self.pods?.refresh()
        }
    }

    /// One trusted run as the pod actions read it.
    nonisolated private static func actionRun(_ result: TrustedCLI<CLIOutcome>.Result) -> PodActionRun {
        switch result {
        case .refused(let why): return .refused(why)
        case .ran(.exited(let status, let stdout)): return .exited(status: status, output: stdout)
        case .ran(.missing): return .missing
        case .ran(.refused(let why)): return .refused(why)
        case .ran(.failedToLaunch), .ran(.killed), .ran(.truncated): return .noAnswer
        }
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
