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
import Testing

/// These drive the real held-watch launcher with /bin/sh: when a line
/// reaches the stream is about pipes and threads, so a fake would test nothing.
@Suite("held watch launcher")
struct CLIStreamTests {
    /// What the launcher delivered, and whether a line came before the exit.
    @MainActor
    final class Record {
        var lines: [String] = []
        var exited = false
        var linesBeforeExit = false
    }

    @MainActor
    @Test("a line reaches the stream while the watch still runs, not at its exit", .timeLimit(.minutes(1)))
    func lineBeforeExit() async throws {
        let record = Record()
        let stream = CLIStream(environment: [:], path: "/bin/sh")
        // One short frame, then the process holds, as a quiet watch does
        // after its replay: the frame must not wait for more output.
        let process = stream.launch(arguments: ["-c", "printf 'one\\n'; exec /bin/sleep 30"], events: WatchEvents(
            lines: { lines in
                record.lines += lines.map { String(decoding: $0, as: UTF8.self) }
                if !record.exited { record.linesBeforeExit = true }
            },
            errors: { _ in },
            exit: { _ in record.exited = true }))
        let deadline = ContinuousClock.now + .seconds(10)
        while record.lines.isEmpty, !record.exited, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(record.lines == ["one"])
        #expect(record.linesBeforeExit)
        #expect(!record.exited)
        process.kill()
        while !record.exited, ContinuousClock.now < deadline + .seconds(10) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(record.exited)
    }
}
