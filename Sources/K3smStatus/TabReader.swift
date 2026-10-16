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

/// TabReader is a console tab's read loop, independent of how a read is
/// made: the app hands it a read (a fixed CLI argument list and a decoder)
/// and observes it through `willChange`. It reads once at `start()`, then at
/// its `interval` until `stop()`. Every read, the loop's and each
/// `refresh()`, runs in a task the reader owns, so `stop()` cancels all of
/// them; a cancelled read's result is discarded, and a CLI read kills its
/// child on cancellation. `PollGate` keeps the reads serial: a refresh
/// during a read runs once more after it, and a start after a stop waits for
/// the stopped tasks to end. The last value is kept across a stop, so a
/// re-selected tab shows it, and its age, at once; a failed read clears it,
/// so a failure is never shown beside a stale list.
@MainActor
public final class TabReader<Value: Sendable> {
    public private(set) var value: Value?
    public private(set) var load: TabLoad = .idle
    /// When the last read finished, decoded or not.
    public private(set) var readAt: Date?

    /// The wait before the next read, given the value last read.
    public var interval: @MainActor (Value?) -> Duration
    /// Called after each finished read.
    public var onRead: (@MainActor () -> Void)?
    /// Called before any of the published state changes.
    public var willChange: (@MainActor () -> Void)?

    private let read: @Sendable () async -> TabResult<Value>
    private var loop: Task<Void, Never>?
    private var refreshes: [Int: Task<Void, Never>] = [:]
    private var nextRefresh = 0
    /// The tasks `stop()` cancelled, until the next `start()` waits for them.
    private var stopping: [Task<Void, Never>] = []
    private var gate = PollGate()

    public init(read: @escaping @Sendable () async -> TabResult<Value>, interval: @escaping @MainActor (Value?) -> Duration) {
        self.read = read
        self.interval = interval
    }

    /// Whether the read loop is running.
    public var running: Bool { loop != nil }

    /// Starts reading: one read now, then one per `interval`. A second start
    /// is a no-op.
    public func start() {
        guard loop == nil else { return }
        let previous = stopping
        stopping = []
        loop = Task { [weak self] in
            for task in previous { await task.value }
            while !Task.isCancelled {
                guard let self else { return }
                await self.poll()
                let wait = self.interval(self.value)
                try? await Task.sleep(for: wait)
            }
        }
    }

    /// Stops reading: the loop and every refresh in flight are cancelled and
    /// their results discarded. The tab keeps its last value.
    public func stop() {
        let tasks = (loop.map { [$0] } ?? []) + Array(refreshes.values)
        guard !tasks.isEmpty else { return }
        for task in tasks { task.cancel() }
        stopping += tasks
        loop = nil
        refreshes = [:]
        set { $0.load = TabLoad.stopped($0.load, readAt: $0.loadedAt) }
    }

    /// Reads now, or, with a read in flight, once more after it, in a task
    /// `stop()` cancels.
    public func refresh() async {
        let id = nextRefresh
        nextRefresh += 1
        let task = Task { [weak self] in _ = await self?.poll() }
        refreshes[id] = task
        await task.value
        refreshes[id] = nil
    }

    /// When the value shown was read, if one was.
    private var loadedAt: Date? {
        if case .loaded(let at) = load { return at }
        return value == nil ? nil : readAt
    }

    private func set(_ change: (TabReader) -> Void) {
        willChange?()
        change(self)
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
        set { $0.load = TabLoad.begin(hasValue: $0.value != nil) }
        let result = await read()
        guard !Task.isCancelled else { return }
        let now = Date()
        set {
            if case .value(let v) = result { $0.value = v } else { $0.value = nil }
            $0.load = TabLoad.finished(result, at: now)
            $0.readAt = now
        }
        onRead?()
    }
}
