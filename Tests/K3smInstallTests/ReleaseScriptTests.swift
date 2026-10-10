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

@testable import K3smInstall

@Suite("release script drift")
struct ReleaseScriptTests {
    /// The repo root, found from this file's own path.
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test("the signing script pins the same designated requirement")
    func requirementMatches() throws {
        let script = try String(contentsOf: Self.root.appending(path: "hack/release/sign-and-notarize.sh"), encoding: .utf8)
        let team = try #require(TeamID("ABCDE12345"))
        let swift = DesignatedRequirement.developerID(teamID: team)
        let shell = swift.replacingOccurrences(of: #""ABCDE12345""#, with: #"\"$team\""#)
        #expect(script.contains("requirement=\"\(shell)\""))
    }

    @Test("the signing script stamps the key the app reads")
    func teamIDKey() throws {
        let script = try String(contentsOf: Self.root.appending(path: "hack/release/sign-and-notarize.sh"), encoding: .utf8)
        #expect(script.contains("plutil -replace \(TeamID.infoPlistKey) -string \"$team\""))
    }
}
