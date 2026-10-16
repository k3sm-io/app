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

/// ReadRequest is one read the MCP server may run: a fixed `K3smCLI`
/// argument list with its deadline and output limit. Its initialiser is
/// private, so the only reads that exist are the constants below; no tool
/// argument can become a command line, and there is no generic kubectl or
/// shell read to reach.
public struct ReadRequest: Equatable, Sendable {
    public let arguments: [String]
    public let deadline: Duration
    public let limit: Int
    /// Whether standard error shares the output: only the metrics APIService
    /// read, which tells a NotFound apart from a failure, keeps it.
    public let keepErrors: Bool

    private init(_ arguments: [String], deadline: Duration, limit: Int, keepErrors: Bool = false) {
        self.arguments = arguments
        self.deadline = deadline
        self.limit = limit
        self.keepErrors = keepErrors
    }

    /// The full status report, as the app reads it on demand.
    public static let report = ReadRequest(K3smCLI.reportArguments, deadline: PollSchedule.killDeadline, limit: OutputLimit.status)
    /// The launchd-only probe: it answers while the API server is down.
    public static let probe = ReadRequest(K3smCLI.probeArguments, deadline: PollSchedule.killDeadline, limit: OutputLimit.status)
    /// The installed CLI's version.
    public static let version = ReadRequest(K3smCLI.versionArguments, deadline: PollSchedule.killDeadline, limit: OutputLimit.status)
    /// The managed update's progress.
    public static let updateStatus = ReadRequest(K3smCLI.updateStatusArguments, deadline: PollSchedule.listDeadline, limit: OutputLimit.status)
    /// The cluster's nodes.
    public static let nodes = ReadRequest(K3smCLI.nodesArguments, deadline: PollSchedule.listDeadline, limit: OutputLimit.list)
    /// Every Event in the cluster.
    public static let events = ReadRequest(K3smCLI.eventsArguments, deadline: PollSchedule.listDeadline, limit: OutputLimit.list)
    /// metrics-server's node and pod samples, and the APIService read that
    /// says whether the metrics API is served.
    public static let nodeMetrics = ReadRequest(K3smCLI.nodeMetricsArguments, deadline: PollSchedule.listDeadline, limit: OutputLimit.metrics)
    public static let podMetrics = ReadRequest(K3smCLI.podMetricsArguments, deadline: PollSchedule.listDeadline, limit: OutputLimit.metrics)
    public static let metricsAPIService = ReadRequest(
        K3smCLI.metricsAPIServiceArguments, deadline: PollSchedule.listDeadline, limit: OutputLimit.status, keepErrors: true)

    /// Every read the server can run.
    public static let all: [ReadRequest] = [
        report, probe, version, updateStatus, nodes, events, nodeMetrics, podMetrics, metricsAPIService,
    ]
}

/// ReadOutcome is what one read came to, as the executable reports it after
/// the trust check and the run.
public enum ReadOutcome: Equatable, Sendable {
    /// The CLI is not installed at its absolute path.
    case missing
    /// The CLI failed its trust check just before the run, so nothing ran.
    case refused(String)
    /// The CLI could not be started.
    case failedToLaunch
    /// The CLI ran past its deadline and was killed.
    case killed
    /// The CLI wrote more than the read's limit and was killed.
    case truncated
    /// The CLI exited on its own.
    case exited(status: Int32, stdout: Data)
}

/// ClusterReader runs one read. The executable's reader checks the installed
/// CLI's trust and runs it by absolute path with the environment it builds;
/// tests pass a fake.
public typealias ClusterReader = @Sendable (ReadRequest) async -> ReadOutcome
