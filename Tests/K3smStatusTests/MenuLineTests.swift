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

import Testing

@testable import K3smStatus

@Suite("status item menu lines")
struct MenuLineTests {
    static func report(verdict: Verdict = .running, summary: String = "", rows: [StatusRow] = []) -> StatusReport {
        StatusReport(schemaVersion: 1, verdict: verdict, role: "server", summary: summary, rows: rows)
    }

    struct HeaderCase: Sendable, CustomTestStringConvertible {
        let name: String
        let verdict: Verdict
        let summary: String
        let want: String
        var testDescription: String { name }
    }

    static let headerCases: [HeaderCase] = [
        HeaderCase(name: "no summary", verdict: .running, summary: "", want: "k3sm · running"),
        HeaderCase(name: "with summary", verdict: .degraded, summary: "netd down", want: "k3sm · degraded · netd down"),
        HeaderCase(
            name: "long summary cut at the limit", verdict: .degraded,
            summary: "netd: launchd reports running, but pid 1292 is not in the process table",
            want: "k3sm · degraded · netd: launchd reports run…"),
        HeaderCase(name: "control characters removed", verdict: .stopped, summary: "a\nb\u{1B}c", want: "k3sm · stopped · a b c"),
    ]

    @Test("header", arguments: headerCases)
    func header(_ c: HeaderCase) {
        let got = StatusDisplay.menuHeader(of: Self.report(verdict: c.verdict, summary: c.summary))
        #expect(got == c.want)
        #expect(got.count <= StatusDisplay.menuLineLimit)
    }

    struct LineCase: Sendable, CustomTestStringConvertible {
        let name: String
        let input: String
        let want: String
        var testDescription: String { name }
    }

    static let limit = StatusDisplay.menuLineLimit

    static let lineCases: [LineCase] = [
        LineCase(name: "short line unchanged", input: "pid 1292", want: "pid 1292"),
        LineCase(name: "one below the limit kept", input: String(repeating: "x", count: limit - 1), want: String(repeating: "x", count: limit - 1)),
        LineCase(name: "exact limit kept", input: String(repeating: "x", count: limit), want: String(repeating: "x", count: limit)),
        LineCase(name: "one over the limit cut", input: String(repeating: "x", count: limit + 1), want: String(repeating: "x", count: limit - 1) + "…"),
        LineCase(
            name: "long LAN note cut",
            input: "Other devices on your network can reach this Mac's workloads on their ports.",
            want: "Other devices on your network can reach thi…"),
        LineCase(name: "control characters removed", input: "a\tb\u{7}c", want: "a b c"),
    ]

    @Test("menu line", arguments: lineCases)
    func line(_ c: LineCase) {
        let got = StatusDisplay.menuLine(c.input)
        #expect(got == c.want)
        #expect(got.filter { $0 == "…" }.count == (c.input.count > Self.limit ? 1 : 0))
    }

    struct StatsCase: Sendable, CustomTestStringConvertible {
        let name: String
        let rows: [StatusRow]
        let want: String?
        var testDescription: String { name }
    }

    static let statsCases: [StatsCase] = [
        StatsCase(
            name: "nodes ready and the pod counts",
            rows: [
                StatusRow(name: "install", state: "ok", detail: "/Library/k3sm/k3sm"),
                StatusRow(name: "node", state: "ready", detail: "2/2 nodes ready · my-mac kubelet v1.36.2"),
                StatusRow(name: "workloads", state: "ok", detail: "6 running · 2 succeeded"),
            ],
            want: "2/2 nodes ready · 6 running · 2 succeeded"),
        StatsCase(
            name: "a long line is cut at the limit",
            rows: [
                StatusRow(name: "node", state: "ready", detail: "12/12 nodes ready"),
                StatusRow(name: "workloads", state: "ok", detail: "120 running · 40 succeeded · 30 vm · 2 failed"),
            ],
            want: "12/12 nodes ready · 120 running · 40 succee…"),
        StatsCase(
            name: "no counts, no line",
            rows: [
                StatusRow(name: "netd", state: "running", detail: "pid 1292"),
                StatusRow(name: "node", state: "unknown", detail: "apiserver unreachable"),
            ],
            want: nil),
    ]

    @Test("one stats line, no rows", arguments: statsCases)
    func stats(_ c: StatsCase) {
        let got = StatusDisplay.menuStats(of: Self.report(rows: c.rows))
        #expect(got == c.want)
        #expect((got?.count ?? 0) <= StatusDisplay.menuLineLimit)
        #expect(!(got ?? "").contains("install") && !(got ?? "").contains("netd"))
    }

    @Test("a real degraded report renders as two short lines")
    func degradedFixture() throws {
        let report = try StatusReport.decode(try fixture("status_json_degraded.json"))
        #expect(StatusDisplay.menuHeader(of: report) == "k3sm · degraded · netd: launchd reports run…")
        #expect(StatusDisplay.menuStats(of: report) == "1/1 nodes ready · 3 running")
    }
}
