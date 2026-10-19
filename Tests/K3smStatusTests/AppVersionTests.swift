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

    /// A development build keeps its short version at `0.0.0`: that is no
    /// release, so the app names its pseudo-version and every path that
    /// needs the payload's release takes its "no payload" branch.
    @Test func developmentBuildCarriesNoRelease() throws {
        #expect(AppVersion.payloadRelease(shortVersion: "0.0.0") == nil)
        #expect(AppVersion.payloadRelease(shortVersion: "0.0.0-rc.1") == nil)
        #expect(AppVersion.payloadRelease(shortVersion: "1.2.3") == SemanticVersion("1.2.3"))
        #expect(AppVersion.payloadRelease(shortVersion: "0.1.0") == SemanticVersion("0.1.0"))
        #expect(AppVersion.payloadRelease(shortVersion: "dev") == nil)
        #expect(AppVersion.payloadRelease(shortVersion: nil) == nil)

        let pseudo = "v0.0.0-0.20261017002053-910af952ea03"
        let development = AppVersion(shortVersion: "0.0.0", buildVersion: pseudo)
        let payload = AppVersion.payloadRelease(shortVersion: "0.0.0")
        let installed = try #require(SemanticVersion("0.1.8"))

        // The popover's version line names the app's build, never 0.0.0.
        let line = development.versionLine(installed: installed, payload: payload)
        #expect(line == "Installed: 0.1.8 · k3sm.app " + pseudo)
        #expect(!line.contains("carries"))
        #expect(!line.replacingOccurrences(of: pseudo, with: "").contains("0.0.0"))
        #expect(development.versionLine(installed: nil, payload: payload) == "Installed: unknown · k3sm.app " + pseudo)
        // A release build keeps the payload sentences.
        let release = AppVersion(shortVersion: "0.1.9", buildVersion: nil)
        let carried = AppVersion.payloadRelease(shortVersion: "0.1.9")
        #expect(release.versionLine(installed: installed, payload: carried) == "Installed: 0.1.8 · this app carries 0.1.9, a newer release")
        #expect(release.versionLine(installed: carried, payload: carried) == "Installed: 0.1.9 · up to date with this app")
        #expect(release.versionLine(installed: nil, payload: carried) == "Installed: unknown · this app carries 0.1.9")

        // The guided plan takes the Terminal fallback, unpinned, signed or not.
        for rootStep in [false, true] {
            let plan = try #require(GuidedSteps.plan(for: .cliMissing, rootStep: rootStep, role: .server, payload: payload))
            #expect(plan.primary == nil)
            #expect(plan.terminalCommand == GuidedSteps.installScriptCommand(version: nil))
            #expect(!(plan.terminalCommand ?? "").contains("0.0.0"))
            #expect(!plan.steps.joined().contains("0.0.0"))
        }
        let partly = try #require(GuidedSteps.plan(for: .partlyRunning(down: [HealthClassifier.netdLabel]),
                                                   rootStep: true, role: .server, payload: payload))
        #expect(partly.secondary == nil)

        // The update plan offers no payload install, and no downgrade block
        // naming 0.0.0 either.
        for role in [NodeRole.server, .agent] {
            let plan = UpdatePlan.decide(UpdatePlanFacts(role: role, installed: installed, payload: payload, workers: 0))
            #expect(plan == .none)
        }
    }

    /// An rc build and the final build of one release carry the same short
    /// version (`vX.Y.Z-rc.N` builds `X.Y.Z`), so the app reads the exact
    /// tag `build-app.sh --payload-tag` stamps as `K3smPayloadTag`: the rc
    /// ranks below the final, and an app built before the key falls back to
    /// the short version.
    @Test func payloadTagDistinguishesReleaseCandidate() throws {
        #expect(AppVersion.payloadTagKey == "K3smPayloadTag")
        let rcInfo: [String: Any] = ["CFBundleShortVersionString": "0.2.0", "K3smPayloadTag": "v0.2.0-rc.1"]
        let finalInfo: [String: Any] = ["CFBundleShortVersionString": "0.2.0", "K3smPayloadTag": "v0.2.0"]
        let rc = try #require(AppVersion.payloadRelease(info: rcInfo))
        let final = try #require(AppVersion.payloadRelease(info: finalInfo))
        #expect(rc != final)
        #expect(rc < final)
        #expect(rc.description == "0.2.0-rc.1")
        #expect(final.description == "0.2.0")
        #expect(AppVersion.payloadTag(info: rcInfo) == "v0.2.0-rc.1")
        #expect(AppVersion.payloadTag(info: finalInfo) == "v0.2.0")
        #expect(PayloadRelation(payload: rc, installed: final) == .older)
        let app = AppVersion(info: rcInfo)
        #expect(app.versionLine(installed: final, payload: rc)
            == "Installed: 0.2.0 · this app carries an older release, 0.2.0-rc.1")

        // An app built before the key: the short version, for one release.
        let legacy: [String: Any] = ["CFBundleShortVersionString": "0.2.0"]
        #expect(AppVersion.payloadTag(info: legacy) == nil)
        #expect(AppVersion.payloadRelease(info: legacy) == SemanticVersion("0.2.0"))
        #expect(AppVersion.payloadRelease(info: ["CFBundleShortVersionString": "0.0.0"]) == nil)
        #expect(AppVersion.payloadRelease(info: nil) == nil)

        // A key that is present but not a release tag of this bundle's
        // version is no release at all, never the short-version fallback.
        let bad: [Any] = [
            "0.2.0", "v0.2.0+build", "v0.2.1", "v0.1.0", "v0.2.0-rc.01", "v0.2.0-beta.1", "v0.2.0-rc",
            " v0.2.0", "v0.2.0\n", "V0.2.0", "v00.2.0", "", "v0.2.0-rc.1-rc.2", 3, ["v0.2.0"],
            "v0.2.0-rc.12345", "v0.2.0-rc.", "v0.2.0-rc.+1",
        ]
        for value in bad {
            let info: [String: Any] = ["CFBundleShortVersionString": "0.2.0", "K3smPayloadTag": value]
            #expect(AppVersion.payloadTag(info: info) == nil, "\(value)")
            #expect(AppVersion.payloadRelease(info: info) == nil, "\(value)")
        }
        // The digit limits of the shell grammar: nine for X, Y and Z, four for N.
        for long in ["v9999999999999.0.0", "v0.9999999999.0", "v0.0.1234567890"] {
            #expect(AppVersion.releaseTagVersion(long) == nil, "\(long)")
        }
        #expect(AppVersion.releaseTagVersion("v999999999.999999999.999999999-rc.9999") != nil)
        #expect(AppVersion.releaseTagVersion("v0.2.0-rc.12345") == nil)

        // The rc number orders numerically, and every rc ranks below its final.
        let rc2 = try #require(AppVersion.payloadRelease(info: ["CFBundleShortVersionString": "0.2.0", "K3smPayloadTag": "v0.2.0-rc.2"]))
        let rc10 = try #require(AppVersion.payloadRelease(info: ["CFBundleShortVersionString": "0.2.0", "K3smPayloadTag": "v0.2.0-rc.10"]))
        #expect(rc2 < rc10)
        #expect(rc10 < final)
        #expect(rc2 < final)
        #expect(!(rc10 < rc2))

        // A tagged development build carries no release either.
        let dev: [String: Any] = ["CFBundleShortVersionString": "0.0.0", "K3smPayloadTag": "v0.0.0"]
        #expect(AppVersion.payloadRelease(info: dev) == nil)
    }
}
