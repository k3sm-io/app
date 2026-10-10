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

@testable import K3smInstall

@Suite("quoting")
struct QuotingTests {
    @Test("a quoted word reaches the shell unchanged", arguments: hostileStrings)
    func roundTrip(_ value: String) throws {
        let result = try shell(["-c", "printf '%s' " + ShellQuote.quote(value)])
        #expect(result.status == 0)
        #expect(result.output == value)
    }

    @Test("a quoted word is one argument", arguments: hostileStrings)
    func oneWord(_ value: String) throws {
        let result = try shell(["-c", "set -- " + ShellQuote.quote(value) + "; printf '%s' \"$#\""])
        #expect(result.output == "1")
    }

    struct LiteralCase: Sendable, CustomTestStringConvertible {
        let input: String
        let want: String
        var testDescription: String { input.debugDescription }
    }

    static let literalCases: [LiteralCase] = [
        LiteralCase(input: "plain", want: #""plain""#),
        LiteralCase(input: #"say "hi""#, want: #""say \"hi\"""#),
        LiteralCase(input: #"back\slash"#, want: #""back\\slash""#),
        LiteralCase(input: "a\nb\rc\td", want: #""a\nb\rc\td""#),
        LiteralCase(input: #"" & (do shell script "id") & ""#, want: #""\" & (do shell script \"id\") & \"""#),
        LiteralCase(input: "it's", want: #""it's""#),
    ]

    @Test("AppleScript literal", arguments: literalCases)
    func literal(_ c: LiteralCase) {
        #expect(AppleScriptText.literal(c.input) == c.want)
    }
}

@Suite("team ID and designated requirement")
struct TeamIDTests {
    @Test("valid Team IDs", arguments: ["ABCDE12345", "0123456789", "ZZZZZZZZZZ"])
    func valid(_ s: String) {
        #expect(TeamID(s)?.value == s)
    }

    @Test("invalid Team IDs", arguments: [
        "", "abcde12345", "ABCDE1234", "ABCDE123456", "ABCDE 1234", "ABCDE1234\"",
        "ABCDE1234\\", "ABCDE-1234", "ÄBCDE12345", "ABCDE1234\n",
    ])
    func invalid(_ s: String) {
        #expect(TeamID(s) == nil)
    }

    @Test("the requirement pins Developer ID Application and the team")
    func requirement() throws {
        let team = try #require(TeamID("ABCDE12345"))
        #expect(DesignatedRequirement.developerID(teamID: team) ==
            #"anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = "ABCDE12345""#)
    }
}
