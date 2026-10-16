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

/// CLIOutcome is what one run of the k3sm CLI produced.
enum CLIOutcome: Sendable {
    /// The CLI is not installed at its absolute path.
    case missing
    /// The CLI could not be started.
    case failedToLaunch
    /// The CLI ran past its deadline and was killed.
    case killed
    /// The CLI exited on its own.
    case exited(status: Int32, stdout: Data)
    /// The CLI wrote more than the run's limit: it was killed, and `stdout`
    /// holds the first `limit` bytes.
    case truncated(stdout: Data)
    /// The CLI failed its trust check just before the run, so it was not run.
    case refused(String)
}

/// CLIProcess runs the k3sm CLI by absolute path with the environment the
/// caller built, collects at most `limit` bytes of its standard output, and
/// kills it at the deadline, when its output passes the limit, or when the
/// task awaiting it is cancelled. Standard error is discarded unless the
/// caller keeps it (`keepErrors`, a console action that reports kubectl's own
/// failure text): it then shares the output pipe and its limit. It runs on a
/// background thread; callers await the outcome.
enum CLIProcess {
    /// How long to wait for the output pipe to close after the process exits.
    /// A grandchild that inherited the pipe can hold it open; the run does not
    /// wait on it past this.
    private static let drainGrace: DispatchTimeInterval = .milliseconds(500)

    /// `onOutput`, when set, receives each chunk of output as it is read,
    /// within the limit, on the reader's thread: a build log sheet shows a
    /// following run as it goes.
    static func run(path: String, arguments: [String], environment: [String: String], deadline: Duration, limit: Int, keepErrors: Bool = false,
                    onOutput: (@Sendable (Data) -> Void)? = nil) async -> CLIOutcome {
        guard FileManager.default.isExecutableFile(atPath: path) else {
            return .missing
        }
        let control = RunControl()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: runBlocking(path: path, arguments: arguments, environment: environment, deadline: deadline, limit: limit, keepErrors: keepErrors, onOutput: onOutput, control: control))
                }
            }
        } onCancel: {
            // A cancelled caller drops the result, so the child need not run
            // on to its deadline: a run of tab clicks ends each earlier run.
            control.stop()
        }
    }

    private static func runBlocking(path: String, arguments: [String], environment: [String: String], deadline: Duration, limit: Int, keepErrors: Bool,
                                    onOutput: (@Sendable (Data) -> Void)?, control: RunControl) -> CLIOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = keepErrors ? pipe : FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            control.exited()
            exited.signal()
        }
        do {
            try process.run()
        } catch {
            return .failedToLaunch
        }
        try? pipe.fileHandleForWriting.close()
        control.launched(process.processIdentifier)

        let output = OutputBuffer(limit: limit)
        let drained = DispatchSemaphore(value: 0)
        let reader = pipe.fileHandleForReading
        Thread.detachNewThread {
            while let chunk = try? reader.read(upToCount: 64 * 1024), !chunk.isEmpty {
                let kept = output.append(chunk)
                if let onOutput { onOutput(kept.data) }
                guard kept.within else {
                    // Past the limit: stop reading and end the run, so the
                    // child is not left blocked on a full pipe.
                    control.stop()
                    break
                }
            }
            drained.signal()
        }

        if exited.wait(timeout: .now() + deadline.dispatchInterval) == .timedOut {
            control.stop()
            exited.wait()
        }
        _ = drained.wait(timeout: .now() + drainGrace)
        let (data, overflowed) = output.result
        if overflowed {
            return .truncated(stdout: data)
        }
        if control.wasStopped {
            return .killed
        }
        return .exited(status: process.terminationStatus, stdout: data)
    }
}

/// OutputBuffer accumulates up to a limit of a child's output across threads.
private final class OutputBuffer: Sendable {
    private let storage: Mutex<CappedOutput>

    init(limit: Int) {
        storage = Mutex(CappedOutput(limit: limit))
    }

    /// append adds `chunk`: `within` is false once the output has passed
    /// the limit, and `data` is the part of the chunk that was kept.
    func append(_ chunk: Data) -> (within: Bool, data: Data) {
        storage.withLock { buffer in
            let before = buffer.data.count
            let within = buffer.append(chunk)
            return (within, Data(buffer.data.dropFirst(before)))
        }
    }

    var result: (data: Data, overflowed: Bool) {
        storage.withLock { ($0.data, $0.overflowed) }
    }
}

/// RunControl is the one place a run's child is killed: at the deadline,
/// past the output limit, or on cancellation, whichever comes first.
///
/// Foundation reaps the child and then runs the termination handler, so a
/// kill sent while `exited` is false can in principle meet a pid released a
/// moment earlier; macOS allocates pids sequentially, so that window is
/// negligible. A stop that arrives before the launch is held and applied the
/// moment the pid is known.
///
/// The signal reaches the direct child only. The `k3sm kubectl` wrapper
/// forks `kubectl` and waits for it, so a killed wrapper leaves that
/// grandchild running until it next writes to the closed pipe or finishes
/// on its own; closing that gap is the wrapper's to do.
private final class RunControl: Sendable {
    private struct State {
        var pid: pid_t = 0
        var exited = false
        var stopped = false
    }
    private let state = Mutex(State())

    func launched(_ pid: pid_t) {
        state.withLock { s in
            s.pid = pid
            if s.stopped && !s.exited { kill(pid, SIGKILL) }
        }
    }

    func exited() {
        state.withLock { $0.exited = true }
    }

    func stop() {
        state.withLock { s in
            guard !s.stopped else { return }
            s.stopped = true
            if s.pid > 0 && !s.exited { kill(s.pid, SIGKILL) }
        }
    }

    var wasStopped: Bool {
        state.withLock { $0.stopped }
    }
}

extension Duration {
    /// The duration as a dispatch interval, at millisecond precision.
    var dispatchInterval: DispatchTimeInterval {
        let (seconds, attoseconds) = components
        return .milliseconds(Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000))
    }
}
