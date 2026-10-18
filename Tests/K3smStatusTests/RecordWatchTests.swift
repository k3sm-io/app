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
import Testing

@testable import K3smStatus

/// FakeChangeSource is a `ChangeSource` the test drives by hand.
final class FakeChangeSource: ChangeSource, @unchecked Sendable {
    private var continuation: AsyncStream<RecordChange>.Continuation?
    private(set) var rechecks = 0

    func start() -> AsyncStream<RecordChange> {
        let (stream, continuation) = AsyncStream<RecordChange>.makeStream()
        self.continuation = continuation
        return stream
    }

    func recheck() { rechecks += 1 }

    func stop() {
        continuation?.finish()
        continuation = nil
    }

    func send(_ change: RecordChange) { continuation?.yield(change) }
}

/// ReadCounter counts the trigger's reads, and how many ran at once.
@MainActor
final class ReadCounter {
    var reads = 0
    var running = 0
    var overlapped = false
    /// While set, a read waits here until the test lets it go.
    var hold: CheckedContinuation<Void, Never>?
    var blocking = false

    func read() async {
        reads += 1
        running += 1
        if running > 1 { overlapped = true }
        if blocking { await withCheckedContinuation { hold = $0 } }
        running -= 1
    }

    func release() {
        hold?.resume()
        hold = nil
    }
}

/// Lets the stream's listener and the read tasks run.
@MainActor
private func settle() async {
    for _ in 0..<50 { await Task.yield() }
}

@MainActor
@Suite("the report trigger", .serialized)
struct RecordWatchTests {
    private static let heartbeat: Duration = .seconds(5 * 60)
    private static let fallback: Duration = .seconds(30)

    private static func fake() -> (ReportTrigger, FakeChangeSource, VirtualClock, ReadCounter) {
        let source = FakeChangeSource()
        let clock = VirtualClock()
        let counter = ReadCounter()
        let trigger = ReportTrigger(source: source, clock: clock, heartbeat: { heartbeat }, fallback: { fallback },
                                    jitter: { 0 }, read: { await counter.read() })
        return (trigger, source, clock, counter)
    }

    private static func advance(_ clock: VirtualClock, by step: Duration) async {
        clock.advance(by: step)
        await settle()
    }

    // MARK: the loop, on a virtual clock

    @Test("no event means no read until the heartbeat, with every watch held")
    func noEventNoRead() async {
        let (trigger, source, clock, counter) = Self.fake()
        trigger.start()
        source.send(.held(true))
        await settle()
        #expect(trigger.held)
        #expect(trigger.cadence == Self.heartbeat)
        await Self.advance(clock, by: .seconds(299))
        #expect(counter.reads == 0)
        #expect(source.rechecks == 0)
        await Self.advance(clock, by: .seconds(1))
        #expect(counter.reads == 1)
        #expect(source.rechecks == 1, "the heartbeat re-checks the paths' identity")
        trigger.stop()
    }

    @Test("a change is read once, 250 ms after it")
    func changeReadAfterQuiet() async {
        let (trigger, source, clock, counter) = Self.fake()
        trigger.start()
        source.send(.held(true))
        source.send(.changed)
        await settle()
        await Self.advance(clock, by: .milliseconds(249))
        #expect(counter.reads == 0)
        await Self.advance(clock, by: .milliseconds(1))
        #expect(counter.reads == 1)
        await Self.advance(clock, by: .seconds(60))
        #expect(counter.reads == 1)
        trigger.stop()
    }

    @Test("a burst coalesces to one read; a burst that never pauses is read at the 3 s ceiling")
    func burstCoalesces() async {
        let (trigger, source, clock, counter) = Self.fake()
        trigger.start()
        source.send(.held(true))
        await settle()
        for _ in 0..<10 {
            source.send(.changed)
            await settle()
            await Self.advance(clock, by: .milliseconds(100))
        }
        #expect(counter.reads == 0)
        await Self.advance(clock, by: .milliseconds(150))
        #expect(counter.reads == 1)
        await Self.advance(clock, by: .seconds(10))
        #expect(counter.reads == 1)

        for _ in 0..<50 {
            source.send(.changed)
            await settle()
            await Self.advance(clock, by: .milliseconds(100))
        }
        // 5 s of changes 100 ms apart: one read at 3 s, one 250 ms after the last.
        #expect(counter.reads == 2)
        await Self.advance(clock, by: .milliseconds(250))
        #expect(counter.reads == 3)
        trigger.stop()
    }

