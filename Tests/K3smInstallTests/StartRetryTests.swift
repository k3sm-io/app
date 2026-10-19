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

/// A runner that answers each root step from a fixed sequence of runs (the
/// last one repeats) and records the scripts it is handed.
final class ScriptedRunner: PrivilegedRunner {
    private let runs: Mutex<[PrivilegedRun]>
    private let seen = Mutex<[RootScript]>([])

    init(_ runs: [PrivilegedRun]) {
        self.runs = Mutex(runs)
    }

    var scripts: [RootScript] { seen.withLock { $0 } }

    func runAsRoot(_ script: RootScript, input: Data?) async -> PrivilegedOutcome {
        await runAsRootReportingError(script, input: input).outcome
    }

    func runAsRootReportingError(_ script: RootScript, input: Data?) async -> PrivilegedRun {
        seen.withLock { $0.append(script) }
        return runs.withLock { $0.count > 1 ? $0.removeFirst() : $0[0] }
    }
}

/// Counts calls and keeps the sentences a driver reported while it ran.
final class Progress: Sendable {
    private let texts = Mutex<[String]>([])
    private let boundReads = Mutex(0)
    var all: [String] { texts.withLock { $0 } }
    var reads: Int { boundReads.withLock { $0 } }
    func append(_ text: String) { texts.withLock { $0.append(text) } }
    func readBound() { boundReads.withLock { $0 += 1 } }
}

/// A deadline timer the test fires by hand. It records the limit of each
/// arm and reports each disarm, and never fires on its own, so a
/// deadline is checked on virtual time. A race disarms only after it has
/// resumed its caller, so a test waits for the disarms it expects.
final class ManualTimer: Sendable {
    private struct Arm: Sendable {
        let limit: Duration
        let fire: @Sendable () -> Void
    }

    private let arms = Mutex<[Arm]>([])
    /// Yields the limit of each arm as it happens.
    let armed: AsyncStream<Duration>
    private let armedContinuation: AsyncStream<Duration>.Continuation
    private let disarms: AsyncStream<Int>
    private let disarmsContinuation: AsyncStream<Int>.Continuation

    init() {
        (armed, armedContinuation) = AsyncStream.makeStream()
        (disarms, disarmsContinuation) = AsyncStream.makeStream()
    }

    var timer: DeadlineTimer {
        DeadlineTimer { limit, fire in
            let index = self.arms.withLock { a -> Int in
                a.append(Arm(limit: limit, fire: fire))
                return a.count - 1
            }
            self.armedContinuation.yield(limit)
            return { self.disarmsContinuation.yield(index) }
        }
    }

    var limits: [Duration] { arms.withLock { $0.map(\.limit) } }

    /// Waits for `count` disarms and returns which arms they were, in order.
    /// Call it once per timer: it reads the one stream of disarms.
    func disarmed(count: Int) async -> [Int] {
        var seen: [Int] = []
        for await index in disarms {
            seen.append(index)
            if seen.count == count { break }
        }
        return seen
    }

    /// Fires arm number `index` (0 for the first), as its limit passing would.
    func fire(_ index: Int) {
        let fire = arms.withLock { $0[index].fire }
        fire()
    }
}

/// Holds every caller of `wait` until `open`. A waiting caller ignores
/// cancellation, as an administrator prompt does.
final class Gate: Sendable {
    private let state = Mutex<(open: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let now = state.withLock { s -> Bool in
                if s.open { return true }
                s.waiters.append(c)
                return false
            }
            if now { c.resume() }
        }
    }

    func open() {
        let waiters = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            s.open = true
            defer { s.waiters = [] }
            return s.waiters
        }
        for w in waiters { w.resume() }
    }
}

/// A value shared with an escaping closure.
final class Box<T: Sendable>: Sendable {
    private let value: Mutex<T>
    init(_ value: T) { self.value = Mutex(value) }
    var get: T { value.withLock { $0 } }
    func set(_ new: T) { value.withLock { $0 = new } }
}

