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

    @Test("the list reads outlast the probe's deadline but not the report interval")
    func listDeadline() {
        #expect(PollSchedule.listDeadline == .seconds(10))
        #expect(PollSchedule.killDeadline < PollSchedule.listDeadline)
        #expect(PollSchedule.listDeadline < PollSchedule.consoleReportInterval)
    }

    enum GateStep: Sendable { case begin(Bool), finish(Bool) }

    struct GateCase: Sendable, CustomTestStringConvertible {
        let name: String
        let steps: [GateStep]
        var testDescription: String { name }
    }

    @Test("the poll gate keeps one run in flight and coalesces the rest into one more", arguments: [
        GateCase(name: "a lone run", steps: [.begin(true), .finish(false)]),
        GateCase(name: "a refresh during a run runs once more after it",
                 steps: [.begin(true), .begin(false), .finish(true), .finish(false)]),
        GateCase(name: "three refreshes during a run coalesce into one",
                 steps: [.begin(true), .begin(false), .begin(false), .begin(false), .finish(true), .finish(false)]),
        GateCase(name: "a refresh during the extra run runs once more again",
                 steps: [.begin(true), .begin(false), .finish(true), .begin(false), .finish(true), .finish(false)]),
        GateCase(name: "the gate is free again after a run",
                 steps: [.begin(true), .finish(false), .begin(true), .finish(false)]),
    ])
    func pollGate(_ c: GateCase) {
        var gate = PollGate()
        for step in c.steps {
            switch step {
            case .begin(let want): #expect(gate.begin() == want)
            case .finish(let want): #expect(gate.finish() == want)
            }
        }
        #expect(gate == PollGate())
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
        ClipCase(name: "right-to-left override removed", input: "nginx\u{202E}gnp.exe", want: "nginxgnp.exe"),
        ClipCase(name: "bidi isolates removed", input: "a\u{2066}b\u{2067}c\u{2068}d\u{2069}e", want: "abcde"),
        ClipCase(name: "zero-width characters removed", input: "re\u{200B}gis\u{200D}try\u{FEFF}", want: "registry"),
        ClipCase(name: "line separator flattened", input: "a\u{2028}b\u{2029}c", want: "a b c"),
        ClipCase(name: "CRLF is one space", input: "a\r\nb", want: "a b"),
        ClipCase(name: "tag characters removed", input: "a\u{E0041}b", want: "ab"),
    ]

    struct BodyCase: Sendable, CustomTestStringConvertible {
        let name: String
        let input: String
        let want: String
        var testDescription: String { name }
    }

    static let bodyCases: [BodyCase] = [
        BodyCase(name: "lines and tabs kept", input: "a\n\tb\nc", want: "a\n\tb\nc"),
        BodyCase(name: "CRLF and CR become one line break", input: "a\r\nb\rc", want: "a\nb\nc"),
        BodyCase(name: "separators become line breaks", input: "a\u{2028}b\u{2029}c", want: "a\nb\nc"),
        BodyCase(name: "escape and NUL removed", input: "\u{1B}[31mred\u{0}", want: "[31mred"),
        BodyCase(name: "C1 control removed", input: "a\u{85}b", want: "ab"),
        BodyCase(name: "bidi and zero-width removed", input: "x\u{202E}y\u{2066}z\u{200B}w", want: "xyzw"),
        BodyCase(name: "markdown stays literal", input: "**not bold** [x](y)", want: "**not bold** [x](y)"),
        BodyCase(name: "non-ASCII letters, marks and emoji kept", input: "\u{E9} e\u{301} \u{65E5}\u{672C} \u{2764}\u{FE0F}", want: "\u{E9} e\u{301} \u{65E5}\u{672C} \u{2764}\u{FE0F}"),
    ]

    @Test("body", arguments: bodyCases)
    func body(_ c: BodyCase) {
        #expect(StatusDisplay.body(c.input) == c.want)
    }

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
