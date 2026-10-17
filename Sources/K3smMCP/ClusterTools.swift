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
import K3smStatus
import Synchronization

/// CallOutcome is the word the call log records for one `tools/call`.
public enum CallOutcome: String, Sendable {
    /// k3sm answered and the result carries what it said.
    case ok
    /// k3sm did not answer (updating, stopped, not installed or unreachable);
    /// the result says why and what is known.
    case unavailable
    /// The arguments did not match the tool's input schema; nothing was read.
    case invalidArguments = "invalid-arguments"
    /// No tool has the name asked for; nothing was read.
    case unknownTool = "unknown-tool"
    /// The client cancelled the call while it ran; no reply was sent.
    case cancelled
}

/// ToolResult is one tool's answer: the structured object (nil for an
/// argument error, which carries only its sentence), the text block every
/// client reads, and the outcome the call log records.
public struct ToolResult: Equatable, Sendable {
    public let structured: JSONValue?
    public let text: String
    public let isError: Bool
    public let outcome: CallOutcome

    static func value(_ object: [String: JSONValue], outcome: CallOutcome) -> ToolResult {
        let value = JSONValue.object(object)
        return ToolResult(structured: value, text: value.text, isError: false, outcome: outcome)
    }

    static func invalid(_ sentence: String) -> ToolResult {
        ToolResult(structured: nil, text: sentence, isError: true, outcome: .invalidArguments)
    }
}

/// ClusterTools runs the read-only tools over a `ClusterReader`. Each tool
/// runs only `ReadRequest` constants, decodes the output with the decoder
/// the app uses, and builds its result from named fields alone: nothing the
/// CLI or the cluster printed reaches a result except a field this file
/// names, every such string clipped by `StatusDisplay`. When a read fails
/// the tool answers with what is known instead of an error.
public struct ClusterTools: Sendable {
    /// The most nodes, pods, update nodes and conditions one result lists.
    public static let maxNodes = 64
    public static let maxPods = 20
    public static let maxConditions = 16
    /// The events tool's default and largest count.
    public static let defaultEvents = 20
    public static let maxEvents = 50
    /// The wait a result suggests before calling again, when k3sm did not answer.
    public static let retryAfterSeconds = 5

    let read: ClusterReader
    let appVersion: String?
    let now: @Sendable () -> Date
    /// The metrics read, shared by metrics calls that overlap: one CLI run
    /// at a time however many clients ask.
    let metricsFlight = SingleFlight()

    /// `appVersion` is the bundle's own version, nil when unknown.
    public init(read: @escaping ClusterReader, appVersion: String?, now: @escaping @Sendable () -> Date = { Date() }) {
        self.read = read
        self.appVersion = appVersion
        self.now = now
    }

    /// Runs one tool with its arguments (the `arguments` object of
    /// `tools/call`, empty when absent).
    public func call(_ name: ToolName, arguments: [String: JSONValue]) async -> ToolResult {
        switch name {
        case .status, .nodes, .updateStatus, .metrics:
            guard arguments.isEmpty else {
                return .invalid("\(name.rawValue) takes no arguments.")
            }
        case .events:
            break
        }
        switch name {
        case .status: return await status()
        case .nodes: return await nodes()
        case .updateStatus: return await updateStatus()
        case .metrics: return await metrics()
        case .events:
            switch Self.eventsArguments(arguments) {
            case .success(let parsed): return await events(namespace: parsed.namespace, limit: parsed.limit)
            case .failure(let why): return .invalid(why.sentence)
            }
        }
    }

    // MARK: - status

    func status() async -> ToolResult {
        let at = now()
        let outcome = await read(.report)
        guard case .exited(_, let stdout) = outcome else {
            return await unavailable(.outcome(outcome, what: "the status report"), at: at, update: true)
        }
        guard let report = try? StatusReport.decode(stdout) else {
            return await unavailable(.unreadable(what: "the status report"), at: at, update: true)
        }
        var result = Self.envelope(at: at)
        result["source"] = "report"
        result.merge(Self.reportFields(report)) { _, new in new }
        result["versions"] = Self.versions(report: report, cli: await cliVersion(), app: appVersion)
        result["update"] = Self.updateRow(report) ?? .null
        return .value(result, outcome: .ok)
    }