@Suite("start retry")
struct StartRetryTests {
    static let team = TeamID("ABCDE12345")!
    static let cordoned = PrivilegedRun(
        outcome: .failed(exitStatus: 1),
        errorOutput: "k3sm: started the node daemon\nk3sm: node is still cordoned (re-run 'sudo k3sm start' to uncordon it)")
    static let otherFailure = PrivilegedRun(outcome: .failed(exitStatus: 1), errorOutput: "k3sm: netd did not come back")
    static let ok = PrivilegedRun(outcome: .succeeded)

    struct StepCase: Sendable, CustomTestStringConvertible {
        let name: String
        let run: PrivilegedRun
        let attempt: Int
        let want: StartRetry.Step
        var testDescription: String { name }
    }

    static let stepCases: [StepCase] = [
        StepCase(name: "success finishes", run: ok, attempt: 1, want: .finished),
        StepCase(name: "first cordoned exit re-runs", run: cordoned, attempt: 1, want: .rerun),
        StepCase(name: "second cordoned exit stops", run: cordoned, attempt: 2, want: .notSchedulable),
        StepCase(name: "exit 1 without the marker is a failure", run: otherFailure, attempt: 1, want: .finished),
        StepCase(name: "exit 1 with no error output is a failure",
                 run: PrivilegedRun(outcome: .failed(exitStatus: 1)), attempt: 1, want: .finished),
        StepCase(name: "the marker on another exit is not the cordoned state",
                 run: PrivilegedRun(outcome: .failed(exitStatus: 2), errorOutput: StartRetry.cordonedMarker), attempt: 1, want: .finished),
        StepCase(name: "a near-miss token is not the marker",
                 run: PrivilegedRun(outcome: .failed(exitStatus: 1), errorOutput: "k3sm: node is cordoned"), attempt: 1, want: .finished),
        StepCase(name: "a cancelled prompt finishes", run: PrivilegedRun(outcome: .cancelled), attempt: 1, want: .finished),
    ]

    @Test("the step after one start run", arguments: stepCases)
    func step(_ c: StepCase) {
        #expect(StartRetry.next(after: c.run, attempt: c.attempt) == c.want)
    }

    @Test("the marker is the CLI's exact token and the app re-runs once")
    func constants() {
        #expect(StartRetry.cordonedMarker == "k3sm: node is still cordoned")
        #expect(StartRetry.automaticReruns == 1)
        #expect(StartRetry.retryingText.contains("started, node not schedulable yet; retrying"))
        #expect(StartRetry.notSchedulableText.contains("`sudo k3sm start`"))
    }

    static func driver(_ runner: ScriptedRunner, progress: Progress, timer: ManualTimer,
                       bound: StartTimeBound.Reading = .printed(420)) -> LifecycleDriver {
        var d = LifecycleDriver(
            teamID: team,
            readStatus: { Reports.stopped },
            confirm: { _ in true },
            runner: runner,
            readStartTimeBound: {
                progress.readBound()
                return bound
            },
            progress: { progress.append($0) })
        d.deadlineTimer = timer.timer
        return d
    }

    /// The deadline every start run races: the printed 420 plus the margin.
    static let wait: Duration = .seconds(420 + StartTimeBound.marginSeconds)

