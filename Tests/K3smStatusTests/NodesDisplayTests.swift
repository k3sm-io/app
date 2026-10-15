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

@Suite("the console panel's nodes block")
struct NodesDisplayTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let fixture: String
        let want: NodesView
        var testDescription: String { fixture }
    }

    static let installed = SemanticVersion("0.1.7")

    static let cases: [Case] = [
        Case(fixture: "status_json_server-with-workers.json", want: NodesView(
            heading: "3/3 nodes ready",
            lines: [
                NodeLine(name: "This Mac", role: "server", version: "0.1.7"),
                NodeLine(name: "node-a", role: "server", version: "0.1.7"),
                NodeLine(name: "node-b", role: "agent", version: "0.1.6"),
            ],
            note: nil)),
        Case(fixture: "status_json_running.json", want: NodesView(
            heading: "1/1 nodes ready",
            lines: [NodeLine(name: "This Mac", role: "server", version: "0.1.7")],
            note: "No other nodes")),
        Case(fixture: "status_json_unknown.json", want: NodesView(
            heading: "apiserver unreachable",
            lines: [NodeLine(name: "This Mac", role: "server", version: "0.1.7")],
            note: "Other nodes unknown: the apiserver did not answer")),
        Case(fixture: "status_json_agent-join-target.json", want: NodesView(
            heading: "apiserver unreachable",
            lines: [
                NodeLine(name: "This Mac", role: "agent", version: "0.1.7"),
                NodeLine(name: "192.0.2.10", role: "server", version: "version unknown"),
            ],
            note: nil)),
    ]

    @Test("each report shape renders its rows", arguments: cases)
    func rendered(_ c: Case) throws {
        let report = try StatusReport.decode(try fixture(c.fixture))
        #expect(NodesDisplay.view(report: report, installed: Self.installed) == c.want)
    }

    @Test("a worker without a join target says so")
    func agentWithoutTarget() throws {
        let report = try StatusReport.decode(try fixture("status_json_agent-waiting.json"))
        let view = NodesDisplay.view(report: report, installed: nil)
        #expect(view.lines == [NodeLine(name: "This Mac", role: "agent", version: "version unknown")])
        #expect(view.note == NodesDisplay.serverUnknown)
    }

    @Test("workers are sorted by name, unknown versions and roles say so, strings are clipped")
    func workers() {
        let long = String(repeating: "n", count: StatusDisplay.maxLength + 20)
        let report = StatusReport(
            schemaVersion: 1, verdict: .running, role: "server", summary: "", rows: [],
            workers: [
                StatusWorker(name: "zeta\u{7}", role: "agent", version: nil),
                StatusWorker(name: "alpha", role: "", version: "v1.36.2"),
                StatusWorker(name: long, role: "agent", version: "v1.36.2+k3sm.0.2.0-rc.1"),
            ])
        let view = NodesDisplay.view(report: report, installed: nil)
        #expect(view.heading == nil)
        #expect(view.lines == [
            NodeLine(name: "This Mac", role: "server", version: "version unknown"),
            NodeLine(name: "alpha", role: "role unknown", version: "v1.36.2"),
            NodeLine(name: StatusDisplay.clip(long), role: "agent", version: "0.2.0-rc.1"),
            NodeLine(name: "zeta ", role: "agent", version: "version unknown"),
        ])
    }

    @Test("the join target's host drops the port and IPv6 brackets", arguments: [
        ("192.0.2.10:9345", "192.0.2.10"), ("server.example", "server.example"),
        ("[2001:db8::1]:9345", "2001:db8::1"), ("2001:db8::1", "2001:db8::1"),
    ])
    func host(_ target: String, _ want: String) {
        #expect(NodesDisplay.host(of: target) == want)
    }
}
