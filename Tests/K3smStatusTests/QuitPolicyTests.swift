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

@Suite("quit policy")
struct QuitPolicyTests {
    /// A fresh, empty defaults domain of its own, so no test reads the user's.
    private static func fresh() -> UserDefaults {
        let name = "io.k3sm.app.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("stop on quit is off by default, kept when set, and reset turns it off")
    func defaultsOff() {
        let defaults = Self.fresh()
        let prefs = AppPreferences(defaults: defaults)
        #expect(AppPreferences.Key.stopOnQuit.defaultValue == false)
        #expect(prefs.stopOnQuit == false)
        prefs.stopOnQuit = true
        #expect(AppPreferences(defaults: defaults).stopOnQuit == true)
        prefs.reset()
        #expect(prefs.stopOnQuit == false)
        #expect(defaults.object(forKey: AppPreferences.Key.stopOnQuit.rawValue) == nil)
    }

    @Test("off: Quit quits whatever k3sm is doing", arguments: [
        LifecycleState.running, .stopped, .notInstalled, .unreadable,
    ])
    func offQuits(_ state: LifecycleState) {
        #expect(QuitPolicy.decide(stopOnQuit: false, state: state) == .quit)
    }

    @Test("on and running: Quit stops k3sm, then quits")
    func onRunningStops() {
        #expect(QuitPolicy.decide(stopOnQuit: true, state: .running) == .stopThenQuit)
    }

    @Test("on and already stopped: Quit quits", arguments: [LifecycleState.stopped, .notInstalled])
    func onStoppedQuits(_ state: LifecycleState) {
        #expect(QuitPolicy.decide(stopOnQuit: true, state: state) == .quit)
    }

    @Test("on and the status unreadable: the app stays open and says why")
    func onUnreadableStays() {
        guard case .stay(let why) = QuitPolicy.decide(stopOnQuit: true, state: .unreadable) else {
            Issue.record("an unreadable status did not keep the app open")
            return
        }
        #expect(why.contains("did not stop k3sm"))
        #expect(why.contains(QuitPolicy.toggleLabel))
    }

    @Test("on and the session ending: Quit quits without asking", arguments: [
        LifecycleState.running, .stopped, .unreadable,
    ])
    func sessionEndingQuits(_ state: LifecycleState) {
        #expect(QuitPolicy.decide(stopOnQuit: true, state: state, sessionEnding: true) == .quit)
    }

    @Test("the stop succeeded: quit")
    func stopSucceededQuits() {
        #expect(QuitPolicy.afterStop(succeeded: true) == .quit)
    }

    @Test("the stop failed or was cancelled: no quit, and the message says so")
    func stopFailedStays() {
        guard case .stay(let why) = QuitPolicy.afterStop(succeeded: false) else {
            Issue.record("a failed stop quit the app")
            return
        }
        #expect(why.hasPrefix("k3sm did not stop, so the app did not quit."))
        #expect(why.contains("Settings > General"))
    }

    @Test("the stop question answered no: no quit")
    func stopDeclinedStays() {
        guard case .stay(let why) = QuitPolicy.afterStop(succeeded: nil) else {
            Issue.record("a declined stop quit the app")
            return
        }
        #expect(why.hasPrefix("k3sm was not stopped, so the app did not quit."))
    }

    @Test("the toggle's help tag is in the General catalog")
    func helpTagRegistered() {
        #expect(Help.General.all.contains(Help.General.stopOnQuit))
        #expect(Help.General.stopOnQuit.label == QuitPolicy.toggleLabel)
    }
}
