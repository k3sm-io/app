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

/// A runner that records the scripts it is handed and never runs them.
final class RecordingRunner: PrivilegedRunner {
    let outcome: PrivilegedOutcome
    private let seen = Mutex<[RootScript]>([])

    init(outcome: PrivilegedOutcome = .succeeded) {
        self.outcome = outcome
    }

    var scripts: [RootScript] { seen.withLock { $0 } }

    func runAsRoot(_ script: RootScript, input: Data?) async -> PrivilegedOutcome {
        seen.withLock { $0.append(script) }
        return outcome
    }
}

/// The confirmations a fake user was asked.
final class Questions: Sendable {
    private let seen = Mutex<[LifecycleConfirmation]>([])
    func append(_ c: LifecycleConfirmation) { seen.withLock { $0.append(c) } }
    var all: [LifecycleConfirmation] { seen.withLock { $0 } }
}

/// Status reads served from a fixed sequence.
final class StatusSequence: Sendable {
    private let reports: Mutex<[StatusReport?]>
    private let count = Mutex(0)

    init(_ reports: [StatusReport?]) {
        self.reports = Mutex(reports)
    }

    var reads: Int { count.withLock { $0 } }

    func next() -> StatusReport? {
        count.withLock { $0 += 1 }
        return reports.withLock { $0.isEmpty ? nil : $0.removeFirst() }
    }
}

@Suite("lifecycle driver")
struct LifecycleDriverTests {
    static let team = TeamID("ABCDE12345")!

    static func driver(_ reads: StatusSequence, runner: RecordingRunner, answer: Bool,
                       asked: Questions? = nil) -> LifecycleDriver {
        LifecycleDriver(
            teamID: team,
            readStatus: { reads.next() },
            confirm: { c in
                asked?.append(c)
                return answer
            },
            runner: runner)
    }

    @Test("stop: live read, confirm with the warning, re-read, then the stop script")
    func stopRuns() async throws {
        let joined = Reports.make(nodeState: "running", verdict: "running", workers: [StatusWorker(name: "w", role: "agent")])
        let reads = StatusSequence([joined, joined])
        let runner = RecordingRunner()
        let asked = Questions()
        let result = await Self.driver(reads, runner: runner, answer: true, asked: asked).perform(.stop, expected: .running)
        #expect(result == .ran(.succeeded, LifecycleOutcome.text(.succeeded, verb: .stop)))
        #expect(reads.reads == 2)
        let question = try #require(asked.all.first)
        #expect(question.verb == .stop)
        #expect(question.warning?.contains("1 other node has joined") == true)
        #expect(runner.scripts == [LifecycleScriptBuilder.render(.stop, teamID: Self.team)])
        #expect(runner.scripts.first?.usesStagingLock == false)
    }

    @Test("the warning comes from the live read, not the state the menu showed")
    func warningIsLive() async throws {
        let unknown = Reports.make(nodeState: "running", verdict: "running", workers: nil)
        let asked = Questions()
        _ = await Self.driver(StatusSequence([unknown, unknown]), runner: RecordingRunner(), answer: false, asked: asked)
            .perform(.stop, expected: .running)
        #expect(asked.all.first?.warning == StopWarning.unknown)
    }

    @Test("start from the notification runs only the start script")
    func startRuns() async {
        let runner = RecordingRunner()
        let result = await Self.driver(StatusSequence([Reports.stopped, Reports.stopped]), runner: runner, answer: true)
            .perform(.start, expected: .stopped)
        #expect(result == .ran(.succeeded, "k3sm is starting."))
        #expect(runner.scripts.map(\.prompt) == ["k3sm wants to start k3sm on this Mac."])
    }

    @Test("a state changed before the question refuses without asking")
    func changedBefore() async {
        let runner = RecordingRunner()
        let asked = Questions()
        let result = await Self.driver(StatusSequence([Reports.stopped]), runner: runner, answer: true, asked: asked)
            .perform(.stop, expected: .running)
        guard case .refused = result else { Issue.record("want refused, got \(result)"); return }
        #expect(asked.all.isEmpty)
        #expect(runner.scripts.isEmpty)
    }

    @Test("a state changed while the question was open refuses before the prompt")
    func changedDuring() async {
        let runner = RecordingRunner()
        let result = await Self.driver(StatusSequence([Reports.running, Reports.stopped]), runner: runner, answer: true)
            .perform(.restart, expected: .running)
        guard case .refused(let why) = result else { Issue.record("want refused, got \(result)"); return }
        #expect(why.contains("stopped now"))
        #expect(runner.scripts.isEmpty)
    }

