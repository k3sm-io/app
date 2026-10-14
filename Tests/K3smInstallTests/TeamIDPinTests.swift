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

@Suite("compiled Team ID pin")
struct TeamIDPinTests {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test("a developer build pins no team")
    func developerDefault() {
        #expect(TeamIDStamp.value == TeamIDPin.marker)
        #expect(TeamIDPin.teamID == nil)
    }

    @Test("stamps", arguments: [
        ("k3sm-team-id-pin:ABCDE12345", "ABCDE12345"),
        ("k3sm-team-id-pin:", nil),
        ("k3sm-team-id-pin:abcde12345", nil),
        ("k3sm-team-id-pin:ABCDE123456", nil),
        ("ABCDE12345", nil),
        ("x-k3sm-team-id-pin:ABCDE12345", nil),
        ("", nil),
    ] as [(String, String?)])
    func parse(_ stamp: String, _ want: String?) {
        #expect(TeamIDPin.parse(stamp)?.value == want)
    }

    @Test("no app source reads the Team ID from Info.plist")
    func noPlistTrustSource() throws {
        let sources = Self.root.appending(path: "Sources")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var swift = 0
        for case let url as URL in files where url.pathExtension == "swift" {
            swift += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(!text.contains("K3smTeamID"), "\(url.lastPathComponent) names K3smTeamID")
            #expect(!text.contains("infoPlistKey"), "\(url.lastPathComponent) names infoPlistKey")
        }
        #expect(swift > 10)
        let plist = try String(contentsOf: Self.root.appending(path: "Resources/Info.plist"), encoding: .utf8)
        #expect(!plist.contains("TeamID"))
    }
}
