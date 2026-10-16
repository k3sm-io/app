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

@Suite("perch")
struct PerchTests {
    /// One keyframe: the phase, the time into it, and the pose expected there
    /// (offset from the perch, tilt, wing opening, hinge angle, opacity).
    struct Key: Sendable, CustomTestStringConvertible {
        let phase: PerchPhase
        let t: TimeInterval
        let dx, dy, rotation, opening, beat, opacity: Double
        var testDescription: String { "\(phase) at \(t) s" }
    }

    @Test("the landing, the perch and the take-off pass their keyframes", arguments: [
        // Landing: in from the upper left, tilted 20 degrees, wings open and flat, unseen.
        Key(phase: .landing, t: 0, dx: -12, dy: -8, rotation: 20, opening: 1, beat: 0, opacity: 0),
        // Half a fast stroke in, the wings at their peak, fading in over 80 ms.
        Key(phase: .landing, t: 0.0625, dx: -4.2890625, dy: -6.46875, rotation: 11.25, opening: 1, beat: 60, opacity: 0.78125),
        // Half the flight: most of the way across, descending, levelling.
        Key(phase: .landing, t: 0.125, dx: -1.125, dy: -3.5, rotation: 5, opening: 1, beat: 0, opacity: 1),
        // Touchdown: on the perch, level, the slow settle stroke begins.
        Key(phase: .landing, t: 0.25, dx: 0, dy: 0, rotation: 0, opening: 1, beat: 0, opacity: 1),
        // The settle's middle: dipped 0.6 pt, wings half folded, one slow stroke.
        Key(phase: .landing, t: 0.30, dx: 0, dy: 0.6, rotation: 0, opening: 0.5, beat: 40, opacity: 1),
        // The landing's end: back up on the perch, wings folded.
        Key(phase: .landing, t: 0.35, dx: 0, dy: 0, rotation: 0, opening: 0, beat: 0, opacity: 1),
        // Perched: wings folded and still, then a half open-and-close each 1.2 s.
        Key(phase: .perched, t: 0, dx: 0, dy: 0, rotation: 0, opening: 0, beat: 0, opacity: 1),
        Key(phase: .perched, t: 0.5, dx: 0, dy: 0, rotation: 0, opening: 0, beat: 0, opacity: 1),
        Key(phase: .perched, t: 0.9, dx: 0, dy: 0, rotation: 0, opening: 0.25, beat: 0, opacity: 1),
        Key(phase: .perched, t: 1.0, dx: 0, dy: 0, rotation: 0, opening: 0.5, beat: 0, opacity: 1),
        Key(phase: .perched, t: 1.2, dx: 0, dy: 0, rotation: 0, opening: 0, beat: 0, opacity: 1),
        Key(phase: .perched, t: 2.2, dx: 0, dy: 0, rotation: 0, opening: 0.5, beat: 0, opacity: 1),
        // Take-off: from the perch with the wings folded...
        Key(phase: .takingOff, t: 0, dx: 0, dy: 0, rotation: 0, opening: 0, beat: 0, opacity: 1),
        // ...open within 60 ms...
        Key(phase: .takingOff, t: 0.06, dx: 0.1261874, dy: -0.4650222, rotation: 0.4408163, opening: 1,
            beat: 59.76344, opacity: 1),
        // ...lifting first, beating fast, starting to fade...
        Key(phase: .takingOff, t: 0.175, dx: 1.625, dy: -3.625, rotation: 3.75, opening: 1, beat: 54.27051, opacity: 0.9259259),
        // ...and gone at the upper right, tilted 15 degrees.
        Key(phase: .takingOff, t: 0.35, dx: 14, dy: -10, rotation: 15, opening: 1, beat: 20.72949, opacity: 0),
    ])
    func keyframes(_ key: Key) {
        let pose = Perch.pose(key.phase, at: key.t)
        #expect(abs(pose.dx - key.dx) < 1e-4, "dx \(pose.dx)")
        #expect(abs(pose.dy - key.dy) < 1e-4, "dy \(pose.dy)")
        #expect(abs(pose.rotation - key.rotation) < 1e-4, "rotation \(pose.rotation)")
        #expect(abs(pose.opening - key.opening) < 1e-4, "opening \(pose.opening)")
        #expect(abs(pose.beat - key.beat) < 1e-3, "beat \(pose.beat)")
        #expect(abs(pose.opacity - key.opacity) < 1e-4, "opacity \(pose.opacity)")
    }

