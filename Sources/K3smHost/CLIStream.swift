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

/// CLIStream is the app's `WatchLauncher`: it starts a held `k3sm kubectl
/// get <kind> -w` by absolute path with the environment the app built,
/// never through a shell, and hands its output to the `WatchStream` that
/// owns it. Standard output is line-framed (`WatchLineFramer`, 2 MiB a
/// line) and delivered in batches on the main actor; the reader blocks when
/// `queueDepth` batches are waiting, so a slow main thread slows the read
/// rather than losing a frame. Standard error has its own pipe, of which
/// the last 4 KiB is kept and passed, through `StatusDisplay.errorText`,
/// to the stream as it grows and with the exit; the stream reads no auth
/// failure from it. An
/// overlong line kills the process and ends it as `.lineTooLong`. The child
/// is killed (`RunControl`) when the stream kills it, and every child still
/// held is in `WatchChildren` so `killAll()` ends them when the app
/// terminates.
/// `CLIProcess` is not used for the held watch and is unchanged; the
/// one-shot list goes through it.
@MainActor
public final class CLIStream: WatchLauncher {
    /// The most line batches waiting for the main actor before the reader blocks.
    public nonisolated static let queueDepth = 32
    /// How long to wait for the pipes to close after the process exits.
    nonisolated static let drainGrace: DispatchTimeInterval = .seconds(2)

    private let path: String
    private let environment: [String: String]

    public init(environment: [String: String], path: String = K3smCLI.path) {
        self.environment = environment
        self.path = path
    }

    public func launch(arguments: [String], events: WatchEvents) -> any WatchProcess {
        let control = RunControl()
        guard FileManager.default.isExecutableFile(atPath: path) else {
            Task { @MainActor in events.exit(.missing) }
            return Handle(control: control)
        }
        let path = path
        let environment = environment
        DispatchQueue.global(qos: .utility).async {
            Self.run(path: path, arguments: arguments, environment: environment, events: events, control: control)
        }
        return Handle(control: control)
    }

    public func list(arguments: [String], completion: @escaping @MainActor @Sendable (Int32?, Data) -> Void) {
        let path = path
        let environment = environment
        Task.detached {
            let outcome = await CLIProcess.run(
                path: path, arguments: arguments, environment: environment,
                deadline: PollSchedule.listDeadline, limit: OutputLimit.list)
            let status: Int32?
            let stdout: Data
            if case .exited(let code, let out) = outcome {
                status = code
                stdout = out
            } else {
                status = nil
                stdout = Data()
            }
            await MainActor.run { completion(status, stdout) }
        }
    }

    /// Kills every held watch the app started and still owns: called as the
    /// app terminates, so no `kubectl` watch outlives it. Only a child whose
    /// `Process` is still running is signalled, through its `RunControl`,
    /// which refuses once the child has exited; a reaped child is never in
    /// the set (`WatchChildren`).
    public nonisolated static func killAll() {
        children.killAll { child in
            if child.process.isRunning { child.control.stop() }
        }
    }

    /// The held watch's handle: the stream's kill is `RunControl`'s stop.
    private final class Handle: WatchProcess {
        let control: RunControl
        init(control: RunControl) { self.control = control }
        func kill() { control.stop() }
    }

    /// A held child: its `Process` and the control that kills it.
    private final class Child: @unchecked Sendable {
        let process: Process
        let control: RunControl
        init(process: Process, control: RunControl) {
            self.process = process
            self.control = control
        }
    }

    private nonisolated static let children = WatchChildren<Child>()

    /// One held watch, on a background thread until the process exits and
    /// its pipes drain; every delivery is queued to the main actor in order,
    /// the exit last.
    private nonisolated static func run(path: String, arguments: [String], environment: [String: String],
                                        events: WatchEvents, control: RunControl) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        let exited = DispatchSemaphore(value: 0)
        // The slot is reserved before the launch and released by the reap,
        // so a child that exits before it is recorded is never recorded.
        let slot = children.reserve()
        process.terminationHandler = { _ in
            control.exited()
            children.reaped(slot)
            exited.signal()
        }
        do {
            try process.run()
        } catch {
            children.reaped(slot)
            onMain { events.exit(.failedToLaunch) }
            return
        }
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
        control.launched(process.processIdentifier)
        children.launched(slot, child: Child(process: process, control: control))

        let overflowed = Atomic<Bool>(false)
        let tail = Mutex(Data())
        let outputDone = DispatchSemaphore(value: 0)
        let errorsDone = DispatchSemaphore(value: 0)
        let slots = DispatchSemaphore(value: queueDepth)

        Thread.detachNewThread {
            let fd = output.fileHandleForReading.fileDescriptor
            var framer = WatchLineFramer()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while let chunk = PipeRead.available(fd, into: &buffer) {
                let lines = framer.append(chunk)
                deliver(lines, events: events, slots: slots)
                if framer.overflowed {
                    overflowed.store(true, ordering: .sequentiallyConsistent)
                    control.stop()
                    break
                }
            }
            if let last = framer.finish() { deliver([last], events: events, slots: slots) }
            outputDone.signal()
        }
        Thread.detachNewThread {
            let fd = errors.fileHandleForReading.fileDescriptor
            var buffer = [UInt8](repeating: 0, count: 4096)
            while let chunk = PipeRead.available(fd, into: &buffer) {
                let text = tail.withLock { kept in
                    kept.append(chunk)
                    if kept.count > WatchPolicy.errorTail { kept = Data(kept.suffix(WatchPolicy.errorTail)) }
                    return StatusDisplay.errorText(String(decoding: kept, as: UTF8.self))
                }
                onMain { events.errors(text) }
            }
            errorsDone.signal()
        }

        exited.wait()
        _ = outputDone.wait(timeout: .now() + drainGrace)
        _ = errorsDone.wait(timeout: .now() + drainGrace)
        let exit: WatchExit
        if overflowed.load(ordering: .sequentiallyConsistent) {
            exit = .lineTooLong
        } else {
            let text = tail.withLock { StatusDisplay.errorText(String(decoding: $0, as: UTF8.self)) }
            exit = .exited(status: process.terminationStatus, errors: text)
        }
        onMain { events.exit(exit) }
    }

    /// Queues one batch to the main actor, waiting for a slot first: the
    /// backpressure that keeps every frame without an unbounded queue.
    private nonisolated static func deliver(_ lines: [Data], events: WatchEvents, slots: DispatchSemaphore) {
        guard !lines.isEmpty else { return }
        slots.wait()
        DispatchQueue.main.async {
            MainActor.assumeIsolated { events.lines(lines) }
            slots.signal()
        }
    }

    private nonisolated static func onMain(_ work: @escaping @MainActor @Sendable () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
    }
}
