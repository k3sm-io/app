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

import K3smStatus
@testable import K3smInstall

/// A fixed table of interface addresses.
struct FixedAddresses: JoinAddressSource {
    let all: [InterfaceAddress]
    func interfaceAddresses() -> [InterfaceAddress] { all }
}

/// A pasteboard that records each write and clear, and whose change count a
/// test can bump as another app's copy would.
@MainActor
final class FakePasteboard: Pasteboard {
    struct Write: Equatable {
        let text: String
        let types: [PasteboardType]
        let options: PasteboardOptions
    }

    private var count = 40
    private(set) var countReads = 0
    private(set) var writes: [Write] = []
    private(set) var clears = 0
    /// What the pasteboard holds now.
    private(set) var contents: String?
    private(set) var currentTypes: [PasteboardType] = []

    var types: [PasteboardType] { currentTypes }
    func string() -> String? { contents }

    /// Another app put this item on the pasteboard.
    func put(_ text: String?, types: [PasteboardType]) {
        count += 1
        contents = text
        currentTypes = types
    }

    var changeCount: Int {
        countReads += 1
        return count
    }

    func write(_ text: String, types: [PasteboardType], options: PasteboardOptions) -> Int {
        count += 1
        writes.append(Write(text: text, types: types, options: options))
        contents = text
        currentTypes = types
        return count
    }

    func clearContents() {
        count += 1
        clears += 1
        contents = nil
        currentTypes = []
    }

    /// Another app copied something.
    func bump() {
        count += 1
        contents = "someone else's"
        currentTypes = [.string]
    }
}

/// A clock a test sets by hand.
@MainActor
final class TestClock {
    var now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    func advance(to seconds: TimeInterval, from start: Date) { now = start.addingTimeInterval(seconds) }
}

/// A scheduler that holds its timers until the test fires them.
@MainActor
final class FakeScheduler: ClearScheduler {
    final class Timer: ClearTimer {
        let deadline: Date
        let fire: @MainActor @Sendable () -> Void
        private(set) var cancelled = false
        init(deadline: Date, fire: @escaping @MainActor @Sendable () -> Void) {
            self.deadline = deadline
            self.fire = fire
        }
        func cancel() { cancelled = true }
    }

    private(set) var timers: [Timer] = []

    func schedule(at deadline: Date, _ fire: @escaping @MainActor @Sendable () -> Void) -> any ClearTimer {
        let t = Timer(deadline: deadline, fire: fire)
        timers.append(t)
        return t
    }

    var live: [Timer] { timers.filter { !$0.cancelled } }

    /// Fires every live timer once, as a wake or a deadline would.
    func fireLive() {
        let due = live
        timers.removeAll { t in due.contains { $0 === t } }
        for t in due { t.fire() }
    }
}

/// Log lines the driver wrote.
final class LogLines: Sendable {
    private let seen = Mutex<[String]>([])
    func append(_ s: String) { seen.withLock { $0.append(s) } }
    var all: [String] { seen.withLock { $0 } }
}

/// A runner that returns a fixed capture and records every script.
final class CapturingRunner: PrivilegedRunner {
    let capture: Result<String, PrivilegedFailure>
    private let seen = Mutex<[RootScript]>([])
    private let plain = Mutex(0)

    init(_ capture: Result<String, PrivilegedFailure>) {
        self.capture = capture
    }

    var scripts: [RootScript] { seen.withLock { $0 } }
    var plainRuns: Int { plain.withLock { $0 } }

    func runAsRoot(_ script: RootScript, input: Data?) async -> PrivilegedOutcome {
        plain.withLock { $0 += 1 }
        seen.withLock { $0.append(script) }
        return .succeeded
    }

    func runAsRootCapturingOutput(_ script: RootScript) async -> Result<String, PrivilegedFailure> {
        seen.withLock { $0.append(script) }
        return capture
    }
}

let lan = InterfaceAddress(interface: "en0", address: "192.0.2.10")
let mesh = InterfaceAddress(interface: "utun4", address: "100.64.0.1", pointToPoint: true)