    @Test("an unreadable status refuses before and after the question")
    func unreadable() async {
        let runner = RecordingRunner()
        let before = await Self.driver(StatusSequence([nil]), runner: runner, answer: true).perform(.stop, expected: .running)
        guard case .refused = before else { Issue.record("want refused, got \(before)"); return }
        let after = await Self.driver(StatusSequence([Reports.running, nil]), runner: runner, answer: true).perform(.stop, expected: .running)
        guard case .refused = after else { Issue.record("want refused, got \(after)"); return }
        #expect(runner.scripts.isEmpty)
    }

    @Test("declining the question runs nothing")
    func declined() async {
        let runner = RecordingRunner()
        let reads = StatusSequence([Reports.running, Reports.running])
        let result = await Self.driver(reads, runner: runner, answer: false).perform(.stop, expected: .running)
        #expect(result == .declined)
        #expect(reads.reads == 1)
        #expect(runner.scripts.isEmpty)
    }

    @Test("every run is a fresh prompt")
    func freshPrompt() async {
        let runner = RecordingRunner()
        let reads = StatusSequence([Reports.running, Reports.running, Reports.running, Reports.running])
        let d = Self.driver(reads, runner: runner, answer: true)
        _ = await d.perform(.restart, expected: .running)
        _ = await d.perform(.restart, expected: .running)
        #expect(runner.scripts.count == 2)
        #expect(reads.reads == 4)
    }
}

/// Trust verdicts served from a fixed sequence; the last one repeats.
final class TrustSequence: Sendable {
    private let verdicts: Mutex<[InstalledCLITrust]>
    private let count = Mutex(0)

    init(_ verdicts: [InstalledCLITrust]) {
        self.verdicts = Mutex(verdicts)
    }

    var checks: Int { count.withLock { $0 } }

    func next() -> InstalledCLITrust {
        count.withLock { $0 += 1 }
        return verdicts.withLock { $0.count > 1 ? $0.removeFirst() : $0[0] }
    }
}

/// Counts the CLI runs a TrustedCLI lets through.
final class RunCounter: Sendable {
    private let runs = Mutex<[[String]]>([])
    var all: [[String]] { runs.withLock { $0 } }
    func record(_ args: [String]) { runs.withLock { $0.append(args) } }
}

@Suite("trust-checked CLI runs")
struct TrustedCLITests {
    @Test("a trust verdict going bad after the first check stops the next CLI run")
    func goesBad() async {
        let trust = TrustSequence([.trusted, .refused("/Library/k3sm/k3sm carries an ACL")])
        let runs = RunCounter()
        let cli = TrustedCLI<Int>(check: { trust.next() }, execute: { args in runs.record(args); return 0 })
        guard case .ran = await cli.run(["version"]) else { Issue.record("the first run was refused"); return }
        guard case .refused(let why) = await cli.run(["status", "-o", "json"]) else {
            Issue.record("the second run ran"); return
        }
        #expect(why == "/Library/k3sm/k3sm carries an ACL")
        #expect(runs.all == [["version"]])
        #expect(trust.checks == 2)
    }

    @Test("every run checks again, even after many good ones")
    func everyRun() async {
        let trust = TrustSequence([.trusted])
        let runs = RunCounter()
        let cli = TrustedCLI<Int>(check: { trust.next() }, execute: { args in runs.record(args); return 0 })
        for _ in 0..<3 { _ = await cli.run(["version"]) }
        #expect(trust.checks == 3)
        #expect(runs.all.count == 3)
    }

    @Test("the driver's re-read goes through the check: trust lost mid-flow runs nothing as root")
    func driverReRead() async {
        let trust = TrustSequence([.trusted, .refused("/Library/k3sm is not owned by root, or is writable by group or others")])
        let runs = RunCounter()
        let cli = TrustedCLI<StatusReport?>(check: { trust.next() }, execute: { args in runs.record(args); return Reports.running })
        let runner = RecordingRunner()
        let driver = LifecycleDriver(
            teamID: TeamID("ABCDE12345")!,
            readStatus: {
                if case .ran(let report) = await cli.run(K3smCLI.reportArguments) { return report }
                return nil
            },
            confirm: { _ in true },
            runner: runner)
        let result = await driver.perform(.stop, expected: .running)
        guard case .refused = result else { Issue.record("want refused, got \(result)"); return }
        #expect(runs.all.count == 1)
        #expect(runner.scripts.isEmpty)
    }
}
