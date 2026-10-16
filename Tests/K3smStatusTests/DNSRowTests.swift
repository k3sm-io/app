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

/// Rows the vendored goldens carry only in their healthy form, driven from a
/// golden: the k3sm report is read, one row is replaced by the shape k3sm's
/// status contract documents for the other state, and the result decoded.
enum GoldenVariant {
    static func report(_ file: String, replacing name: String, with row: [String: Any]) throws -> StatusReport {
        var object = try #require(try JSONSerialization.jsonObject(with: try fixture(file)) as? [String: Any])
        var rows = try #require(object["rows"] as? [[String: Any]])
        let index = try #require(rows.firstIndex { $0["name"] as? String == name }, "\(file) has no \(name) row")
        rows[index] = row
        object["rows"] = rows
        return try StatusReport.decode(try JSONSerialization.data(withJSONObject: object))
    }
}

@Suite("the dns row")
struct DNSRowTests {
    /// Every vendored full report carries a dns row; installed ones answer.
    static let answering = [
        "status_json_agent-join-target.json", "status_json_agent-waiting.json", "status_json_degraded.json",
        "status_json_network-absent.json", "status_json_network-applied-unreadable.json", "status_json_network-recorded.json",
        "status_json_network-unreadable.json", "status_json_running.json", "status_json_server-with-workers.json",
        "status_json_unknown.json",
    ]
    static let skipped = ["status_json_not-installed.json", "status_json_stopped-by-user.json", "status_json_stopped-clean.json"]

    @Test("an answering resolver is ok, healthy, with its wide fields", arguments: answering)
    func ok(_ file: String) throws {
        let row = try #require(try StatusReport.decode(try fixture(file)).row(named: "dns"))
        #expect(row.rowState == .healthy("ok"))
        #expect(row.rowState.tone == .healthy)
        #expect(row.wide == ["answer": "10.43.0.1", "name": "kubernetes.default.svc.cluster.local", "vip": "10.43.0.10"])
        #expect(StatusDisplay.rowDetail(row) == "10.43.0.10 answered 10.43.0.1 over UDP for kubernetes.default.svc.cluster.local")
    }

    @Test("a stopped or uninstalled Mac skips it", arguments: skipped)
    func skip(_ file: String) throws {
        let row = try #require(try StatusReport.decode(try fixture(file)).row(named: "dns"))
        #expect(row.rowState == .reported("skip"))
    }

    @Test("down is its own state, for attention, with the kickstart remedy and wide.tcp", arguments: [
        ("status_json_running.json", "sudo launchctl kickstart -k system/io.k3sm.server"),
        ("status_json_agent-waiting.json", "sudo launchctl kickstart -k system/io.k3sm.agent"),
    ])
    func down(_ file: String, _ remedy: String) throws {
        let report = try GoldenVariant.report(file, replacing: "dns", with: [
            "name": "dns", "state": "down", "severity": "warn",
            "detail": "10.43.0.10 did not answer over UDP in 3s; TCP answered 10.43.0.1", "remedy": remedy,
            "wide": ["vip": "10.43.0.10", "name": "kubernetes.default.svc.cluster.local", "tcp": "10.43.0.1"],
        ])
        let row = try #require(report.row(named: "dns"))
        #expect(row.rowState == .down)
        #expect(row.rowState.word == "down")
        #expect(row.rowState.tone == .attention)
        #expect(row.rowState.degradesVerdict)
        #expect(row.wide["tcp"] == "10.43.0.1")
        #expect(StatusDisplay.rowDetail(row) == "10.43.0.10 did not answer over UDP in 3s; TCP answered 10.43.0.1; run " + remedy)
        #expect(StatusDisplay.panelText(row) == "down")
    }

    @Test("unhealthy is its own state, for attention")
    func unhealthy() throws {
        let report = try GoldenVariant.report("status_json_running.json", replacing: "dns", with: [
            "name": "dns", "state": "unhealthy", "severity": "warn", "detail": "10.43.0.10 answered NXDOMAIN",
            "wide": ["vip": "10.43.0.10", "name": "kubernetes.default.svc.cluster.local"],
        ])
        let row = try #require(report.row(named: "dns"))
        #expect(row.rowState == .unhealthy)
        #expect(row.rowState.tone == .attention)
        #expect(row.rowState.degradesVerdict)
        #expect(StatusDisplay.rowDetail(row) == "10.43.0.10 answered NXDOMAIN")
    }
}
