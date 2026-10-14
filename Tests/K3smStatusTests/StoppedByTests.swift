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

@Suite("decode stoppedBy")
struct StoppedByTests {
    @Test("the stopped-by-user fixtures carry it", arguments: [
        "status_json_stopped-by-user.json", "status_daemons_json_stopped-by-user.json",
    ])
    func fixtures(_ file: String) throws {
        let report = try StatusReport.decode(try fixture(file))
        #expect(report.verdict == .stopped)
        let sb = try #require(report.stoppedBy)
        #expect(sb == StoppedBy(actor: "user", reason: "maintenance window", at: "2026-09-05T09:28:30Z", phase: "stopped"))
        #expect(sb.line == "stopped by user: maintenance window")
    }

    @Test("absent on a report without a stop marker", arguments: [
        "status_json_running.json", "status_daemons_json_stopped-clean.json",
    ])
    func absent(_ file: String) throws {
        #expect(try StatusReport.decode(try fixture(file)).stoppedBy == nil)
    }

    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let value: String
        let want: StoppedBy?
        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(name: "null", value: "null", want: nil),
        Case(name: "a string", value: #""user""#, want: nil),
        Case(name: "an array", value: "[]", want: nil),
        Case(name: "empty object", value: "{}", want: StoppedBy(actor: "", reason: "", at: "", phase: "")),
        Case(name: "mistyped fields", value: #"{"actor":7,"reason":null,"at":true,"phase":"stopping"}"#,
             want: StoppedBy(actor: "", reason: "", at: "", phase: "stopping")),
        Case(name: "extra fields and an unknown actor", value: #"{"actor":"robot","reason":"","at":"x","phase":"stopped","new":1}"#,
             want: StoppedBy(actor: "robot", reason: "", at: "x", phase: "stopped")),
    ]

    @Test("decodes tolerantly and never fails the report", arguments: cases)
    func tolerant(_ c: Case) throws {
        let json = Data(#"{"schemaVersion":1,"verdict":"stopped","role":"server","summary":"s","rows":[],"stoppedBy":"#.utf8
            + Data(c.value.utf8) + Data("}".utf8))
        let report = try StatusReport.decode(json)
        #expect(report.stoppedBy == c.want)
    }

    @Test("the line names the phase, the actor and the reason")
    func line() {
        #expect(StoppedBy(actor: "auto", reason: "", at: "", phase: "stopping").line == "stopping by auto")
        #expect(StoppedBy(actor: "", reason: "r", at: "", phase: "").line == "stopped by someone: r")
    }
}