    @Test("a cordoned start is re-run once and then succeeds")
    func retryThenSuccess() async {
        let runner = ScriptedRunner([Self.cordoned, Self.ok])
        let progress = Progress()
        let timer = ManualTimer()
        let result = await Self.driver(runner, progress: progress, timer: timer).perform(.start, expected: .stopped)
        #expect(result == .ran(.succeeded, "k3sm is starting."))
        // Each run raced the whole bound, and each finished first.
        #expect(timer.limits == [Self.wait, Self.wait])
        #expect(await timer.disarmed(count: 2).sorted() == [0, 1])
        #expect(runner.scripts == [LifecycleScriptBuilder.render(.start, teamID: Self.team),
                                   LifecycleScriptBuilder.render(.start, teamID: Self.team)])
        #expect(progress.all == [StartRetry.retryingText])
        #expect(progress.reads == 1)
    }

    @Test("a second cordoned exit shows that state and runs nothing further")
    func retryThenStillCordoned() async {
        let runner = ScriptedRunner([Self.cordoned, Self.cordoned, Self.ok])
        let progress = Progress()
        let timer = ManualTimer()
        let result = await Self.driver(runner, progress: progress, timer: timer).perform(.start, expected: .stopped)
        #expect(result == .startedNotSchedulable(StartRetry.notSchedulableText))
        #expect(timer.limits == [Self.wait, Self.wait])
        #expect(runner.scripts.count == 2)
        #expect(progress.all == [StartRetry.retryingText])
    }

    @Test("any other exit 1 stays a failed start, not re-run")
    func otherExitOne() async {
        let runner = ScriptedRunner([Self.otherFailure, Self.ok])
        let progress = Progress()
        let timer = ManualTimer()
        let result = await Self.driver(runner, progress: progress, timer: timer).perform(.start, expected: .stopped)
        #expect(timer.limits == [Self.wait])
        #expect(result == .ran(.failed(exitStatus: 1), LifecycleOutcome.text(.failed(exitStatus: 1), verb: .start)))
        #expect(runner.scripts.count == 1)
        #expect(progress.all.isEmpty)
    }

    @Test("stop and restart never read the start bound and never re-run")
    func otherVerbs() async {
        for verb in [LifecycleVerb.stop, .restart] {
            let runner = ScriptedRunner([Self.cordoned])
            let progress = Progress()
            let d = LifecycleDriver(
                teamID: Self.team, readStatus: { Reports.running }, confirm: { _ in true }, runner: runner,
                readStartTimeBound: { progress.readBound(); return .printed(1) }, progress: { progress.append($0) })
            _ = await d.perform(verb, expected: .running)
            #expect(runner.scripts.count == 1)
            #expect(progress.reads == 0)
            #expect(progress.all.isEmpty)
        }
    }

    @Test("a declined start reads no bound and runs nothing")
    func declined() async {
        let runner = ScriptedRunner([Self.ok])
        let progress = Progress()
        let d = LifecycleDriver(
            teamID: Self.team, readStatus: { Reports.stopped }, confirm: { _ in false }, runner: runner,
            readStartTimeBound: { progress.readBound(); return .printed(1) })
        #expect(await d.perform(.start, expected: .stopped) == .declined)
        #expect(progress.reads == 0)
        #expect(runner.scripts.isEmpty)
    }

    @Test("the deadline returns the value when the operation is first")
    func deadlineValue() async {
        // A limit no stalled pool can reach: only the value can win.
        let v = await Deadline.race(.seconds(3600)) { 7 }
        #expect(v == 7)
    }

    @Test("the deadline returns nil when the operation runs past it")
    func deadlinePassed() async {
        let timer = ManualTimer()
        var armed = timer.armed.makeAsyncIterator()
        let gate = Gate(), done = Gate()
        let sawCancel = Box(false)
        let race = Task {
            await Deadline.race(.milliseconds(50), timer: timer.timer) { () -> Int in
                await gate.wait()
                sawCancel.set(Task.isCancelled)
                done.open()
                return 7
            }
        }
        #expect(await armed.next() == .milliseconds(50))
        timer.fire(0)
        // The operation cannot finish before the gate opens, so the nil is
        // the timer's, and the operation saw the race cancel it.
        #expect(await race.value == nil)
        gate.open()
        await done.wait()
        #expect(sawCancel.get)
    }

    @Test("the operation's value wins, disarms the timer, and a late fire is dropped")
    func deadlineOperationFirst() async {
        let timer = ManualTimer()
        let v = await Deadline.race(.seconds(30), timer: timer.timer) { 7 }
        #expect(v == 7)
        #expect(timer.limits == [.seconds(30)])
        #expect(await timer.disarmed(count: 1) == [0])
        timer.fire(0)
    }

    /// Runs the jobs of the tasks that prefer it on one serial dispatch
    /// queue, off the cooperative pool, so a test can await and time a
    /// result while every pool thread is blocked.
    final class QueueTaskExecutor: TaskExecutor {
        let queue = DispatchQueue(label: "io.k3sm.app.tests.deadline")

        func enqueue(_ job: consuming ExecutorJob) {
            let job = UnownedJob(job)
            queue.async { job.runSynchronously(on: self.asUnownedTaskExecutor()) }
        }
    }

    /// Holds the calling thread, without giving it back to the pool, until
    /// `semaphore` is signalled or a minute passes; false on the minute.
    static func hold(_ semaphore: DispatchSemaphore) -> Bool {
        semaphore.wait(timeout: .now() + 60) == .success
    }

    /// Lets the holders take their threads before the race starts.
    static func settle() {
        Thread.sleep(forTimeInterval: 0.1)
    }

    @Test("the deadline fires while every cooperative thread is held")
    func deadlineSaturatedPool() async {
        let executor = QueueTaskExecutor()
        let width = ProcessInfo.processInfo.activeProcessorCount
        let release = DispatchSemaphore(value: 0)
        let gaveUp = Box(0)
        let v: Int? = await Task(executorPreference: executor) { () -> Int? in
            // More blocking jobs than the pool has threads, each holding its
            // thread until the race is over, so the pool stays blocked only
            // as long as the race. A holder gives up only after a minute, a
            // hang guard: the race returning first is the proof that the
            // timer needed no pool thread.
            for _ in 0..<(width + 4) {
                Task.detached {
                    if !Self.hold(release) {
                        gaveUp.set(gaveUp.get + 1)
                    }
                }
            }
            Self.settle()
            let v: Int? = await Deadline.race(.milliseconds(50)) {
                try? await Task.sleep(for: .seconds(3600))
                return 7
            }
            // Released from here, on the queue: this test's own body runs on
            // the pool and could not resume to do it.
            let held = gaveUp.get
            for _ in 0..<(width + 4) { release.signal() }
            return held == 0 ? v : -1
        }.value
        #expect(v == nil, "-1: the race returned only after a held thread gave up")
    }

    /// A root step that returns only when the test opens its gate, and would
    /// ask for a re-run if it were ever awaited; it counts its calls.
    final class GatedCordonedRunner: PrivilegedRunner {
        private let count = Mutex(0)
        let gate = Gate()
        let returned = Gate()
        var calls: Int { count.withLock { $0 } }

        func runAsRoot(_ script: RootScript, input: Data?) async -> PrivilegedOutcome {
            await runAsRootReportingError(script, input: input).outcome
        }

        func runAsRootReportingError(_ script: RootScript, input: Data?) async -> PrivilegedRun {
            count.withLock { $0 += 1 }
            await gate.wait()
            returned.open()
            return StartRetryTests.cordoned
        }
    }

    @Test("a start past its deadline times out and runs the root step only once")
    func startTimesOutOnce() async {
        let runner = GatedCordonedRunner()
        let timer = ManualTimer()
        var armed = timer.armed.makeAsyncIterator()
        let d = {
            var d = LifecycleDriver(
                teamID: Self.team, readStatus: { Reports.stopped }, confirm: { _ in true }, runner: runner,
                readStartTimeBound: { .printed(420) })
            d.deadlineTimer = timer.timer
            return d
        }()
        let perform = Task { await d.perform(.start, expected: .stopped) }
        #expect(await armed.next() == Self.wait)
        timer.fire(0)
        #expect(await perform.value == .timedOut(StartRetry.timedOutText(seconds: 420 + StartTimeBound.marginSeconds)))
        // The run the driver stopped waiting for now ends cordoned; the
        // driver has returned, so nothing runs it again.
        runner.gate.open()
        await runner.returned.wait()
        #expect(runner.calls == 1)
        #expect(timer.limits == [Self.wait])
    }

    @Test("the deadline's dispatch interval")
    func deadlineInterval() {
        #expect(Deadline.interval(.milliseconds(50)) == .nanoseconds(50_000_000))
        #expect(Deadline.interval(.seconds(450)) == .nanoseconds(450_000_000_000))
        #expect(Deadline.interval(.zero) == .nanoseconds(0))
        #expect(Deadline.interval(.milliseconds(-5)) == .nanoseconds(0))
        #expect(Deadline.interval(.seconds(Int64.max)) == nil)
    }

    @Test("the timeout sentence names the whole wait")
    func timeoutText() {
        #expect(StartRetry.timedOutText(seconds: 450).contains("within 450 seconds"))
    }
}