/// Where the join address comes from: the underlay only, exactly one.
@Suite("join address")
struct JoinAddressTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let addresses: [InterfaceAddress]
        let want: JoinAddressResolution
        var testDescription: String { name }
    }

    static let one = JoinAddressResolution.one(try! ServerAddress(parsing: "192.0.2.10"))

    static let cases: [Case] = [
        Case(name: "one LAN address", addresses: [lan], want: one),
        Case(name: "the mesh tunnel is never used", addresses: [lan, mesh], want: one),
        Case(name: "a mesh-range address on any interface is never used",
             addresses: [lan, InterfaceAddress(interface: "en7", address: "100.64.1.1")], want: one),
        Case(name: "the top of the mesh range is excluded",
             addresses: [lan, InterfaceAddress(interface: "en7", address: "100.127.255.254")], want: one),
        Case(name: "just outside the mesh range is a candidate",
             addresses: [lan, InterfaceAddress(interface: "en7", address: "100.128.0.1")], want: .several(["100.128.0.1", "192.0.2.10"])),
        Case(name: "loopback is never used",
             addresses: [lan, InterfaceAddress(interface: "lo0", address: "127.0.0.1", loopback: true)], want: one),
        Case(name: "link-local is never used",
             addresses: [lan, InterfaceAddress(interface: "en1", address: "169.254.3.4")], want: one),
        Case(name: "a VM NAT bridge is never used",
             addresses: [lan, InterfaceAddress(interface: "bridge100", address: "192.168.64.1")], want: one),
        Case(name: "an interface that is down is never used",
             addresses: [lan, InterfaceAddress(interface: "en1", address: "10.0.0.5", up: false)], want: one),
        Case(name: "an interface that is not running is never used",
             addresses: [lan, InterfaceAddress(interface: "en1", address: "10.0.0.5", running: false)], want: one),
        Case(name: "no LAN address", addresses: [mesh], want: .none),
        Case(name: "nothing at all", addresses: [], want: .none),
        Case(name: "two LAN addresses are ambiguous",
             addresses: [lan, InterfaceAddress(interface: "en1", address: "10.0.0.5")], want: .several(["10.0.0.5", "192.0.2.10"])),
        Case(name: "the same address twice is one",
             addresses: [lan, InterfaceAddress(interface: "en1", address: "192.0.2.10")], want: one),
        Case(name: "a malformed address is ignored",
             addresses: [lan, InterfaceAddress(interface: "en1", address: "10.0.0.05")], want: one),
    ]

    @Test("the underlay address choice", arguments: cases)
    func choice(_ c: Case) {
        #expect(JoinAddress.select(c.addresses) == c.want)
        #expect(JoinAddress.resolve(FixedAddresses(all: c.addresses)) == c.want)
    }

    @Test("zero and several say why")
    func reasons() {
        #expect(JoinAddressResolution.none.disabledReason?.contains("no local network IPv4 address") == true)
        let several = JoinAddressResolution.several(["10.0.0.5", "192.0.2.10"]).disabledReason ?? ""
        #expect(several.contains("10.0.0.5, 192.0.2.10"))
        #expect(several.contains("stays off while more than one is active"))
        #expect(several.contains("A later version will let you choose the address"))
        #expect(Self.one.disabledReason == nil)
    }
}

