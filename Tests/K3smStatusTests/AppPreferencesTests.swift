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

@Suite("the app's preferences")
struct AppPreferencesTests {
    /// A fresh, empty defaults domain of its own, so no test reads the user's.
    private static func fresh() -> UserDefaults {
        let name = "io.k3sm.app.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("every preference has its default, a change is kept, and reset puts the defaults back")
    func preferencesDefaultsAndReset() {
        let defaults = Self.fresh()
        let prefs = AppPreferences(defaults: defaults)
        #expect(prefs.notifyStoppedAtLogin == true)
        #expect(prefs.openWindowAtLogin == false)
        #expect(prefs.dockAnimation == true)
        #expect(prefs.allChecksOpen == false)
        #expect(prefs.settingsPane == .general)
        for key in AppPreferences.Key.allCases {
            #expect(prefs.bool(key) == key.defaultValue)
            #expect(defaults.object(forKey: key.rawValue) == nil)
        }

        prefs.notifyStoppedAtLogin = false
        prefs.openWindowAtLogin = true
        prefs.dockAnimation = false
        prefs.allChecksOpen = true
        prefs.settingsPane = .advanced
        #expect(AppPreferences(defaults: defaults).allChecksOpen == true)
        #expect(AppPreferences(defaults: defaults).settingsPane == .advanced)
        #expect(AppPreferences(defaults: defaults).notifyStoppedAtLogin == false)
        #expect(AppPreferences(defaults: defaults).openWindowAtLogin == true)
        #expect(AppPreferences(defaults: defaults).dockAnimation == false)

        // A value of the wrong type reads as the default, never as a failure.
        defaults.set("yes", forKey: AppPreferences.Key.dockAnimation.rawValue)
        #expect(prefs.dockAnimation == true)
        defaults.set("profiles", forKey: AppPreferences.settingsPaneKey)
        #expect(prefs.settingsPane == .general)

        // Reset clears the preferences and leaves the remembered layout alone.
        defaults.set(400.0, forKey: PanelLayout.widthKey)
        defaults.set("Images", forKey: ConsoleTabs.sectionKey)
        prefs.reset()
        for key in AppPreferences.Key.allCases {
            #expect(defaults.object(forKey: key.rawValue) == nil)
            #expect(prefs.bool(key) == key.defaultValue)
        }
        #expect(defaults.object(forKey: AppPreferences.settingsPaneKey) == nil)
        #expect(defaults.double(forKey: PanelLayout.widthKey) == 400)
        #expect(defaults.string(forKey: ConsoleTabs.sectionKey) == "Images")
    }

    @Test("reset window layout clears the layout keys only")
    func resetLayoutClearsLayoutOnly() {
        let defaults = Self.fresh()
        let prefs = AppPreferences(defaults: defaults)
        #expect(Set(AppPreferences.layoutKeys) == [
            "consolePanelMode", "consoleInspectorShown", "consolePanelWidth", "consolePanelCollapsed",
            "consoleInspectorWidth", "consoleLogPaneHeight",
            "columnWidths.pods", "columnWidths.events", "columnWidths.nodes", "columnWidths.images",
            "columnWidths.builds", "columnWidths.services", "columnWidths.storage", "columnWidths.models",
        ])
        for key in AppPreferences.layoutKeys { defaults.set(true, forKey: key) }
        defaults.set("Images", forKey: ConsoleTabs.sectionKey)
        defaults.set("x", forKey: ConsoleTabs.queryKey(.images))
        prefs.dockAnimation = false
        prefs.resetLayout()
        for key in AppPreferences.layoutKeys { #expect(defaults.object(forKey: key) == nil) }
        #expect(defaults.string(forKey: ConsoleTabs.sectionKey) == "Images")
        #expect(defaults.string(forKey: ConsoleTabs.queryKey(.images)) == "x")
        #expect(prefs.dockAnimation == false)
    }

