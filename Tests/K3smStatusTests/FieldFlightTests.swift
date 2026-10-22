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
    /// Times across the whole cycle of laps, every 10 ms.
    private static let cycle = (0..<Int(FieldFlight.cycle * 100)).map { Double($0) / 100 }

    @Test("under Reduce Motion it perches still on the tallest flower")
    func perched() {
        let perched = FieldFlight.pose(at: 3, reduceMotion: true)
        #expect(perched.perched && perched.beat == 0 && perched.hindBeat == 0 && perched.pitch == 0 && perched.tilt == 0)
        #expect(FieldFlight.pose(at: 700, reduceMotion: true) == perched)
        let top = FieldFlight.flowerTop(FieldFlight.perch)
        #expect(perched.x == top.x && perched.y == top.y)
        #expect(FieldFlight.flowers.map(\.height).max() == FieldFlight.flowers[FieldFlight.perch].height)
    }

    @Test("in flight it stays above the flowers, on a visit it comes down to the flower's head, its wings within the stroke")
    func bounds() throws {
        let highestFlowerTop = try #require(FieldFlight.flowers.indices.map { FieldFlight.flowerTop($0).y }.min())
        for t in Self.cycle {
            let pose = FieldFlight.pose(at: t, reduceMotion: false)
            #expect(pose.x > 0.05 && pose.x < 0.95)
            if let visit = FieldFlight.landing(at: t) {
                #expect(pose.y > 0.1 && pose.y <= FieldFlight.flowerTop(visit.landing.flower).y + 1e-9)
            } else {
                #expect(!pose.perched && !pose.folded)
                #expect(pose.y > 0.1 && pose.y < highestFlowerTop - 0.05)
                #expect(pose.beat >= FieldWings.bottom - 1e-9 && pose.beat <= FieldWings.top + 1e-9)
                #expect(pose.hindBeat >= FieldWings.bottom - 1e-9 && pose.hindBeat <= FieldWings.top + 1e-9)
            }
            #expect(pose.beat >= FieldWings.bottom - 1e-9 && pose.beat <= FieldWings.closed + 1e-9)
            #expect(abs(pose.tilt) <= FieldFlight.maxTilt + 1e-9)
            #expect(abs(pose.pitch) <= max(FieldFlight.maxPitch, FieldFlight.flare) + 1e-9)
            #expect(abs(pose.turn) <= 1 + 1e-12)
        }
    }

    @Test("a time always gives the same pose, and the cycle of laps ends where it began")
    func deterministic() throws {
        for t in [0, 0.37, 4.6, 7.0, 11.2, 17.99, 40.5, 123.456] {
            #expect(FieldFlight.pose(at: t, reduceMotion: false) == FieldFlight.pose(at: t, reduceMotion: false))
            let a = FieldFlight.pose(at: t, reduceMotion: false)
            let b = FieldFlight.pose(at: t + FieldFlight.cycle, reduceMotion: false)
            #expect(abs(a.x - b.x) < 1e-9 && abs(a.y - b.y) < 1e-9 && abs(a.tilt - b.tilt) < 1e-6 && abs(a.turn - b.turn) < 1e-9)
            #expect(abs(a.beat - b.beat) < 1e-6 && abs(a.hindBeat - b.hindBeat) < 1e-6 && abs(a.pitch - b.pitch) < 1e-6)
            #expect(a.perched == b.perched && a.folded == b.folded)
        }
        // Pinned values, so a change to the flight is a visible change here.
        #expect(abs(FieldFlight.beatPhase(at: 1) - 3.34835) < 1e-4)
        let first = FieldFlight.landing(at: 0.5)?.landing
        #expect(first?.start == 0.2 && first?.at == 0.2 && first?.flower == 3)
        #expect(FieldFlight.landing(at: 0.19) == nil)
        // The loop's clock waits while the butterfly is away, and runs on after.
        let away = try #require(first).length
        #expect(FieldFlight.loopTime(at: 0.19) == 0.19 && FieldFlight.loopTime(at: 3) == 0.2)
        #expect(abs(FieldFlight.loopTime(at: 0.2 + away + 1) - 1.2) < 1e-9)
        #expect(abs(FieldFlight.cycle - (FieldFlight.period * Double(FieldFlight.laps)
            + FieldFlight.schedule.reduce(0) { $0 + $1.landing.length })) < 1e-9)
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
    func hindwingLag() {
        #expect(FieldWings.hindLag > 0 && FieldWings.hindLag < 0.15)
        // In flapping flight the hindwing angle is the forewing angle a lag earlier.
        // A second of plain flapping flight: no glide or visit.
        let flapping = 10.5
        for step in 0..<30 {
            let t = flapping + Double(step) / 30
            let pose = FieldFlight.pose(at: t, reduceMotion: false)
            let flown = FieldFlight.loopTime(at: t)
            #expect(FieldFlight.flapping(at: flown) == 1 && FieldFlight.landing(at: t) == nil)
            let phase = FieldFlight.beatPhase(at: flown)
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
            let wall = Self.wall(forLoop: mid)
            #expect(FieldFlight.landing(at: wall) == nil)
            let pose = FieldFlight.pose(at: wall, reduceMotion: false)
            #expect(FieldFlight.flapping(at: mid) == 0)
            #expect(pose.beat == FieldWings.glide && pose.hindBeat == FieldWings.glide && pose.pitch == 0)
        }
        #expect(FieldWings.glide > 0 && FieldWings.glide < 45)
        let gliding = Self.lap.filter { FieldFlight.flapping(at: $0) < 1 }.count
        #expect(gliding > 0 && Double(gliding) < 0.25 * Double(Self.lap.count))

        // Away from the loop's ends, where it always stops to come back, it moves
        // across the field most slowly near the flowers at x 0.27 and 0.78.
        func speed(_ t: Double) -> Double {
            let a = FieldFlight.pose(at: t, reduceMotion: false), b = FieldFlight.pose(at: t + 0.01, reduceMotion: false)
            return abs(a.x - 0.5) < 0.3 ? abs(b.x - a.x) : .infinity
        }
        let speeds = Self.lap.filter { FieldFlight.landing(at: $0) == nil && FieldFlight.landing(at: $0 + 0.01) == nil }.map { (t: $0, v: speed($0)) }
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

    /// Every visit in the cycle: when it starts on the wall clock, and the landing.
    private static var visits: [(at: Double, landing: FieldLanding)] {
        FieldFlight.schedule.map { ($0.landing.at, $0.landing) }
    }

    /// The wall-clock time at which the loop's clock reads `loop` in the
    /// first lap: the loop's time plus every visit made before it.
    private static func wall(forLoop loop: Double) -> Double {
        loop + FieldFlight.schedule.filter { $0.leave < loop }.reduce(0) { $0 + $1.landing.length }
    }

    @Test("once or twice a lap it lands on a flower's head, a different flower each time over the cycle")
    func landsOnFlowerHeads() throws {
        #expect(FieldFlight.visits.allSatisfy { (1...2).contains($0.count) })
        #expect(Set(Self.visits.map(\.landing.flower)).count == Self.visits.count)
        for visit in Self.visits {
            let top = FieldFlight.flowerTop(visit.landing.flower)
            let touchdown = visit.at + visit.landing.touchdown
            for t in stride(from: touchdown + 0.001, to: touchdown + FieldFlight.fold + FieldFlight.rest - 0.001, by: 0.01) {
                let pose = FieldFlight.pose(at: t, reduceMotion: false)
                #expect(pose.perched)
                // Its feet are on the flower's head, the Reduce Motion perch's placement.
                #expect(abs(pose.x - top.x) < 1e-12 && abs(pose.y - top.y) < 1e-12)
                #expect(pose.tilt == 0 && pose.turn == visit.landing.facing)
            }
            // It brakes with quick beats and its nose up just before touching down.
            let braking = FieldFlight.pose(at: touchdown - FieldFlight.brake / 2, reduceMotion: false)
            #expect(braking.pitch > FieldFlight.maxPitch)
            #expect(!braking.perched)
        }
    }

    @Test("it rests folded for the intended time, opening and closing its wings slowly once")
    func restsFolded() {
        for visit in Self.visits {
            let touchdown = visit.at + visit.landing.touchdown
            let takeOff = touchdown + FieldFlight.fold + FieldFlight.rest
            var perched = 0.0, folded = 0.0, widest = FieldWings.closed
            for t in stride(from: visit.at, to: visit.at + visit.landing.length, by: 0.001) {
                let pose = FieldFlight.pose(at: t, reduceMotion: false)
                if pose.perched { perched += 0.001 }
                if pose.folded { folded += 0.001 }
                if pose.perched && t >= touchdown + FieldFlight.fold + 0.001 { widest = min(widest, pose.beat) }
            }
            #expect(abs(perched - (FieldFlight.fold + FieldFlight.rest)) < 0.005)
            #expect(abs(folded - (FieldFlight.rest - FieldFlight.openClose)) < 0.005)
            #expect(abs(widest - FieldFlight.openAngle) < 0.01)
            // Closed side-on once the wings have folded, and open at the middle of the open-and-close.
            #expect(FieldFlight.pose(at: touchdown + FieldFlight.fold + 0.1, reduceMotion: false).folded)
            let open = FieldFlight.pose(at: touchdown + FieldFlight.fold + FieldFlight.openAt + FieldFlight.openClose / 2, reduceMotion: false)
            #expect(open.perched && !open.folded && abs(open.beat - FieldFlight.openAngle) < 1e-9)
            #expect(!FieldFlight.pose(at: takeOff + 0.001, reduceMotion: false).perched)
        }
    }

    @Test("it takes off with quick beats and rejoins the loop where the loop has got to")
    func takesOff() {
        for visit in Self.visits {
            let takeOff = visit.at + visit.landing.takeOff
            // Quick beats: the wings sweep from the top past level within the first quick beat.
            let beats = stride(from: takeOff + 1e-9, to: takeOff + FieldFlight.quickBeat, by: 0.005).map { FieldFlight.pose(at: $0, reduceMotion: false).beat }
            #expect(abs((beats.first ?? 0) - FieldWings.closed) < 1e-3)
            #expect((beats.min() ?? 90) < 0)
            // Off the flower, then back in the loop.
            #expect(FieldFlight.pose(at: takeOff + 0.3, reduceMotion: false).y < FieldFlight.flowerTop(visit.landing.flower).y)
            let back = visit.at + visit.landing.length
            #expect(FieldFlight.landing(at: back + 0.001) == nil)
            let end = FieldFlight.pose(at: back - 1e-6, reduceMotion: false)
            let loop = FieldFlight.pose(at: back + 1e-6, reduceMotion: false)
            #expect(abs(end.x - loop.x) < 1e-4 && abs(end.y - loop.y) < 1e-4 && abs(end.turn - loop.turn) < 1e-4)
            #expect(!loop.perched)
        }
    }

    @Test("turning side-on and back, and every visit, is continuous: no jump in turn, place, wings or pitch")
    func continuous() {
        var turned = Set<Double>()
        var previous = FieldFlight.pose(at: 0, reduceMotion: false)
        for step in 1...Int(FieldFlight.cycle * 1000) {
            let t = Double(step) / 1000
            let pose = FieldFlight.pose(at: t, reduceMotion: false)
            #expect(abs(pose.turn - previous.turn) < 0.01)
            #expect(abs(pose.x - previous.x) < 0.002 && abs(pose.y - previous.y) < 0.002)
            #expect(abs(pose.beat - previous.beat) < 3 && abs(pose.hindBeat - previous.hindBeat) < 3)
            #expect(abs(pose.pitch - previous.pitch) < 0.5 && abs(pose.tilt - previous.tilt) < 0.5)
            if abs(pose.turn) > 0.6 && FieldFlight.landing(at: t) == nil {
                turned.insert((FieldFlight.loopTime(at: t) / FieldFlight.period).rounded(.down))
            }
            previous = pose
        }
        // It turns to show its side in flight in every lap.
        #expect(turned.count == FieldFlight.laps)
        // The drawn wings move continuously through a turn.
        for angle in [FieldWings.bottom, 20, FieldWings.top] {
            for turn in stride(from: -1.0, to: 1.0, by: 0.01) {
                let a = WingProjection.of(angle: angle, left: true, size: 26, turn: turn, pitch: 3, hind: false).apply(x: 2, y: 4)
                let b = WingProjection.of(angle: angle, left: true, size: 26, turn: turn + 0.01, pitch: 3, hind: false).apply(x: 2, y: 4)
                #expect(hypot(a.x - b.x, a.y - b.y) < 1)
            }
        }
    }

    @Test("side-on with its wings closed it draws exactly the perched mark, so the change to it does not show")
    func closedSideOnIsTheFoldedMark() {
        let size = 26.0, c = size / 2
        for facing in [1.0, -1.0] {
            for left in [true, false] {
                for hind in [false, true] {
                    let projection = WingProjection.of(angle: FieldWings.closed, left: left, size: size, turn: facing, pitch: 0, hind: hind)
                    for (x, y) in [(2.0, 3.0), (11.0, 20.0), (left ? 6.0 : 20.0, 14.0)] {
                        let point = (left == (x < c)) ? (x, y) : (size - x, y)
                        let drawn = projection.apply(x: point.0, y: point.1)
                        // FoldedButterfly: the mark turned so its head points right, both
                        // halves above the body, stretched by Perch.sideFill about the
                        // centre; mirrored for a head to the left.
                        let foldedX = c + facing * Perch.sideFill.x * (c - point.1)
                        let foldedY = c - Perch.sideFill.y * abs(point.0 - c)
                        #expect(abs(drawn.x - foldedX) < 1e-9 && abs(drawn.y - foldedY) < 1e-9)
                    }
                }
            }
        }
    }

    @Test("at the top of the stroke the hindwings tuck up toward the forewings; level, they stay where the mark has them")
    func hindwingsTuckUp() {
        let size = 26.0
        let level = WingProjection.of(angle: 0, left: true, size: size, turn: 0, pitch: 0, hind: true).apply(x: 6, y: 22)
        #expect(abs(level.x - 6) < 1e-9 && abs(level.y - 22) < 1e-9)
        let fore = WingProjection.of(angle: FieldWings.top, left: true, size: size, turn: 0, pitch: 0, hind: false).apply(x: 6, y: 22)
        let hind = WingProjection.of(angle: FieldWings.top, left: true, size: size, turn: 0, pitch: 0, hind: true).apply(x: 6, y: 22)
        #expect(hind.y < fore.y - 1.5)
    }
}
