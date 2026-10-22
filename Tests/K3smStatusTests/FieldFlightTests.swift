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

@Suite("the Alerts field's butterfly")
struct FieldFlightTests {
    /// Times across one lap, every 10 ms.
    private static let lap = (0..<Int(FieldFlight.period * 100)).map { Double($0) / 100 }

    @Test("under Reduce Motion it perches still on the tallest flower")
    func perched() {
        let perched = FieldFlight.pose(at: 3, reduceMotion: true)
        #expect(perched.perched && perched.beat == 0 && perched.hindBeat == 0 && perched.pitch == 0 && perched.tilt == 0)
        #expect(FieldFlight.pose(at: 700, reduceMotion: true) == perched)
        let top = FieldFlight.flowerTop(FieldFlight.perch)
        #expect(perched.x == top.x && perched.y == top.y)
        #expect(FieldFlight.flowers.map(\.height).max() == FieldFlight.flowers[FieldFlight.perch].height)
    }

    @Test("in flight it stays above the flowers, its wings within the stroke, and it leans no further than the limit")
    func bounds() throws {
        let highestFlowerTop = try #require(FieldFlight.flowers.indices.map { FieldFlight.flowerTop($0).y }.min())
        for t in Self.lap {
            let pose = FieldFlight.pose(at: t, reduceMotion: false)
            #expect(!pose.perched)
            #expect(pose.x > 0.05 && pose.x < 0.95)
            #expect(pose.y > 0.1 && pose.y < highestFlowerTop - 0.05)
            for angle in [pose.beat, pose.hindBeat] {
                #expect(angle >= FieldWings.bottom - 1e-9 && angle <= FieldWings.top + 1e-9)
            }
            #expect(abs(pose.tilt) <= FieldFlight.maxTilt + 1e-9)
            #expect(abs(pose.pitch) <= FieldFlight.maxPitch + 1e-9)
        }
    }

    @Test("a time always gives the same pose, and a lap ends where it began")
    func deterministic() {
        for t in [0, 0.37, 4.6, 11.2, 17.99, 123.456] {
            #expect(FieldFlight.pose(at: t, reduceMotion: false) == FieldFlight.pose(at: t, reduceMotion: false))
            let a = FieldFlight.pose(at: t, reduceMotion: false)
            let b = FieldFlight.pose(at: t + FieldFlight.period, reduceMotion: false)
            #expect(abs(a.x - b.x) < 1e-9 && abs(a.y - b.y) < 1e-9 && abs(a.tilt - b.tilt) < 1e-6)
            #expect(abs(a.beat - b.beat) < 1e-6 && abs(a.hindBeat - b.hindBeat) < 1e-6 && abs(a.pitch - b.pitch) < 1e-6)
        }
        // Pinned values, so a change to the flight is a visible change here.
        let pose = FieldFlight.pose(at: 1, reduceMotion: false)
        #expect(abs(FieldFlight.beatPhase(at: 1) - 3.50407) < 1e-4)
        #expect(abs(pose.beat - FieldWings.angle(phase: FieldFlight.beatPhase(at: 1))) < 1e-9)
    }

