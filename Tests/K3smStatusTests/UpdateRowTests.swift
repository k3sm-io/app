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

@Suite("the update row")
struct UpdateRowTests {
    /// The vendored full reports of an installed server carry an `update` row.
    static let serverReports = [
        "status_json_degraded.json", "status_json_network-absent.json",
        "status_json_network-applied-unreadable.json", "status_json_network-recorded.json",
        "status_json_network-unreadable.json", "status_json_running.json", "status_json_server-with-workers.json",
        "status_json_stopped-by-user.json", "status_json_stopped-clean.json", "status_json_unknown.json",
    ]
    /// A worker, or a Mac with no install, has none.
    static let otherReports = [
        "status_json_agent-join-target.json", "status_json_agent-waiting.json", "status_json_not-installed.json",
    ]

    @Test("a server's update row with no check recorded is unknown, with its detail", arguments: serverReports)
    func serverFixtures(_ file: String) throws {
        let report = try StatusReport.decode(try fixture(file))
        let row = try #require(report.row(named: "update"))
        #expect(row.state == "unknown")
        #expect(row.rowState == .unknown("unknown"))
        #expect(row.detail == "no update check is recorded yet (the server checks once an hour)")
        #expect(row.remedy == "sudo k3sm update check")
        #expect(StatusDisplay.rowDetail(row) == "no update check is recorded yet (the server checks once an hour)")
        #expect(StatusDisplay.panelText(row) == "unknown")
    }

    @Test("a worker or an uninstalled Mac reports no update row", arguments: otherReports)
    func otherFixtures(_ file: String) throws {
        let report = try StatusReport.decode(try fixture(file))
        #expect(report.row(named: "update") == nil)
    }

    static let behindRow = StatusRow(
        name: "update", state: "behind", detail: "k3sm v0.1.8 is available; node mac-2 runs v0.1.7",
        remedy: "curl -fsSL https://k3sm.io/install.sh | sh")

    @Test("behind is its own state, drawn for attention, and never moves the verdict")
    func behind() {
        let row = Self.behindRow
        #expect(row.rowState == .behind)
        #expect(row.rowState.tone == .attention)
        #expect(!row.rowState.degradesVerdict)
        #expect(StatusDisplay.panelText(row) == "behind")
        #expect(StatusDisplay.rowDetail(row)
            == "k3sm v0.1.8 is available; node mac-2 runs v0.1.7; run curl -fsSL https://k3sm.io/install.sh | sh")
        let report = StatusReport(schemaVersion: 1, verdict: .running, role: "server", summary: "1/1 nodes ready",
                                  rows: [row])
        #expect(MenuStatus.thisMac(of: report) == .ok)
        #expect(StatusDisplay.headline(report) == "k3sm running · 1/1 nodes ready")
    }

    @Test("ahead is its own state with the ok tone and shows its detail")
    func ahead() {
        let row = StatusRow(name: "update", state: "ahead", detail: "node mac-1 runs v0.1.9, newer than v0.1.8")
        #expect(row.rowState == .ahead)
        #expect(row.rowState.tone == .healthy)
        #expect(!row.rowState.degradesVerdict)
        #expect(StatusDisplay.panelText(row) == "ahead")
        #expect(StatusDisplay.rowDetail(row) == "node mac-1 runs v0.1.9, newer than v0.1.8")
    }

    @Test("a behind row's detail and remedy are untrusted and clipped to one line")
    func behindClipped() {
        let row = StatusRow(name: "update", state: "behind", detail: "old\u{202E}er\nnode",
                            remedy: "curl x | sh\n" + String(repeating: "y", count: 400))
        let text = StatusDisplay.rowDetail(row)
        #expect(!text.contains("\n"))
        #expect(!text.unicodeScalars.contains("\u{202E}"))
        #expect(text.hasPrefix("older node; run curl x | sh y"))
        #expect(text.count == StatusDisplay.maxLength)
    }
}