/// The B571 acceptance leg: the Start flow end to end against a fake `k3sm`
/// that the gate script writes and names in K3SM_B571_FAKE_K3SM. The fake
/// stands in for what the root step runs after its checks (the start argv,
/// exactly), so this runs as the user; the gate asserts the state file this
/// writes and the fake's own record of its calls.
@Suite("start against a fake CLI", .enabled(if: ProcessInfo.processInfo.environment["K3SM_B571_FAKE_K3SM"] != nil))
struct StartFakeCLITests {
    /// Runs the fake with `arguments`, as the app would run the CLI: absolute
    /// path, its own environment, no shell.
    static func run(_ path: String, _ arguments: [String]) async -> (status: Int32, stdout: Data, stderr: Data)? {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: path)
                p.arguments = arguments
                p.environment = K3smCLI.environment(home: NSHomeDirectory(), user: NSUserName())
                    .merging(["K3SM_B571_CALLS": ProcessInfo.processInfo.environment["K3SM_B571_CALLS"] ?? "/dev/null"]) { $1 }
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch { continuation.resume(returning: nil); return }
                let o = out.fileHandleForReading.readDataToEndOfFile()
                let e = err.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                continuation.resume(returning: (p.terminationStatus, o, e))
            }
        }
    }

    /// The root step, minus the root: checks it is the start script, then
    /// runs the fake with the start argv.
    final class FakeRootRunner: PrivilegedRunner {
        let path: String
        init(path: String) { self.path = path }

        func runAsRoot(_ script: RootScript, input: Data?) async -> PrivilegedOutcome {
            await runAsRootReportingError(script, input: input).outcome
        }

        func runAsRootReportingError(_ script: RootScript, input: Data?) async -> PrivilegedRun {
            let argv = LifecycleScriptBuilder.arguments(for: .start)
            guard script.prompt == LifecycleVerb.start.prompt,
                  script.text.contains("exec \"$k3sm\" " + argv.map(ShellQuote.quote).joined(separator: " ")) else {
                return PrivilegedRun(outcome: .couldNotStart)
            }
            guard let r = await StartFakeCLITests.run(path, argv) else { return PrivilegedRun(outcome: .couldNotStart) }
            return PrivilegedRun(outcome: r.status == 0 ? .succeeded : .failed(exitStatus: r.status),
                                 errorOutput: String(decoding: r.stderr, as: UTF8.self))
        }
    }

    @Test("Start reads the bound, waits past it, re-runs a cordoned start once, and reports")
    func startFlow() async throws {
        let env = ProcessInfo.processInfo.environment
        let fake = try #require(env["K3SM_B571_FAKE_K3SM"])
        let statePath = try #require(env["K3SM_B571_STATE"])
        let progress = Progress()
        let bound = Mutex<StartTimeBound.Reading?>(nil)
        let driver = LifecycleDriver(
            teamID: TeamID("ABCDE12345")!,
            readStatus: { Reports.stopped },
            confirm: { _ in true },
            runner: FakeRootRunner(path: fake),
            readStartTimeBound: {
                let r = await Self.run(fake, K3smCLI.startTimeBoundArguments)
                let reading = StartTimeBound.parse(exitStatus: r?.status, stdout: r?.stdout ?? Data())
                bound.withLock { $0 = reading }
                return reading
            },
            progress: { progress.append($0) })
        let result = await driver.perform(.start, expected: .stopped)
        // The sentence the window shows for each result, as AppModel.perform
        // assigns it.
        let shown: String
        switch result {
        case .refused(let why): shown = why
        case .declined: shown = "declined"
        case .ran(_, let text), .startedNotSchedulable(let text), .timedOut(let text): shown = text
        }
        var lines = ["bound: \(bound.withLock { $0 }?.seconds ?? -1)"]
        lines += progress.all.map { "progress: " + $0 }
        lines.append("result: " + shown)
        try (lines.joined(separator: "\n") + "\n").write(toFile: statePath, atomically: true, encoding: .utf8)
    }
}
