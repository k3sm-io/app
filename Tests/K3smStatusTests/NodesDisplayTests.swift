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
            note: nil, versions: "versions differ")),
        Case(fixture: "status_json_running.json", want: NodesView(
            heading: "1/1 nodes ready",
            lines: [NodeLine(name: "This Mac", role: "server", version: nil)],
            note: "No other nodes", versions: "k3sm 0.1.7")),
        Case(fixture: "status_json_unknown.json", want: NodesView(
            heading: "apiserver unreachable",
            lines: [NodeLine(name: "This Mac", role: "server", version: nil)],
            note: "Other nodes unknown: the apiserver did not answer", versions: "k3sm 0.1.7")),
        Case(fixture: "status_json_agent-join-target.json", want: NodesView(
            heading: "apiserver unreachable",
            lines: [
                NodeLine(name: "This Mac", role: "agent", version: "0.1.7"),
                NodeLine(name: "192.0.2.10", role: "server", version: "version unknown"),
            ],
            note: nil, versions: "versions: some unknown")),
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
        #expect(view.versions == nil)
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
        #expect(view.versions == "versions: some unknown")
    }

    @Test("one release on every node is named once, not per row")
    func sameRelease() {
        let report = StatusReport(
            schemaVersion: 1, verdict: .running, role: "server", summary: "", rows: [],
            workers: [StatusWorker(name: "node-b", role: "agent", version: "v1.36.2+k3sm.0.1.7")])
        let view = NodesDisplay.view(report: report, installed: Self.installed)
        #expect(view.lines == [
            NodeLine(name: "This Mac", role: "server", version: nil),
            NodeLine(name: "node-b", role: "agent", version: nil),
        ])
        #expect(view.versions == "k3sm 0.1.7")
    }

    struct AgreementCase: Sendable, CustomTestStringConvertible {
        let name: String
        let releases: [String?]
        let want: VersionAgreement
        let stat: String?
        var testDescription: String { name }
    }

    static let agreementCases: [AgreementCase] = [
        AgreementCase(name: "all the same", releases: ["0.1.7", "0.1.7", "0.1.7"], want: .same(SemanticVersion("0.1.7")!), stat: "k3sm 0.1.7"),
        AgreementCase(name: "one node", releases: ["0.2.0-rc.1"], want: .same(SemanticVersion("0.2.0-rc.1")!), stat: "k3sm 0.2.0-rc.1"),
        AgreementCase(name: "two differ", releases: ["0.1.7", "0.1.6"], want: .differ, stat: "versions differ"),
        AgreementCase(name: "differ with one unknown", releases: ["0.1.7", nil, "0.1.6"], want: .differ, stat: "versions differ"),
        AgreementCase(name: "agree with one unknown", releases: ["0.1.7", nil], want: .someUnknown, stat: "versions: some unknown"),
        AgreementCase(name: "all unknown", releases: [nil, nil], want: .unknown, stat: nil),
        AgreementCase(name: "no nodes", releases: [], want: .unknown, stat: nil),
    ]

    @Test("the version agreement of the nodes", arguments: agreementCases)
    func agreement(_ c: AgreementCase) {
        let got = VersionAgreement.of(c.releases.map { $0.flatMap(SemanticVersion.init) })
        #expect(got == c.want)
        #expect(got.stat?.text == c.stat)
        #expect(got.showsPerNode == (c.stat?.hasPrefix("k3sm ") != true))
    }

    @Test("the join target's host drops the port and IPv6 brackets", arguments: [
        ("192.0.2.10:9345", "192.0.2.10"), ("server.example", "server.example"),
        ("[2001:db8::1]:9345", "2001:db8::1"), ("2001:db8::1", "2001:db8::1"),
    ])
    func host(_ target: String, _ want: String) {
        #expect(NodesDisplay.host(of: target) == want)
    }
}