/// When Copy Join Command shows and is enabled.
@Suite("copy join gating")
struct CopyJoinGatingTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let report: StatusReport?
        let availability: PrivilegedAvailability
        let busy: Bool
        let addresses: JoinAddressResolution
        let want: String
        var testDescription: String { name }
    }

    static let addr = try! ServerAddress(parsing: "192.0.2.10")
    static let ok = PrivilegedAvailability.enabled
    static let unsigned = PrivilegedAvailability.disabled(reason: "not signed")

    static let cases: [Case] = [
        Case(name: "a running server with one address is enabled", report: Reports.running, availability: ok, busy: false,
             addresses: .one(addr), want: "enabled"),
        Case(name: "a worker never shows it", report: Reports.make(role: "agent", nodeState: "running", verdict: "running"),
             availability: ok, busy: false, addresses: .one(addr), want: "hidden"),
        Case(name: "no report hides it", report: nil, availability: ok, busy: false, addresses: .one(addr), want: "hidden"),
        Case(name: "a stopped server disables it", report: Reports.stopped, availability: ok, busy: false,
             addresses: .one(addr), want: "not running"),
        Case(name: "privileged actions unavailable disables it", report: Reports.running, availability: unsigned, busy: false,
             addresses: .one(addr), want: "not signed"),
        Case(name: "another change running disables it", report: Reports.running, availability: ok, busy: true,
             addresses: .one(addr), want: "Another change"),
        Case(name: "no address disables it", report: Reports.running, availability: ok, busy: false,
             addresses: .none, want: "no local network"),
        Case(name: "several addresses disable it", report: Reports.running, availability: ok, busy: false,
             addresses: .several(["10.0.0.5", "192.0.2.10"]), want: "several local network"),
    ]

    @Test("the gating table", arguments: cases)
    func gate(_ c: Case) {
        let state = CopyJoinCommand.evaluate(report: c.report, availability: c.availability, busy: c.busy, addresses: c.addresses)
        switch (state, c.want) {
        case (.enabled(let a), "enabled"): #expect(a == Self.addr)
        case (.hidden, "hidden"): break
        case (.disabled(let why), let want) where want != "enabled" && want != "hidden": #expect(why.contains(want), "\(why)")
        default: Issue.record("got \(state), want \(c.want)")
        }
    }

    @Test("the menu and result notes name the lifetime, the concealment and the history")
    func notes() {
        let menu = CopyJoinCommand.menuNote
        #expect(menu.contains("15 minutes") && menu.contains("concealed") && menu.contains("this Mac only") && menu.contains("60 s"))
        let note = CopyJoinCommand.copiedNote
        for phrase in ["expires in 15 minutes", "concealed item", "stays on this Mac", "cleared after 60 seconds",
                       "some clipboard managers may still keep it", "shell history until it expires",
                       "quits unexpectedly before the 60 seconds are up", "until k3sm next starts or something else is copied"] {
            #expect(note.contains(phrase), "the note lost \(phrase)")
        }
    }
}

/// The concealed, local-only pasteboard item and its clear.
@Suite("concealed clipboard")
@MainActor
struct ConcealedClipboardTests {
    static func make() -> (ConcealedClipboard, FakePasteboard, FakeScheduler, TestClock) {
        let pb = FakePasteboard()
        let sched = FakeScheduler()
        let clock = TestClock()
        return (ConcealedClipboard(pasteboard: pb, scheduler: sched, now: { clock.now }), pb, sched, clock)
    }

    @Test("one write declares the string and concealed types, this Mac only")
    func flags() {
        let (clip, pb, sched, clock) = Self.make()
        clip.copy("cmd")
        #expect(pb.writes == [FakePasteboard.Write(text: "cmd", types: [.string, .concealed], options: [.currentHostOnly])])
        #expect(PasteboardType.concealed.rawValue == "org.nspasteboard.ConcealedType")
        #expect(PasteboardType.string.rawValue == "public.utf8-plain-text")
        #expect(sched.live.map(\.deadline) == [clock.now.addingTimeInterval(60)])
    }

    @Test("the baseline is the count the write returned, never a later read")
    func baselineFromWrite() {
        let (clip, pb, _, _) = Self.make()
        clip.copy("cmd")
        #expect(pb.countReads == 0)
    }

    @Test("59 s present, 60 s cleared when unchanged")
    func clearsAt60() {
        let (clip, pb, sched, clock) = Self.make()
        let start = clock.now
        clip.copy("cmd")
        clock.advance(to: 59, from: start)
        sched.fireLive()
        #expect(pb.contents == "cmd")
        #expect(pb.clears == 0)
        #expect(clip.isPending)
        clock.advance(to: 60, from: start)
        sched.fireLive()
        #expect(pb.contents == nil)
        #expect(pb.clears == 1)
        #expect(!clip.isPending)
    }

