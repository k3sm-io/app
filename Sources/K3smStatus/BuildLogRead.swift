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

/// BuildLogRun is one run of `k3sm build logs`: it is handed the argument
/// list and a sink for each chunk of output as it is read, and returns how
/// the run ended. The app's run is `CLIProcess` through `TrustedCLI`, whose
/// cancellation handler kills the CLI, so cancelling the task awaiting a run
/// is what ends a following `build logs -f`.
public typealias BuildLogRun = @Sendable (_ arguments: [String], _ onOutput: @escaping @Sendable (Data) -> Void) async -> BuildLog.End

/// BuildLogRead is one build log sheet's read: the build's `build logs`
/// arguments (`-f` while it was running), the bytes read so far, in order,
/// and how the read ended. `stop` cancels the run, which kills a following
/// CLI, and a stopped read never starts again.
@MainActor
public final class BuildLogRead {
    public let target: BuildLogTarget
    /// The bytes read so far; the run caps them (`OutputLimit.buildLog`).
    public private(set) var data = Data()
    public private(set) var end: BuildLog.End = .reading
    /// Whether `stop` was called.
    public private(set) var stopped = false
    /// Called after every change, for a view to re-render.
    public var changed: (@MainActor () -> Void)?
    private var task: Task<Void, Never>?

    public init(target: BuildLogTarget) {
        self.target = target
    }

    /// The CLI arguments the read runs.
    public var arguments: [String] { K3smCLI.buildLogsArguments(id: target.id, follow: target.follow) }

    /// Starts the read; a second start, or a start after `stop`, does nothing.
    public func start(_ run: @escaping BuildLogRun) {
        guard task == nil, !stopped else { return }
        let arguments = arguments
        task = Task { [weak self] in
            let end = await run(arguments) { chunk in
                // The main queue keeps the chunks in order.
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.append(chunk) } }
            }
            guard !Task.isCancelled else { return }
            // Let the chunks already queued land before the end is shown.
            await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
            self?.finish(end)
        }
    }

    /// Stops the read, cancelling its run, which kills a CLI still following.
    public func stop() {
        stopped = true
        task?.cancel()
        task = nil
    }

    private func append(_ chunk: Data) {
        guard !stopped else { return }
        data.append(chunk)
        changed?()
    }

    private func finish(_ end: BuildLog.End) {
        guard !stopped else { return }
        self.end = end
        task = nil
        changed?()
    }
}

/// BuildLogSlot is the console's one build log sheet: opening a log stops
/// the read on screen first, and closing it stops it, so at most one
/// `build logs` CLI runs for the sheet, and none once it is gone.
@MainActor
public final class BuildLogSlot {
    public private(set) var current: BuildLogRead?

    public init() {}

    /// A new read for `target`, after stopping the one on screen.
    public func open(_ target: BuildLogTarget) -> BuildLogRead {
        current?.stop()
        let read = BuildLogRead(target: target)
        current = read
        return read
    }

    /// Stops the read on screen and clears the slot.
    public func close() {
        current?.stop()
        current = nil
    }
}