    @Test("the downstroke is quicker than the upstroke, from the top of the stroke to below the body and back")
    func strokeAsymmetry() {
        #expect(FieldWings.angle(phase: 0) == FieldWings.top)
        #expect(abs(FieldWings.angle(phase: FieldWings.downstroke) - FieldWings.bottom) < 1e-9)
        #expect(FieldWings.angle(phase: 1) == FieldWings.top)
        #expect(FieldWings.top > 60 && FieldWings.bottom < 0)
        #expect(FieldWings.downstroke < 0.5)
        // Falling all through the downstroke and rising all through the upstroke.
        var previous = FieldWings.angle(phase: 0)
        for step in 1...200 {
            let phase = Double(step) / 200
            let angle = FieldWings.angle(phase: phase)
            if phase <= FieldWings.downstroke { #expect(angle < previous) } else { #expect(angle > previous) }
            previous = angle
        }
        // The same sweep in less time: the wings move faster on the way down.
        let down = (FieldWings.top - FieldWings.bottom) / FieldWings.downstroke
        let up = (FieldWings.top - FieldWings.bottom) / (1 - FieldWings.downstroke)
        #expect(down > up * 1.3)
        // At the middle of each half the downstroke is the quicker one.
        let dDown = FieldWings.angle(phase: FieldWings.downstroke / 2 - 0.001) - FieldWings.angle(phase: FieldWings.downstroke / 2 + 0.001)
        let midUp = FieldWings.downstroke + (1 - FieldWings.downstroke) / 2
        let dUp = FieldWings.angle(phase: midUp + 0.001) - FieldWings.angle(phase: midUp - 0.001)
        #expect(dDown > dUp)
    }

    @Test("the hindwings trail the forewings by a small part of a beat")
    func hindwingLag() throws {
        #expect(FieldWings.hindLag > 0 && FieldWings.hindLag < 0.15)
        // In flapping flight the hindwing angle is the forewing angle a lag earlier.
        let flapping = try #require(Self.lap.first { FieldFlight.flapping(at: $0) == 1 && FieldFlight.flapping(at: $0 + 1) == 1 })
        for step in 0..<30 {
            let t = flapping + Double(step) / 30
            let pose = FieldFlight.pose(at: t, reduceMotion: false)
            let phase = FieldFlight.beatPhase(at: t)
            #expect(abs(pose.beat - FieldWings.angle(phase: phase)) < 1e-9)
            #expect(abs(pose.hindBeat - FieldWings.angle(phase: phase - FieldWings.hindLag)) < 1e-9)
        }
        // So just after the top of the stroke the forewings are already falling
        // while the hindwings are still rising to meet them.
        let fore = 0.03, hind = fore - FieldWings.hindLag
        #expect(FieldWings.angle(phase: fore + 0.01) < FieldWings.angle(phase: fore))
        #expect(FieldWings.angle(phase: hind + 0.01) > FieldWings.angle(phase: hind))
    }

    @Test("the body rises as the wings come down and pitches a quarter beat behind them")
    func bodyFollowsTheBeat() {
        #expect(FieldWings.lift(phase: 0) == 0)
        #expect(abs(FieldWings.lift(phase: FieldWings.downstroke) - 1) < 1e-9)
        // Lowest pitch in the downstroke, highest in the upstroke, level at the turns.
        #expect(abs(FieldWings.pitch(phase: FieldWings.downstroke / 2) + 1) < 1e-9)
        #expect(abs(FieldWings.pitch(phase: FieldWings.downstroke + (1 - FieldWings.downstroke) / 2) - 1) < 1e-9)
        #expect(abs(FieldWings.pitch(phase: 0)) < 1e-9 && abs(FieldWings.pitch(phase: FieldWings.downstroke)) < 1e-9)
    }

    @Test("it flutters: the beat rate drifts, it glides with its wings held partly open, and it lingers near flowers")
    func flutters() throws {
        // Beat lengths over a lap: the time between successive tops of the stroke.
        var tops: [Double] = []
        var t = 0.0
        var beat = FieldFlight.beatPhase(at: 0).rounded(.up)
        while t < FieldFlight.period {
            if FieldFlight.beatPhase(at: t) >= beat { tops.append(t); beat += 1 }
            t += 0.001
        }
        let lengths = zip(tops.dropFirst(), tops).map { $0 - $1 }
        let shortest = try #require(lengths.min()), longest = try #require(lengths.max())
        #expect(shortest > 0.2 && longest < 0.45 && longest - shortest > 0.08)
        // The phase never runs backwards.
        for t in Self.lap { #expect(FieldFlight.beatPhase(at: t + 0.01) > FieldFlight.beatPhase(at: t)) }

        // Every glide holds the wings at the glide angle, with no bob or pitch.
        for glide in FieldFlight.glides {
            let mid = glide.start + glide.length / 2
            let pose = FieldFlight.pose(at: mid, reduceMotion: false)
            #expect(FieldFlight.flapping(at: mid) == 0)
            #expect(pose.beat == FieldWings.glide && pose.hindBeat == FieldWings.glide && pose.pitch == 0)
        }
        #expect(FieldWings.glide > 0 && FieldWings.glide < 45)
        let gliding = Self.lap.filter { FieldFlight.flapping(at: $0) < 1 }.count
        #expect(gliding > 0 && Double(gliding) < 0.25 * Double(Self.lap.count))

        // It moves across the field more slowly near the flowers at x 0.27 and 0.78.
        func speed(_ t: Double) -> Double {
            abs(FieldFlight.pose(at: t + 0.01, reduceMotion: false).x - FieldFlight.pose(at: t, reduceMotion: false).x)
        }
        let speeds = Self.lap.map { (t: $0, v: speed($0)) }
        let slowest = try #require(speeds.min { $0.v < $1.v })
        let x = FieldFlight.pose(at: slowest.t, reduceMotion: false).x
        #expect(min(abs(x - 0.27), abs(x - 0.78)) < 0.08)
    }

    @Test("a raised wing is drawn up the screen and in toward the body, a lowered one down, and level is the flat mark")
    func wingProjection() {
        let size = 26.0
        for left in [true, false] {
            let flat = WingProjection.of(angle: 0, left: left, size: size)
            let p = flat.apply(x: 3, y: 5)
            #expect(abs(p.x - 3) < 1e-9 && abs(p.y - 5) < 1e-9)
        }
        // A forewing tip on each side.
        let tips = [(left: true, x: 1.5, y: 2.5), (left: false, x: 24.5, y: 2.5)]
        for tip in tips {
            let raised = WingProjection.of(angle: FieldWings.top, left: tip.left, size: size).apply(x: tip.x, y: tip.y)
            let lowered = WingProjection.of(angle: FieldWings.bottom, left: tip.left, size: size).apply(x: tip.x, y: tip.y)
            #expect(raised.y < tip.y - 4)
            #expect(abs(raised.x - size / 2) < abs(tip.x - size / 2) / 2)
            #expect(lowered.y > tip.y)
            #expect(abs(lowered.x - size / 2) < abs(tip.x - size / 2))
            // A point on the hinge never moves.
            let hinge = WingProjection.of(angle: 50, left: tip.left, size: size).apply(x: size / 2, y: 9)
            #expect(abs(hinge.x - size / 2) < 1e-9 && abs(hinge.y - 9) < 1e-9)
        }
        // The two halves mirror each other.
        let l = WingProjection.of(angle: 40, left: true, size: size).apply(x: 4, y: 7)
        let r = WingProjection.of(angle: 40, left: false, size: size).apply(x: size - 4, y: 7)
        #expect(abs(l.x - (size - r.x)) < 1e-9 && abs(l.y - r.y) < 1e-9)
    }
}
