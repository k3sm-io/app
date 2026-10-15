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

@Suite("status item menu status lines")
struct MenuStatusTests {
    static func report(verdict: Verdict = .running, role: String = "server", node: String?) -> StatusReport {
        let rows = node.map { [StatusRow(name: "node", state: "ready", detail: $0)] } ?? []
        return StatusReport(schemaVersion: 1, verdict: verdict, role: role, summary: "", rows: rows)
    }

    struct MacCase: Sendable, CustomTestStringConvertible {
        let name: String
        let verdict: Verdict?
        let readFailed: Bool
        let want: MenuHealth
        var testDescription: String { name }
    }

    static let macCases: [MacCase] = [
        MacCase(name: "running", verdict: .running, readFailed: false, want: .ok),
        MacCase(name: "degraded", verdict: .degraded, readFailed: false, want: .degraded),
        MacCase(name: "stopped", verdict: .stopped, readFailed: false, want: .down),
        MacCase(name: "not installed", verdict: .notInstalled, readFailed: false, want: .down),
        MacCase(name: "unknown verdict", verdict: .unknown, readFailed: false, want: .unknown),
        MacCase(name: "unrecognized verdict", verdict: .unrecognized("paused"), readFailed: false, want: .unknown),
        MacCase(name: "read failed", verdict: nil, readFailed: true, want: .down),
        MacCase(name: "no report yet", verdict: nil, readFailed: false, want: .unknown),
    ]

    @Test("This Mac", arguments: macCases)
    func thisMac(_ c: MacCase) {
        let report = c.verdict.map { Self.report(verdict: $0, node: nil) }
        #expect(MenuStatus.thisMac(of: report, readFailed: c.readFailed) == c.want)
    }

    struct ClusterCase: Sendable, CustomTestStringConvertible {
        let name: String
        let node: String?
        let want: MenuHealth
        var testDescription: String { name }
    }

    static let clusterCases: [ClusterCase] = [
        ClusterCase(name: "all ready", node: "3/3 nodes ready · my-mac kubelet v1.36.2", want: .ok),
        ClusterCase(name: "one of one", node: "1/1 nodes ready", want: .ok),
        ClusterCase(name: "some ready", node: "2/3 nodes ready · my-mac kubelet v1.36.2", want: .degraded),
        ClusterCase(name: "none ready", node: "0/2 nodes ready", want: .down),
        ClusterCase(name: "apiserver unreachable", node: "apiserver unreachable", want: .down),
        ClusterCase(name: "no node row", node: nil, want: .unknown),
        ClusterCase(name: "other shape", node: "waiting for the server", want: .unknown),
        ClusterCase(name: "more ready than nodes", node: "4/3 nodes ready", want: .unknown),
        ClusterCase(name: "zero nodes", node: "0/0 nodes ready", want: .unknown),
        ClusterCase(name: "not digits", node: "a/3 nodes ready", want: .unknown),
        ClusterCase(name: "overflowing count", node: "99999999999999999999/99999999999999999999 nodes ready", want: .unknown),
    ]

    @Test("Cluster", arguments: clusterCases)
    func cluster(_ c: ClusterCase) {
        #expect(MenuStatus.cluster(of: Self.report(node: c.node)) == c.want)
    }

    @Test("Cluster with no report is unknown")
    func clusterNoReport() {
        #expect(MenuStatus.cluster(of: nil) == .unknown)
    }

    @Test("the fixtures", arguments: [
        ("status_json_running.json", MenuHealth.ok, MenuHealth.ok),
        ("status_json_degraded.json", MenuHealth.ok, MenuHealth.degraded),
        ("status_json_server-with-workers.json", MenuHealth.ok, MenuHealth.ok),
        ("status_json_stopped-clean.json", MenuHealth.down, MenuHealth.down),
        ("status_json_agent-join-target.json", MenuHealth.down, MenuHealth.degraded),
    ])
    func fixtures(_ file: String, _ cluster: MenuHealth, _ mac: MenuHealth) throws {
        let report = try StatusReport.decode(try fixture(file))
        #expect(MenuStatus.cluster(of: report) == cluster)
        #expect(MenuStatus.thisMac(of: report) == mac)
    }

    @Test("the word rides the title and the accessibility text")
    func text() {
        #expect(MenuStatus.title(MenuStatus.clusterLabel, .ok) == "Cluster · ok")
        #expect(MenuStatus.accessibilityText(MenuStatus.thisMacLabel, .down) == "This Mac: down")
        #expect(MenuStatus.accessibilityText(MenuStatus.clusterLabel, .degraded) == "Cluster: degraded")
    }
}
