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

    static func read(_ path: String) throws -> String {
        try String(contentsOf: root.appending(path: path), encoding: .utf8)
    }

    @Test("the signing script no longer stamps a Team ID into Info.plist")
    func noPlistTrust() throws {
        let script = try Self.read("hack/release/sign-and-notarize.sh")
        #expect(!script.contains("K3smTeamID"))
        #expect(!script.contains("plutil -replace"))
    }

    @Test("the signing script refuses a binary not built for its team")
    func signingChecksCompiledPin() throws {
        let script = try Self.read("hack/release/sign-and-notarize.sh")
        #expect(script.contains(#""$HERE/../check-team-pin.sh" "$app/Contents/MacOS/k3sm-app" "$team""#))
        let build = try Self.read("hack/build-app.sh")
        #expect(build.contains(#"bash "$ROOT/hack/check-team-pin.sh" "$APP/Contents/MacOS/$EXE" "$TEAM_ID""#))
    }

    @Test("the pin checker looks for the marker the app compiles")
    func checkerMarker() throws {
        let checker = try Self.read("hack/check-team-pin.sh")
        #expect(checker.contains("marker='\(TeamIDPin.marker)'"))
    }

    @Test("build-app.sh writes the stamp the app compiles")
    func buildWritesStamp() throws {
        let script = try Self.read("hack/build-app.sh")
        #expect(script.contains(#"static let value = \""# + TeamIDPin.marker + #"$TEAM_ID\""#))
        #expect(script.contains("Sources/K3smInstall/TeamIDStamp.swift"))
    }
}