    /// loginLaunch, openWindowAtLogin, notifyStoppedAtLogin, opens the window, checks the notice.
    @Test("a launch opens the window and checks the stopped notice as the preferences say", arguments: [
        (false, false, true, true, false),
        (false, true, false, true, false),
        (true, false, true, false, true),
        (true, true, true, true, true),
        (true, false, false, false, false),
    ] as [(Bool, Bool, Bool, Bool, Bool)])
    func launchFollowsPreferences(_ loginLaunch: Bool, _ openAtLogin: Bool, _ notify: Bool, _ opens: Bool, _ checks: Bool) {
        let prefs = AppPreferences(defaults: Self.fresh())
        prefs.openWindowAtLogin = openAtLogin
        prefs.notifyStoppedAtLogin = notify
        #expect(prefs.opensWindow(loginLaunch: loginLaunch) == opens)
        #expect(prefs.checksStoppedNotice(loginLaunch: loginLaunch) == checks)
    }

    @Test("the Dock animation is off and disabled, with a note, under Reduce Motion")
    func dockAnimationUnderReduceMotion() {
        let on = DockAnimationDisplay.decide(preference: true, reduceMotion: false)
        #expect(on == DockAnimationDisplay(isOn: true, isEnabled: true, note: nil))
        let off = DockAnimationDisplay.decide(preference: false, reduceMotion: false)
        #expect(off == DockAnimationDisplay(isOn: false, isEnabled: true, note: nil))
        for preference in [true, false] {
            let reduced = DockAnimationDisplay.decide(preference: preference, reduceMotion: true)
            #expect(!reduced.isOn)
            #expect(!reduced.isEnabled)
            #expect(reduced.note?.contains("Reduce Motion") == true)
        }
    }

    @Test("the settings panes are data, and only built panes are shown")
    func settingsPanes() {
        #expect(SettingsPane.shown == [.general, .cluster, .network, .storage, .updates, .advanced])
        #expect(SettingsPane.shown.map(\.title) == ["General", "Cluster", "Network", "Storage", "Updates", "Advanced"])
        #expect(SettingsPane.shown.map(\.symbol) == ["gearshape", "server.rack", "network", "externaldrive", "arrow.triangle.2.circlepath",
                                                    "wrench.and.screwdriver"])
        #expect(SettingsPane.restore(from: "general") == .general)
        #expect(SettingsPane.restore(from: "network") == .network)
        #expect(SettingsPane.restore(from: "advanced") == .advanced)
        #expect(SettingsPane.restore(from: nil) == .general)
        #expect(SettingsPane.restore(from: 3) == .general)
        // Settings keeps its own frame, apart from the console's.
        #expect(AppPreferences.settingsFrameKey != WindowFrame.key)
    }

    /// status, from /Applications, on, enabled, offers Login Items, has a note.
    @Test("the login item control follows the system's status", arguments: [
        (LoginItemStatus.enabled, true, true, true, false, false),
        (.requiresApproval, true, true, true, true, true),
        (.notRegistered, true, false, true, false, false),
        (.notRegistered, false, false, false, false, true),
        (.notFound, true, false, true, false, true),
        (.notFound, false, false, false, false, true),
        (.enabled, false, true, true, false, false),
    ] as [(LoginItemStatus, Bool, Bool, Bool, Bool, Bool)])
    func loginItemDisplay(_ status: LoginItemStatus, _ inApplications: Bool, _ on: Bool, _ enabled: Bool,
                          _ offers: Bool, _ noted: Bool) {
        let d = LoginItemDisplay.decide(status: status, inApplications: inApplications, error: nil)
        #expect(d.isOn == on)
        #expect(d.isEnabled == enabled)
        #expect(d.offersLoginItems == offers)
        #expect((d.note != nil) == noted)
    }

    @Test("a failed change shows the system's reason, cleaned")
    func loginItemError() {
        let d = LoginItemDisplay.decide(status: .notRegistered, inApplications: true, error: "Operation not\u{1B}[31m permitted\n")
        #expect(d.note?.hasPrefix("macOS did not change the login item: ") == true)
        #expect(d.note?.contains("\u{1B}") == false)
        #expect(d.note?.contains("\n") == false)
    }

    @Test("the app is a regular app while any of its windows is open")
    func windowPresence() {
        var presence = WindowPresence()
        #expect(!presence.regular)
        let steps = [
            presence.opened(.console), presence.opened(.settings),
            presence.closed(.console), presence.closed(.settings), presence.closed(.settings),
        ]
        #expect(steps == [true, true, true, false, false])
        #expect(!presence.regular)
    }
}
