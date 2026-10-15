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

@Suite("flap")
struct FlapTests {
    @Test("a beat starts and ends with the wings flat")
    func flatAtBothEnds() {
        let frames = Flap.frames()
        #expect(frames.first == 0)
        #expect(abs(frames.last ?? 1) < 1e-9)
        #expect(Flap.angle(at: -1) == 0)
        #expect(Flap.angle(at: Flap.duration + 1) == 0)
    }

    @Test("the first stroke is the highest and the second is lower")
    func strokeHeights() {
        let first = Flap.angle(at: Flap.duration / 4)
        let second = Flap.angle(at: Flap.duration * 3 / 4)
        #expect(abs(first - Flap.peak) < 1e-9)
        #expect(abs(second - Flap.peak * Flap.secondDepth) < 1e-9)
    }

    @Test("every frame stays between flat and the peak")
    func framesInRange() {
        let frames = Flap.frames()
        #expect(frames.count == Int((Flap.duration * Flap.frameRate).rounded()) + 1)
        for a in frames {
            #expect(a >= 0 && a <= Flap.peak + 1e-9)
        }
    }

    /// inFlight, reduceMotion, windowVisible, started, and the verdict.
    @Test("a hover starts a beat only when one may play now", arguments: [
        (false, false, true, true, true),
        (true, false, true, true, false),
        (false, true, true, true, false),
        (false, false, false, true, false),
        (true, true, false, true, false),
        (false, false, true, false, false),
    ] as [(Bool, Bool, Bool, Bool, Bool)])
    func hoverStartsBeat(_ inFlight: Bool, _ reduceMotion: Bool, _ windowVisible: Bool, _ started: Bool, _ want: Bool) {
        #expect(Flap.hoverStartsBeat(inFlight: inFlight, reduceMotion: reduceMotion, windowVisible: windowVisible,
                                     sinceLastBeat: nil, started: started) == want)
    }

    @Test("a hover within the cooldown of the last beat's end starts nothing", arguments: [
        (nil, true), (0, false), (Flap.hoverCooldown - 0.01, false), (Flap.hoverCooldown, true),
        (Flap.hoverCooldown + 5, true), (-1, false), (.nan, false),
    ] as [(TimeInterval?, Bool)])
    func hoverCooldown(_ since: TimeInterval?, _ want: Bool) {
        #expect(Flap.hoverStartsBeat(inFlight: false, reduceMotion: false, windowVisible: true, sinceLastBeat: since) == want)
    }

    @Test("the rest stays between its bounds", arguments: [-1.0, 0, 0.5, 1, 2])
    func restBounds(unit: Double) {
        let r = Flap.rest(unit: unit)
        #expect(r >= Flap.restMin && r <= Flap.restMax)
    }

    @Test("a beat plays only with motion allowed and the window visible", arguments: [
        (false, true, true), (true, true, false), (false, false, false), (true, false, false),
    ])
    func plays(reduceMotion: Bool, windowVisible: Bool, want: Bool) {
        #expect(Flap.plays(reduceMotion: reduceMotion, windowVisible: windowVisible) == want)
    }
}

@Suite("dock frame")
struct DockFrameTests {
    @Test("outside the console the bundle icon comes back, rendered or not", arguments: [true, false])
    func outsideConsole(rendered: Bool) {
        #expect(DockFrame.decide(consoleShown: false, rendered: rendered) == .bundleIcon)
    }

    @Test("on the console a rendered frame is shown and a failed one keeps the last")
    func onConsole() {
        #expect(DockFrame.decide(consoleShown: true, rendered: true) == .newFrame)
        #expect(DockFrame.decide(consoleShown: true, rendered: false) == .keepLast)
    }
}

