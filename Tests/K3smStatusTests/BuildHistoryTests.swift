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

@Suite("the build history")
struct BuildHistoryTests {
    static func at(_ text: String) -> Date { BuildHistory.timestamp(text)! }

    @Test("k3sm build ls -o json decodes into rows, newest first, with every field the ledger records")
    func buildHistoryDecodesLedgerRows() throws {
        let rows = try BuildHistory.decode(fixture("build_ls_json.json"))
        #expect(rows.map(\.key) == ["05ed1a6a9d12", "48346d2e1129", "46d8d9a0a692", "cc5ce47dda43"])
        #expect(rows.map(\.status) == [.running, .cancelled, .failed, .succeeded])
        #expect(rows.allSatisfy { $0.id?.value == $0.key })

        let running = rows[0]
        #expect(running.tag == "worker:dev" && running.platform == "linux/arm64" && running.engine == "engine")
        #expect(running.context == "/Users/dev/worker" && running.dockerfile == "/Users/dev/worker/Dockerfile")
        #expect(running.startedAt == Self.at("2026-10-16T07:41:07.492153Z"))
        #expect(running.finishedAt == nil && running.digest == nil && running.error == nil)
        #expect(running.duration(now: Self.at("2026-10-16T07:42:07.492153Z")) == 60)

        let cancelled = rows[1]
        #expect(cancelled.duration() == 72.5)

        let failed = rows[2]
        #expect(failed.platform == "linux/arm64,linux/amd64")
        #expect(failed.error == #"process "/bin/sh -c make" did not complete successfully: exit code: 2"#)
        #expect(failed.digest == nil)

        let succeeded = rows[3]
        #expect(succeeded.engine == "native")
        #expect(succeeded.digest == "sha256:9f2c4e1b7a3d5f60812e4b9c0d7a6e5f4c3b2a1908f7e6d5c4b3a29180716253")
        #expect(BuildHistory.duration(succeeded.duration()) == "5s")

        #expect(BuildHistory.tabResult(exitCode: 0, stdout: try fixture("build_ls_json.json")) == .value(rows))
    }

    @Test("an empty ledger is an empty list, and a failed or foreign read is a failure")
    func emptyAndFailures() {
        #expect(BuildHistory.tabResult(exitCode: 0, stdout: Data("[]\n".utf8)) == .value([]))
        #expect(BuildHistory.tabResult(exitCode: 1, stdout: Data()) == .failed("k3sm build ls exited 1"))
        #expect(BuildHistory.tabResult(exitCode: 0, stdout: Data("{not json".utf8)) == .failed("the build history could not be read"))
        #expect(throws: BuildHistoryDecodeError.notAnArray) { try BuildHistory.decode(Data(#"{"id":"aaaaaaaaaaaa"}"#.utf8)) }
    }

