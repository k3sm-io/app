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
import Testing

@testable import K3smStatus

/// RunProbe records what fake `build logs` runs saw: the ids that started
/// and the ids whose run was cancelled while it was still following, which
/// is where the app's `CLIProcess` kills the CLI.
final class RunProbe: Sendable {
    private let state = Mutex<(started: [String], killed: [String])>(([], []))

    func started(_ id: String) { state.withLock { $0.started.append(id) } }
    func killed(_ id: String) { state.withLock { $0.killed.append(id) } }
    var startedIDs: [String] { state.withLock { $0.started } }
    var killedIDs: [String] { state.withLock { $0.killed } }

    /// A `build logs -f` that prints one line and follows until cancelled.
    func following() -> BuildLogRun {
        { arguments, onOutput in
            let id = arguments.last ?? ""
            self.started(id)
            onOutput(Data("step 1 of \(id)\n".utf8))
            await withTaskCancellationHandler {
                while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            } onCancel: {
                self.killed(id)
            }
            return .stopped
        }
    }
}

@MainActor
@Suite("the build log sheet's read")
struct BuildLogReadTests {
    static func target(_ id: String, follow: Bool = true) -> BuildLogTarget {
        BuildLogTarget(id: BuildRecordID(id)!, title: "web:dev", follow: follow)
    }

    /// Waits up to two seconds for `condition`, letting the main queue run.
    static func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<400 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    @Test("closing the sheet kills the followed build logs -f")
    func closeKillsTheFollow() async {
        let probe = RunProbe()
        let slot = BuildLogSlot()
        let read = slot.open(Self.target("aaaaaaaaaaaa"))
        #expect(read.arguments == ["build", "logs", "-f", "aaaaaaaaaaaa"])
        read.start(probe.following())
        #expect(await Self.eventually { !read.data.isEmpty })
        #expect(probe.killedIDs.isEmpty)
        slot.close()
        #expect(await Self.eventually { probe.killedIDs == ["aaaaaaaaaaaa"] })
        #expect(slot.current == nil && read.stopped && read.end == .reading)
    }

    @Test("opening another log kills the one it replaces, and only that one")
    func replaceKillsTheOld() async {
        let probe = RunProbe()
        let slot = BuildLogSlot()
        let first = slot.open(Self.target("aaaaaaaaaaaa"))
        first.start(probe.following())
        #expect(await Self.eventually { probe.startedIDs == ["aaaaaaaaaaaa"] })
        let second = slot.open(Self.target("bbbbbbbbbbbb"))
        second.start(probe.following())
        #expect(await Self.eventually { probe.killedIDs == ["aaaaaaaaaaaa"] && probe.startedIDs.count == 2 })
        #expect(slot.current === second && !second.stopped)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(probe.killedIDs == ["aaaaaaaaaaaa"])
        // Output from the replaced read never reaches it after the stop.
        let kept = first.data
        slot.close()
        #expect(await Self.eventually { probe.killedIDs == ["aaaaaaaaaaaa", "bbbbbbbbbbbb"] })
        #expect(first.data == kept)
    }

    @Test("a stopped read never starts its run")
    func stoppedNeverStarts() async {
        let probe = RunProbe()
        let read = BuildLogRead(target: Self.target("aaaaaaaaaaaa"))
        read.stop()
        read.start(probe.following())
        try? await Task.sleep(for: .milliseconds(50))
        #expect(probe.startedIDs.isEmpty)
    }

    @Test("a finished build's log reads to its end, in order, with nothing killed")
    func finishedRead() async {
        let probe = RunProbe()
        let read = BuildLogRead(target: Self.target("cccccccccccc", follow: false))
        #expect(read.arguments == ["build", "logs", "cccccccccccc"])
        var changes = 0
        read.changed = { changes += 1 }
        read.start { _, onOutput in
            onOutput(Data("one\n".utf8))
            onOutput(Data("two\n".utf8))
            return .exited(0)
        }
        #expect(await Self.eventually { read.end == .exited(0) })
        #expect(String(decoding: read.data, as: UTF8.self) == "one\ntwo\n")
        #expect(changes == 3)
        #expect(probe.killedIDs.isEmpty)
    }
}