    /// The installed CLI's version, nil when it did not say.
    func cliVersion() async -> String? {
        guard case .exited(0, let stdout) = await read(.version) else { return nil }
        return SemanticVersion.fromVersionCommand(String(decoding: stdout, as: UTF8.self)).map { StatusDisplay.clip($0.description) }
    }

    static func reportFields(_ report: StatusReport) -> [String: JSONValue] {
        [
            "verdict": .string(StatusDisplay.clip(report.verdict.word)),
            "role": .string(StatusDisplay.clip(report.role)),
            "summary": .string(StatusDisplay.clip(report.summary)),
            "stoppedBy": .optional(report.stoppedBy.map { StatusDisplay.clip($0.line) }),
            "rows": .array(report.rows.prefix(StatusDisplay.maxRows).map(row)),
        ]
    }

    static func row(_ row: StatusRow) -> JSONValue {
        let remedy = StatusDisplay.clip(row.remedy)
        return [
            "name": .string(StatusDisplay.clip(row.name)),
            "state": .string(StatusDisplay.clip(row.state)),
            "severity": .string(StatusDisplay.clip(row.severity)),
            "detail": .string(StatusDisplay.clip(row.detail)),
            "remedy": remedy.isEmpty ? .null : .string(remedy),
        ]
    }

    static func versions(report: StatusReport, cli: String?, app: String?) -> JSONValue {
        let latest = report.row(named: "update").flatMap(UpdateOffer.latestTag(in:))
        var versions: [String: JSONValue] = [
            "cli": .optional(cli),
            "app": .optional(app.map(StatusDisplay.clip)),
            "latest": .optional(latest.map(StatusDisplay.clip)),
        ]
        if let workers = report.workers {
            versions["nodes"] = .array(workers.prefix(maxNodes).map { worker in
                [
                    "name": .string(StatusDisplay.clip(worker.name)),
                    "role": .string(StatusDisplay.clip(worker.role)),
                    "version": .optional(worker.version.map(StatusDisplay.clip)),
                ]
            })
        }
        return .object(versions)
    }

    /// The report's `update` row, nil when it has none.
    static func updateRow(_ report: StatusReport?) -> JSONValue? {
        guard let report, let row = report.row(named: "update") else { return nil }
        return [
            "state": .string(StatusDisplay.clip(row.state)),
            "severity": .string(StatusDisplay.clip(row.severity)),
            "detail": .string(StatusDisplay.clip(row.detail)),
            "latest": .optional(UpdateOffer.latestTag(in: row).map(StatusDisplay.clip)),
            "rolling": .bool(UpdateOffer.rowRolling(in: report)),
        ]
    }

    // MARK: - nodes

    func nodes() async -> ToolResult {
        let at = now()
        let outcome = await read(.nodes)
        guard case .exited(0, let stdout) = outcome else {
            return await unavailable(.outcome(outcome, what: "the node list"), at: at, update: true)
        }
        guard let nodes = try? Nodes.decode(stdout) else {
            return await unavailable(.unreadable(what: "the node list"), at: at, update: true)
        }
        var result = Self.envelope(at: at)
        result["count"] = .int(nodes.count)
        result["omitted"] = .int(max(0, nodes.count - Self.maxNodes))
        result["nodes"] = .array(nodes.prefix(Self.maxNodes).map(Self.node))
        return .value(result, outcome: .ok)
    }

    static func node(_ node: ClusterNode) -> JSONValue {
        [
            "name": .string(StatusDisplay.clip(node.name)),
            "role": .string(node.controlPlane ? NodeRole.server.rawValue : NodeRole.agent.rawValue),
            "ready": .optional(node.ready),
            "cordoned": .bool(node.unschedulable),
            "kubeletVersion": .optional(node.kubeletVersion.map(StatusDisplay.clip)),
            "k3smRelease": .optional(node.k3smRelease.map { StatusDisplay.clip($0.description) }),
            "conditions": .array(node.conditions.prefix(maxConditions).map { condition in
                [
                    "type": .string(StatusDisplay.clip(condition.type)),
                    "status": .string(StatusDisplay.clip(condition.status)),
                    "reason": .optional(condition.reason.map(StatusDisplay.clip)),
                    "healthy": .bool(condition.healthy),
                ]
            }),
        ]
    }

    // MARK: - update status

