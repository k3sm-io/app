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

@Suite("app version")
struct AppVersionTests {
    struct DisplayCase: Sendable, CustomTestStringConvertible {
        let name: String
        let short: String?
        let build: String?
        let text: String?
        let development: Bool
        var testDescription: String { name }
    }

    static let displayCases: [DisplayCase] = [
        DisplayCase(name: "development build", short: "0.0.0",
                    build: "v0.0.0-0.20261016221530-2eda966a1b2c",
                    text: "v0.0.0-0.20261016221530-2eda966a1b2c", development: true),
        DisplayCase(name: "development build from a modified tree", short: "0.0.0",
                    build: "v0.1.9-0.20261016221530-2eda966a1b2c+dirty",
                    text: "v0.1.9-0.20261016221530-2eda966a1b2c+dirty", development: true),
        DisplayCase(name: "development build outside git", short: "0.0.0",
                    build: "v0.0.0-unknown", text: "v0.0.0-unknown", development: true),
        DisplayCase(name: "release build", short: "1.2.3", build: nil, text: "1.2.3", development: false),
        DisplayCase(name: "unstamped developer build", short: "0.0.0", build: nil, text: "0.0.0", development: false),
        DisplayCase(name: "build key without its v", short: "0.0.0",
                    build: "0.0.0-0.20261016221530-2eda966a1b2c", text: "0.0.0", development: false),
        DisplayCase(name: "build key that is not a version", short: "1.2.3",
                    build: "v1.2.3 (evil)", text: "1.2.3", development: false),
        DisplayCase(name: "short version that is not a version", short: "dev", build: nil, text: nil, development: false),
        DisplayCase(name: "nothing stamped (swift run)", short: nil, build: nil, text: nil, development: false),
    ]

    @Test(arguments: displayCases)
    func devBuildVersionDisplay(_ c: DisplayCase) {
        let version = AppVersion(shortVersion: c.short, buildVersion: c.build)
        #expect(version.text == c.text)
        #expect(version.isDevelopment == c.development)
        #expect(version.title == "k3sm.app " + (c.text.map { $0.hasPrefix("v") ? $0 : "v" + $0 } ?? "unknown"))
        if c.development {
            #expect(version.aboutPanel == AppVersion.AboutPanel(applicationVersion: c.text!, version: ""))
        } else {
            #expect(version.aboutPanel == nil)
        }
    }

    @Test func devBuildVersionDisplayClipsLongStamps() {
        let long = "v0.0.0-" + String(repeating: "a", count: 400)
        let version = AppVersion(shortVersion: "0.0.0", buildVersion: long)
        #expect(version.text!.count <= StatusDisplay.maxLength)
    }

    @Test func devBuildVersionDisplayReadsTheBundleKeys() {
        let version = AppVersion(info: [
            "CFBundleShortVersionString": "0.0.0",
            AppVersion.buildVersionKey: "v0.0.0-0.20261016221530-2eda966a1b2c",
        ])
        #expect(version.text == "v0.0.0-0.20261016221530-2eda966a1b2c")
        #expect(AppVersion(info: ["CFBundleShortVersionString": 3]).text == nil)
        #expect(AppVersion.buildVersionKey == "K3smBuildVersion")
    }
}
