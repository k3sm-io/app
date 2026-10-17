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

/// VirtualClock is a `WatchClock` the test moves by hand: `advance` fires
/// every timer due on the way, in time order, at its own time.
@MainActor
final class VirtualClock: WatchClock {
    private(set) var now: Duration = .zero
    private var timers: [VirtualTimer] = []
    private var sequence = 0

    final class VirtualTimer: WatchTimer {
        let at: Duration
        let sequence: Int
        let fire: @MainActor () -> Void
        var cancelled = false
        init(at: Duration, sequence: Int, fire: @escaping @MainActor () -> Void) {
            self.at = at
            self.sequence = sequence
            self.fire = fire
        }
        func cancel() { cancelled = true }
    }

    func schedule(at time: Duration, _ fire: @escaping @MainActor () -> Void) -> any WatchTimer {
        sequence += 1
        let timer = VirtualTimer(at: max(time, now), sequence: sequence, fire: fire)
        timers.append(timer)
        return timer
    }

    func advance(by step: Duration) {
        let target = now + step
        while true {
            timers.removeAll { $0.cancelled }
            guard let next = timers.filter({ $0.at <= target }).min(by: { ($0.at, $0.sequence) < ($1.at, $1.sequence) }) else { break }
            timers.removeAll { $0 === next }
            now = max(now, next.at)
            next.fire()
        }
        now = target
    }
}

/// FakeScript is what one fake watch process does: its stderr, its lines,
/// then it holds or exits.
struct FakeScript {
    var errors: String?
    var lines: [Data] = []
    var exit: (after: Duration, WatchExit)?
}

/// FakeLauncher stands in for `CLIStream`: it records every start, kill
/// and one-shot list, and plays each process's script on the virtual clock.
@MainActor
final class FakeLauncher: WatchLauncher {
    final class Process: WatchProcess {
        let kind: String
        let startedAt: Duration
        var events: WatchEvents?
        var killed = false
        var exited = false
        init(kind: String, startedAt: Duration) {
            self.kind = kind
            self.startedAt = startedAt
        }
        func kill() { killed = true }
    }

