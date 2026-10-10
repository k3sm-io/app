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

@Suite("versions")
struct VersionTests {
    struct ParseCase: Sendable, CustomTestStringConvertible {
        let text: String
        let want: String?
        var testDescription: String { "parse \(text.debugDescription)" }
    }

    static let parseCases: [ParseCase] = [
        ParseCase(text: "v0.1.7", want: "0.1.7"),
        ParseCase(text: "0.1.7", want: "0.1.7"),
        ParseCase(text: "v1.2.3-rc.1", want: "1.2.3-rc.1"),
        ParseCase(text: "1.2.3+build.5", want: "1.2.3"),
        ParseCase(text: "1.2.3-alpha+sha.0123abc", want: "1.2.3-alpha"),
        ParseCase(text: "v0.0.0-20261001120000-0123456789ab", want: "0.0.0-20261001120000-0123456789ab"),
        ParseCase(text: "dev", want: nil),
        ParseCase(text: "", want: nil),
        ParseCase(text: "v", want: nil),
        ParseCase(text: "1.2", want: nil),
        ParseCase(text: "1.2.3.4", want: nil),
        ParseCase(text: "01.2.3", want: nil),
        ParseCase(text: "1.2.3-01", want: nil),
        ParseCase(text: "1.2.3-", want: nil),
        ParseCase(text: "1.2.3+", want: nil),
        ParseCase(text: "1.2.3-a..b", want: nil),
        ParseCase(text: "vv1.2.3", want: nil),
        ParseCase(text: " 1.2.3", want: nil),
        ParseCase(text: "1.2.3; rm -rf /", want: nil),
        ParseCase(text: "1.2.٣", want: nil),
        ParseCase(text: "1234567890.0.0", want: nil),
    ]

    @Test("parse", arguments: parseCases)
    func parse(_ c: ParseCase) {
        #expect(SemanticVersion(c.text)?.description == c.want)
    }

    struct OrderCase: Sendable, CustomTestStringConvertible {
        let lower: String
        let higher: String
        var testDescription: String { "\(lower) < \(higher)" }
    }

    // The semver specification's own precedence example, plus the core fields.
    static let orderCases: [OrderCase] = [
        OrderCase(lower: "1.0.0", higher: "2.0.0"),
        OrderCase(lower: "2.0.0", higher: "2.1.0"),
        OrderCase(lower: "2.1.0", higher: "2.1.1"),
        OrderCase(lower: "0.9.9", higher: "0.10.0"),
        OrderCase(lower: "1.0.0-alpha", higher: "1.0.0-alpha.1"),
        OrderCase(lower: "1.0.0-alpha.1", higher: "1.0.0-alpha.beta"),
        OrderCase(lower: "1.0.0-alpha.beta", higher: "1.0.0-beta"),
        OrderCase(lower: "1.0.0-beta", higher: "1.0.0-beta.2"),
        OrderCase(lower: "1.0.0-beta.2", higher: "1.0.0-beta.11"),
        OrderCase(lower: "1.0.0-beta.11", higher: "1.0.0-rc.1"),
        OrderCase(lower: "1.0.0-rc.1", higher: "1.0.0"),
    ]

    @Test("precedence", arguments: orderCases)
    func order(_ c: OrderCase) throws {
        let lower = try #require(SemanticVersion(c.lower))
        let higher = try #require(SemanticVersion(c.higher))
        #expect(lower < higher)
        #expect(!(higher < lower))
        #expect(lower != higher)
    }

    @Test("build metadata does not change precedence")
    func buildIgnored() throws {
        let a = try #require(SemanticVersion("1.2.3+a"))
        let b = try #require(SemanticVersion("v1.2.3+b"))
        #expect(a == b)
        #expect(!(a < b) && !(b < a))
    }

    struct RelationCase: Sendable, CustomTestStringConvertible {
        let payload: String
        let installed: String
        let want: PayloadRelation
        var testDescription: String { "payload \(payload) vs installed \(installed)" }
    }

    static let relationCases: [RelationCase] = [
        RelationCase(payload: "0.1.8", installed: "0.1.7", want: .newer),
        RelationCase(payload: "0.1.7", installed: "v0.1.7", want: .same),
        RelationCase(payload: "0.1.6", installed: "0.1.7", want: .older),
        RelationCase(payload: "0.2.0", installed: "0.2.0-rc.3", want: .newer),
        RelationCase(payload: "0.2.0-rc.3", installed: "0.2.0", want: .older),
        RelationCase(payload: "1.0.0", installed: "0.99.99", want: .newer),
    ]

    @Test("payload relation", arguments: relationCases)
    func relation(_ c: RelationCase) throws {
        let payload = try #require(SemanticVersion(c.payload))
        let installed = try #require(SemanticVersion(c.installed))
        #expect(PayloadRelation(payload: payload, installed: installed) == c.want)
    }

    struct CommandCase: Sendable, CustomTestStringConvertible {
        let name: String
        let output: String
        let want: String?
        var testDescription: String { name }
    }

    static let commandCases: [CommandCase] = [
        CommandCase(name: "release build", output: "k3sm v0.1.7\n  commit:        0123abc\n  go:            go1.26.1\n", want: "0.1.7"),
        CommandCase(name: "single line", output: "k3sm v0.2.0-rc.1", want: "0.2.0-rc.1"),
        CommandCase(name: "developer build", output: "k3sm dev\n  go:            go1.26.1\n", want: nil),
        CommandCase(name: "wrong program", output: "kubectl v1.36.2\n", want: nil),
        CommandCase(name: "extra words", output: "k3sm v0.1.7 extra\n", want: nil),
        CommandCase(name: "empty", output: "", want: nil),
    ]

    @Test("version command output", arguments: commandCases)
    func command(_ c: CommandCase) {
        #expect(SemanticVersion.fromVersionCommand(c.output)?.description == c.want)
    }
}