    @Test("a lost watch falls back to the 30 s cadence, never the bare heartbeat")
    func lostWatchFallsBack() async {
        let (trigger, source, clock, counter) = Self.fake()
        trigger.start()
        // Before the source says it holds every path, the timer is 30 s.
        #expect(trigger.cadence == Self.fallback)
        source.send(.held(true))
        await settle()
        await Self.advance(clock, by: .seconds(100))
        #expect(counter.reads == 0)
        source.send(.held(false))
        await settle()
        #expect(trigger.cadence == Self.fallback)
        await Self.advance(clock, by: .seconds(30))
        #expect(counter.reads == 1)
        await Self.advance(clock, by: .seconds(30))
        #expect(counter.reads == 2)
        #expect(source.rechecks == 2, "each fallback tick tries to arm the watch again")
        source.send(.held(true))
        await settle()
        await Self.advance(clock, by: .seconds(299))
        #expect(counter.reads == 2)
        await Self.advance(clock, by: .seconds(1))
        #expect(counter.reads == 3)
        trigger.stop()
    }

    @Test("reads never overlap: a change during a read is one more read after it")
    func readsNeverOverlap() async {
        let (trigger, source, clock, counter) = Self.fake()
        trigger.start()
        source.send(.held(true))
        counter.blocking = true
        source.send(.changed)
        await settle()
        await Self.advance(clock, by: .milliseconds(250))
        #expect(counter.reads == 1)
        for _ in 0..<3 {
            source.send(.changed)
            await settle()
            await Self.advance(clock, by: .seconds(1))
        }
        #expect(counter.reads == 1)
        counter.blocking = false
        counter.release()
        await settle()
        #expect(counter.reads == 2)
        #expect(!counter.overlapped)
        trigger.stop()
    }

    @Test("the status item's probe: 15 s while shown, 60 s while hidden")
    func probeCadence() {
        #expect(PollSchedule.interval(visible: true, in: PollProfile.normal.intervals) == .seconds(15))
        #expect(PollSchedule.interval(visible: false, in: PollProfile.normal.intervals) == .seconds(60))
        #expect(PollSchedule.interval(visible: true, in: PollProfile.lowPower.intervals) == .seconds(30))
        #expect(PollSchedule.interval(visible: false, in: PollProfile.lowPower.intervals) == .seconds(120))
        // The tabs keep their own cadence.
        #expect(PollSchedule.interval(for: .workloads, engineReady: false, in: PollProfile.normal.intervals) == .seconds(5))
        #expect(PollProfile.normal.intervals.consoleHeartbeat == .seconds(5 * 60))
        #expect(PollProfile.normal.intervals.consoleReport == .seconds(30))
        #expect(RecordWatchPolicy.quiet == WatchPolicy.settleQuiet)
        #expect(RecordWatchPolicy.ceiling == WatchPolicy.settleCap)
    }

    // MARK: the real watch, on a temp directory