    let clock: VirtualClock
    var script: (_ kind: String, _ index: Int) -> FakeScript
    var listResult: (Int32?, Data) = (0, Data(#"{"apiVersion":"v1","kind":"List","items":[]}"#.utf8))
    private(set) var processes: [Process] = []
    private(set) var arguments: [[String]] = []
    private(set) var lists = 0

    init(clock: VirtualClock, script: @escaping (_ kind: String, _ index: Int) -> FakeScript) {
        self.clock = clock
        self.script = script
    }

    func starts(_ kind: String) -> [Process] { processes.filter { $0.kind == kind } }

    func launch(arguments: [String], events: WatchEvents) -> any WatchProcess {
        let kind = arguments[2]
        let process = Process(kind: kind, startedAt: clock.now)
        let plan = script(kind, starts(kind).count)
        process.events = events
        processes.append(process)
        self.arguments.append(arguments)
        if let errors = plan.errors {
            _ = clock.schedule(at: clock.now + .milliseconds(5)) {
                if !process.killed { events.errors(errors) }
            }
        }
        if !plan.lines.isEmpty {
            _ = clock.schedule(at: clock.now + .milliseconds(10)) {
                if !process.killed { events.lines(plan.lines) }
            }
        }
        if let (after, exit) = plan.exit {
            _ = clock.schedule(at: clock.now + after) {
                guard !process.killed else { return }
                process.exited = true
                events.exit(exit)
            }
        }
        return process
    }

    /// Delivers lines from the newest live process, as its reader would.
    func send(_ lines: [Data]) {
        guard let process = processes.last(where: { !$0.killed && !$0.exited }) else { return }
        process.events?.lines(lines)
    }

    func list(arguments: [String], completion: @escaping @MainActor @Sendable (Int32?, Data) -> Void) {
        lists += 1
        let result = listResult
        _ = clock.schedule(at: clock.now + .milliseconds(50)) { completion(result.0, result.1) }
    }
}

/// One compact watch line as kubectl prints it.
func watchLine(_ type: String, uid: String?, name: String, kind: String = "Pod", namespace: String? = "default", extra: String = "") -> Data {
    var metadata = #""name":"\#(name)""#
    if let namespace { metadata += #","namespace":"\#(namespace)""# }
    if let uid { metadata += #","uid":"\#(uid)""# }
    // A pod needs its containers to decode.
    let spec = kind == "Pod" ? #","spec":{"containers":[]}"# : ""
    let object = #"{"apiVersion":"v1","kind":"\#(kind)","metadata":{\#(metadata)}\#(spec)\#(extra)}"#
    return Data(#"{"type":"\#(type)","object":\#(object)}"#.utf8)
}

/// The fixture's items as ADDED lines, each object's bytes as serialized.
func addedLines(_ data: Data) throws -> [Data] {
    let top = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let items = try #require(top["items"] as? [Any])
    return try items.map { item in
        var line = Data(#"{"type":"ADDED","object":"#.utf8)
        line.append(try JSONSerialization.data(withJSONObject: item))
        line.append(UInt8(ascii: "}"))
        return line
    }
}

@Suite("the held watch: framing, folding, and the stream's lifecycle")
@MainActor
struct WatchFoldTests {
    // MARK: framing

    @Test("lines are split across chunks; CR and empty lines are dropped")
    func framerSplitsLines() {
        var framer = WatchLineFramer(maxLine: 64)
        #expect(framer.append(Data("{\"a\":1}\n{\"b\"".utf8)) == [Data("{\"a\":1}".utf8)])
        #expect(framer.append(Data(":2}\r\n\n{\"c\":3}\n".utf8)) == [Data("{\"b\":2}".utf8), Data("{\"c\":3}".utf8)])
        #expect(framer.append(Data("{\"d\"".utf8)).isEmpty)
        #expect(framer.finish() == Data("{\"d\"".utf8))
        #expect(!framer.overflowed)
    }

    @Test("a line past the bound stops the framer for good")
    func framerOverflows() {
        var framer = WatchLineFramer(maxLine: 8)
        #expect(framer.append(Data("short\n0123".utf8)) == [Data("short".utf8)])
        #expect(framer.append(Data("456789\nnext\n".utf8)).isEmpty)
        #expect(framer.overflowed)
        #expect(framer.append(Data("ok\n".utf8)).isEmpty)
        #expect(framer.finish() == nil)
        #expect(WatchLineFramer().maxLine == 2 << 20)
    }

    // MARK: frames

    @Test("watch events parse to frames; the object's bytes are cut from the line")
    func framesParse() throws {
        let added = watchLine("ADDED", uid: "u1", name: "a")
        guard case .upsert(let key, let object) = WatchFrame.parse(added, kind: .pods) else {
            Issue.record("not an upsert")
            return
        }
        #expect(key == "u1")
        #expect(object == Data(#"{"apiVersion":"v1","kind":"Pod","metadata":{"name":"a","namespace":"default","uid":"u1"},"spec":{"containers":[]}}"#.utf8))
        #expect(WatchFrame.parse(watchLine("MODIFIED", uid: nil, name: "a"), kind: .pods).isUpsert(key: "Pod/default/a"))
        #expect(WatchFrame.parse(watchLine("DELETED", uid: "u1", name: "a"), kind: .pods) == .delete(key: "u1"))
        #expect(WatchFrame.parse(watchLine("ADDED", uid: nil, name: "n1", kind: "Node", namespace: nil), kind: .nodes).isUpsert(key: "Node//n1"))
        #expect(WatchFrame.parse(watchLine("BOOKMARK", uid: nil, name: "x"), kind: .pods) == .ignored)
        #expect(WatchFrame.parse(watchLine("SOMETHINGNEW", uid: "u", name: "x"), kind: .pods) == .ignored)
        let gone = Data(#"{"type":"ERROR","object":{"kind":"Status","code":410,"message":"too old resource version"}}"#.utf8)
        #expect(WatchFrame.parse(gone, kind: .pods) == .gone)
        let failure = Data(#"{"type":"ERROR","object":{"kind":"Status","code":500,"message":"etcd‮ down"}}"#.utf8)
        #expect(WatchFrame.parse(failure, kind: .pods) == .failure(code: 500, message: "etcd down"))
        #expect(WatchFrame.parse(Data("not json".utf8), kind: .pods) == .undecodable)
        #expect(WatchFrame.parse(Data(#"{"type":"ADDED","object":{"metadata":{}}}"#.utf8), kind: .pods) == .undecodable)
        // Another key order still reads, by serializing the parsed object.
        let reordered = Data(#"{"object":{"kind":"Pod","metadata":{"name":"b","uid":"u2"}},"type":"ADDED"}"#.utf8)
        #expect(WatchFrame.parse(reordered, kind: .pods).isUpsert(key: "u2"))
    }

    // MARK: the fold

    @Test("add, modify and delete fold into the list; a delete of an unknown uid changes nothing")
    func foldAppliesEvents() throws {
        var fold = WatchFold()
        let a = Data(#"{"kind":"Pod","metadata":{"name":"a","uid":"u1"}}"#.utf8)
        let a2 = Data(#"{"kind":"Pod","metadata":{"name":"a","uid":"u1","labels":{"x":"y"}}}"#.utf8)
        let b = Data(#"{"kind":"Pod","metadata":{"name":"b","uid":"u2"}}"#.utf8)
        #expect(fold.apply(.upsert(key: "u1", object: a)) == .changed)
        #expect(fold.apply(.upsert(key: "u2", object: b)) == .changed)
        #expect(fold.apply(.upsert(key: "u1", object: a)) == .unchanged)
        #expect(fold.apply(.upsert(key: "u1", object: a2)) == .changed)
        #expect(fold.apply(.delete(key: "nobody")) == .unchanged)
        #expect(fold.apply(.ignored) == .unchanged)
        #expect(fold.count == 2)
        #expect(fold.bytes == a2.count + b.count)
        var expected = Data(#"{"apiVersion":"v1","kind":"PodList","items":["#.utf8)
        expected.append(a2)
        expected.append(UInt8(ascii: ","))
        expected.append(b)
        expected.append(contentsOf: Array("]}".utf8))
        #expect(fold.list(kind: .pods) == expected)
        #expect(fold.apply(.delete(key: "u1")) == .changed)
        #expect(fold.count == 1)
        #expect(fold.bytes == b.count)
    }

    @Test("a folded pod list decodes as the polled one did")
    func foldedPodsDecodeAsPolled() throws {
        for name in ["kubectl_pods_mixed.json", "kubectl_pods_running.json", "kubectl_pods_two_nodes.json"] {
            let polled = try fixture(name)
            var fold = WatchFold()
            for line in try addedLines(polled) { _ = fold.apply(WatchFrame.parse(line, kind: .pods)) }
            #expect(try Workloads.decode(fold.list(kind: .pods)) == Workloads.decode(polled), "\(name)")
        }
        #expect(try Workloads.decode(WatchFold().list(kind: .pods)) == Workloads.decode(fixture("kubectl_pods_empty.json")))
    }

    @Test("a folded node list decodes as the polled one did")
    func foldedNodesDecodeAsPolled() throws {
        for name in ["kubectl_nodes_two.json", "kubectl_nodes_images.json", "kubectl_nodes_versions.json"] {
            let polled = try fixture(name)
            var fold = WatchFold()
            for line in try addedLines(polled) { _ = fold.apply(WatchFrame.parse(line, kind: .nodes)) }
            #expect(try NodeListRead.decode(fold.list(kind: .nodes)) == NodeListRead.decode(polled), "\(name)")
        }
    }

    @Test("the fold refuses past its object and byte caps")
    func foldCaps() {
        var byCount = WatchFold(maxObjects: 2, maxBytes: 1 << 20)
        #expect(byCount.apply(.upsert(key: "1", object: Data("{}".utf8))) == .changed)
        #expect(byCount.apply(.upsert(key: "2", object: Data("{}".utf8))) == .changed)
        #expect(byCount.apply(.upsert(key: "3", object: Data("{}".utf8))) == .overCap)
        #expect(byCount.apply(.upsert(key: "2", object: Data("{ }".utf8))) == .changed)
        var byBytes = WatchFold(maxObjects: 10, maxBytes: 5)
        #expect(byBytes.apply(.upsert(key: "1", object: Data("{1234}".utf8))) == .overCap)
        #expect(byBytes.count == 0)
        #expect(WatchPolicy.maxObjects == 20_000 && WatchPolicy.maxFoldBytes == 64 << 20)
    }

    // MARK: the stream

    private func makeStream(_ kind: WatchKind, _ launcher: FakeLauncher, spacer: WatchRelistSpacer? = nil,
                            jitter: @escaping @MainActor () -> Double = { 0.5 }) -> WatchStream {
        WatchStream(kind: kind, launcher: launcher, clock: launcher.clock, spacer: spacer, jitter: jitter)
    }

    private func pods(_ stream: WatchStream) throws -> [String] {
        try Workloads.decode(try #require(stream.list)).pods.map(\.name)
    }

    @Test("the watch arguments: one kind, -A, events, JSON, a whole-second request timeout")
    func watchArguments() {
        #expect(K3smCLI.watchArguments(kind: .pods, requestTimeout: .seconds(1830)) ==
            ["kubectl", "get", "pods", "-A", "-w", "--output-watch-events", "-o", "json", "--request-timeout=1830s"])
        #expect(K3smCLI.watchArguments(kind: .nodes, requestTimeout: .milliseconds(10))[2...3] == ["nodes", "-A"])
        #expect(WatchKind.pods.listArguments == K3smCLI.workloadsArguments)
        #expect(WatchKind.nodes.listArguments == K3smCLI.nodesArguments)
    }

    @Test("loading until the replay settles 250 ms after its last frame; then live, with later changes coalesced")
    func settlesAndPublishes() throws {
        let clock = VirtualClock()
        let launcher = FakeLauncher(clock: clock) { _, _ in
            FakeScript(lines: [watchLine("ADDED", uid: "u1", name: "a"), watchLine("ADDED", uid: "u2", name: "b")])
        }
        let stream = makeStream(.pods, launcher)
        var published = 0
        stream.onPublish = { published += 1 }
        stream.start()
        #expect(stream.state == .loading)
        #expect(launcher.arguments.first?.contains("--request-timeout=1980s") == true) // 30 min spread by 0.5
        clock.advance(by: .milliseconds(200))
        #expect(stream.state == .loading)
        #expect(stream.list == nil)
        clock.advance(by: .milliseconds(100))
        #expect(stream.state == .live)
        #expect(try pods(stream) == ["a", "b"])
        #expect(published == 1)

        // Three changes in a burst are one redraw; a delete of an unknown
        // uid and a bookmark are none.
        launcher.send([
            watchLine("MODIFIED", uid: "u1", name: "a", extra: #","status":{"phase":"Running"}"#),
            watchLine("DELETED", uid: "u2", name: "b"),
            watchLine("ADDED", uid: "u3", name: "c"),
            watchLine("DELETED", uid: "ghost", name: "g"),
            watchLine("BOOKMARK", uid: nil, name: "x"),
        ])
        #expect(published == 1)
        // 250 ms after the burst, but never within 500 ms of the last redraw.
        clock.advance(by: .milliseconds(300))
        #expect(published == 1)
        clock.advance(by: .milliseconds(200))
        #expect(published == 2)
        #expect(try pods(stream) == ["a", "c"])
        launcher.send([watchLine("DELETED", uid: "ghost", name: "g")])
        clock.advance(by: .seconds(1))
        #expect(published == 2)
        // At most two redraws a second under a steady trickle.
        for i in 0..<20 {
            launcher.send([watchLine("ADDED", uid: "t\(i)", name: "t\(i)")])
            clock.advance(by: .milliseconds(100))
        }
        #expect(published - 2 <= 5)
        #expect(published - 2 >= 3)
    }

    @Test("a replay that never pauses settles at the cap after its first frame")
    func settleCap() {
        let clock = VirtualClock()
        let launcher = FakeLauncher(clock: clock) { _, _ in FakeScript(lines: [watchLine("ADDED", uid: "u0", name: "p0")]) }
        let stream = makeStream(.pods, launcher)
        stream.start()
        clock.advance(by: .milliseconds(10))
        for i in 1...40 {
            clock.advance(by: .milliseconds(100))
            launcher.send([watchLine("ADDED", uid: "u\(i)", name: "p\(i)")])
            if clock.now < .milliseconds(10) + WatchPolicy.settleCap { #expect(stream.state == .loading) }
        }
        #expect(stream.state == .live)
    }

    @Test("an empty kind settles on the one-shot list")
    func emptyKindSettlesOnList() throws {
        let clock = VirtualClock()
        let launcher = FakeLauncher(clock: clock) { _, _ in FakeScript() }
        let stream = makeStream(.pods, launcher)
        stream.start()
        clock.advance(by: .milliseconds(4900))
        #expect(stream.state == .loading)
        #expect(launcher.lists == 0)
        clock.advance(by: .milliseconds(200))
        #expect(launcher.lists == 1)
        #expect(stream.state == .live)
        #expect(try pods(stream).isEmpty)
        #expect(launcher.processes.count == 1)
    }

    @Test("the relist replays into a shadow map that replaces the shown one at once")
    func relistSwapsShadow() throws {
        let clock = VirtualClock()
        let launcher = FakeLauncher(clock: clock) { _, index in
            index == 0
                ? FakeScript(lines: [watchLine("ADDED", uid: "u1", name: "a"), watchLine("ADDED", uid: "u2", name: "b")])
                : FakeScript(lines: [watchLine("ADDED", uid: "u2", name: "b"), watchLine("ADDED", uid: "u3", name: "c")])
        }
        let stream = makeStream(.pods, launcher, jitter: { 0 })
        stream.start()
        clock.advance(by: .seconds(1))
        #expect(try pods(stream) == ["a", "b"])
        // The relist is due one interval after the settle (at 0.26 s).
        clock.advance(by: WatchPolicy.relistInterval - .seconds(1) + .milliseconds(255))
        #expect(launcher.processes.count == 1)
        clock.advance(by: .milliseconds(10))
        #expect(launcher.processes.count == 2)
        #expect(launcher.processes[0].killed)
        // During the replay the old list stays on screen and the stream live.
        #expect(stream.state == .live)
        #expect(try pods(stream) == ["a", "b"])
        clock.advance(by: .milliseconds(5))
        #expect(try pods(stream) == ["a", "b"])
        clock.advance(by: .milliseconds(500))
        // The pod deleted while no one watched is gone after the swap.
        #expect(try pods(stream) == ["b", "c"])
    }

    @Test("410 Gone relists at once; a second Gone before a healthy run backs off; other errors back off")
    func goneAndErrors() {
        let clock = VirtualClock()
        let gone = Data(#"{"type":"ERROR","object":{"kind":"Status","code":410}}"#.utf8)
        let failure = Data(#"{"type":"ERROR","object":{"kind":"Status","code":500,"message":"boom"}}"#.utf8)
        let launcher = FakeLauncher(clock: clock) { _, index in
            switch index {
            case 0, 1: return FakeScript(lines: [watchLine("ADDED", uid: "u1", name: "a"), gone])
            case 2: return FakeScript(lines: [failure])
            default: return FakeScript(lines: [watchLine("ADDED", uid: "u1", name: "a")])
            }
        }
        let stream = makeStream(.pods, launcher)
        stream.start()
        clock.advance(by: .milliseconds(10))
        #expect(launcher.processes.count == 2) // the first Gone: at once
        #expect(launcher.processes[0].killed)
        clock.advance(by: .milliseconds(10))
        #expect(launcher.processes.count == 2) // the second: backoff
        #expect(stream.state == .retrying)
        clock.advance(by: WatchPolicy.backoffBase)
        #expect(launcher.processes.count == 3)
        clock.advance(by: .milliseconds(10)) // a 500: backoff, 2 s
        #expect(stream.state == .retrying)
        clock.advance(by: .milliseconds(1900))
        #expect(launcher.processes.count == 3)
        clock.advance(by: .milliseconds(200))
        #expect(launcher.processes.count == 4)
        clock.advance(by: .seconds(1))
        #expect(stream.state == .live)
    }

    @Test("a process that exits at once is started a bounded number of times, the wait capped at 60 s")
    func immediateExitBacksOff() {
        let clock = VirtualClock()
        let launcher = FakeLauncher(clock: clock) { _, _ in
            FakeScript(exit: (.milliseconds(20), .exited(status: 1, errors: "error: connection refused")))
        }
        let stream = makeStream(.nodes, launcher)
        stream.start()
        clock.advance(by: .seconds(600))
        // 1, 2, 4 ... 32 s, then every 60 s: about 16 starts in 10 minutes.
        #expect(launcher.processes.count <= 20)
        #expect(launcher.processes.count >= 10)
        let gaps = zip(launcher.processes.dropFirst(), launcher.processes).map { $0.startedAt - $1.startedAt }
        #expect(gaps.allSatisfy { $0 <= WatchPolicy.backoffMax + .milliseconds(20) })
        #expect(stream.state == .retrying)
        #expect(WatchPolicy.backoff(failures: 0) == .seconds(1))
        #expect(WatchPolicy.backoff(failures: 40) == .seconds(60))
    }

    @Test("a process that lived 30 s is replaced at once")
    func healthyExitRespawnsAtOnce() {
        let clock = VirtualClock()
        let launcher = FakeLauncher(clock: clock) { _, index in
            index == 0
                ? FakeScript(lines: [watchLine("ADDED", uid: "u1", name: "a")], exit: (.seconds(40), .exited(status: 0, errors: "")))
                : FakeScript(lines: [watchLine("ADDED", uid: "u1", name: "a")])
        }
        let stream = makeStream(.pods, launcher)
        stream.start()
        clock.advance(by: .seconds(40))
        #expect(launcher.processes.count == 2)
        #expect(launcher.processes[1].startedAt == .seconds(40))
        #expect(stream.state == .live)
    }

    @Test("an auth failure on stderr or at exit is its own state, never respawned")
    func authFailureNeverRespawns() {
        for script in [
            FakeScript(errors: "error: You must be logged in to the server (Unauthorized)"),
            FakeScript(exit: (.milliseconds(20), .exited(status: 1, errors: "Error from server (Forbidden): pods is forbidden"))),
            FakeScript(lines: [Data(#"{"type":"ERROR","object":{"kind":"Status","code":401,"message":"no"}}"#.utf8)]),
        ] {
            let clock = VirtualClock()
            let launcher = FakeLauncher(clock: clock) { _, _ in script }
            let stream = makeStream(.pods, launcher)
            stream.start()
            clock.advance(by: .seconds(600))
            #expect(launcher.processes.count == 1)
            #expect(launcher.processes[0].killed || launcher.processes[0].exited)
            guard case .authFailed = stream.state else {
                Issue.record("state \(stream.state)")
                continue
            }
            #expect(!stream.running)
        }
        #expect(WatchAuth.isAuthFailure("the server returned 403"))
        #expect(!WatchAuth.isAuthFailure("pod web-4031 crashed"))
        #expect(WatchAuth.isGone("The resourceVersion for the provided watch is too old."
            + " too old resource version: 1 (2)"))
        #expect(!WatchAuth.isGone("pod web-4101"))
    }

    @Test("an overlong line, an oversized fold or a burst of undecodable lines degrades the stream, with no retry")
    func degradations() {
        let clock = VirtualClock()
        let longLine = FakeLauncher(clock: clock) { _, _ in FakeScript(exit: (.milliseconds(20), .lineTooLong)) }
        let a = makeStream(.pods, longLine)
        a.start()
        clock.advance(by: .seconds(600))
        #expect(a.state == .degraded(.lineTooLong))
        #expect(longLine.processes.count == 1)

        let missing = FakeLauncher(clock: clock) { _, _ in FakeScript(exit: (.zero, .missing)) }
        let m = makeStream(.pods, missing)
        m.start()
        clock.advance(by: .seconds(60))
        #expect(m.state == .degraded(.missing))
        #expect(missing.processes.count == 1)

        let big = FakeLauncher(clock: clock) { _, _ in
            FakeScript(lines: (0..<3).map { watchLine("ADDED", uid: "u\($0)", name: "p\($0)") })
        }
        let b = WatchStream(kind: .pods, launcher: big, clock: clock, maxObjects: 2)
        b.start()
        clock.advance(by: .seconds(600))
        #expect(b.state == .degraded(.tooLarge))
        #expect(big.processes.count == 1 && big.processes[0].killed)

        let junk = FakeLauncher(clock: clock) { _, _ in
            FakeScript(lines: Array(repeating: Data("{]".utf8), count: 19) + [watchLine("ADDED", uid: "u", name: "p")])
        }
        let c = makeStream(.pods, junk)
        c.start()
        clock.advance(by: .seconds(1))
        #expect(c.state == .live) // 19 is under the burst
        junk.send([Data("garbage".utf8)])
        #expect(c.state == .degraded(.undecodable))
        clock.advance(by: .seconds(600))
        #expect(junk.processes.count == 1)
        // A new start tries again from scratch.
        c.start()
        #expect(junk.processes.count == 2)
        c.stop()
    }

    @Test("a wake restarts each running stream exactly once")
    func wakeRestartsOnce() {
        let clock = VirtualClock()
        let launcher = FakeLauncher(clock: clock) { kind, _ in
            FakeScript(lines: [watchLine("ADDED", uid: "u-\(kind)", name: "x", kind: kind == "pods" ? "Pod" : "Node")])
        }
        let spacer = WatchRelistSpacer()
        let pods = makeStream(.pods, launcher, spacer: spacer)
        let nodes = makeStream(.nodes, launcher, spacer: spacer)
        pods.start()
        nodes.start()
        clock.advance(by: .seconds(10))
        #expect(launcher.processes.count == 2)
        pods.wake()
        nodes.wake()
        #expect(launcher.starts("pods").count == 2)
        #expect(launcher.starts("nodes").count == 2)
        #expect(launcher.processes.prefix(2).allSatisfy { $0.killed })
        clock.advance(by: .seconds(10))
        #expect(launcher.processes.count == 4)
        #expect(pods.state == .live && nodes.state == .live)
        // A stopped stream is not restarted by a wake.
        pods.stop()
        pods.wake()
        #expect(launcher.starts("pods").count == 2)
        nodes.stop()
    }

    @Test("10 minutes with the Workloads tab open: two held streams and their jittered relists, no list polls")
    func spawnCountOverTenMinutes() throws {
        let clock = VirtualClock()
        let launcher = FakeLauncher(clock: clock) { kind, _ in
            kind == "pods"
                ? FakeScript(lines: (0..<50).map { watchLine("ADDED", uid: "p\($0)", name: "pod-\($0)") })
                : FakeScript(lines: [watchLine("ADDED", uid: "n1", name: "node-1", kind: "Node", namespace: nil)])
        }
        let spacer = WatchRelistSpacer()
        // Both streams draw the same jitter: the spacer alone keeps them apart.
        let pods = makeStream(.pods, launcher, spacer: spacer, jitter: { 0.3 })
        let nodes = makeStream(.nodes, launcher, spacer: spacer, jitter: { 0.3 })
        pods.start()
        nodes.start()
        var maxHeld = 0
        for _ in 0..<600 {
            clock.advance(by: .seconds(1))
            maxHeld = max(maxHeld, launcher.processes.filter { !$0.killed && !$0.exited }.count)
        }
        let minutes = 10.0
        let relistMinutes = WatchPolicy.relistInterval.inSeconds / 60
        let bound = Int(2 * (1 + minutes / relistMinutes))
        #expect(launcher.processes.count <= bound)
        #expect(launcher.starts("pods").count == 2)
        #expect(launcher.starts("nodes").count == 2)
        #expect(launcher.lists == 0)
        #expect(maxHeld <= 2)
        #expect(try Workloads.decode(try #require(pods.list)).pods.count == 50)
        // The relists are jittered (past 5 min) and never in the same tick.
        let podRelist = launcher.starts("pods")[1].startedAt
        let nodeRelist = launcher.starts("nodes")[1].startedAt
        #expect(podRelist > WatchPolicy.relistInterval && nodeRelist > WatchPolicy.relistInterval)
        #expect(abs((podRelist - nodeRelist).inSeconds) >= WatchPolicy.relistSpacing.inSeconds)
        // Closing the tab kills every process it started.
        pods.stop()
        nodes.stop()
        #expect(launcher.processes.allSatisfy { $0.killed || $0.exited })
        #expect(pods.state == .idle && nodes.state == .idle)
        clock.advance(by: .seconds(600))
        #expect(launcher.processes.count <= bound)
    }

    @Test("a tab read takes the live list without a poll, polls otherwise, and names a refused kubeconfig")
    func tabReadOverStream() async throws {
        let clock = VirtualClock()
        let launcher = FakeLauncher(clock: clock) { _, _ in FakeScript(lines: [watchLine("ADDED", uid: "u1", name: "a")]) }
        let stream = makeStream(.pods, launcher)
        let polls = PollCounter()
        let decode: @Sendable (Data) -> TabResult<Workloads> = { Workloads.tabResult(exitCode: 0, stdout: $0) }
        let poll: @Sendable () async -> TabResult<Workloads> = {
            await polls.count()
            return .failed("k3sm kubectl exited 1")
        }
        // Stopped: the poll.
        #expect(await WatchRead.read(stream: stream, decode: decode, poll: poll) == .failed("k3sm kubectl exited 1"))
        #expect(await polls.value == 1)
        // Loading: the read waits for the settle, then takes the list.
        stream.start()
        let read = Task { await WatchRead.read(stream: stream, decode: decode, poll: poll) }
        for _ in 0..<5 { await Task.yield() }
        clock.advance(by: .seconds(1))
        guard case .value(let workloads) = await read.value else {
            Issue.record("no list")
            return
        }
        #expect(workloads.pods.map(\.name) == ["a"])
        for _ in 0..<10 { _ = await WatchRead.read(stream: stream, decode: decode, poll: poll) }
        #expect(await polls.value == 1)
        // Refused: the poll's failure names the kubeconfig.
        launcher.send([Data(#"{"type":"ERROR","object":{"kind":"Status","code":403,"message":"forbidden"}}"#.utf8)])
        #expect(await WatchRead.read(stream: stream, decode: decode, poll: poll)
            == .failed("the cluster refused the admin kubeconfig: forbidden"))
        #expect(WatchRead.fallback(TabResult<Int>.value(1), state: .authFailed("x")) == .value(1))
        #expect(WatchRead.fallback(TabResult<Int>.failed("y"), state: .retrying) == .failed("y"))
    }
}

actor PollCounter {
    private(set) var value = 0
    func count() { value += 1 }
}

extension WatchFrame {
    func isUpsert(key expected: String) -> Bool {
        if case .upsert(let key, _) = self { return key == expected }
        return false
    }
}
