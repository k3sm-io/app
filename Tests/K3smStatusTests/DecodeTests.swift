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

struct DecodeCase: CustomTestStringConvertible, Sendable {
    let file: String
    let verdict: Verdict
    let role: String
    let summary: String
    let rowCount: Int
    let nodeRow: String
    let nodeState: String
    var testDescription: String { file }
}

@Suite("decode k3sm status JSON")
struct DecodeTests {
    static let cases: [DecodeCase] = [
        DecodeCase(file: "status_daemons_json_running.json", verdict: .running, role: "server",
                   summary: "the control-plane daemon and netd are running (the apiserver was not probed)",
                   rowCount: 2, nodeRow: "server", nodeState: "running"),
        DecodeCase(file: "status_json_running.json", verdict: .running, role: "server",
                   summary: "1/1 nodes ready", rowCount: 12, nodeRow: "server", nodeState: "running"),
        DecodeCase(file: "status_daemons_json_degraded.json", verdict: .degraded, role: "server",
                   summary: "netd: launchd reports running, but pid 1292 is not in the process table · socket /var/lib/k3sm/run/netd.sock",
                   rowCount: 2, nodeRow: "server", nodeState: "unknown"),
        DecodeCase(file: "status_json_degraded.json", verdict: .degraded, role: "server",
                   summary: "", rowCount: -1, nodeRow: "server", nodeState: "unknown"),
        DecodeCase(file: "status_daemons_json_stopped-clean.json", verdict: .stopped, role: "server",
                   summary: "io.k3sm.server is stopped", rowCount: 2, nodeRow: "server", nodeState: "stopped"),
        DecodeCase(file: "status_json_stopped-clean.json", verdict: .stopped, role: "server",
                   summary: "", rowCount: -1, nodeRow: "server", nodeState: "stopped"),
        DecodeCase(file: "status_daemons_json_not-installed.json", verdict: .notInstalled, role: "server",
                   summary: "k3sm is not installed on this Mac", rowCount: 2, nodeRow: "server", nodeState: "not-loaded"),
        DecodeCase(file: "status_daemons_json_unknown.json", verdict: .unknown, role: "server",
                   summary: "", rowCount: 2, nodeRow: "server", nodeState: "unknown"),
        DecodeCase(file: "status_daemons_json_agent-waiting.json", verdict: .degraded, role: "agent",
                   summary: "", rowCount: 2, nodeRow: "agent", nodeState: "waiting"),
    ]

    @Test("fixture decodes", arguments: cases)
    func decodes(_ c: DecodeCase) throws {
        let report = try StatusReport.decode(try fixture(c.file))
        #expect(report.schemaVersion == 1)
        #expect(report.verdict == c.verdict)
        #expect(report.role == c.role)
        if !c.summary.isEmpty {
            #expect(report.summary == c.summary)
        } else {
            #expect(!report.summary.isEmpty)
        }
        if c.rowCount >= 0 {
            #expect(report.rows.count == c.rowCount)
        }
        let row = try #require(report.row(named: c.nodeRow))
        #expect(row.state == c.nodeState)
        #expect(!row.detail.isEmpty)
    }

    @Test("a CLI error is not a report")
    func cliError() throws {
        #expect(throws: StatusDecodeError.malformed) {
            try StatusReport.decode(try fixture("cli-error.txt"))
        }
    }

    @Test("empty output is not a report")
    func empty() {
        #expect(throws: StatusDecodeError.malformed) {
            try StatusReport.decode(Data())
        }
    }

    @Test("a missing schemaVersion is malformed")
    func missingSchema() {
        let json = Data(#"{"verdict":"running","role":"server","summary":"s","rows":[]}"#.utf8)
        #expect(throws: StatusDecodeError.malformed) {
            try StatusReport.decode(json)
        }
    }

    @Test("an unknown contract version is refused")
    func futureSchema() {
        #expect(throws: StatusDecodeError.unsupportedSchema(2)) {
            try StatusReport.decode(try fixture("schema-v2.json"))
        }
    }

    @Test("an unknown verdict word decodes as unrecognized")
    func unrecognizedVerdict() throws {
        let json = Data(#"{"schemaVersion":1,"verdict":"sideways","role":"server","summary":"s","rows":[]}"#.utf8)
        let report = try StatusReport.decode(json)
        #expect(report.verdict == .unrecognized("sideways"))
        #expect(report.verdict.word == "sideways")
    }

    @Test("verdict words round-trip", arguments: ["running", "degraded", "stopped", "not-installed", "unknown"])
    func verdictWords(_ word: String) {
        #expect(Verdict(word: word).word == word)
        #expect(Verdict(word: word) != .unrecognized(word))
    }
}
