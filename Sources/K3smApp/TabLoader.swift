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

/// TabLoader reads one list for a console tab through the one CLI seam: a
/// fixed argument list from `K3smCLI` and a decoder from `K3smStatus`. It
/// reads once at `start()`, then at its cadence until `stop()`, which
/// cancels the loop and kills the CLI child. `PollGate` keeps the reads
/// serial: a refresh during a read runs once more after it, and a start
/// after a stop waits for the stopped loop to end. The last value is kept
/// across a stop, so a re-selected tab shows it, and its age, at once; a
/// failed read clears it.
@MainActor
final class TabLoader<Value: Sendable>: ObservableObject, TabLoading {
    @Published private(set) var value: Value?
    @Published private(set) var load: TabLoad = .idle
    /// When the last read finished, decoded or not.
    @Published private(set) var readAt: Date?

    /// The wait before the next read, given the value last read.
    var interval: @MainActor (Value?) -> Duration
    /// Called on the main actor after each finished read.
    var onRead: (@MainActor () -> Void)?

    private let arguments: [String]
    /// What the list is called in the line shown when it is too large.
    private let what: String
    private let decode: @Sendable (Int32, Data) -> TabResult<Value>
    private let environment: [String: String]
    private var task: Task<Void, Never>?
    /// The loop `stop()` cancelled, until the next `start()` waits for it.
    private var stopping: Task<Void, Never>?
    private var gate = PollGate()

    init(
        arguments: [String], what: String, environment: [String: String],
        decode: @escaping @Sendable (Int32, Data) -> TabResult<Value>,
        interval: @escaping @MainActor (Value?) -> Duration
    ) {
        self.arguments = arguments
        self.what = what
        self.environment = environment
        self.decode = decode
        self.interval = interval
    }

    /// Whether the read loop is running.
    var running: Bool { task != nil }

    /// Starts reading: one read now, then one per `interval`. A second start
    /// is a no-op; the new loop first waits for a stopped one to end.
    func start() {
        guard task == nil else { return }
        let previous = stopping
        stopping = nil
        task = Task { [weak self] in
            await previous?.value
            while !Task.isCancelled {
                guard let self else { return }
                await self.poll()
                let wait = self.interval(self.value)
                try? await Task.sleep(for: wait)
            }
        }
    }

    /// Stops reading. The cancelled read kills its CLI child; the tab keeps
    /// its last value, and the next `start()` waits for the loop to end.
    func stop() {
        guard let task else { return }
        task.cancel()
        stopping = task
        self.task = nil
        load = TabLoad.stopped(load, readAt: loadedAt)
    }

    /// Reads now, or, with a read in flight, once more after it.
    func refresh() async {
        await poll()
    }

    /// When the value shown was read, if one was.
    private var loadedAt: Date? {
        if case .loaded(let at) = load { return at }
        return value == nil ? nil : readAt
    }

    /// One run through the gate, repeated while a refresh asked for another.
    /// A cancelled run still drains the gate so it is never left held.
    private func poll() async {
        guard gate.begin() else { return }
        repeat {
            if !Task.isCancelled {
                await pollOnce()
            }
        } while gate.finish()
    }

    private func pollOnce() async {
        load = TabLoad.begin(hasValue: value != nil)
        let outcome = await CLIProcess.run(
            path: K3smCLI.path, arguments: arguments, environment: environment,
            deadline: PollSchedule.listDeadline, limit: OutputLimit.list)
        guard !Task.isCancelled else { return }
        let result: TabResult<Value>
        switch outcome {
        case .missing:
            result = .unavailable(TabLoad.notInstalled)
        case .failedToLaunch, .killed, .refused:
            result = .failed("the k3sm CLI did not answer")
        case .truncated:
            result = .failed("the \(what) is larger than \(OutputLimit.list >> 20) MiB")
        case .exited(let status, let stdout):
            result = decode(status, stdout)
        }
        let now = Date()
        // A failed read replaces the value, as the list it read did not
        // decode: the tab shows the failure, never a stale list beside it.
        if case .value(let v) = result { value = v } else { value = nil }
        load = TabLoad.finished(result, at: now)
        readAt = now
        onRead?()
    }
}