    @Test("folded wings are the pair seen nearly edge-on; open wings are the whole mark")
    func wingScale() {
        #expect(Perch.pose(.perched, at: 0).wingScale == Perch.folded)
        #expect(Perch.folded > 0 && Perch.folded <= 0.35)
        #expect(Perch.pose(.landing, at: 0.1).wingScale == 1)
        #expect(abs(Perch.pose(.perched, at: 1.0).wingScale - (Perch.folded + (1 - Perch.folded) * 0.5)) < 1e-9)
    }

    @Test("the motion is continuous: the landing ends where the perch begins, the perch where the take-off begins")
    func continuity() {
        let step = 1.0 / 240
        for (phase, length) in [(PerchPhase.landing, Perch.landing), (.takingOff, Perch.takeOff)] {
            var last = Perch.pose(phase, at: 0)
            for i in 1...Int((length / step).rounded()) {
                let pose = Perch.pose(phase, at: Double(i) * step)
                #expect(abs(pose.dx - last.dx) < 1.5)
                #expect(abs(pose.dy - last.dy) < 1.5)
                #expect(abs(pose.rotation - last.rotation) < 3)
                #expect(abs(pose.opening - last.opening) < 0.35)
                last = pose
            }
        }
        #expect(Perch.pose(.landing, at: Perch.landing) == Perch.pose(.perched, at: 0))
        #expect(Perch.pose(.takingOff, at: 0, from: 0) == Perch.pose(.perched, at: 0))
        // A take-off that begins mid flex opens from where the wings were.
        #expect(Perch.pose(.takingOff, at: 0, from: 0.4).opening == 0.4)
        // Times outside a phase are held at its ends; one that is not a number is the perch.
        #expect(Perch.pose(.landing, at: -1) == Perch.pose(.landing, at: 0))
        #expect(Perch.pose(.takingOff, at: 9) == Perch.pose(.takingOff, at: Perch.takeOff))
        #expect(Perch.pose(.landing, at: .nan) == Perch.still)
    }

    @Test("the flight stays in the strip and never over the previous tab's label")
    func flightStaysInItsRoom() {
        // The strip's 13 pt system font (ascent, descent, cap height) and its 10 pt mark.
        let mark = TabStripLayout.waitingMarkFrame(ascent: 12.38, descent: 3.14, capHeight: 9.17, markSize: 10)
        let shortest = ConsoleSection.allCases.map { TabStripLayout.labelWidth($0.title) }.min() ?? 0
        // The landing starts within the label's own leading area plus the gap before it.
        let start = Perch.pose(.landing, at: 0)
        #expect(start.dx < 0 && start.dx > -TabStripLayout.tabSpacing)
        #expect(start.dy < 0)
        let step = 1.0 / 240
        for (phase, length) in [(PerchPhase.landing, Perch.landing), (.takingOff, Perch.takeOff), (.perched, 3.0)] {
            for i in 0...Int((length / step).rounded()) {
                let pose = Perch.pose(phase, at: Double(i) * step)
                // The mark's square turned by its tilt, at its offset: its bounding box.
                let r = pose.rotation * .pi / 180
                let half = mark.size / 2 * (abs(cos(r)) + abs(sin(r)))
                let cx = mark.midX + pose.dx
                let cy = mark.minY + mark.size / 2 + pose.dy
                #expect(cx - half > -TabStripLayout.tabSpacing, "\(phase) \(Double(i) * step)")
                #expect(cx + half < shortest + TabStripLayout.tabSpacing, "\(phase) \(Double(i) * step)")
                #expect(cy - half >= 0, "\(phase) \(Double(i) * step)")
                #expect(cy + half <= TabStripLayout.height, "\(phase) \(Double(i) * step)")
            }
        }
    }

