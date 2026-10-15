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
import K3smStatus

/// FlapModel plays the wordmark butterfly's wing beat while the console is
/// on screen: a `Flap` beat after each random rest, skipped while Reduce
/// Motion is on, and one at once when the pointer enters the mark (`poke`).
/// The window controller starts and stops it with the console's polls, so
/// nothing runs while the window is closed. Between
/// beats no timer fires but the one that ends the rest.
@MainActor
final class FlapModel: ObservableObject {
    /// The wings' hinge angle in degrees; 0 is flat.
    @Published private(set) var angle = 0.0
    /// Whether the window can be seen, asked when a beat comes due: false
    /// while it is miniaturized or fully covered. The window controller
    /// supplies it; a skipped beat is like one under Reduce Motion, and the
    /// rests go on.
    var windowVisible: @MainActor () -> Bool = { true }
    private var restTimer: Timer?
    private var frameTimer: Timer?
    private var frames: [Double] = []
    private var frameIndex = 0
    /// When the last beat ended, on the system's monotonic uptime clock; nil
    /// before the first.
    private var lastBeatEnded: TimeInterval?

    /// start schedules the first beat; a second start is a no-op.
    func start() {
        guard restTimer == nil, frameTimer == nil else { return }
        rest()
    }

    /// stop cancels any beat and leaves the wings flat.
    func stop() {
        restTimer?.invalidate()
        restTimer = nil
        frameTimer?.invalidate()
        frameTimer = nil
        angle = 0
    }

    /// poke plays one beat now when `Flap.hoverStartsBeat` allows it (the
    /// beats are running, none is playing, and `Flap.plays` passes: Reduce
    /// Motion off, the window visible) and `Flap.hoverCooldown` has passed
    /// since the last beat ended, and does
    /// nothing otherwise. The pending rest is cancelled so it cannot fire
    /// mid-beat; the beat's end draws the next random rest as usual.
    func poke() {
        let started = restTimer != nil || frameTimer != nil
        guard Flap.hoverStartsBeat(
            inFlight: frameTimer != nil, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            windowVisible: windowVisible(),
            sinceLastBeat: lastBeatEnded.map { ProcessInfo.processInfo.systemUptime - $0 },
            started: started) else { return }
        restTimer?.invalidate()
        restTimer = nil
        play()
    }

    private func rest() {
        restTimer = Timer.scheduledTimer(withTimeInterval: Flap.rest(unit: .random(in: 0...1)), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.beat() }
        }
    }

    private func beat() {
        restTimer = nil
        guard Flap.plays(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, windowVisible: windowVisible()) else {
            rest()
            return
        }
        play()
    }

    private func play() {
        frames = Flap.frames()
        frameIndex = 0
        frameTimer = Timer.scheduledTimer(withTimeInterval: 1 / Flap.frameRate, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
    }

    private func step() {
        guard frameIndex < frames.count else {
            frameTimer?.invalidate()
            frameTimer = nil
            angle = 0
            lastBeatEnded = ProcessInfo.processInfo.systemUptime
            rest()
            return
        }
        angle = frames[frameIndex]
        frameIndex += 1
    }
}