    @Test("rows are sorted by start, newest first, whatever order the ledger printed them in")
    func newestFirst() throws {
        let json = #"""
            [{"id":"aaaaaaaaaaaa","status":"succeeded","startedAt":"2026-10-16T07:00:00Z"},
             {"id":"bbbbbbbbbbbb","status":"succeeded"},
             {"id":"cccccccccccc","status":"succeeded","startedAt":"2026-10-16T09:00:00+02:00"},
             {"id":"dddddddddddd","status":"running","startedAt":"2026-10-16T08:00:00Z"}]
            """#
        #expect(try BuildHistory.decode(Data(json.utf8)).map(\.key) == ["dddddddddddd", "aaaaaaaaaaaa", "cccccccccccc", "bbbbbbbbbbbb"])
    }

    @Test("an unknown status is kept as printed, a record without an id is skipped, and a repeated id is listed once")
    func tolerant() throws {
        let json = #"""
            [{"id":"aaaaaaaaaaaa","status":"queued","tag":"a:1"},
             {"status":"succeeded","tag":"no-id"},
             {"id":"aaaaaaaaaaaa","status":"failed","tag":"a:2"}]
            """#
        let rows = try BuildHistory.decode(Data(json.utf8))
        #expect(rows.map(\.tag) == ["a:1"])
        #expect(rows[0].status == .other("queued") && rows[0].status.word == "queued" && !rows[0].status.finished)
    }

    @Test("ledger strings are untrusted: clipped, with control and format characters removed")
    func untrustedStrings() throws {
        let long = String(repeating: "x", count: 400)
        let json = #"{"id":"aaaaaaaaaaaa","tag":"evil‮:gpj\nsecond","context":"\#(long)","status":"failed","error":"line one\nline two\u0007"}"#
        let row = try #require(try BuildHistory.decode(Data("[\(json)]".utf8)).first)
        #expect(row.tag == "evil:gpj second")
        #expect(row.context.count == StatusDisplay.maxLength && row.context.hasSuffix("…"))
        #expect(row.error == "line one line two")
    }

    @Test("Go's RFC 3339 times parse, with or without a fraction, in UTC or at an offset")
    func timestamps() {
        #expect(BuildHistory.timestamp("2026-10-16T07:30:00Z") == Date(timeIntervalSince1970: 1_792_135_800))
        #expect(BuildHistory.timestamp("2026-10-16T09:30:00+02:00") == Date(timeIntervalSince1970: 1_792_135_800))
        #expect(BuildHistory.timestamp("2026-10-16T07:30:00.25Z") == Date(timeIntervalSince1970: 1_792_135_800.25))
        #expect(BuildHistory.timestamp("2026-10-16T07:30:00.123456789-05:00") != nil)
        for bad in ["", "2026-10-16", "2026-10-16T07:30:00", "2026-10-16T07:30:00.Z", "2026-10-16T07:30:00.1234567891Z", "yesterday"] {
            #expect(BuildHistory.timestamp(bad) == nil, "\(bad) parsed")
        }
    }

    @Test("durations and start times read the way the row shows them")
    func formatting() {
        #expect(BuildHistory.duration(nil) == "")
        #expect(BuildHistory.duration(0.9) == "0s")
        #expect(BuildHistory.duration(42) == "42s")
        #expect(BuildHistory.duration(185) == "3m 05s")
        #expect(BuildHistory.duration(3720) == "1h 02m")
        #expect(BuildHistory.started(nil) == "")
        let utc = TimeZone(identifier: "UTC")!
        #expect(BuildHistory.started(Self.at("2026-10-16T07:41:07.9Z"), timeZone: utc) == "2026-10-16 07:41:07")
    }

    @Test("the inspector shows the image, status, start, duration, context and record id")
    func inspector() throws {
        let rows = try BuildHistory.decode(fixture("build_ls_json.json"))
        let utc = TimeZone(identifier: "UTC")!
        let body = InspectorDetails.buildRecord(rows[2], timeZone: utc)
        #expect(body.kind == "Build" && body.title == "api:v2")
        let facts = Dictionary(uniqueKeysWithValues: body.facts.map { ($0.label, $0.value) })
        #expect(facts["Image"] == "api:v2")
        #expect(facts["Status"] == "Failed")
        #expect(facts["Started"] == "2026-10-16 07:12:03")
        #expect(facts["Duration"] == "3m 05s")
        #expect(facts["Context"] == "/Users/dev/api")
        #expect(facts["Record"] == "46d8d9a0a692")
        #expect(facts["Error"]?.hasPrefix("process") == true)
        let running = InspectorDetails.buildRecord(rows[0], now: Self.at("2026-10-16T07:41:17.492153Z"), timeZone: utc)
        #expect(running.facts.first { $0.label == "Duration" }?.value == "10s so far")
    }

    @Test("the tab's keys are the engine card and every row, and nothing before both reads")
    func keys() throws {
        let rows = try BuildHistory.decode(fixture("build_ls_json.json"))
        let engine = try BuildEngine.decode(fixture("kubectl_builder_ready.json"))
        #expect(InspectorDetails.keys(engine: nil, history: nil) == nil)
        #expect(InspectorDetails.keys(engine: engine, history: rows) == Set(rows.map(\.key) + [InspectorDetails.engineRow]))
        #expect(InspectorDetails.keys(engine: nil, history: rows) == Set(rows.map(\.key)))
        #expect(!rows.contains { $0.key == InspectorDetails.engineRow })
    }

    @Test("the history's argument list is fixed")
    func historyArgumentsGolden() {
        #expect(K3smCLI.buildHistoryArguments == ["build", "ls", "-o", "json"])
    }
}
