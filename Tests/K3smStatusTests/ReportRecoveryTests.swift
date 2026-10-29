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

private func settle() async {
    for _ in 0..<50 { await Task.yield() }
}

/// ConsoleHarness plays the window's refresh as `AppModel.refresh` does it:
/// each full read takes the next scripted result, goes through
/// `ReportRecovery.take`, and the health check classifies what is shown.
/// Its retries come only from the recovery's own timer: nothing here
/// presses Refresh.
@MainActor
private final class ConsoleHarness {
    let clock = VirtualClock()
    var script: [StatusReport?]
    var reads = 0
    var shown: StatusReport?
    var health: HealthState?
    var recovery: ReportRecovery!

    init(_ script: [StatusReport?]) {
        self.script = script
        recovery = ReportRecovery(clock: clock, jitter: { 0 }) { [weak self] in self?.refresh() }
    }

    func refresh() {
        reads += 1
        let read = script.isEmpty ? nil : script.removeFirst()
        shown = recovery.take(read)
        health = HealthClassifier.classify(HealthClassifierTests.installed(shown))
    }
}

@Suite("report recovery")
@MainActor
struct ReportRecoveryTests {
    static let good = HealthClassifierTests.report("status_json_running.json")

    @Test("StatusUnreadableRecoversOnNextPoll")
    func statusUnreadableRecoversOnNextPoll() async {
        // One failed read, then a good one: the console recovers on its own.
        let first = ConsoleHarness([nil, Self.good])
        first.refresh()
        #expect(first.health == .statusUnreadable)
        #expect(first.recovery.retryPending)
        first.clock.advance(by: PollSchedule.consoleReportInterval)
        await settle()
        #expect(first.reads == 2)
        #expect(first.shown == Self.good)
        #expect(first.health == .healthy)
        #expect(!first.recovery.retryPending)

        // A good read, then one failed read: the last good report stays,
        // marked stale, and "could not be read" never shows.
        let second = ConsoleHarness([Self.good, nil, Self.good])
        second.refresh()
        second.refresh()
        #expect(second.shown == Self.good)
        #expect(second.health == .healthy)
        #expect(second.health?.line != HealthState.statusUnreadable.line)
        #expect(second.recovery.hold.staleLine() != nil)
        second.clock.advance(by: PollSchedule.reportRetryInterval)
        await settle()
        #expect(second.reads == 3)
        #expect(second.recovery.hold.staleLine() == nil)
        #expect(!second.recovery.retryPending)
    }

    @Test("the hold is bounded, and the retries keep coming after it ends")
    func holdIsBounded() async {
        let console = ConsoleHarness([Self.good])
        console.refresh()
        for _ in 0..<ReportHold.maxHeldFailures {
            console.script.append(nil)
        }
        console.refresh()
        #expect(console.health == .healthy)
        for _ in 1..<ReportHold.maxHeldFailures {
            console.clock.advance(by: PollSchedule.reportRetryInterval)
            await settle()
            #expect(console.health == .healthy)
        }
        #expect(console.reads == 1 + ReportHold.maxHeldFailures)
        console.script.append(nil)
        console.clock.advance(by: PollSchedule.reportRetryInterval)
        await settle()
        #expect(console.health == .statusUnreadable)
        #expect(console.recovery.hold.staleLine() == nil)
        // Past the hold it retries at the slower cadence, not faster.
        console.script.append(Self.good)
        console.clock.advance(by: PollSchedule.reportRetryInterval)
        await settle()
        #expect(console.health == .statusUnreadable)
        console.clock.advance(by: PollSchedule.consoleReportInterval)
        await settle()
        #expect(console.health == .healthy)
        #expect(!console.recovery.retryPending)
    }

    @Test("the stale line names the held report's age")
    func staleLine() {
        var hold = ReportHold()
        let readAt = Date(timeIntervalSince1970: 1_000_000)
        _ = hold.take(Self.good, now: readAt)
        #expect(hold.staleLine(now: readAt) == nil)
        #expect(hold.take(nil, now: readAt) == Self.good)
        #expect(hold.staleLine(now: readAt.addingTimeInterval(40))
                == "The last status read failed; showing the report from 40 s ago. It is read again shortly.")
        #expect(hold.staleLine(now: readAt.addingTimeInterval(180))?.contains("3 min ago") == true)
        hold.reset()
        #expect(hold.take(nil) == nil)
    }

    @Test("a reset forgets the held report and cancels the retry")
    func reset() {
        let console = ConsoleHarness([Self.good, nil])
        console.refresh()
        console.refresh()
        #expect(console.recovery.retryPending)
        console.recovery.reset()
        #expect(!console.recovery.retryPending)
        #expect(console.recovery.take(nil) == nil)
    }

    @Test("the full report gets its own deadline, longer than the quick reads'")
    func reportDeadline() {
        #expect(PollSchedule.deadline(for: K3smCLI.reportArguments) == PollSchedule.reportDeadline)
        #expect(PollSchedule.deadline(for: K3smCLI.versionArguments) == PollSchedule.killDeadline)
        #expect(PollSchedule.reportDeadline > PollSchedule.killDeadline)
        #expect(PollSchedule.reportDeadline < PollSchedule.consoleReportInterval)
    }
}
