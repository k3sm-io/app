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

@Suite("the info popover")
struct StatusPopoverTests {
    private static func report(_ name: String) throws -> StatusReport {
        try StatusReport.decode(fixture(name))
    }

    @Test("the popover lists only the checks that are not ok, or says all are ok")
    func popoverShowsOnlyProblemRows() throws {
        let running = try Self.report("status_json_running.json")
        // datastore skip, update unknown and runtimed needs-admin are not problems.
        #expect(StatusPopover.problemRows(of: running).isEmpty)
        #expect(StatusPopover.allOkLine(running) == "All 10 checks are ok.")

        let degraded = try Self.report("status_json_degraded.json")
        #expect(StatusPopover.problemRows(of: degraded).map(\.name) == ["netd", "server"])
        #expect(StatusPopover.allOkLine(degraded) == nil)

        let stopped = try Self.report("status_json_stopped-by-user.json")
        #expect(StatusPopover.problemRows(of: stopped).map(\.name) == ["netd", "server", "apiserver"])

        let waiting = try Self.report("status_json_agent-waiting.json")
        #expect(StatusPopover.problemRows(of: waiting).map(\.name) == ["agent", "kubeconfig"])

        // The rows are clipped as the full table clips them.
        let full = StatusDisplay.rows(of: degraded)
        #expect(StatusPopover.problemRows(of: degraded) == full.filter { ["netd", "server"].contains($0.name) })
    }

    @Test("a row's severity decides; a row without one falls back to how it is drawn", arguments: [
        ("warn", "ok", true),
        ("fail", "running", true),
        ("ok", "stopped", false),
        ("skip", "needs-admin", false),
        ("unknown", "unknown", false),
        ("", "stopped", true),
        ("", "running", false),
        ("", "needs-admin", false),
        ("", "behind", false),
        ("bogus", "down", true),
    ] as [(String, String, Bool)])
    func problemBySeverity(_ severity: String, _ state: String, _ problem: Bool) {
        let row = StatusRow(name: "r", state: state, detail: "d", severity: severity)
        #expect(StatusPopover.isProblem(row) == problem)
    }

    @Test("the severity decodes as printed and reads as empty when missing or mistyped")
    func severityDecodes() throws {
        let json = #"{"schemaVersion":1,"verdict":"running","role":"server","summary":"s","rows":[{"name":"a","state":"ok","severity":"warn","detail":""},{"name":"b","state":"ok","detail":""},{"name":"c","state":"ok","severity":3,"detail":""}]}"#
        let report = try StatusReport.decode(Data(json.utf8))
        #expect(report.rows.map(\.severity) == ["warn", "", ""])
        let allOk = try StatusReport.decode(Data(json.replacingOccurrences(of: "\"warn\"", with: "\"ok\"").utf8))
        // b has no severity and a healthy state; c's mistyped severity reads as none.
        #expect(StatusPopover.allOkLine(allOk) == "All 3 checks are ok.")
    }

    /// log, running, last step succeeded, shown.
    @Test("the root step's log shows only while a step runs or after one failed", arguments: [
        ("", true, false, false),
        ("", false, false, false),
        ("log", true, true, true),
        ("log", false, false, true),
        ("log", false, true, false),
    ] as [(String, Bool, Bool, Bool)])
    func logShows(_ log: String, _ running: Bool, _ succeeded: Bool, _ shown: Bool) {
        #expect(StatusPopover.showsLog(logTail: log, running: running, lastStepSucceeded: succeeded) == shown)
    }
}