    @Test("a perched mark holds still: upright, on the perch, beating no stroke")
    func perchedHoldsStill() {
        for t in stride(from: 0.0, through: 5, by: 0.05) {
            let pose = Perch.pose(.perched, at: t)
            #expect(pose.dx == 0 && pose.dy == 0 && pose.rotation == 0 && pose.beat == 0 && pose.opacity == 1)
            #expect(pose.opening >= 0 && pose.opening <= Perch.flexOpening)
        }
    }

    @Test("the perched profile is full size: it fills the flight mark's box, its body on the perch line")
    func perchedProfileIsFullSize() {
        // The side view before its stretch: the turned mark (as long as the mark is tall) and
        // the mirrored half standing above the body (as tall as half the mark is wide).
        let length = TabStripLayout.markFoot - Perch.markTop
        let rise = 0.5 - Perch.markLeft
        #expect(rise < length / 2 + 0.05, "unstretched, the profile is about half the box")
        // Stretched by `sideFill`, it is as wide and as tall as the flight mark.
        let width = length * Perch.sideFill.x, height = rise * Perch.sideFill.y
        #expect(abs(width - (Perch.markRight - Perch.markLeft)) < 1e-9)
        #expect(abs(height - (TabStripLayout.markFoot - Perch.markTop)) < 1e-9)
        // With its body on the perch line, its top is the flight mark's top, inside the square,
        // and it is no wider than the square, so the strip's room holds (`flightStaysInItsRoom`).
        let top = TabStripLayout.markFoot - height
        #expect(abs(top - Perch.markTop) < 1e-9 && top >= 0)
        #expect(width <= 1 && 0.5 - width / 2 >= 0)
        // At rest it is drawn at that full size, not compressed.
        #expect(Perch.pose(.perched, at: 0).sideScale == 1)
        #expect(Perch.pose(.landing, at: Perch.landing).sideScale == 1)
    }