    private final class TempDir {
        let url: URL
        init() throws {
            url = FileManager.default.temporaryDirectory.appendingPathComponent("k3sm-recordwatch-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: url) }
        func path(_ name: String) -> String { url.appendingPathComponent(name).path }
    }

    private static func real(_ path: String) -> (ReportTrigger, DirectoryChangeSource, ReadCounter) {
        let source = DirectoryChangeSource(paths: [path])
        let counter = ReadCounter()
        let trigger = ReportTrigger(source: source, clock: WatchSystemClock(), heartbeat: { .seconds(3600) },
                                    fallback: { .seconds(3600) }, jitter: { 0 }, read: { await counter.read() })
        return (trigger, source, counter)
    }

    /// Waits up to 2 s for `count` reads, then a further 600 ms (past the
    /// debounce), and returns the count: one change reads exactly once.
    private static func reads(_ counter: ReadCounter, reaching count: Int) async throws -> Int {
        for _ in 0..<100 where counter.reads < count {
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(600))
        return counter.reads
    }

    private static func waitHeld(_ trigger: ReportTrigger, _ want: Bool = true) async throws {
        for _ in 0..<100 where trigger.held != want {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test("a record created in the watched directory is read once")
    func realCreate() async throws {
        let dir = try TempDir()
        let status = dir.path("status")
        try FileManager.default.createDirectory(atPath: status, withIntermediateDirectories: false)
        let (trigger, _, counter) = Self.real(status)
        trigger.start()
        try await Self.waitHeld(trigger)
        #expect(trigger.held)
        try Data("{}".utf8).write(to: URL(fileURLWithPath: status + "/services.json"))
        #expect(try await Self.reads(counter, reaching: 1) == 1)
        trigger.stop()
    }

    @Test("a record replaced by temp file and rename is read once")
    func realRenameReplace() async throws {
        let dir = try TempDir()
        let status = dir.path("status")
        try FileManager.default.createDirectory(atPath: status, withIntermediateDirectories: false)
        try Data("{}".utf8).write(to: URL(fileURLWithPath: status + "/endpoints.json"))
        let (trigger, _, counter) = Self.real(status)
        trigger.start()
        try await Self.waitHeld(trigger)
        let temp = status + "/.endpoints.json.tmp"
        try Data(#"{"a":1}"#.utf8).write(to: URL(fileURLWithPath: temp))
        #expect(rename(temp, status + "/endpoints.json") == 0)
        #expect(try await Self.reads(counter, reaching: 1) == 1)
        trigger.stop()
    }

    @Test("a record deleted is read once")
    func realDelete() async throws {
        let dir = try TempDir()
        let status = dir.path("status")
        try FileManager.default.createDirectory(atPath: status, withIntermediateDirectories: false)
        try Data("{}".utf8).write(to: URL(fileURLWithPath: status + "/update.json"))
        let (trigger, _, counter) = Self.real(status)
        trigger.start()
        try await Self.waitHeld(trigger)
        try FileManager.default.removeItem(atPath: status + "/update.json")
        #expect(try await Self.reads(counter, reaching: 1) == 1)
        trigger.stop()
    }

    @Test("a directory that appears late is watched, and read once when it appears")
    func realLateDirectory() async throws {
        let dir = try TempDir()
        let status = dir.path("data/status")
        let (trigger, _, counter) = Self.real(status)
        trigger.start()
        try await Task.sleep(for: .milliseconds(100))
        #expect(!trigger.held, "a missing path is not held: the timer stays at the fallback")
        try FileManager.default.createDirectory(atPath: dir.path("data"), withIntermediateDirectories: false)
        try await Task.sleep(for: .milliseconds(100))
        #expect(counter.reads == 0, "a nearer ancestor appearing is not a change")
        try FileManager.default.createDirectory(atPath: status, withIntermediateDirectories: false)
        #expect(try await Self.reads(counter, reaching: 1) == 1)
        #expect(trigger.held)
        try Data("{}".utf8).write(to: URL(fileURLWithPath: status + "/mesh-claims.json"))
        #expect(try await Self.reads(counter, reaching: 2) == 2)
        trigger.stop()
    }

    @Test("a directory removed and recreated is armed again")
    func realRecreate() async throws {
        let dir = try TempDir()
        let status = dir.path("status")
        try FileManager.default.createDirectory(atPath: status, withIntermediateDirectories: false)
        let (trigger, _, counter) = Self.real(status)
        trigger.start()
        try await Self.waitHeld(trigger)
        try FileManager.default.removeItem(atPath: status)
        #expect(try await Self.reads(counter, reaching: 1) == 1)
        #expect(!trigger.held)
        try FileManager.default.createDirectory(atPath: status, withIntermediateDirectories: false)
        #expect(try await Self.reads(counter, reaching: 2) == 2)
        #expect(trigger.held)
        try Data("{}".utf8).write(to: URL(fileURLWithPath: status + "/registry-state.json"))
        #expect(try await Self.reads(counter, reaching: 3) == 3)
        trigger.stop()
    }

    @Test("a directory replaced without an event is armed again by the identity re-check")
    func realIdentityRecheck() async throws {
        let dir = try TempDir()
        let status = dir.path("data/status")
        try FileManager.default.createDirectory(atPath: status, withIntermediateDirectories: true)
        let (trigger, source, counter) = Self.real(status)
        trigger.start()
        try await Self.waitHeld(trigger)
        // Renaming the parent away sends the watched directory no event, as
        // a volume mounted over the mountpoint does not: the path now names
        // another directory, which the old source never sees.
        #expect(rename(dir.path("data"), dir.path("old")) == 0)
        try FileManager.default.createDirectory(atPath: status, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: URL(fileURLWithPath: status + "/services.json"))
        #expect(try await Self.reads(counter, reaching: 1) == 0)
        source.recheck()
        #expect(try await Self.reads(counter, reaching: 1) == 1)
        #expect(trigger.held)
        try Data("{}".utf8).write(to: URL(fileURLWithPath: status + "/endpoints.json"))
        #expect(try await Self.reads(counter, reaching: 2) == 2)
        trigger.stop()
    }

    @Test("ancestors are resolved and the path is kept as written")
    func resolve() async throws {
        #expect(DirectoryChangeSource.resolve("/var/lib/k3sm/status") == "/private/var/lib/k3sm/status")
        #expect(DirectoryChangeSource.resolve("/Library/LaunchDaemons") == "/Library/LaunchDaemons")
        let dir = try TempDir()
        let link = dir.path("link")
        try FileManager.default.createDirectory(atPath: dir.path("target"), withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: dir.path("target"))
        // A symlink as the watched path itself is never followed: not held.
        let source = DirectoryChangeSource(paths: [link])
        let stream = source.start()
        var changes = stream.makeAsyncIterator()
        source.stop()
        var seen: [RecordChange] = []
        while let change = await changes.next() { seen.append(change) }
        #expect(seen == [.held(false)])
    }
}
