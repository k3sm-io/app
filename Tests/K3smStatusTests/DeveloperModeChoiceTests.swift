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

/// Developer mode on the screens: only a developer build (no Team ID pin)
/// takes it, the first-run checkbox turns the review into the checked root
/// step, the marker lets the guided panel, Repair and the app-carried update
/// run the root step, and nothing about it is ever stored.
@Suite("developer mode on the screens")
struct DeveloperModeChoiceTests {
    static let v017 = SemanticVersion("0.1.7")!
    static let v018 = SemanticVersion("0.1.8")!
    static let pseudo = "v0.0.0-0.20261031000000-abcdef012345"
    static let devBuild = AppVersion(shortVersion: "0.0.0", buildVersion: pseudo)
    static let release = AppVersion(shortVersion: "0.1.8", buildVersion: nil)
    static let cli = TerminalScript.Payload(quotedCLI: "'/Applications/k3sm.app/Contents/Resources/payload/k3sm'")

    @Test("the payload version: the release, else the build's pseudo-version only in developer mode with a payload k3sm")
    func developerModePayload() {
        let dev = SemanticVersion(Self.pseudo)!
        // A release always wins, pinned or not, in the mode or not.
        for pinned in [false, true] {
            for mode in [false, true] {
                #expect(DeveloperModeChoice.payload(release: Self.v018, build: Self.devBuild, pinned: pinned, developerMode: mode,
                                                    payloadCLI: true) == Self.v018)
            }
        }
        #expect(DeveloperModeChoice.payload(release: nil, build: Self.devBuild, pinned: false, developerMode: true, payloadCLI: true) == dev)
        #expect(DeveloperModeChoice.payload(release: nil, build: Self.devBuild, pinned: false, developerMode: false, payloadCLI: true) == nil)
        #expect(DeveloperModeChoice.payload(release: nil, build: Self.devBuild, pinned: false, developerMode: true, payloadCLI: false) == nil)
        // A pinned build never takes the pseudo-version.
        #expect(DeveloperModeChoice.payload(release: nil, build: Self.devBuild, pinned: true, developerMode: true, payloadCLI: true) == nil)
        // Nor does a build that is not a development build.
        #expect(DeveloperModeChoice.payload(release: nil, build: Self.release, pinned: false, developerMode: true, payloadCLI: true) == nil)
        #expect(DeveloperModeChoice.rootStep(pinned: true, developerMode: false))
        #expect(DeveloperModeChoice.rootStep(pinned: false, developerMode: true))
        #expect(!DeveloperModeChoice.rootStep(pinned: false, developerMode: false))
    }

    @Test("the first-run review: the checkbox on a developer build with a payload offers the root step", arguments: FirstRunPath.allCases)
    func developerModeFirstRunReview(_ path: FirstRunPath) {
        let server = path == .join ? "10.0.0.2:9345" : nil
        let argument = path == .join ? "10.0.0.2" : nil
        let dev = SemanticVersion(Self.pseudo)!
        func review(developerBuild: Bool, payload: SemanticVersion?, cli: TerminalScript.Payload?, mode: Bool) -> FirstRunReview {
            FirstRunFlow.review(path: path, server: server, serverArgument: argument, developerBuild: developerBuild,
                                payload: payload, payloadCLI: cli, developerMode: mode)
        }
        // Checked, with a payload k3sm: the checked root step, as a signed build offers it.
        let on = review(developerBuild: true, payload: dev, cli: Self.cli, mode: true)
        #expect(on.installButton == (path == .join ? "Join Cluster…" : "Start Cluster…"))
        #expect(on.terminalScript == nil && on.terminalButton == nil && on.terminalCommand == nil)
        #expect(on.lines.contains(FirstRunFlow.promptLine))
        #expect(!on.lines.contains { $0.contains("not Developer ID signed") })
        // Unchecked: Install in Terminal, exactly as before the checkbox existed.
        let off = review(developerBuild: true, payload: nil, cli: Self.cli, mode: false)
        #expect(off.installButton == nil)
        #expect(off.terminalButton == FirstRunFlow.terminalButton)
        #expect(off == FirstRunFlow.review(path: path, server: server, serverArgument: argument, developerBuild: true,
                                           payload: nil, payloadCLI: Self.cli))
        // Checked without a payload k3sm: still Terminal.
        #expect(review(developerBuild: true, payload: nil, cli: nil, mode: true).installButton == nil)
        // A pinned build ignores the checkbox.
        #expect(review(developerBuild: false, payload: Self.v018, cli: Self.cli, mode: true)
            == review(developerBuild: false, payload: Self.v018, cli: Self.cli, mode: false))
    }

    @Test("the guided panel runs the root step in developer mode and the Terminal command outside it")
    func developerModeGuided() throws {
        let on = try #require(GuidedSteps.plan(for: .installedStopped(nil),
                                               rootStep: DeveloperModeChoice.rootStep(pinned: false, developerMode: true),
                                               role: .server, payload: nil))
        #expect(on.primary == .start)
        #expect(on.terminalCommand == nil)
        let off = try #require(GuidedSteps.plan(for: .installedStopped(nil),
                                                rootStep: DeveloperModeChoice.rootStep(pinned: false, developerMode: false),
                                                role: .server, payload: nil))
        #expect(off.primary == nil)
        #expect(off.terminalCommand == GuidedSteps.startCommand)
        // A missing command is repaired from the build's own payload in developer mode.
        let dev = SemanticVersion(Self.pseudo)!
        let repair = try #require(GuidedSteps.plan(for: .cliMissing, rootStep: true, role: .server, payload: dev, payloadCLI: Self.cli))
        #expect(repair.primary == .repair)
    }

    @Test("the update plan: a developer build runs the app-carried update only in developer mode")
    func developerModeUpdatePlan() {
        func plan(developerBuild: Bool, mode: Bool) -> UpdatePlan {
            UpdatePlan.decide(UpdatePlanFacts(role: .agent, installed: Self.v017, payload: Self.v018,
                                              developerBuild: developerBuild, developerMode: mode))
        }
        #expect(plan(developerBuild: true, mode: false) == .blocked(.appDeveloperBuild(.payload(Self.v018))))
        #expect(plan(developerBuild: true, mode: true) == .payload(Self.v018))
        // A pinned build ignores it.
        #expect(plan(developerBuild: false, mode: true) == plan(developerBuild: false, mode: false))
        #expect(plan(developerBuild: false, mode: false) == .payload(Self.v018))
        // The version set's roll is bound to a Developer ID requirement, so it stays blocked.
        #expect(UpdatePath.bundled(tag: "v0.1.8").needsDeveloperID)
        #expect(!UpdatePath.payload(Self.v018).needsDeveloperID)
        #expect(!UpdatePath.managed(tag: "v0.1.8").needsDeveloperID)
    }

    @Test("developer mode is never a stored preference")
    func developerModeNeverPersisted() throws {
        for key in AppPreferences.Key.allCases {
            #expect(!key.rawValue.lowercased().contains("developer"), "\(key.rawValue)")
        }
        // Neither the preferences nor the store that publishes them name it.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for file in ["Sources/K3smStatus/AppPreferences.swift", "Sources/K3smApp/PreferencesStore.swift"] {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            #expect(!text.lowercased().contains("developer"), "\(file)")
        }
        // The first run's checkbox is off at every launch and lives only on
        // the model: no line that names it reads or writes the defaults.
        let model = try String(contentsOf: root.appendingPathComponent("Sources/K3smApp/AppModel.swift"), encoding: .utf8)
        #expect(model.contains("@Published var developerModeChecked = false {"))
        for line in model.split(separator: "\n") where line.contains("developerModeChecked") {
            #expect(!line.contains("UserDefaults") && !line.contains("defaults") && !line.contains("preferences")
                    && !line.contains("@AppStorage") && !line.contains("restor"), "\(line)")
        }
        // A stored developer-mode key changes nothing the preferences read.
        let suite = "io.k3sm.test.developer-mode.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let clean = AppPreferences(defaults: defaults)
        let before = AppPreferences.Key.allCases.map { clean.bool($0) }
        for key in ["developerMode", "pref.developerMode", "developerModeChecked"] {
            defaults.set(true, forKey: key)
        }
        #expect(AppPreferences.Key.allCases.map { AppPreferences(defaults: defaults).bool($0) } == before)
    }
}