    @Test("the tab butterfly sits side-on through the perch and beats its closed wings once per beat")
    func perchedPoseIsSideways() {
        // Fully side-on, level and in place, through the perched phase.
        for t in stride(from: 0.0, through: 5, by: 0.05) {
            let pose = Perch.pose(.perched, at: t)
            #expect(pose.sideOn == 1)
            #expect(pose.rotation == 0 && pose.dx == 0 && pose.dy == 0 && pose.beat == 0)
            #expect(pose.squeeze >= 0 && pose.squeeze <= Perch.sidePeak + 1e-9)
            #expect(pose.sideScale <= 1 && pose.sideScale >= 0.85 - 1e-9)
        }
        // One stroke per Flap beat: full size at each beat's ends, smallest at its middle, repeating.
        #expect(Perch.sideBeat == Flap.duration)
        let d = Flap.duration
        for k in 0..<3 {
            let start = Double(k) * d
            #expect(abs(Perch.pose(.perched, at: start).sideScale - 1) < 1e-9)
            #expect(abs(Perch.pose(.perched, at: start + d / 2).sideScale - 0.85) < 1e-9)
            #expect(abs(Perch.pose(.perched, at: start + d / 4).squeeze - Perch.sidePeak / 2) < 1e-9)
        }
        // At rest the full-size profile; each stroke makes it a little smaller, about 0.85, never more.
        #expect(Perch.pose(.perched, at: 0).sideScale == 1)
        let smallest = (0...800).map { Perch.pose(.perched, at: Double($0) * d / 800).sideScale }.min() ?? 0
        #expect(abs(smallest - 0.85) < 1e-6)
        #expect(Perch.sidePeak > 0 && Perch.sidePeak <= 0.2)
        #expect(Perch.profilePeak < 0.5)
        var rises = 0, last = 0.0
        for t in stride(from: 0.0, through: d, by: 0.01) {
            let b = Perch.pose(.perched, at: t).squeeze
            if b > last + 1e-12 && last <= 1e-12 { rises += 1 }
            last = b
        }
        #expect(rises == 1)
        // The landing turns side-on at its start and stays side-on through touchdown (`landingIsSideways`).
        #expect(Perch.pose(.landing, at: 0).sideOn == 0)
        for t in [0.1, 0.125, 0.25, 0.30, Perch.landing] {
            #expect(Perch.pose(.landing, at: t).sideOn == 1)
        }
        // The take-off turns back to the flight view within turnTime, then matches today's flight.
        #expect(Perch.pose(.takingOff, at: 0).sideOn == 1)
        #expect(Perch.pose(.takingOff, at: Perch.turnTime / 2).sideOn == 0.5)
        for t in [Perch.turnTime, 0.175, Perch.takeOff] {
            let pose = Perch.pose(.takingOff, at: t)
            #expect(pose.sideOn == 0 && pose.squeeze == 0)
        }
        // A take-off mid stroke starts at the size the profile had and returns it to full size as it turns.
        let held = Perch.pose(.perched, at: 0.2).squeeze
        #expect(Perch.pose(.takingOff, at: 0, squeezed: held).squeeze == held)
        #expect(Perch.pose(.takingOff, at: Perch.turnTime, squeezed: held).squeeze == 0)
        let flight = LabelFlight(shownAt: 10, leftAt: 10 + Perch.landing + 0.2, reduceMotion: false)
        #expect(abs(flight.pose(at: 10 + Perch.landing + 0.2).squeeze - held) < 1e-9)
        // No size jump at take-off: the side view's scale moves smoothly from the perch's.
        var size = flight.pose(at: 10 + Perch.landing + 0.2 - 1.0 / 240).sideScale
        for i in 0...Int((Perch.takeOff * 240).rounded()) {
            let s = flight.pose(at: 10 + Perch.landing + 0.2 + Double(i) / 240).sideScale
            #expect(abs(s - size) < 0.05, "take-off size jump at \(i)")
            size = s
        }
        // The turn is continuous in time, and Reduce Motion stays the still mark, not side-on.
        let step = 1.0 / 240
        var prev = Perch.pose(.landing, at: 0).sideOn
        for i in 1...Int((Perch.landing / step).rounded()) {
            let s = Perch.pose(.landing, at: Double(i) * step).sideOn
            #expect(abs(s - prev) < 0.2)
            prev = s
        }
        #expect(Perch.still.sideOn == 0 && Perch.still.squeeze == 0)
        let still = LabelFlight(shownAt: 10, leftAt: nil, reduceMotion: true)
        for t in [10.0, 10.5, 11.2, 13] {
            #expect(still.pose(at: t) == Perch.still)
        }
    }