    @Test("a sleep past the deadline clears on the first fire after it")
    func sleepDoesNotExtend() {
        let (clip, pb, sched, clock) = Self.make()
        let start = clock.now
        clip.copy("cmd")
        clock.advance(to: 3600, from: start)
        sched.fireLive()
        #expect(pb.clears == 1)
        #expect(!clip.isPending)
    }

    @Test("a foreign copy is left alone")
    func foreignBump() {
        let (clip, pb, sched, clock) = Self.make()
        let start = clock.now
        clip.copy("cmd")
        pb.bump()
        clock.advance(to: 60, from: start)
        sched.fireLive()
        #expect(pb.clears == 0)
        #expect(pb.contents == "someone else's")
        #expect(!clip.isPending)
    }

    @Test("a second use cancels the first timer and re-baselines")
    func secondUse() {
        let (clip, pb, sched, clock) = Self.make()
        let start = clock.now
        clip.copy("first")
        let firstTimer = sched.live.first
        clock.advance(to: 30, from: start)
        clip.copy("second")
        #expect(firstTimer?.cancelled == true)
        #expect(sched.live.count == 1)
        clock.advance(to: 60, from: start)
        sched.fireLive()
        #expect(pb.contents == "second")
        #expect(pb.clears == 0)
        clock.advance(to: 90, from: start)
        sched.fireLive()
        #expect(pb.contents == nil)
        #expect(pb.clears == 1)
    }

    @Test("quit clears an unchanged item, and only that")
    func terminate() {
        let (clip, pb, sched, _) = Self.make()
        clip.copy("cmd")
        clip.clearIfUnchanged()
        #expect(pb.clears == 1)
        #expect(sched.live.isEmpty)
        #expect(!clip.isPending)

        let (clip2, pb2, _, _) = Self.make()
        clip2.copy("cmd")
        pb2.bump()
        clip2.clearIfUnchanged()
        #expect(pb2.clears == 0)

        let (clip3, pb3, _, _) = Self.make()
        clip3.clearIfUnchanged()
        #expect(pb3.clears == 0)
    }
}

/// The launch-time sweep of a join command a crashed run left behind.
@Suite("leftover sweep")
@MainActor
struct LeftoverSweepTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let text: String?
        let types: [PasteboardType]
        let cleared: Bool
        var testDescription: String { name }
    }

    nonisolated static let ours = JoinCommandText.render(
        token: JoinToken(validating: sentinelToken)!, server: try! ServerAddress(parsing: "192.0.2.10"))!

    nonisolated static let cases: [Case] = [
        Case(name: "our concealed join command is cleared", text: ours, types: [.string, .concealed], cleared: true),
        Case(name: "our line without the concealed marker is left", text: ours, types: [.string], cleared: false),
        Case(name: "a foreign concealed item is left", text: "hunter2", types: [.string, .concealed], cleared: false),
        Case(name: "a plain string is left", text: "hello", types: [.string], cleared: false),
        Case(name: "a concealed item with no string is left", text: nil, types: [.concealed], cleared: false),
        Case(name: "a concealed join command with a bad token is left",
             text: ours.replacingOccurrences(of: "deadbeef", with: "DEADBEEF"), types: [.string, .concealed], cleared: false),
        Case(name: "a concealed join command with extra text is left", text: ours + "; id", types: [.string, .concealed], cleared: false),
        Case(name: "a concealed join command naming a host name is left",
             text: ours.replacingOccurrences(of: "192.0.2.10", with: "server.local"), types: [.string, .concealed], cleared: false),
        Case(name: "an empty pasteboard is left", text: nil, types: [], cleared: false),
    ]

    @Test("only this app's own concealed join command is swept", arguments: cases)
    func sweep(_ c: Case) {
        let pb = FakePasteboard()
        pb.put(c.text, types: c.types)
        #expect(ConcealedClipboard.sweepLeftover(pb) == c.cleared)
        #expect(pb.clears == (c.cleared ? 1 : 0))
        if !c.cleared { #expect(pb.contents == c.text) }
    }

    @Test("the line this app writes is recognised, byte for byte")
    func recognised() {
        #expect(JoinCommandText.isJoinCommand(Self.ours))
        #expect(!JoinCommandText.isJoinCommand(" " + Self.ours))
    }
}

