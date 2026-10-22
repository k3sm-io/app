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

/// These follow the butterfly's body through the whole cycle, every
/// millisecond, and hold the flights to and from the flowers to the loop's
/// own motion: never faster than ordinary flight, never a harder push or
/// brake than a wingbeat gives, no jump in velocity where one part of the
/// flight hands over to the next, and at rest when it touches down. They
/// also hold its turn to its travel: side profile, facing ahead, when it
/// moves across the field, seen from above when it hovers.
@Suite("the Alerts field's butterfly moves like ordinary flight")
struct FieldMotionTests {
    /// The sampling step, in seconds.
    private static let step = 0.001
    /// The scene's usual width over its height, for speeds in field heights.
    private static let widthOverHeight = 3.3

    /// Sample is the body's place, velocity and acceleration at one time,
    /// in field heights and seconds, and what it is doing.
    private struct Sample {
        let t: Double
        let place: (x: Double, y: Double)
        let turn: Double
        let speed: Double
        let acceleration: Double
        let velocity: (x: Double, y: Double)
        let visiting: Bool
        let perched: Bool
    }

    /// Every sample of the cycle, each pose computed once.
    private static let samples: [Sample] = {
        let count = Int((FieldFlight.cycle / step).rounded())
        let poses = (-1...count).map { FieldFlight.pose(at: Double($0) * step, reduceMotion: false) }
        let places = poses.map { (x: $0.x * widthOverHeight, y: $0.y) }
        var out: [Sample] = []
        out.reserveCapacity(count)
        for index in 0..<count {
            let previous = places[index], here = places[index + 1], next = places[index + 2]
            let t = Double(index) * step
            let v = ((next.x - previous.x) / (2 * step), (next.y - previous.y) / (2 * step))
            let a = hypot(next.x - 2 * here.x + previous.x, next.y - 2 * here.y + previous.y) / (step * step)
            out.append(Sample(t: t, place: here, turn: poses[index + 1].turn, speed: hypot(v.0, v.1), acceleration: a,
                              velocity: v, visiting: FieldFlight.landing(at: t) != nil, perched: poses[index + 1].perched))
        }
        return out
    }()

    /// The fastest and the hardest-pushed the body ever is in the loop.
    private static var cruise: (speed: Double, acceleration: Double) {
        let loop = samples.filter { !$0.visiting }
        return (loop.map(\.speed).max() ?? 0, loop.map(\.acceleration).max() ?? 0)
    }

    @Test("flying to a flower and back is never faster than ordinary flight")
    func speedCap() throws {
        let cap = Self.cruise.speed
        #expect(cap > 0.3 && cap < 1)
        let visiting = Self.samples.filter(\.visiting)
        #expect(!visiting.isEmpty)
        let fastest = try #require(visiting.max { $0.speed < $1.speed })
        #expect(fastest.speed <= cap, "at \(fastest.t) s the body moves \(fastest.speed) field heights a second; ordinary flight peaks at \(cap)")
    }

    @Test("no part of a visit pushes or brakes the body harder than a wingbeat does")
    func accelerationBound() throws {
        let bound = Self.cruise.acceleration
        let hardest = try #require(Self.samples.filter(\.visiting).max { $0.acceleration < $1.acceleration })
        #expect(hardest.acceleration <= bound, "at \(hardest.t) s the body accelerates at \(hardest.acceleration); ordinary flight peaks at \(bound)")
    }

    @Test("velocity is continuous where the loop hands over to a visit, at touchdown, at take-off and back in the loop")
    func velocityContinuous() {
        let bound = Self.cruise.acceleration
        var transitions = 0
        for (before, after) in zip(Self.samples, Self.samples.dropFirst())
        where before.visiting != after.visiting || before.perched != after.perched {
            transitions += 1
            let jump = hypot(after.velocity.x - before.velocity.x, after.velocity.y - before.velocity.y)
            // Across one step the velocity can change by at most what the
            // hardest ordinary acceleration gives in that step, with room for rounding.
            #expect(jump <= bound * Self.step * 1.5 + 1e-6, "velocity jumps by \(jump) at \(after.t) s")
        }
        // Four hand-offs a visit: leaving the loop, touchdown, take-off, rejoining.
        #expect(transitions == 4 * FieldFlight.visits.map(\.count).reduce(0, +))
    }

    @Test("it is at rest when it touches down and when it takes off")
    func restAtTouchdown() {
        for (before, after) in zip(Self.samples, Self.samples.dropFirst()) where before.perched != after.perched {
            let moving = before.perched ? after : before
            #expect(moving.speed < 0.005, "speed \(moving.speed) field heights a second at \(moving.t) s")
        }
    }

    /// The body's velocity at sample `index`, averaged over the 0.3 s around
    /// it, so the bob of each wingbeat cancels and what is left is its travel.
    private static func travel(_ index: Int) -> (x: Double, y: Double)? {
        let half = 150
        guard index >= half, index + half < samples.count else { return nil }
        let a = samples[index - half].place, b = samples[index + half].place
        let span = Double(2 * half) * step
        return ((b.x - a.x) / span, (b.y - a.y) / span)
    }

    @Test("travelling across the field it is in side profile, facing the way it goes")
    func sideProfileAcross() {
        var across = 0, inProfile = 0
        for index in Self.samples.indices {
            guard let v = Self.travel(index), abs(v.x) > 0.25, abs(v.y) < 0.35 * abs(v.x) else { continue }
            across += 1
            let turn = Self.samples[index].turn
            // Near 1: the smoothed turn is still finishing as such travel begins.
            if abs(turn) >= 0.85 && (turn > 0) == (v.x > 0) { inProfile += 1 }
        }
        #expect(across > 10_000)
        #expect(inProfile == across, "side profile in \(inProfile) of \(across) samples travelling across the field")
    }

    @Test("hovering, or moving mostly up or down, it is seen from above")
    func frontalWhenStill() {
        var still = 0
        for index in Self.samples.indices {
            let sample = Self.samples[index]
            guard !sample.visiting, let v = Self.travel(index) else { continue }
            if hypot(v.x, v.y) < 0.06 || abs(v.x) < 0.2 * abs(v.y) {
                still += 1
                // Near zero: the turn is smoothed over half a second, so as travel
                // across the field begins it has started to turn a little.
                #expect(abs(sample.turn) <= 0.25, "turn \(sample.turn) at \(sample.t) s while hardly moving across the field")
            }
        }
        #expect(still > 1_000)
    }

    @Test("the turn never snaps: it changes smoothly and no faster than a turn takes")
    func turnChangesSmoothly() {
        // Smoothed over half a second with a raised cosine, the turn changes by
        // at most 8 a second, so turning from one side to the other takes at
        // least a quarter of a second.
        for (before, after) in zip(Self.samples, Self.samples.dropFirst()) {
            #expect(abs(after.turn - before.turn) <= 0.008, "turn jumps by \(after.turn - before.turn) at \(after.t) s")
        }
    }
}
