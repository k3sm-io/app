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

import Combine
import Foundation
import K3smStatus

/// WaitingModel is the console's waiting butterflies: for each tab, where
/// `Waiting.shows` puts the mark (`marks`), from that tab's `TabLoad` as
/// `load` reports it, fed through a `WaitingTracker`. It re-checks on every
/// change the window controller forwards (`changed`) and, while any tab is
/// reading or still showing its mark, on a short tick so the debounce and
/// the minimum shown time pass without a change. One `FlapModel` beats
/// continuously while any mark is shown; every mark draws its angle.
@MainActor
final class WaitingModel: ObservableObject {
    /// How often the verdict is re-checked while a tab is active, in seconds.
    private static let tick: TimeInterval = 0.05

    @Published private(set) var marks: [ConsoleSection: WaitingMark] = [:]
    let flap = FlapModel()
    /// Each tab's read state, nil for a tab whose loader does not exist yet.
    var load: @MainActor (ConsoleSection) -> TabLoad? = { _ in nil }
    private var trackers: [ConsoleSection: WaitingTracker] = [:]
    private var ticker: Timer?

    /// changed re-checks after a loader's change; loaders announce a change
    /// before making it, so the check runs on the next turn of the main queue.
    func changed() {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.update() } }
    }

    /// stop clears every mark and stops the beat and the tick.
    func stop() {
        ticker?.invalidate()
        ticker = nil
        trackers = [:]
        if !marks.isEmpty { marks = [:] }
        flap.stop()
    }

    private func update() {
        let now = ProcessInfo.processInfo.systemUptime
        var next: [ConsoleSection: WaitingMark] = [:]
        var active = false
        for section in ConsoleSection.allCases {
            var tracker = trackers[section] ?? WaitingTracker()
            next[section] = tracker.update(load: load(section) ?? .idle, now: now)
            active = active || tracker.active
            trackers[section] = tracker
        }
        if next != marks { marks = next }
        if marks.isEmpty { flap.stop() } else { flap.startContinuous() }
        if active, ticker == nil {
            ticker = Timer.scheduledTimer(withTimeInterval: Self.tick, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            }
        } else if !active {
            ticker?.invalidate()
            ticker = nil
        }
    }
}