    func updateStatus() async -> ToolResult {
        let at = now()
        let report: StatusReport?
        if case .exited(_, let stdout) = await read(.report) {
            report = try? StatusReport.decode(stdout)
        } else {
            report = nil
        }
        let outcome = await read(.updateStatus)
        guard case .exited(0, let stdout) = outcome else {
            return await unavailable(.outcome(outcome, what: "the update status"), at: at, update: false, report: report)
        }
        guard let status = try? UpdateStatus.decode(stdout) else {
            return await unavailable(.unreadable(what: "the update status"), at: at, update: false, report: report)
        }
        var result = Self.envelope(at: at)
        result["row"] = Self.updateRow(report) ?? .null
        result["update"] = Self.update(status)
        return .value(result, outcome: .ok)
    }

    static func update(_ status: UpdateStatus) -> JSONValue {
        [
            "present": .bool(status.present),
            "name": .string(StatusDisplay.clip(status.name)),
            "phase": .string(StatusDisplay.clip(status.phase.word)),
            "version": .string(StatusDisplay.clip(status.version)),
            "target": .string(StatusDisplay.clip(status.target)),
            "finished": .bool(status.finished),
            "ended": .optional(status.ended.map { StatusDisplay.clip($0.word) }),
            "rolling": .bool(status.present && !status.finished),
            "nodes": .array(status.nodes.prefix(maxNodes).map { node in
                [
                    "name": .string(StatusDisplay.clip(node.name)),
                    "from": .string(StatusDisplay.clip(node.from)),
                    "to": .string(StatusDisplay.clip(node.to)),
                    "phase": .string(StatusDisplay.clip(node.phase)),
                    "message": .string(StatusDisplay.clip(node.message)),
                    "lastProgress": .string(StatusDisplay.clip(node.lastProgress)),
                ]
            }),
            "conditions": .array(status.conditions.prefix(maxConditions).map { condition in
                [
                    "type": .string(StatusDisplay.clip(condition.type)),
                    "status": .string(StatusDisplay.clip(condition.status)),
                    "reason": .string(StatusDisplay.clip(condition.reason)),
                    "message": .string(StatusDisplay.clip(condition.message)),
                ]
            }),
        ]
    }

    // MARK: - metrics

    func metrics() async -> ToolResult {
        let at = now()
        let metrics = await metricsFlight.run { [read] in await read(.metrics) }
        let reading: MetricsReading
        switch metrics {
        case .exited(let status, let stdout):
            if let partial = Metrics.sampled(combined: stdout, exit: status) {
                reading = partial
                break
            }
            var apiService: (exit: Int32, stdout: Data)?
            if case .exited(let code, let out) = await read(.metricsAPIService) { apiService = (code, out) }
            reading = Metrics.unavailable(nodesExit: status, apiService: apiService)
        default:
            return await unavailable(.outcome(metrics, what: "the metrics"), at: at, update: true)
        }
        var result = Self.envelope(at: at)
        switch reading {
        case .sampled(let sample):
            result["metricsAPI"] = "served"
            result.merge(Self.sampleFields(sample)) { _, new in new }
        case .absent(let line):
            result["metricsAPI"] = "absent"
            result["note"] = .string(StatusDisplay.errorText(line))
            result["nodes"] = []
            result["podsRead"] = false
            result["podCount"] = 0
            result["pods"] = []
        case .failed:
            // The app shows this line, which may quote kubectl's own error
            // output; a tool result carries only the fixed sentence.
            return await unavailable(.outcome(metrics, what: "the metrics"), at: at, update: true)
        }
        return .value(result, outcome: .ok)
    }

    static func sampleFields(_ sample: MetricsSample) -> [String: JSONValue] {
        let nodes = sample.nodes.values.sorted { $0.name < $1.name }.prefix(maxNodes).map { usage -> JSONValue in
            [
                "name": .string(StatusDisplay.clip(usage.name)),
                "cpuMillicores": .optional(usage.cores.map(millicores)),
                "memoryBytes": .optional(usage.memoryBytes),
            ]
        }
        let pods = (sample.pods ?? [:]).sorted { a, b in
            a.value.cores != b.value.cores ? a.value.cores > b.value.cores : a.key < b.key
        }
        let top = pods.prefix(maxPods).map { key, usage -> JSONValue in
            let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
            return [
                "namespace": .string(StatusDisplay.clip(parts.first ?? "")),
                "name": .string(StatusDisplay.clip(parts.count > 1 ? parts[1] : "")),
                "cpuMillicores": .int(millicores(usage.cores)),
                "memoryBytes": .optional(Optional(usage.memoryBytes)),
            ]
        }
        return [
            "nodes": .array(Array(nodes)),
            "podsRead": .bool(sample.pods != nil),
            "podCount": .int(pods.count),
            "pods": .array(Array(top)),
        ]
    }

