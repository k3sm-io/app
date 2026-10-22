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

import K3smStatus
@testable import K3smInstall

/// The re-read rule after a lifecycle verb. Before it, the app read the
/// status once right after the verb; a Start whose read landed while the
/// stop record was still on disk left the banner saying "stopped (by you)".
@Suite("reading the status again after a lifecycle verb")
struct LifecycleSettleTests {
    private static func report(_ json: String) throws -> StatusReport {
        try StatusReport.decode(Data(json.utf8))
    }

    private static let running = """
    {"schemaVersion": 1, "verdict": "running", "role": "server", "summary": "k3sm is running",
     "rows": [{"name": "server", "state": "running", "detail": "pid 1"}]}
    """
    private static let stopped = """
    {"schemaVersion": 1, "verdict": "stopped", "role": "server", "summary": "k3sm is stopped",
     "rows": [{"name": "server", "state": "stopped", "detail": "not running"}],
     "stoppedBy": {"actor": "user", "reason": "", "at": "2026-10-21T20:00:00Z", "phase": "stopped"}}
    """
    private static let upButRecorded = """
    {"schemaVersion": 1, "verdict": "running", "role": "server", "summary": "k3sm is running",
     "rows": [{"name": "server", "state": "running", "detail": "pid 1"}],
     "stoppedBy": {"actor": "user", "reason": "", "at": "2026-10-21T20:00:00Z", "phase": "stopped"}}
    """

    @Test("Stop ends stopped, Start and Restart end running, the rest change nothing")
    func endStates() {
        #expect(LifecycleSettle.endState(of: .stop) == .stopped)
        #expect(LifecycleSettle.endState(of: .start) == .running)
        #expect(LifecycleSettle.endState(of: .restart) == .running)
        #expect(LifecycleSettle.endState(of: .lanOn) == nil)
        #expect(LifecycleSettle.endState(of: .lanOff) == nil)
        #expect(LifecycleSettle.endState(of: .updateApply) == nil)
    }

    @Test("a Start is settled only when the daemon is up and the stop record is gone")
    func startSettles() throws {
        #expect(LifecycleSettle.settled(.start, report: try Self.report(Self.running)))
        #expect(!LifecycleSettle.settled(.start, report: try Self.report(Self.upButRecorded)))
        #expect(!LifecycleSettle.settled(.start, report: try Self.report(Self.stopped)))
        #expect(!LifecycleSettle.settled(.start, report: nil))
    }

    @Test("a Stop is settled once the daemon is down")
    func stopSettles() throws {
        #expect(LifecycleSettle.settled(.stop, report: try Self.report(Self.stopped)))
        #expect(!LifecycleSettle.settled(.stop, report: try Self.report(Self.running)))
    }

    @Test("a verb with no end state never asks for another read")
    func lanVerbsSettleAtOnce() throws {
        #expect(LifecycleSettle.settled(.lanOn, report: nil))
        #expect(!LifecycleSettle.readsAgain(.lanOff, succeeded: true, report: nil, reads: 0))
    }

    @Test("reads again while unsettled, within the bound, only after a verb that succeeded")
    func readsAgain() throws {
        let trailing = try Self.report(Self.upButRecorded)
        #expect(LifecycleSettle.readsAgain(.start, succeeded: true, report: trailing, reads: 0))
        #expect(LifecycleSettle.readsAgain(.start, succeeded: true, report: trailing, reads: LifecycleSettle.maxReads - 1))
        #expect(!LifecycleSettle.readsAgain(.start, succeeded: true, report: trailing, reads: LifecycleSettle.maxReads))
        #expect(!LifecycleSettle.readsAgain(.start, succeeded: false, report: trailing, reads: 0))
        #expect(!LifecycleSettle.readsAgain(.start, succeeded: true, report: try Self.report(Self.running), reads: 0))
    }
}
