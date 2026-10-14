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
import K3smInstall

/// AppleScriptPrivilegedRunner runs a root step through the standard macOS
/// administrator prompt (`do shell script ... with administrator
/// privileges`). The command line is RootScript's, which wraps the builder's
/// script in a scrubbed environment and the copy-out lock; this type adds
/// only the AppleScript literal and the stdin plumbing. It runs on its own
/// thread so the prompt never blocks the main thread. Tests and ci never
/// construct it.
struct AppleScriptPrivilegedRunner: PrivilegedRunner {
    /// The most stdin the runner forwards: a join token is about a hundred
    /// bytes, and a FIFO's buffer holds far more than this, so the writer
    /// never blocks on a reader that went away.
    static let maxInput = 4096

    func runAsRoot(_ script: RootScript, input: Data?) async -> PrivilegedOutcome {
        await runAsRootReportingError(script, input: input).outcome
    }

    /// Runs the step and keeps `do shell script`'s error message, which is
    /// the script's standard error when it exits non-zero. The text is raw;
    /// the caller cleans it before showing it.
    func runAsRootReportingError(_ script: RootScript, input: Data?) async -> PrivilegedRun {
        if let input, input.count > Self.maxInput {
            return PrivilegedRun(outcome: .couldNotStart)
        }
        return await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(returning: Self.runBlocking(script, input: input))
            }
        }
    }

    private static func runBlocking(_ script: RootScript, input: Data?) -> PrivilegedRun {
        var fifo: InputFIFO?
        if let input {
            guard let made = try? InputFIFO(feeding: input) else { return PrivilegedRun(outcome: .couldNotStart) }
            fifo = made
        }
        defer { fifo?.finish() }
        let command = script.command(inputPath: fifo?.path ?? "/dev/null")
        let source = "do shell script \(AppleScriptText.literal(command))"
            + " with prompt \(AppleScriptText.literal(script.prompt))"
            + " with administrator privileges"
        guard let compiled = NSAppleScript(source: source) else { return PrivilegedRun(outcome: .couldNotStart) }
        var error: NSDictionary?
        compiled.executeAndReturnError(&error)
        guard let error else { return PrivilegedRun(outcome: .succeeded) }
        let number = (error[NSAppleScript.errorNumber] as? NSNumber)?.int32Value ?? -1
        // -128 is userCanceledErr: the prompt was dismissed.
        if number == -128 { return PrivilegedRun(outcome: .cancelled) }
        return PrivilegedRun(outcome: .failed(exitStatus: number), errorOutput: error[NSAppleScript.errorMessage] as? String)
    }
}

/// InputFIFO hands stdin bytes to the root step without writing them to a
/// regular file: a FIFO, mode 0600, in a fresh 0700 directory under the
/// user's temporary directory. A writer thread blocks until root opens the
/// FIFO for reading, writes the bytes, and closes it.
final class InputFIFO: Sendable {
    let path: String
    private let directory: String
    private let written = DispatchSemaphore(value: 0)

    init(feeding data: Data) throws {
        var template = Array((NSTemporaryDirectory() + "k3sm-input.XXXXXX").utf8CString)
        guard mkdtemp(&template) != nil else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        directory = String(decoding: template.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        path = directory + "/input"
        guard mkfifo(path, 0o600) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            rmdir(directory)
            throw POSIXError(code)
        }
        let path = self.path
        let written = self.written
        Thread.detachNewThread {
            let fd = open(path, O_WRONLY)
            if fd >= 0 {
                data.withUnsafeBytes { raw in
                    var offset = 0
                    while offset < raw.count {
                        let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                        if n <= 0 { break }
                        offset += n
                    }
                }
                close(fd)
            }
            written.signal()
        }
    }

    /// Releases a writer still waiting for a reader (the prompt was dismissed
    /// or the script failed before reading), then removes the FIFO and its
    /// directory. The bytes then sit only in the kernel's pipe buffer, which
    /// is freed when the last descriptor closes.
    func finish() {
        if written.wait(timeout: .now()) == .timedOut {
            let fd = open(path, O_RDONLY | O_NONBLOCK)
            written.wait()
            if fd >= 0 { close(fd) }
        }
        unlink(path)
        rmdir(directory)
    }
}