    /// Cores as whole millicores, as `kubectl top` shows them; a whole
    /// number, so the JSON carries no binary-fraction noise.
    static func millicores(_ cores: Double) -> Int {
        guard cores.isFinite, cores > 0 else { return 0 }
        return Int(min((cores * 1000).rounded(), Double(Int32.max)))
    }

    // MARK: - events

    /// The events tool's arguments, checked against its input schema.
    struct EventsArguments: Equatable {
        let namespace: ResourceName?
        let limit: Int
    }

    struct ArgumentError: Error, Equatable {
        let sentence: String
    }

    static func eventsArguments(_ arguments: [String: JSONValue]) -> Result<EventsArguments, ArgumentError> {
        let known: Set<String> = ["namespace", "limit"]
        if arguments.keys.contains(where: { !known.contains($0) }) {
            return .failure(ArgumentError(sentence: "k3sm_events takes only namespace and limit."))
        }
        var namespace: ResourceName?
        if let value = arguments["namespace"], value != .null {
            guard let text = value.stringValue, let name = ResourceName(text) else {
                return .failure(ArgumentError(sentence: "namespace must be a Kubernetes name: lowercase letters, digits, '-' and '.'."))
            }
            namespace = name
        }
        var limit = defaultEvents
        if let value = arguments["limit"], value != .null {
            guard let n = value.intValue, (1...maxEvents).contains(n) else {
                return .failure(ArgumentError(sentence: "limit must be a whole number from 1 to \(maxEvents)."))
            }
            limit = n
        }
        return .success(EventsArguments(namespace: namespace, limit: limit))
    }

    func events(namespace: ResourceName?, limit: Int) async -> ToolResult {
        let at = now()
        let outcome = await read(.events)
        guard case .exited(0, let stdout) = outcome else {
            return await unavailable(.outcome(outcome, what: "the event list"), at: at, update: true)
        }
        guard let all = try? EventsList.decode(stdout) else {
            return await unavailable(.unreadable(what: "the event list"), at: at, update: true)
        }
        let warnings = all.filter { $0.type == "Warning" && (namespace == nil || $0.namespace == namespace?.value) }
            .sorted(by: EventsList.newerFirst)
        let shown = warnings.prefix(limit)
        var result = Self.envelope(at: at)
        result["namespace"] = .optional(namespace?.value)
        result["warningCount"] = .int(warnings.count)
        result["shown"] = .int(shown.count)
        result["events"] = .array(shown.map { event in
            [
                "namespace": .string(StatusDisplay.clip(event.namespace)),
                "reason": .string(StatusDisplay.clip(event.reason)),
                // Free text written by whatever raised the event; named so
                // no reader takes it for the tool's own words.
                "clusterMessage": .string(StatusDisplay.clip(event.message)),
                "object": .string(StatusDisplay.clip(event.object)),
                "count": .int(event.count),
                "lastSeen": .optional(event.time.map(Self.timestamp)),
            ]
        })
        return .value(result, outcome: .ok)
    }

    // MARK: - when k3sm does not answer

    /// Failure is why a tool's own read gave no result.
    enum Failure: Equatable {
        case outcome(ReadOutcome, what: String)
        case unreadable(what: String)
    }

    /// The first sentence every transient answer starts with.
    public static let updatingOrUnreachable = "k3sm is updating or unreachable"

    /// The condition word and sentence for one failure, before what is known
    /// refines them.
    static func describe(_ failure: Failure) -> (condition: String, message: String, transient: Bool) {
        switch failure {
        case .outcome(.missing, _):
            return ("not-installed", "k3sm is not installed on this Mac: \(K3smCLI.path) is absent.", false)
        case .outcome(.refused(let why), _):
            return ("cli-refused",
                    "\(updatingOrUnreachable): the installed k3sm did not pass the trust check (\(StatusDisplay.errorText(why))). An update replaces it in one step, so try again shortly.",
                    true)
        case .outcome(.failedToLaunch, _):
            return ("updating-or-unreachable", "\(updatingOrUnreachable): the k3sm CLI could not be started.", true)
        case .outcome(.killed, let what):
            return ("updating-or-unreachable", "\(updatingOrUnreachable): \(what) did not answer in time.", true)
        case .outcome(.truncated, let what):
            return ("too-large", "\(what.prefix(1).uppercased() + what.dropFirst()) is larger than this tool reads, so it was not read.", false)
        case .outcome(.exited(let status, _), let what):
            return ("updating-or-unreachable", "\(updatingOrUnreachable): \(what) exited \(status); the API server may be restarting.", true)
        case .unreadable(let what):
            return ("updating-or-unreachable", "\(updatingOrUnreachable): \(what) could not be read.", true)
        }
    }

