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

import AppKit
import Foundation
import Testing

@testable import K3smStatus

@Suite("the appearance preference")
struct AppearancePreferenceTests {
    /// A fresh, empty defaults domain of its own, so no test reads the user's.
    private static func fresh() -> UserDefaults {
        let name = "io.k3sm.app.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("the appearance is System at first, a choice is kept, and reset puts System back")
    func roundTripAndDefault() {
        let defaults = Self.fresh()
        let prefs = AppPreferences(defaults: defaults)
        #expect(prefs.appearance == .system)
        #expect(defaults.object(forKey: AppPreferences.appearanceKey) == nil)
        for choice in AppAppearance.allCases {
            prefs.appearance = choice
            #expect(AppPreferences(defaults: defaults).appearance == choice)
            #expect(defaults.string(forKey: AppPreferences.appearanceKey) == choice.rawValue)
        }
        prefs.appearance = .dark
        prefs.reset()
        #expect(defaults.object(forKey: AppPreferences.appearanceKey) == nil)
        #expect(prefs.appearance == .system)
    }

    @Test("an unknown word or a value of another type reads as System")
    func unknownReadsAsSystem() {
        let defaults = Self.fresh()
        let prefs = AppPreferences(defaults: defaults)
        defaults.set("sepia", forKey: AppPreferences.appearanceKey)
        #expect(prefs.appearance == .system)
        defaults.set(true, forKey: AppPreferences.appearanceKey)
        #expect(prefs.appearance == .system)
        defaults.set(2, forKey: AppPreferences.appearanceKey)
        #expect(prefs.appearance == .system)
        #expect(AppAppearance.restore(from: nil) == .system)
        #expect(AppAppearance.restore(from: "Dark") == .system)
        #expect(AppAppearance.restore(from: "dark") == .dark)
    }

    @Test("System sets no appearance; Light and Dark name aqua and darkAqua")
    func mapsToAppearanceNames() {
        #expect(AppAppearance.system.appearanceName == nil)
        #expect(AppAppearance.light.appearanceName == NSAppearance.Name.aqua.rawValue)
        #expect(AppAppearance.dark.appearanceName == NSAppearance.Name.darkAqua.rawValue)
    }

    @Test("the General pane offers System, Light and Dark, in that order")
    func choicesListed() {
        #expect(AppAppearance.allCases == [.system, .light, .dark])
        #expect(AppAppearance.allCases.map(\.title) == ["System", "Light", "Dark"])
        #expect(Help.General.all.contains(Help.General.appearance))
    }
}
