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

/// The source scan behind the channel's root step: one caller, and the pin.
@Suite("update channel root path")
struct UpdateChannelPathTests {
    @Test("the app reaches the script one way, with the pinned Team ID")
    func onePath() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appending(path: "Sources")
        var texts: [String: String] = [:]
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let file as URL in files where file.pathExtension == "swift" {
            texts[file.lastPathComponent] = try String(contentsOf: file, encoding: .utf8)
        }
        func holders(_ word: String) -> Set<String> { Set(texts.filter { $0.value.contains(word) }.keys) }
        #expect(holders("renderUpdateChannel(") == ["Lifecycle.swift", "UpdateChannelStep.swift"])
        #expect(holders("UpdateChannelDriver(") == ["AppModel.swift"])
        #expect(holders("K3smCLI.updateChannelArguments(") == ["Lifecycle.swift"])

        // The app builds the driver from the pin itself, never from the policy
        // developer mode can set.
        let model = try #require(texts["AppModel.swift"])
        let start = try #require(model.range(of: "func setUpdateChannel(_ channel: UpdateChannel) {"))
        let rest = model[start.upperBound...]
        let body = rest[..<(rest.range(of: "\n    }\n")?.lowerBound ?? rest.endIndex)]
        #expect(body.contains(", let teamID else { return }"))
        #expect(body.contains("teamID: teamID,"))
        #expect(!body.contains("trustPolicy") && !body.contains("TrustPolicy"))
    }
}
