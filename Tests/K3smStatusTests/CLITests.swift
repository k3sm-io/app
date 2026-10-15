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

@Suite("CLI invocation and display")
struct CLITests {
    @Test("the CLI runs by absolute path with fixed arguments")
    func fixedInvocation() {
        #expect(K3smCLI.path == "/Library/k3sm/k3sm")
        #expect(K3smCLI.path.hasPrefix(K3smCLI.installRoot + "/"))
        #expect(K3smCLI.probeArguments == ["status", "daemons", "-o", "json"])
        #expect(K3smCLI.reportArguments == ["status", "-o", "json"])
    }

    struct EnvCase: Sendable, CustomTestStringConvertible {
        let name: String
        let home: String
        let wantHome: String
        var testDescription: String { name }
    }

    static let envCases: [EnvCase] = [
        EnvCase(name: "absolute home kept", home: "/Users/alice", wantHome: "/Users/alice"),
        EnvCase(name: "empty home replaced", home: "", wantHome: "/var/empty"),
        EnvCase(name: "relative home replaced", home: "alice", wantHome: "/var/empty"),
        EnvCase(name: "tilde home replaced", home: "~alice", wantHome: "/var/empty"),
    ]

    @Test("the environment is built, never inherited", arguments: envCases)
    func environment(_ c: EnvCase) {
        let env = K3smCLI.environment(home: c.home, user: "alice")
        #expect(env == ["HOME": c.wantHome, "USER": "alice", "LOGNAME": "alice", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
        #expect(env["KUBECONFIG"] == nil)
        #expect(env["K3SM_WORK_DIR"] == nil)
    }

    @Test("poll cadence follows visibility")
    func cadence() {
        #expect(PollSchedule.interval(visible: true) == .seconds(5))
        #expect(PollSchedule.interval(visible: false) == .seconds(15))
        #expect(PollSchedule.killDeadline < PollSchedule.visibleInterval)
    }

    struct StatedCase: Sendable, CustomTestStringConvertible {
        let name: String
        let value: Duration
        let seconds: Int64
        let readme: String
        var testDescription: String { name }
    }

    @Test("the schedule is what the README states", arguments: [
        StatedCase(name: "console report", value: PollSchedule.consoleReportInterval, seconds: 30,
                   readme: "re-read every 30 seconds"),
    ])
    func stated(_ c: StatedCase) throws {
        #expect(c.value == .seconds(c.seconds))
        let readme = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("README.md")
        let text = try String(contentsOf: readme, encoding: .utf8)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(text.contains(c.readme))
    }

    struct ClipCase: Sendable, CustomTestStringConvertible {
        let name: String
        let input: String
        let want: String
        var testDescription: String { name }
    }

    static let clipCases: [ClipCase] = [
        ClipCase(name: "plain text unchanged", input: "pid 1292", want: "pid 1292"),
        ClipCase(name: "newline flattened", input: "a\nb", want: "a b"),
        ClipCase(name: "escape and tab flattened", input: "a\u{1B}[31mb\tc", want: "a [31mb c"),
        ClipCase(name: "markdown stays literal", input: "[click](https://example.com) **bold**", want: "[click](https://example.com) **bold**"),
        ClipCase(name: "exact limit kept", input: String(repeating: "x", count: 160), want: String(repeating: "x", count: 160)),
        ClipCase(name: "over limit clipped", input: String(repeating: "x", count: 161), want: String(repeating: "x", count: 159) + "…"),
    ]

    @Test("clip", arguments: clipCases)
    func clip(_ c: ClipCase) {
        #expect(StatusDisplay.clip(c.input) == c.want)
    }

    @Test("rows are capped and clipped")
    func rowCap() {
        let rows = (0..<40).map { StatusRow(name: "row\($0)", state: "ok", detail: String(repeating: "d", count: 500)) }
        let report = StatusReport(schemaVersion: 1, verdict: .running, role: "server", summary: "", rows: rows)
        let shown = StatusDisplay.rows(of: report)
        #expect(shown.count == StatusDisplay.maxRows)
        #expect(shown.allSatisfy { $0.detail.count == StatusDisplay.maxLength })
        #expect(shown.first?.name == "row0")
    }
}
