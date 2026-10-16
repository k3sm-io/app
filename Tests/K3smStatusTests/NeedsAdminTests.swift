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

@Suite("needs-admin rows")
struct NeedsAdminTests {
    /// Every vendored full report; each carries a `needs-admin` runtimed row.
    static let fullReports = [
        "status_json_agent-join-target.json", "status_json_agent-waiting.json", "status_json_degraded.json",
        "status_json_network-absent.json", "status_json_network-applied-unreadable.json",
        "status_json_network-recorded.json", "status_json_network-unreadable.json",
        "status_json_not-installed.json", "status_json_running.json", "status_json_server-with-workers.json",
        "status_json_stopped-by-user.json", "status_json_stopped-clean.json", "status_json_unknown.json",
    ]

    static func adminRow(_ name: String) -> StatusRow {
        StatusRow(name: name, state: "needs-admin", detail: "needs sudo", remedy: "sudo k3sm status")
    }

    @Test("needs-admin rows do not degrade the verdict", arguments: fullReports)
    func needsAdminRowsDoNotDegradeTheVerdict(_ file: String) throws {
        let report = try StatusReport.decode(try fixture(file))
        let admin = report.rows.filter { $0.rowState == .needsAdmin }
        #expect(!admin.isEmpty)
        for row in admin {
            #expect(row.rowState.tone == .notChecked)
            #expect(!row.rowState.degradesVerdict)
        }
        // The headline and the panel lead with the CLI's own verdict word.
        #expect(StatusDisplay.headline(report).hasPrefix("k3sm \(report.verdict.word)"))
        if report.verdict == .running {
            #expect(MenuStatus.thisMac(of: report) == .ok)
            #expect(StatusDisplay.panelStateLine(report, podCount: 2).hasPrefix("Running, 2 pods"))
        }
    }

    @Test("a running report of only needs-admin rows still reads running")
    func onlyNeedsAdminRows() {
        let report = StatusReport(schemaVersion: 1, verdict: .running, role: "server", summary: "1/1 nodes ready",
                                  rows: ["runtimed", "admin-kubeconfig", "server-args"].map(Self.adminRow))
        #expect(report.rows.allSatisfy { !$0.rowState.degradesVerdict })
        #expect(MenuStatus.thisMac(of: report) == .ok)
        #expect(StatusDisplay.headline(report) == "k3sm running · 1/1 nodes ready · 3 checks need an administrator")
        #expect(StatusDisplay.panelStateLine(report, podCount: 1) == "Running, 1 pod · 3 checks need an administrator")
    }

    @Test("the runtimed row decodes as needs-admin with its remedy, never unknown", arguments: fullReports)
    func decodesAsItsOwnState(_ file: String) throws {
        let report = try StatusReport.decode(try fixture(file))
        let row = try #require(report.row(named: "runtimed"))
        #expect(row.state == "needs-admin")
        #expect(row.rowState == .needsAdmin)
        #expect(row.rowState != .unknown("needs-admin"))
        #expect(row.remedy == "sudo k3sm status")
        #expect(row.detail == "needs sudo: the runtime daemon's socket is owner-only")
        #expect(StatusDisplay.rowDetail(row) == "needs an administrator; run sudo k3sm status")
        let shown = try #require(StatusDisplay.rows(of: report).first { $0.name == "runtimed" })
        #expect(shown.detail == "needs an administrator; run sudo k3sm status")
        #expect(StatusDisplay.needsAdminLine(report) == "1 check needs an administrator")
    }

    @Test("the panel shows the needs-admin sentence and other rows' state words")
    func panelText() {
        #expect(StatusDisplay.panelText(Self.adminRow("datastore")) == "needs an administrator; run sudo k3sm status")
        #expect(StatusDisplay.panelText(StatusRow(name: "netd", state: "running", detail: "pid 1")) == "running")
    }

    @Test("a needs-admin row without a remedy says only that it needs an administrator")
    func noRemedy() {
        let row = StatusRow(name: "runtimed", state: "needs-admin", detail: "d")
        #expect(StatusDisplay.rowDetail(row) == "needs an administrator")
    }

    @Test("the remedy is untrusted and shown clipped to one line")
    func remedyClipped() {
        let row = StatusRow(name: "runtimed", state: "needs-admin", detail: "d",
                            remedy: "sudo k3sm status\n\u{202E}rm -rf /" + String(repeating: "x", count: 400))
        let text = StatusDisplay.rowDetail(row)
        #expect(!text.contains("\n"))
        #expect(!text.unicodeScalars.contains("\u{202E}"))
        #expect(text.hasPrefix("needs an administrator; run sudo k3sm status rm -rf /"))
        #expect(text.count == StatusDisplay.maxLength)
    }

    @Test("a missing or mistyped remedy decodes as empty")
    func remedyTolerant() throws {
        let json = Data(#"{"schemaVersion":1,"verdict":"running","role":"server","summary":"s","rows":[{"name":"a","state":"ok","detail":"d"},{"name":"b","state":"ok","detail":"d","remedy":7}]}"#.utf8)
        let report = try StatusReport.decode(json)
        #expect(report.rows.map(\.remedy) == ["", ""])
    }

    @Test("the summary line counts needs-admin rows", arguments: [(0, nil), (1, "1 check needs an administrator"), (3, "3 checks need an administrator")] as [(Int, String?)])
    func summaryLine(_ count: Int, _ want: String?) {
        let rows = (0..<count).map { Self.adminRow("r\($0)") } + [StatusRow(name: "netd", state: "running", detail: "d")]
        let report = StatusReport(schemaVersion: 1, verdict: .running, role: "server", summary: "", rows: rows)
        #expect(StatusDisplay.needsAdminCount(report) == count)
        #expect(StatusDisplay.needsAdminLine(report) == want)
        #expect(StatusDisplay.headline(report) == (want.map { "k3sm running · " + $0 } ?? "k3sm running"))
    }

    @Test("an unrecognised future state decodes as unknown", arguments: ["needs-admin2", "sideways", "unknown", ""])
    func futureState(_ word: String) {
        let state = RowState(word: word)
        #expect(state == .unknown(word))
        #expect(state.word == word)
        #expect(state.tone == .attention)
        #expect(state.degradesVerdict)
    }

    @Test("committed state words round-trip", arguments: [
        "running", "ok", "ready", "healthy", "needs-admin", "stopped", "not-loaded", "disabled", "failed",
        "crash-loop", "waiting", "expired", "corrupt", "address-mismatch", "down", "not-ready", "wrong-owner",
        "not-mounted", "absent", "partial", "missing", "skip", "drift", "unhealthy", "stale", "behind", "ahead",
        "rolling",
    ])
    func committedWords(_ word: String) {
        let state = RowState(word: word)
        #expect(state.word == word)
        #expect(state != .unknown(word))
    }

    @Test("tones", arguments: [("running", RowTone.healthy), ("needs-admin", .notChecked), ("skip", .attention), ("unknown", .attention), ("behind", .attention), ("ahead", .healthy), ("rolling", .healthy), ("down", .attention), ("unhealthy", .attention)])
    func tones(_ word: String, _ tone: RowTone) {
        #expect(RowState(word: word).tone == tone)
    }
}
