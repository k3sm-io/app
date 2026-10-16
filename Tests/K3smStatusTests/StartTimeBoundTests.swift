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

@Suite("start time bound")
struct StartTimeBoundTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let exit: Int32?
        let stdout: String
        let want: Int?
        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(name: "a printed bound", exit: 0, stdout: "420\n", want: 420),
        Case(name: "surrounding whitespace", exit: 0, stdout: "  75 \n", want: 75),
        Case(name: "the largest accepted", exit: 0, stdout: "3600", want: 3600),
        Case(name: "no flag: usage exit", exit: 2, stdout: "", want: nil),
        Case(name: "a number with a non-zero exit", exit: 1, stdout: "420\n", want: nil),
        Case(name: "the CLI did not answer", exit: nil, stdout: "", want: nil),
        Case(name: "empty output", exit: 0, stdout: "", want: nil),
        Case(name: "a duration word", exit: 0, stdout: "7m0s\n", want: nil),
        Case(name: "a fraction", exit: 0, stdout: "420.5\n", want: nil),
        Case(name: "a sign", exit: 0, stdout: "+420\n", want: nil),
        Case(name: "negative", exit: 0, stdout: "-5\n", want: nil),
        Case(name: "zero", exit: 0, stdout: "0\n", want: nil),
        Case(name: "past the cap", exit: 0, stdout: "3601\n", want: nil),
        Case(name: "an overflowing number", exit: 0, stdout: "99999999999999999999999\n", want: nil),
        Case(name: "two lines", exit: 0, stdout: "420\n420\n", want: nil),
        Case(name: "non-ASCII digits", exit: 0, stdout: "٤٢٠\n", want: nil),
    ]

    @Test("parse: a printed whole number in range, else the fallback with a reason", arguments: cases)
    func parse(_ c: Case) {
        let reading = StartTimeBound.parse(exitStatus: c.exit, stdout: Data(c.stdout.utf8))
        if let want = c.want {
            #expect(reading == .printed(want))
            #expect(reading.seconds == want)
        } else {
            guard case .fallback(let reason) = reading else {
                Issue.record("want a fallback, got \(reading)"); return
            }
            #expect(!reason.isEmpty)
            #expect(reading.seconds == StartTimeBound.fallbackSeconds)
        }
    }

    @Test("the fallback is at least ten minutes and the margin is 30 s")
    func constants() {
        #expect(StartTimeBound.fallbackSeconds >= 600)
        #expect(StartTimeBound.marginSeconds == 30)
    }

    @Test("the timeout is the bound plus the margin")
    func timeout() {
        #expect(StartTimeBound.Reading.printed(420).timeout == .seconds(450))
        #expect(StartTimeBound.Reading.fallback(reason: "x").timeout == .seconds(StartTimeBound.fallbackSeconds + 30))
    }

    @Test("the bound is read with a fixed argument list")
    func arguments() {
        #expect(K3smCLI.startTimeBoundArguments == ["start", "--print-time-bound"])
    }

    @Test("a reason never carries the CLI's output")
    func reasonIsOurs() {
        let reading = StartTimeBound.parse(exitStatus: 0, stdout: Data("rm -rf /\n".utf8))
        guard case .fallback(let reason) = reading else { Issue.record("want a fallback"); return }
        #expect(!reason.contains("rm -rf"))
    }
}
