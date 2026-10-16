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
import K3smStatus

/// TabLoading is what the console does with any tab's loader: start it when
/// the tab is selected, stop it when the tab is left or the window goes, and
/// refresh it on demand.
@MainActor
protocol TabLoading: AnyObject {
    func start()
    func stop()
    func refresh() async
}

/// TabLoader is a console tab's list read as the views observe it: a
/// `TabReader` (the loop, the gate, start, stop and refresh, all tested in
/// `K3smStatus`) whose read runs one fixed argument list from `K3smCLI`
/// through the one CLI seam, with `PollSchedule.listDeadline` and
/// `OutputLimit.list`, and decodes it with a `K3smStatus` decoder. A read
/// the reader cancels kills its CLI child.
@MainActor
final class TabLoader<Value: Sendable>: ObservableObject, TabLoading {
    let reader: TabReader<Value>

    convenience init(
        arguments: [String], what: String, environment: [String: String],
        decode: @escaping @Sendable (Int32, Data) -> TabResult<Value>,
        interval: @escaping @MainActor (Value?) -> Duration
    ) {
        self.init(
            read: {
                let outcome = await Self.run(arguments: arguments, environment: environment)
                return Self.result(of: outcome, what: what, decode: decode)
            },
            interval: interval)
    }

    /// A loader whose read is made of more than one CLI run (the Models
    /// tab's list, then discovery after a failed list), each through `run`.
    init(read: @escaping @Sendable () async -> TabResult<Value>, interval: @escaping @MainActor (Value?) -> Duration) {
        reader = TabReader(read: read, interval: interval)
        reader.willChange = { [weak self] in self?.objectWillChange.send() }
    }

    var value: Value? { reader.value }
    var load: TabLoad { reader.load }
    var readAt: Date? { reader.readAt }
    var running: Bool { reader.running }
    var interval: @MainActor (Value?) -> Duration {
        get { reader.interval }
        set { reader.interval = newValue }
    }
    var onRead: (@MainActor () -> Void)? {
        get { reader.onRead }
        set { reader.onRead = newValue }
    }

    func start() { reader.start() }
    func stop() { reader.stop() }
    func refresh() async { await reader.refresh() }

    /// One run of a fixed argument list, with the list deadline and limit.
    nonisolated static func run(arguments: [String], environment: [String: String]) async -> CLIOutcome {
        await CLIProcess.run(
            path: K3smCLI.path, arguments: arguments, environment: environment,
            deadline: PollSchedule.listDeadline, limit: OutputLimit.list)
    }

    /// One CLI run as a tab result.
    nonisolated static func result(
        of outcome: CLIOutcome, what: String, decode: (Int32, Data) -> TabResult<Value>
    ) -> TabResult<Value> {
        switch outcome {
        case .missing:
            return .unavailable(TabLoad.notInstalled)
        case .failedToLaunch, .killed, .refused:
            return .failed("the k3sm CLI did not answer")
        case .truncated:
            return .failed("the \(what) is larger than \(OutputLimit.list >> 20) MiB")
        case .exited(let status, let stdout):
            return decode(status, stdout)
        }
    }
}

/// TabLoaderGroup is a tab read by more than one loader (Storage: the claim
/// list and the data volume card): started, stopped and refreshed together.
@MainActor
final class TabLoaderGroup: TabLoading {
    private let members: [any TabLoading]

    init(_ members: [any TabLoading]) {
        self.members = members
    }

    func start() { members.forEach { $0.start() } }
    func stop() { members.forEach { $0.stop() } }
    func refresh() async {
        for member in members { await member.refresh() }
    }
}
