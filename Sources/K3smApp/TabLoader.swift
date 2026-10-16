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

    init(
        arguments: [String], what: String, environment: [String: String],
        decode: @escaping @Sendable (Int32, Data) -> TabResult<Value>,
        interval: @escaping @MainActor (Value?) -> Duration
    ) {
        reader = TabReader(
            read: { await Self.read(arguments: arguments, what: what, environment: environment, decode: decode) },
            interval: interval)
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

    /// One CLI run as a tab result.
    private nonisolated static func read(
        arguments: [String], what: String, environment: [String: String],
        decode: @Sendable (Int32, Data) -> TabResult<Value>
    ) async -> TabResult<Value> {
        let outcome = await CLIProcess.run(
            path: K3smCLI.path, arguments: arguments, environment: environment,
            deadline: PollSchedule.listDeadline, limit: OutputLimit.list)
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
