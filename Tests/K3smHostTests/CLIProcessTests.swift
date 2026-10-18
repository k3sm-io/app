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
import K3smHost
import K3smStatus
import Synchronization
import Testing

/// These drive the real runner with /bin/sh and /bin/sleep: the kill paths
/// are about processes, so a fake would test nothing.
@Suite("CLI runner")
struct CLIProcessTests {
    static let sh = "/bin/sh"

    private func run(_ script: String, deadline: Duration = .seconds(10), limit: Int = OutputLimit.status,
                     keepErrors: Bool = false, onOutput: (@Sendable (Data) -> Void)? = nil) async -> CLIOutcome {
        await CLIProcess.run(path: Self.sh, arguments: ["-c", script], environment: [:], deadline: deadline, limit: limit,
                             keepErrors: keepErrors, onOutput: onOutput)
    }

    private func seconds(since start: ContinuousClock.Instant) -> Double {
        let d = ContinuousClock.now - start
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    /// A temporary file path for a child to write its pid to.
    private func pidFile() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("k3sm-cli-test-\(UUID().uuidString)").path
    }

    private func readPID(_ path: String, within limit: Duration) async -> pid_t? {
        let start = ContinuousClock.now
        while ContinuousClock.now - start < limit {
            if let text = try? String(contentsOfFile: path, encoding: .utf8),
               let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return pid
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    @Test("a run that exits reports its status and its output")
    func exits() async {
        guard case .exited(let status, let stdout) = await run("printf hi; exit 3") else {
            Issue.record("not exited")
            return
        }
        #expect(status == 3)
        #expect(stdout == Data("hi".utf8))
    }

    @Test("a CLI that is not installed is missing, and nothing runs")
    func missing() async {
        let outcome = await CLIProcess.run(path: "/nonexistent/k3sm", arguments: [], environment: [:], deadline: .seconds(1), limit: 1)
        guard case .missing = outcome else {
            Issue.record("not missing: \(outcome)")
            return
        }
    }

    @Test("output past the limit ends the run at once, with the first limit bytes")
    func truncates() async {
        let start = ContinuousClock.now
        let outcome = await run("exec yes", deadline: .seconds(10), limit: 1024)
        guard case .truncated(let stdout) = outcome else {
            Issue.record("not truncated: \(outcome)")
            return
        }
        #expect(stdout.count == 1024)
        #expect(stdout.prefix(4) == Data("y\ny\n".utf8))
        #expect(seconds(since: start) < 3, "the run waited for its deadline")
    }

    @Test("a run past its deadline is killed")
    func deadline() async {
        let start = ContinuousClock.now
        let outcome = await run("exec /bin/sleep 30", deadline: .milliseconds(300))
        guard case .killed = outcome else {
            Issue.record("not killed: \(outcome)")
            return
        }
        #expect(seconds(since: start) < 3)
    }

    @Test("cancelling the awaiting task kills the child at once")
    func cancel() async {
        let file = pidFile()
        defer { try? FileManager.default.removeItem(atPath: file) }
        let task = Task { await run("echo $$ > '\(file)'; exec /bin/sleep 30", deadline: .seconds(15)) }
        guard let pid = await readPID(file, within: .seconds(5)) else {
            task.cancel()
            Issue.record("the child never started")
            return
        }
        let cancelled = ContinuousClock.now
        task.cancel()
        let outcome = await task.value
        guard case .killed = outcome else {
            Issue.record("not killed: \(outcome)")
            return
        }
        #expect(seconds(since: cancelled) < 3, "the run waited for its deadline")
        // The run returns after the termination handler, so the child is
        // gone: signal 0 to its pid finds no process.
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }

    @Test("standard error is dropped unless the run keeps it")
    func errorsDroppedByDefault() async {
        guard case .exited(_, let stdout) = await run("printf err >&2") else {
            Issue.record("not exited")
            return
        }
        #expect(stdout.isEmpty)
        guard case .exited(_, let kept) = await run("printf err >&2", keepErrors: true) else {
            Issue.record("not exited")
            return
        }
        #expect(kept == Data("err".utf8))
    }

    @Test("kept errors share the output limit")
    func keptErrorsShareTheLimit() async {
        let outcome = await run("exec yes >&2", deadline: .seconds(10), limit: 1024, keepErrors: true)
        guard case .truncated(let stdout) = outcome else {
            Issue.record("not truncated: \(outcome)")
            return
        }
        #expect(stdout.count == 1024)
    }

    @Test("onOutput sees every chunk in order, and together they are the output")
    func onOutputFollows() async {
        let chunks = Mutex<[Data]>([])
        let outcome = await run("printf abc; /bin/sleep 0.2; printf def") { chunk in
            chunks.withLock { $0.append(chunk) }
        }
        guard case .exited(_, let stdout) = outcome else {
            Issue.record("not exited: \(outcome)")
            return
        }
        let seen = chunks.withLock { $0 }
        #expect(stdout == Data("abcdef".utf8))
        #expect(seen.reduce(Data(), +) == stdout)
        #expect(!seen.isEmpty)
    }

    @Test("onOutput stops at the limit: what it saw is what was kept")
    func onOutputWithinTheLimit() async {
        let total = Mutex(0)
        let outcome = await run("exec yes", limit: 1024) { chunk in
            total.withLock { $0 += chunk.count }
        }
        guard case .truncated(let stdout) = outcome else {
            Issue.record("not truncated: \(outcome)")
            return
        }
        #expect(stdout.count == 1024)
        #expect(total.withLock { $0 } == 1024)
    }
}
