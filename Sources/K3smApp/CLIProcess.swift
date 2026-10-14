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
    /// The CLI failed its trust check just before the run, so it was not run.
    case refused(String)
}

/// CLIProcess runs the k3sm CLI by absolute path with the environment the
/// caller built, collects its standard output, and kills it at the deadline.
/// It runs on a background thread; callers await the outcome.
enum CLIProcess {
    /// How long to wait for the output pipe to close after the process exits.
    /// A grandchild that inherited the pipe can hold it open; the run does not
    /// wait on it past this.
    private static let drainGrace: DispatchTimeInterval = .milliseconds(500)

    static func run(path: String, arguments: [String], environment: [String: String], deadline: Duration) async -> CLIOutcome {
        guard FileManager.default.isExecutableFile(atPath: path) else {
            return .missing
        }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: runBlocking(path: path, arguments: arguments, environment: environment, deadline: deadline))
            }
        }
    }

    private static func runBlocking(path: String, arguments: [String], environment: [String: String], deadline: Duration) -> CLIOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return .failedToLaunch
        }
        try? pipe.fileHandleForWriting.close()

        let output = OutputBuffer()
        let drained = DispatchSemaphore(value: 0)
        let reader = pipe.fileHandleForReading
        Thread.detachNewThread {
            while let chunk = try? reader.read(upToCount: 64 * 1024), !chunk.isEmpty {
                output.append(chunk)
            }
            drained.signal()
        }

        // The pid cannot be reused before the termination handler runs: the
        // process is not reaped until then, so the kill reaches only this run.
        let pid = process.processIdentifier
        var killed = false
        if exited.wait(timeout: .now() + deadline.dispatchInterval) == .timedOut {
            kill(pid, SIGKILL)
            killed = true
            exited.wait()
        }
        _ = drained.wait(timeout: .now() + drainGrace)
        if killed {
            return .killed
        }
        return .exited(status: process.terminationStatus, stdout: output.data)
    }
}

/// OutputBuffer accumulates a child's output across threads.
private final class OutputBuffer: Sendable {
    private let storage = Mutex(Data())

    func append(_ chunk: Data) {
        storage.withLock { $0.append(chunk) }
    }

    var data: Data {
        storage.withLock { $0 }
    }
}

extension Duration {
    /// The duration as a dispatch interval, at millisecond precision.
    var dispatchInterval: DispatchTimeInterval {
        let (seconds, attoseconds) = components
        return .milliseconds(Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000))
    }
}
