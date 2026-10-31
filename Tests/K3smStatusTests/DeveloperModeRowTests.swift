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

/// The developer-mode row, decoded from k3sm's vendored goldens: a full
/// report carries it at severity warn while anything is at the marker path;
/// a daemons-only report (`--daemons`) carries none.
@Suite("the developer-mode row")
struct DeveloperModeRowTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let file: String
        let state: String
        let detail: String
        let remedy: String
        let signing: String
        let fixNeedsAdmin: Bool
        var testDescription: String { file }
    }

    static let cases: [Case] = [
        Case(file: "status_json_developer_mode.json", state: "on",
             detail: "Developer mode: the signature of the k3sm that runs as root is not checked",
             remedy: "Run sudo k3sm install --developer-mode off, or update through k3sm.app to a release whose every program "
                 + "carries the Developer ID signature of one team, the installed k3sm's team if it has one",
             signing: "ad-hoc", fixNeedsAdmin: true),
        Case(file: "status_json_developer_mode_invalid.json", state: "invalid",
             detail: "A developer-mode marker exists but is not a root-owned file, so it is ignored and the signature checks stay on",
             remedy: "sudo rm /Library/k3sm.developer-mode", signing: "team ABCDE12345", fixNeedsAdmin: true),
    ]

    @Test("a full report carries the row at severity warn, with its alert", arguments: cases)
    func fullReport(_ c: Case) throws {
        let report = try StatusReport.decode(try fixture(c.file))
        #expect(report.verdict == .running)
        let row = try #require(report.row(named: "developer-mode"))
        #expect(row.state == c.state)
        #expect(row.severity == "warn")
        #expect(row.detail == c.detail)
        #expect(row.remedy == c.remedy)
        #expect(row.wide == ["signing": c.signing])
        let alert = try #require(row.alert)
        #expect(alert.docs == "install.md#developer-mode")
        #expect(alert.evidence == [c.detail])
        #expect(alert.fix.count == 1)
        #expect(alert.fix.first?.needsAdmin == c.fixNeedsAdmin)
        // The row's text is the CLI's, so it reaches the window only clipped.
        #expect(StatusDisplay.rowDetail(row) == StatusDisplay.clip(c.detail))
    }

    @Test("a daemons-only report decodes with no developer-mode row", arguments: [
        "status_daemons_json_developer_mode.json", "status_daemons_json_developer_mode_invalid.json",
    ])
    func daemonsReport(_ file: String) throws {
        let report = try StatusReport.decode(try fixture(file))
        #expect(report.verdict == .running)
        #expect(report.row(named: "developer-mode") == nil)
        #expect(report.rows.map(\.name) == ["netd", "server"])
    }
}