/// Copy Join Command from click to pasteboard, following a sentinel token.
@Suite("copy join driver")
@MainActor
struct CopyJoinDriverTests {
    static let team = TeamID("ABCDE12345")!

    struct Rig {
        let driver: JoinCommandDriver
        let pb: FakePasteboard
        let runner: CapturingRunner
        let logs: LogLines
        let reads: StatusSequence
    }

    static func rig(_ capture: Result<String, PrivilegedFailure>, reports: [StatusReport?] = [Reports.running],
                    addresses: [InterfaceAddress] = [lan, mesh],
                    availability: PrivilegedAvailability = .enabled) -> Rig {
        let pb = FakePasteboard()
        let clip = ConcealedClipboard(pasteboard: pb, scheduler: FakeScheduler())
        let runner = CapturingRunner(capture)
        let logs = LogLines()
        let reads = StatusSequence(reports)
        let driver = JoinCommandDriver(
            teamID: team, readStatus: { reads.next() }, availability: { availability },
            addresses: FixedAddresses(all: addresses), runner: runner, clipboard: clip, log: { logs.append($0) })
        return Rig(driver: driver, pb: pb, runner: runner, logs: logs, reads: reads)
    }

    func expectNoToken(_ rig: Rig, _ result: JoinCommandDriver.Result) {
        #expect(!rig.logs.all.contains { $0.contains("deadbeef") || $0.contains(sentinelToken) })
        #expect(!String(describing: result).contains("deadbeef"))
        for s in rig.runner.scripts {
            #expect(!s.text.contains("deadbeef") && !s.prompt.contains("deadbeef") && !s.command(inputPath: "/dev/null").contains("deadbeef"))
        }
    }

    @Test("the token reaches the pasteboard and nothing else")
    func copied() async throws {
        let rig = Self.rig(.success(sentinelToken))
        let result = await rig.driver.perform()
        guard case .copied(let note) = result else { Issue.record("got \(result)"); return }
        #expect(note.contains("192.0.2.10"))
        #expect(note.contains(CopyJoinCommand.copiedNote))
        let token = try #require(JoinToken(validating: sentinelToken))
        #expect(rig.pb.writes.map(\.text) == [JoinCommandText.render(token: token, server: try ServerAddress(parsing: "192.0.2.10"))!])
        #expect(rig.runner.scripts == [JoinTokenMint.render(.workerToken, teamID: Self.team)])
        #expect(rig.runner.plainRuns == 0)
        #expect(!rig.logs.all.isEmpty)
        expectNoToken(rig, result)
    }

    @Test("a failed mint's error text never carries the token, and nothing is copied")
    func failedMint() async {
        let run = PrivilegedRun(outcome: .failed(exitStatus: 1), errorOutput: "mint failed near \(sentinelToken)")
        let rig = Self.rig(.failure(.notSucceeded(run)))
        let result = await rig.driver.perform()
        guard case .failed(let text) = result else { Issue.record("got \(result)"); return }
        #expect(text.contains("mint failed near"))
        #expect(!text.contains("deadbeef"))
        #expect(rig.pb.writes.isEmpty)
        expectNoToken(rig, result)
    }

    @Test("a dismissed prompt copies nothing")
    func cancelled() async {
        let rig = Self.rig(.failure(.notSucceeded(PrivilegedRun(outcome: .cancelled))))
        #expect(await rig.driver.perform() == .cancelled)
        #expect(rig.pb.writes.isEmpty)
    }