    @Test("the tab butterfly lands in profile: turned side-on within 0.1 s, beating its wings side-on down to touchdown")
    func landingIsSideways() {
        // The turn to side-on happens at the start of the landing and is complete within its first 0.1 s.
        #expect(Perch.turnIn > 0 && Perch.turnIn <= 0.1)
        // The cross-fade from the flight view ends inside the fade-in, while the mark is still faint.
        #expect(Perch.turnIn < Perch.fadeIn)
        #expect(Perch.pose(.landing, at: Perch.turnIn).opacity <= 0.5 + 1e-9)
        #expect(Perch.pose(.landing, at: Perch.turnIn).sideOn == 1)
        #expect(Perch.pose(.landing, at: 0).sideOn == 0)
        #expect(Perch.pose(.landing, at: Perch.turnIn / 2).sideOn > 0)
        let step = 1.0 / 240
        for i in 0...Int((Perch.landing / step).rounded()) {
            let t = Double(i) * step
            let pose = Perch.pose(.landing, at: t)
            if t >= 0.1 { #expect(pose.sideOn == 1, "sideOn \(pose.sideOn) at \(t)") }
            #expect(pose.squeeze >= 0 && pose.squeeze <= Perch.profilePeak + 1e-9)
        }
        // The descent beats in profile: each stroke draws it in by `profilePeak` and back to full size.
        let flight = Perch.landing - Perch.settle
        for k in 0..<Int((flight / Perch.beatPeriod).rounded()) {
            let start = Double(k) * Perch.beatPeriod
            #expect(abs(Perch.pose(.landing, at: start).squeeze) < 1e-9)
            #expect(abs(Perch.pose(.landing, at: start + Perch.beatPeriod / 2).squeeze - Perch.profilePeak) < 1e-9)
        }
        #expect(Perch.profilePeak > Perch.sidePeak)
        // Touchdown is at full size, a slow settle stroke draws it in by at most `sidePeak`,
        // and the landing ends at the full-size profile, where the perch begins.
        #expect(abs(Perch.pose(.landing, at: flight).squeeze) < 1e-9)
        for t in stride(from: flight, through: Perch.landing, by: 0.01) {
            #expect(Perch.pose(.landing, at: t).squeeze <= Perch.sidePeak + 1e-9)
        }
        #expect(abs(Perch.pose(.landing, at: Perch.landing).squeeze) < 1e-9)
        #expect(Perch.pose(.landing, at: Perch.landing).sideScale == 1)
        // No size jump through the landing and into the perch.
        var size = Perch.pose(.landing, at: 0).sideScale
        for i in 1...Int((Perch.landing * 240).rounded()) {
            let s = Perch.pose(.landing, at: Double(i) / 240).sideScale
            #expect(abs(s - size) < 0.05, "landing size jump at \(i)")
            size = s
        }
        #expect(abs(Perch.pose(.perched, at: 1.0 / 240).sideScale - size) < 0.05)
        #expect(Perch.pose(.landing, at: Perch.landing) == Perch.pose(.perched, at: 0))
        // The perch stays side-on; the take-off is unchanged: it turns back within turnTime.
        #expect(Perch.pose(.perched, at: 0).sideOn == 1)
        #expect(Perch.pose(.takingOff, at: 0).sideOn == 1)
        #expect(Perch.pose(.takingOff, at: Perch.turnTime).sideOn == 0)
        // Reduce Motion: the still mark throughout.
        let still = LabelFlight(shownAt: 10, leftAt: nil, reduceMotion: true)
        for t in [10.0, 10.05, 10.1, 10.3] {
            #expect(still.pose(at: t) == Perch.still)
        }
    }

    @Test("a flight's phase follows its clock: landing, perched, then taking off once it has left")
    func flightPhases() {
        let flight = LabelFlight(shownAt: 10, leftAt: nil, reduceMotion: false)
        #expect(flight.phase(at: 10) == .landing)
        #expect(flight.phase(at: 10.2) == .landing)
        #expect(flight.phase(at: 10.36) == .perched)
        #expect(flight.phase(at: 13) == .perched)
        #expect(flight.pose(at: 10) == Perch.pose(.landing, at: 0))
        #expect(abs(flight.pose(at: 11.35).opening - Perch.pose(.perched, at: 1.0).opening) < 1e-9)
        let left = LabelFlight(shownAt: 10, leftAt: 11.35, reduceMotion: false)
        #expect(left.phase(at: 11.35) == .takingOff)
        #expect(left.phase(at: 11.5) == .takingOff)
        // It leaves from mid flex, so the take-off opens from half open.
        #expect(abs(left.pose(at: 11.35).opening - 0.5) < 1e-9)
        let mid = left.pose(at: 11.525), want = Perch.pose(.takingOff, at: 0.175, from: 0.5)
        #expect(abs(mid.dx - want.dx) < 1e-9 && abs(mid.dy - want.dy) < 1e-9 && abs(mid.opacity - want.opacity) < 1e-9)
        // Under Reduce Motion it is the still perched mark throughout.
        let still = LabelFlight(shownAt: 10, leftAt: nil, reduceMotion: true)
        #expect(still.phase(at: 10) == .perched)
        for t in [10.0, 10.1, 10.3, 11, 12.5] {
            #expect(still.pose(at: t) == Perch.still)
        }
    }
}
