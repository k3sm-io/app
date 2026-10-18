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

    static func driver(_ runner: ScriptedRunner, progress: Progress, bound: StartTimeBound.Reading = .printed(420)) -> LifecycleDriver {
        LifecycleDriver(
            teamID: team,
            readStatus: { Reports.stopped },
            confirm: { _ in true },
            runner: runner,
            readStartTimeBound: {
                progress.readBound()
                return bound
            },
            progress: { progress.append($0) })
    }

    @Test("a cordoned start is re-run once and then succeeds")
    func retryThenSuccess() async {
        let runner = ScriptedRunner([Self.cordoned, Self.ok])
        let progress = Progress()
        let result = await Self.driver(runner, progress: progress).perform(.start, expected: .stopped)
        #expect(result == .ran(.succeeded, "k3sm is starting."))
        #expect(runner.scripts == [LifecycleScriptBuilder.render(.start, teamID: Self.team),
                                   LifecycleScriptBuilder.render(.start, teamID: Self.team)])
        #expect(progress.all == [StartRetry.retryingText])
        #expect(progress.reads == 1)
    }

    @Test("a second cordoned exit shows that state and runs nothing further")
    func retryThenStillCordoned() async {
        let runner = ScriptedRunner([Self.cordoned, Self.cordoned, Self.ok])
        let progress = Progress()
        let result = await Self.driver(runner, progress: progress).perform(.start, expected: .stopped)
        #expect(result == .startedNotSchedulable(StartRetry.notSchedulableText))
        #expect(runner.scripts.count == 2)
        #expect(progress.all == [StartRetry.retryingText])
    }

    @Test("any other exit 1 stays a failed start, not re-run")
    func otherExitOne() async {
        let runner = ScriptedRunner([Self.otherFailure, Self.ok])
        let progress = Progress()
        let result = await Self.driver(runner, progress: progress).perform(.start, expected: .stopped)
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
        let v = await Deadline.race(.seconds(5)) { 7 }
        #expect(v == 7)
    }

    @Test("the deadline returns nil when the operation runs past it")
    func deadlinePassed() async {
        let start = ContinuousClock.now
        let v: Int? = await Deadline.race(.milliseconds(50)) {
            try? await Task.sleep(for: .seconds(3))
            return 7
        }
        #expect(v == nil)
        #expect(ContinuousClock.now - start < .seconds(2))
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

    /// Holds the calling thread: a sleep that does not give it back to the pool.
    static func block(seconds: Double) {
        Thread.sleep(forTimeInterval: seconds)
    }

    @Test("the deadline returns nil on time while the cooperative pool is saturated")
    func deadlineSaturatedPool() async {
        let executor = QueueTaskExecutor()
        let elapsed = await Task(executorPreference: executor) { () -> (Int?, Duration) in
            // More blocking jobs than the pool has threads, each holding its
            // thread for a second with a sleep the pool cannot reclaim.
            for _ in 0..<(ProcessInfo.processInfo.activeProcessorCount + 4) {
                Task.detached { Self.block(seconds: 1) }
            }
            Self.block(seconds: 0.1)
            let start = ContinuousClock.now
            let v: Int? = await Deadline.race(.milliseconds(50)) {
                try? await Task.sleep(for: .seconds(5))
                return 7
            }
            return (v, ContinuousClock.now - start)
        }.value
        #expect(elapsed.0 == nil)
        #expect(elapsed.1 < .milliseconds(500), "returned after \(elapsed.1)")
    }

    /// A root step that outlives any deadline and would ask for a re-run if
    /// it were ever awaited; it counts its calls.
    final class SlowCordonedRunner: PrivilegedRunner {
        private let count = Mutex(0)
        var calls: Int { count.withLock { $0 } }

        func runAsRoot(_ script: RootScript, input: Data?) async -> PrivilegedOutcome {
            await runAsRootReportingError(script, input: input).outcome
        }

        func runAsRootReportingError(_ script: RootScript, input: Data?) async -> PrivilegedRun {
            count.withLock { $0 += 1 }
            try? await Task.sleep(for: .seconds(5))
            return StartRetryTests.cordoned
        }
    }

    @Test("a start past its deadline times out and runs the root step only once")
    func startTimesOutOnce() async {
        let runner = SlowCordonedRunner()
        let start = ContinuousClock.now
        // A printed bound of minus the margin is a zero wait, so the
        // deadline passes while the first run is still going.
        let d = LifecycleDriver(
            teamID: Self.team, readStatus: { Reports.stopped }, confirm: { _ in true }, runner: runner,
            readStartTimeBound: { .printed(-StartTimeBound.marginSeconds) })
        let result = await d.perform(.start, expected: .stopped)
        #expect(result == .timedOut(StartRetry.timedOutText(seconds: 0)))
        #expect(ContinuousClock.now - start < .seconds(2))
        try? await Task.sleep(for: .milliseconds(200))
        #expect(runner.calls == 1)
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