    /// The answer when a tool's read failed: the condition, a sentence, when
    /// to retry, and what is known. What is known comes from `report` when
    /// the tool already read it, else from the launchd probe, which answers
    /// while the API server is down; with `update`, the managed update's
    /// state is read too, so an agent sees a roll in progress. Nothing more
    /// is read when the CLI is missing or failed its trust check.
    func unavailable(_ failure: Failure, at: Date, update: Bool, report: StatusReport? = nil) async -> ToolResult {
        var (condition, message, transient) = Self.describe(failure)
        var known: [String: JSONValue] = [:]
        let skip: Bool
        switch failure {
        case .outcome(.missing, _), .outcome(.refused, _): skip = true
        default: skip = false
        }
        if !skip {
            var source = report
            if source == nil, case .exited(_, let stdout) = await read(.probe) {
                source = try? StatusReport.decode(stdout)
            }
            if let source {
                known.merge(Self.reportFields(source)) { _, new in new }
                if source.row(named: "update") != nil {
                    known["updateRolling"] = .bool(UpdateOffer.rowRolling(in: source))
                }
                if source.verdict == .notInstalled {
                    (condition, message, transient) = ("not-installed", "k3sm is not installed on this Mac.", false)
                } else if source.verdict == .stopped, let stopped = source.stoppedBy {
                    (condition, message, transient) = (
                        "stopped",
                        "k3sm is stopped on this Mac (\(StatusDisplay.clip(stopped.line))). Start it from the k3sm app or with `sudo k3sm start`.",
                        false)
                }
            }
            if update, condition != "stopped", condition != "not-installed",
               case .exited(0, let stdout) = await read(.updateStatus), let status = try? UpdateStatus.decode(stdout) {
                known["update"] = Self.update(status)
                if status.present && !status.finished {
                    known["updateRolling"] = true
                }
            }
            if known["updateRolling"] == .bool(true), transient {
                condition = "updating"
                message += " A managed update is rolling, so parts of the cluster restart; k3sm_update_status shows its progress."
            }
        }
        var result = Self.envelope(at: at)
        result["available"] = false
        result["condition"] = .string(condition)
        result["message"] = .string(message)
        if transient { result["retryAfterSeconds"] = .int(Self.retryAfterSeconds) }
        if !known.isEmpty { result["known"] = .object(known) }
        return .value(result, outcome: .unavailable)
    }

    // MARK: - shared

    /// The fields every result starts with.
    static func envelope(at: Date) -> [String: JSONValue] {
        ["available": true, "untrustedData": true, "readAt": .string(timestamp(at))]
    }

    static func timestamp(_ date: Date) -> String {
        date.formatted(.iso8601)
    }
}

/// SingleFlight shares one read among the callers that overlap it: the first
/// caller starts the read, later callers until it finishes await the same
/// outcome, and the next caller after it starts a new one. The read is
/// cancelled only when every caller waiting on it was cancelled.
final class SingleFlight: Sendable {
    private struct State {
        var task: Task<ReadOutcome, Never>?
        var generation = 0
        var waiters = 0
    }

    private let state = Mutex(State())

    func run(_ body: @escaping @Sendable () async -> ReadOutcome) async -> ReadOutcome {
        let (task, generation) = state.withLock { s -> (Task<ReadOutcome, Never>, Int) in
            if let task = s.task {
                s.waiters += 1
                return (task, s.generation)
            }
            let task = Task { await body() }
            s.task = task
            s.generation += 1
            s.waiters = 1
            return (task, s.generation)
        }
        let outcome = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            let last = state.withLock { s -> Bool in
                guard s.generation == generation else { return false }
                s.waiters -= 1
                return s.waiters == 0
            }
            if last { task.cancel() }
        }
        state.withLock { s in
            if s.generation == generation { s.task = nil }
        }
        return outcome
    }
}