    @Test("output that is not a token copies nothing", arguments: ["", "K10abc", sentinelToken + "'; id", "hello\n" + sentinelToken])
    func notAToken(_ output: String) async {
        let rig = Self.rig(.success(output))
        let result = await rig.driver.perform()
        #expect(result == .failed(JoinCommandDriver.notAToken))
        #expect(rig.pb.writes.isEmpty)
        expectNoToken(rig, result)
    }

    @Test("refused output copies nothing")
    func outputRefused() async {
        let rig = Self.rig(.failure(.outputRefused))
        #expect(await rig.driver.perform() == .failed(JoinCommandDriver.notAToken))
        #expect(rig.pb.writes.isEmpty)
    }

    @Test("a role changed to worker refuses before any prompt")
    func roleChanged() async {
        let rig = Self.rig(.success(sentinelToken), reports: [Reports.make(role: "agent", nodeState: "running", verdict: "running")])
        let result = await rig.driver.perform()
        guard case .refused = result else { Issue.record("got \(result)"); return }
        #expect(rig.runner.scripts.isEmpty)
        #expect(rig.pb.writes.isEmpty)
        #expect(rig.reads.reads == 1)
    }

    @Test("a stopped server, an unreadable status or no address refuses before any prompt",
          arguments: [0, 1, 2, 3])
    func refusedBeforePrompt(_ which: Int) async {
        let rig: Rig
        switch which {
        case 0: rig = Self.rig(.success(sentinelToken), reports: [Reports.stopped])
        case 1: rig = Self.rig(.success(sentinelToken), reports: [nil])
        case 2: rig = Self.rig(.success(sentinelToken), addresses: [mesh])
        default: rig = Self.rig(.success(sentinelToken), availability: .disabled(reason: "not signed"))
        }
        let result = await rig.driver.perform()
        guard case .refused = result else { Issue.record("got \(result)"); return }
        #expect(rig.runner.scripts.isEmpty)
        #expect(rig.pb.writes.isEmpty)
    }

    @Test("each click reads, prompts and mints anew")
    func nothingCached() async {
        let rig = Self.rig(.success(sentinelToken), reports: [Reports.running, Reports.running])
        _ = await rig.driver.perform()
        _ = await rig.driver.perform()
        #expect(rig.reads.reads == 2)
        #expect(rig.runner.scripts.count == 2)
        #expect(rig.pb.writes.count == 2)
    }

    @Test("two rapid invocations mint exactly once")
    func singleFlight() async {
        let rig = Self.rig(.success(sentinelToken), reports: [Reports.running, Reports.running])
        async let first = rig.driver.perform()
        async let second = rig.driver.perform()
        let results = await [first, second]
        #expect(rig.runner.scripts.count == 1)
        #expect(rig.pb.writes.count == 1)
        #expect(results.filter { if case .copied = $0 { return true } else { return false } }.count == 1)
        #expect(results.contains(.refused("Another change is running. Nothing was copied.")))
        #expect(!rig.driver.inFlight)
    }

    @Test("a refused binary and a rejected signature name themselves")
    func refusals() {
        #expect(JoinCommandDriver.failureText(PrivilegedRun(outcome: .failed(exitStatus: 100))).contains("not owned by root"))
        #expect(JoinCommandDriver.failureText(PrivilegedRun(outcome: .failed(exitStatus: 101))).contains("Developer ID"))
        #expect(JoinCommandDriver.failureText(PrivilegedRun(outcome: .couldNotStart)).contains("could not be shown"))
    }

    @Test("the default capture of a runner without one runs nothing")
    func defaultCapture() async {
        let runner = RecordingRunner()
        let result = await runner.runAsRootCapturingOutput(JoinTokenMint.render(.workerToken, teamID: Self.team))
        #expect(result == .failure(.notSucceeded(PrivilegedRun(outcome: .couldNotStart))))
        #expect(runner.scripts.isEmpty)
    }
}
