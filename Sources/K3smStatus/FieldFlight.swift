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

/// FieldPose is where the Alerts tab's resting butterfly is at one moment,
/// in the field's unit square (x right, y down): where its body is; its
/// forewings' and hindwings' hinge angles (`beat`, `hindBeat`), in degrees
/// above level, so 0 is the flat mark, a positive angle raises the wings
/// over the back (90 closes them together) and a negative one lowers them
/// below the body; its pitch (`pitch`, nose up positive) and its lean
/// (`tilt`), in degrees; how far it has turned to show its side (`turn`, 0
/// seen from above, 1 side-on with its head to the right, -1 side-on with
/// its head to the left); whether it is standing on a flower (`perched`);
/// and whether it is drawn as the side-on perched mark (`folded`), its
/// feet on the flower at its body's place.
public struct FieldPose: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let beat: Double
    public let hindBeat: Double
    public let pitch: Double
    public let tilt: Double
    public let turn: Double
    public let perched: Bool
    public let folded: Bool
}

/// FieldWings is one wingbeat of the field butterfly and how a wing is
/// seen, as pure functions, after slow-motion recordings of butterflies in
/// flight. The beat starts at the top, where the wings nearly meet above
/// the back (the clap), sweeps down through level to below the body in the
/// shorter part of the beat, and rises again in the longer part. Each half
/// of the mark is hinged on the body, the centre line, and seen from above
/// and a little behind, so a raised wing moves up the screen and in toward
/// the body as well as narrowing, and a lowered one moves down: a beat
/// reads as wings rising and falling, not as the mark squeezing.
public enum FieldWings {
    /// The hinge angle at the top of the stroke, in degrees.
    public static let top: Double = 80
    /// The hinge angle at the bottom of the stroke, in degrees.
    public static let bottom: Double = -20
    /// The hinge angle of wings closed together over the back, in degrees.
    public static let closed: Double = 90
    /// The share of a beat the downstroke takes; the upstroke takes the rest.
    public static let downstroke: Double = 0.42
    /// How far the hindwings trail the forewings, in beats.
    public static let hindLag: Double = 0.07
    /// How far a hindwing swings forward along the body as it rises, at the
    /// top of the stroke, as a fraction of the mark's size: raised, the
    /// hindwings tuck up under the forewings. Seen from above only; it fades
    /// out as the butterfly turns side-on, where the perched mark has none.
    public static let hindSweep: Double = 0.08
    /// The angle the wings are held at in a glide, in degrees: partly open,
    /// in a shallow V.
    public static let glide: Double = 20
    /// How far up the screen a wing point rises per unit of its height
    /// above the wing plane: the tangent of the view's elevation behind the
    /// butterfly, so 0 is straight down from above.
    public static let rise: Double = 0.6
    /// How much nearer a raised wing point comes, per unit of its height
    /// above the wing plane over the mark's size: a little perspective, so
    /// a raised wing grows slightly and a lowered one shrinks. It fades out
    /// as the butterfly turns side-on, where the profile is drawn flat.
    public static let depth: Double = 0.3
    /// How far the body rolls about its long axis when it is fully side-on,
    /// in degrees; it turns its head across the screen by 90 degrees at the
    /// same time. Rolled this far, the view from above and behind sees it
    /// from the side and a little above.
    public static let sideRoll: Double = 75

    /// The forewings' hinge angle `phase` beats from the top of a stroke
    /// (any real number; only its fraction counts). Each half of the stroke
    /// is eased in and out, so the wings turn smoothly at the top and the
    /// bottom.
    public static func angle(phase: Double) -> Double {
        let f = phase - phase.rounded(.down)
        if f < downstroke {
            return top - (top - bottom) * ease(f / downstroke)
        }
        return bottom + (top - bottom) * ease((f - downstroke) / (1 - downstroke))
    }

    /// How far the wings are through their fall, 0 at the top of the stroke
    /// and 1 at the bottom: the body rises by this share of its bob, because
    /// the downstroke carries the weight.
    public static func lift(phase: Double) -> Double {
        (top - angle(phase: phase)) / (top - bottom)
    }

    /// The body's pitch `phase` beats from the top as a share of its swing,
    /// from -1 to 1: it oscillates once a beat, a quarter beat behind the
    /// wings, lowest near the middle of the downstroke and highest near the
    /// middle of the upstroke.
    public static func pitch(phase: Double) -> Double {
        let f = phase - phase.rounded(.down)
        if f < downstroke {
            return -sin(.pi * f / downstroke)
        }
        return sin(.pi * (f - downstroke) / (1 - downstroke))
    }

    /// ease is a smooth step from 0 to 1 over 0...1, flat at both ends.
    public static func ease(_ s: Double) -> Double {
        0.5 - 0.5 * cos(.pi * min(max(s, 0), 1))
    }
}

/// WingProjection is how one wing of the mark is drawn: a 3 by 3 projective
/// transform in the row-vector form of SwiftUI's `ProjectionTransform` (a
/// point (x, y, 1) times the matrix, then divided by the third coordinate),
/// in the mark's own coordinates, a `size` by `size` square with y down and
/// the hinge, the body, on its vertical centre line, the head at the top.
///
/// A wing point at distance u from the hinge, raised by its angle, lies
/// u cos(angle) out to its side and u sin(angle) above the wing plane. A
/// hindwing also swings forward as it rises (`FieldWings.hindSweep`). The
/// body then pitches nose up by `pitch`, rolls about its long axis by
/// `turn` times `FieldWings.sideRoll` and turns its head across the screen
/// by `turn` times 90 degrees. The camera looks from above and a little
/// behind: a point's height moves it up the screen by `FieldWings.rise`
/// and nearer by `FieldWings.depth`. Side-on, the drawing is stretched to
/// fill the same box the perched mark (`FoldedButterfly`) fills
/// (`Perch.sideFill`), so wings closed over the back at a full turn and no
/// pitch draw exactly that mark, its body on the centre line; turned part
/// way, the stretch follows the cube of the turn, so a three-quarter view
/// keeps nearly the mark's own proportions. At level, unturned and
/// unpitched it is the identity, the flat mark.
public struct WingProjection: Equatable, Sendable {
    public let m11: Double, m12: Double, m13: Double
    public let m21: Double, m22: Double, m23: Double
    public let m31: Double, m32: Double, m33: Double

    /// The transform for the left (`left`) or right half of a mark `size`
    /// points square with its wing at `angle` degrees, seen from above.
    public static func of(angle: Double, left: Bool, size: Double) -> WingProjection {
        of(angle: angle, left: left, size: size, turn: 0, pitch: 0, hind: false)
    }

    /// The transform for one wing, left (`left`) or right and fore or hind
    /// (`hind`), at `angle` degrees, with the body at `pitch` degrees and
    /// `turn` toward its side.
    public static func of(angle: Double, left: Bool, size: Double, turn: Double, pitch: Double, hind: Bool) -> WingProjection {
        let theta = angle * .pi / 180, q = pitch * .pi / 180
        let roll = turn * FieldWings.sideRoll * .pi / 180, yaw = -turn * .pi / 2
        let c = size / 2
        // Each quantity is affine in the mark point: (x, y, 1) dotted with it.
        let dx = Affine(x: 1, y: 0, k: -c), dy = Affine(x: 0, y: 1, k: -c)
        let out = dx * cos(theta)
        let up = dx * ((left ? -1 : 1) * sin(theta))
        let sweep = hind ? FieldWings.hindSweep * size * pow(max(0, sin(theta)), 2) * (1 - abs(turn)) : 0
        let along = dy * -1 + Affine(x: 0, y: 0, k: sweep)
        // Pitch about the side axis, roll about the body, yaw about the vertical.
        let b1 = along * cos(q) - up * sin(q), u1 = along * sin(q) + up * cos(q)
        let l2 = out * cos(roll) - u1 * sin(roll), u2 = out * sin(roll) + u1 * cos(roll)
        let screenX = l2 * cos(yaw) - b1 * sin(yaw)
        let screenUp = l2 * sin(yaw) + b1 * cos(yaw) + u2 * FieldWings.rise
        let side = pow(abs(turn), 3)
        let profileGain = sin(FieldWings.sideRoll * .pi / 180) + FieldWings.rise * cos(FieldWings.sideRoll * .pi / 180)
        let gx = 1 + (Perch.sideFill.x - 1) * side
        let gy = 1 + (Perch.sideFill.y / profileGain - 1) * side
        let w = Affine(x: 0, y: 0, k: 1) - u2 * (FieldWings.depth * (1 - abs(turn)) / size)
        let sx = w * c + screenX * gx
        let sy = w * c - screenUp * gy
        return WingProjection(m11: sx.x, m12: sy.x, m13: w.x,
                              m21: sx.y, m22: sy.y, m23: w.y,
                              m31: sx.k, m32: sy.k, m33: w.k)
    }

    /// Where the point (`x`, `y`) of the mark is drawn.
    public func apply(x: Double, y: Double) -> (x: Double, y: Double) {
        let w = x * m13 + y * m23 + m33
        return ((x * m11 + y * m21 + m31) / w, (x * m12 + y * m22 + m32) / w)
    }

    /// Affine is a quantity affine in the mark point, x * `x` + y * `y` + `k`.
    struct Affine {
        let x: Double, y: Double, k: Double
        static func * (a: Affine, s: Double) -> Affine { Affine(x: a.x * s, y: a.y * s, k: a.k * s) }
        static func + (a: Affine, b: Affine) -> Affine { Affine(x: a.x + b.x, y: a.y + b.y, k: a.k + b.k) }
        static func - (a: Affine, b: Affine) -> Affine { a + b * -1 }
    }
}

/// FieldLanding is one visit to a flower: when it starts, which
/// flower, which way the butterfly faces on it (1 head right, -1 head
/// left), the way it was flying when it set off for it, and how long its
/// approach and its departure take, each set by its distance at a gentle
/// pace (`FieldFlight.pace`), so a far flower takes longer, never faster.
public struct FieldLanding: Equatable, Sendable {
    /// When the visit starts on the loop's clock, into its lap.
    public let start: TimeInterval
    /// When the visit starts on the wall clock, into the cycle.
    public let at: TimeInterval
    public let flower: Int
    public let facing: Double
    public let approach: TimeInterval
    public let depart: TimeInterval

    /// The whole visit, from leaving the loop to rejoining it.
    public var length: TimeInterval { approach + FieldFlight.fold + FieldFlight.rest + depart }
    /// When it touches down, into the visit.
    public var touchdown: TimeInterval { approach }
    /// When it takes off, into the visit.
    public var takeOff: TimeInterval { approach + FieldFlight.fold + FieldFlight.rest }
}

/// FieldFlight is the field the Alerts tab rests in when nothing is wrong
/// and the butterfly's flight over it, as pure functions of the time so the
/// view only samples them and a time always gives the same pose. The field
/// is a gentle hill line with a few flowers on it. The flight follows a
/// slow figure of eight above the flowers, one lap in `period`, that slows,
/// dips and turns near two of them; on it the butterfly flutters, after
/// recordings of real flight: the wingbeat rate drifts, every downstroke
/// lifts the body and pitches it, small irregular hops ride on the path,
/// and now and then it glides with the wings held partly open, sinking a
/// little. It is turned the way it travels: in side profile, facing ahead,
/// when it moves across the field, and seen from above when it hovers or
/// moves mostly up or down (`flightTurn(at:)`). Twice a lap it
/// visits a flower (`visits`, a different flower each time
/// over a `cycle` of laps, set off where the loop passes nearest it): it
/// flies to the flower's head at a gentle pace, slowing to a stop, brakes
/// with quick shallow beats and its nose up, turns side-on, lands with its
/// feet on the flower, closes its wings over its back, rests, slowly opens
/// and closes them once, and takes off with a burst of quick beats,
/// gathering speed back into the loop. Its body's path is smooth at every
/// change: the flight to and from the flower is a curve that leaves and
/// rejoins the loop's own path with the same velocity and acceleration,
/// and starts and ends on the flower at rest, so it is never faster than
/// ordinary flight. The loop keeps its own clock (`loopTime(at:)`), which
/// waits while the butterfly is away: it leaves the loop where the loop
/// passes nearest the flower and rejoins it at that same point, carrying
/// on along it, so it never has to chase the loop. Every term repeats over
/// the cycle, the loop's laps and the visits together. Under Reduce Motion
/// the butterfly perches on the tallest flower instead and does not move.
public enum FieldFlight {
    /// One lap of the loop, in seconds.
    public static let period: TimeInterval = 24
    /// How many laps the flower visits take to repeat.
    public static let laps = 3
    /// The whole flight repeats every `cycle` seconds: the laps of the loop
    /// and every visit, during which the loop waits.
    public static let cycle: TimeInterval = period * Double(laps) + schedule.reduce(0) { $0 + $1.landing.length }
    /// The mean wingbeat, in seconds; the rate drifts about 25 % either way.
    /// `period` holds a whole number of mean beats, so a lap ends on the
    /// beat it started on.
    public static let beatPeriod: TimeInterval = 0.3
    /// The most the butterfly leans into a turn, in degrees.
    public static let maxTilt: Double = 16
    /// The most the body pitches on a beat, in degrees.
    public static let maxPitch: Double = 6
    /// How far the nose comes up to brake before landing, in degrees.
    public static let flare: Double = 12
    /// How far the body rises on a downstroke, as a fraction of the field's height.
    public static let bob: Double = 0.016
    /// How far it sinks in a glide, as a fraction of the field's height.
    public static let sink: Double = 0.03
    /// The glides in a lap: when each one is held from, and for how long,
    /// in seconds. The wings settle into and out of each over `glideEase`.
    public static let glides: [(start: TimeInterval, length: TimeInterval)] = [
        (1.0, 0.5), (13.0, 0.6), (21.4, 0.45),
    ]
    /// How long the wings take to settle into a glide and to start beating
    /// again, in seconds.
    public static let glideEase: TimeInterval = 0.2
    /// How the butterfly is turned follows the way its body travels: in
    /// side profile, facing ahead, when it moves mostly across the field,
    /// and seen from above when it hovers or moves mostly up or down. The
    /// share of its speed that is across the field turns it: none of the
    /// way at `sideShare.from` or less, all the way at `sideShare.to` or
    /// more. Below `stillSpeed` (field heights a second) it counts as
    /// hovering. The turn is smoothed over `turnSmoothing` seconds, so a
    /// hop or a brief change of direction never flips it.
    public static let sideShare = (from: 0.4, to: 0.85)
    public static let stillSpeed: Double = 0.1
    public static let turnSmoothing: TimeInterval = 0.5
    /// How long before touchdown it settles fully side-on to land, and how
    /// long after take-off it is free to turn with its flight again.
    public static let settleSide: TimeInterval = 0.8
    /// The flower visits of each lap of the cycle: when each starts in its
    /// lap and the flower. Each starts where the loop passes nearest its
    /// flower, so the flight to it is short, and every flower is visited
    /// once a cycle.
    public static let visits: [[(start: TimeInterval, flower: Int)]] = [
        [(0.2, 3), (15.67, 0)], [(4.07, 4), (13.68, 1)], [(4.51, 5), (11.44, 2)],
    ]
    /// Scheduled is one planned visit: the visit, when it leaves the loop
    /// on the loop's clock (from the start of the cycle), and the loop's
    /// path there with its velocity and acceleration, where it leaves the
    /// loop and where it rejoins it.
    struct Scheduled {
        let landing: FieldLanding
        let leave: TimeInterval
        let handoff: Motion
    }

    /// Every visit, planned once, in order through the cycle.
    static let schedule: [Scheduled] = {
        var out: [Scheduled] = []
        var away = 0.0
        for (lap, list) in visits.enumerated() {
            for visit in list {
                let leave = Double(lap) * period + visit.start
                let landing = plan(leave: leave, inLap: visit.start, at: leave + away, flower: visit.flower)
                out.append(Scheduled(landing: landing, leave: leave, handoff: Motion(of: track, at: leave)))
                away += landing.length
            }
        }
        return out
    }()

    /// The scene's usual width over its height: how far one unit across the
    /// field is against one unit down it, for distances and speeds.
    public static let aspect: Double = 3.3
    /// The mean speed of the flight to a flower and back to the loop, in
    /// field heights a second: about a third of the loop's fastest, so with
    /// the slow start and stop of the curve its peak stays below ordinary
    /// flight.
    public static let pace: Double = 0.22
    /// A visit's parts, in seconds: the approach to the flower (at least
    /// `shortestApproach`, longer for a farther flower; the last `brake` of
    /// it in quick shallow beats with the nose up), the wings closing after
    /// touchdown (`fold`), the rest on the flower (`rest`, with one slow
    /// open-and-close of `openClose` starting `openAt` into it, the wings
    /// opening down to `openAngle`), and the departure back to the loop (at
    /// least `shortestDepart`; the first `burst` of it in quick beats).
    public static let shortestApproach: TimeInterval = 1.4
    public static let brake: TimeInterval = 0.5
    public static let fold: TimeInterval = 0.3
    public static let rest: TimeInterval = 3.0
    public static let openAt: TimeInterval = 0.8
    public static let openClose: TimeInterval = 1.6
    public static let openAngle: Double = 35
    public static let shortestDepart: TimeInterval = 1.2
    public static let burst: TimeInterval = 0.6
    /// The quick beat of braking and take-off, in seconds.
    public static let quickBeat: TimeInterval = 0.16
    /// Where the ground lies, as a fraction of the field's height from the top.
    public static let ground: Double = 0.82
    /// The flowers: each one's x and its height above the ground, both as
    /// fractions of the field.
    public static let flowers: [(x: Double, height: Double)] = [
        (0.12, 0.10), (0.27, 0.16), (0.44, 0.09), (0.63, 0.22), (0.78, 0.12), (0.91, 0.08),
    ]
    /// The flower the butterfly perches on under Reduce Motion: the tallest.
    public static let perch = 3

    /// The hill line's height above `ground` at `x`, a fraction of the
    /// field's height: two long, low swells.
    public static func hill(at x: Double) -> Double {
        0.035 * sin(2 * .pi * (x * 1.3 + 0.1)) + 0.02 * sin(2 * .pi * x * 0.55)
    }

    /// The top of flower `index`, where a perched butterfly's feet are.
    public static func flowerTop(_ index: Int) -> (x: Double, y: Double) {
        let flower = flowers[index]
        return (flower.x, ground - hill(at: flower.x) - flower.height)
    }

    /// How many beats the wings have made at `now` on the loop's clock:
    /// the mean rate with two slow drifts on it, integrated, so the rate
    /// changes smoothly and never stops.
    public static func beatPhase(at now: TimeInterval) -> Double {
        let w1 = 2 * .pi * 7 / period, w2 = 2 * .pi * 19 / period
        return (now - 0.16 / w1 * cos(w1 * now) - 0.09 / w2 * cos(w2 * now + 1.3)) / beatPeriod
    }

    /// How much the wings are beating at `now` on the loop's clock: 1 in flapping
    /// flight, 0 held in a glide, easing between the two.
    public static func flapping(at now: TimeInterval) -> Double {
        let t = lapTime(now)
        var held = 0.0
        for glide in glides {
            held = max(held, window(t, start: glide.start, hold: glide.length, ease: glideEase))
        }
        return 1 - held
    }

    /// The flower visit under way `now`, with the time into it, or nil in
    /// the loop.
    public static func landing(at now: TimeInterval) -> (landing: FieldLanding, into: TimeInterval)? {
        clock(now).visit.map { ($0.visit.landing, $0.into) }
    }

    /// The loop's clock `now`: the time the loop has flown, which waits
    /// while the butterfly is away on a visit.
    public static func loopTime(at now: TimeInterval) -> TimeInterval {
        clock(now).loop
    }

    /// clock is where `now` falls in the cycle: the loop's clock, and the
    /// visit under way with the time into it, if any.
    static func clock(_ now: TimeInterval) -> (loop: TimeInterval, visit: (visit: Scheduled, into: TimeInterval)?) {
        let wall = now - (now / cycle).rounded(.down) * cycle
        var away = 0.0
        for visit in schedule {
            if wall < visit.landing.at { break }
            if wall < visit.landing.at + visit.landing.length {
                return (visit.leave, (visit, wall - visit.landing.at))
            }
            away += visit.landing.length
        }
        return (wall - away, nil)
    }

    /// plan is the visit to `flower` that leaves the loop at `leave` on the
    /// loop's clock (`inLap` into its lap) and at `at` on the wall clock:
    /// which way it faces, and how long the flight there and the flight
    /// back take at `pace`, each at least its shortest. It rejoins the loop
    /// where it left it, so both flights cover the same distance.
    static func plan(leave: TimeInterval, inLap: TimeInterval, at: TimeInterval, flower: Int) -> FieldLanding {
        let top = flowerTop(flower)
        let leaving = track(at: leave)
        let far = distance(leaving, top) / pace
        return FieldLanding(start: inLap, at: at, flower: flower, facing: top.x >= leaving.x ? 1 : -1,
                            approach: max(shortestApproach, far), depart: max(shortestDepart, far))
    }

    /// The distance between two field points, in field heights.
    static func distance(_ a: (x: Double, y: Double), _ b: (x: Double, y: Double)) -> Double {
        hypot((a.x - b.x) * aspect, a.y - b.y)
    }

    /// The pose `now` seconds into the flight; perched and still under
    /// `reduceMotion`.
    public static func pose(at now: TimeInterval, reduceMotion: Bool) -> FieldPose {
        if reduceMotion {
            let top = flowerTop(perch)
            return FieldPose(x: top.x, y: top.y, beat: 0, hindBeat: 0, pitch: 0, tilt: 0, turn: 0, perched: true, folded: true)
        }
        let (loopTime, visit) = clock(now)
        guard let (scheduled, into) = visit else {
            let loop = cruise(at: loopTime)
            let turn = flightTurn(at: now)
            return FieldPose(x: loop.x, y: loop.y, beat: loop.beat, hindBeat: loop.hind, pitch: loop.pitch,
                             tilt: loop.tilt * (1 - 0.6 * abs(turn)), turn: turn, perched: false, folded: false)
        }
        let landing = scheduled.landing
        let touchdown = landing.touchdown, takeOff = landing.takeOff
        // The loop's clock as the wings and the bob see it: running on from
        // where it left the loop on the way to the flower, and running up to
        // where it rejoins on the way back, so both carry on without a break.
        let flown = into < takeOff ? scheduled.leave + into : scheduled.leave - (landing.length - into)
        let loop = cruise(at: flown)
        let (path, there) = body(at: now)
        // The loop's bob fades out on the way to the flower and back in on the way back.
        let place = (x: path.x, y: path.y + bobbing(at: flown) * (1 - there))
        // It turns with its flight, settling side-on, facing the flower's way,
        // just before touchdown, and holds that until it has taken off.
        let free = flightTurn(at: now)
        let held = into < touchdown ? smooth((into - (touchdown - settleSide)) / settleSide)
            : into < takeOff ? 1 : 1 - smooth((into - takeOff) / settleSide)
        let turn = into >= touchdown && into < takeOff ? landing.facing : free + (landing.facing - free) * held

        func wings(lag: Double) -> Double {
            if into < takeOff {
                let braking = into < touchdown - brake ? 0 : FieldWings.ease((into - (touchdown - brake)) / 0.15)
                let quick = 85 - 70 * FieldWings.lift(phase: (into - (touchdown - brake)) / quickBeat - lag)
                let closing = into < touchdown ? 0 : FieldWings.ease((into - touchdown) / fold)
                let flying = lag == 0 ? loop.beat : loop.hind
                let beat = flying + (quick - flying) * braking
                let resting = FieldWings.closed - (FieldWings.closed - openAngle)
                    * pow(sin(.pi * min(max((into - touchdown - fold - openAt) / openClose, 0), 1)), 2)
                return closing < 1 ? beat + (FieldWings.closed - beat) * closing : resting
            }
            let up = into - takeOff
            let opening = FieldWings.ease(up / 0.1)
            let quick = FieldWings.angle(phase: up / quickBeat - lag)
            let rejoin = FieldWings.ease((up - burst) / 0.3)
            let flying = lag == 0 ? loop.beat : loop.hind
            let beat = FieldWings.closed + (quick - FieldWings.closed) * opening
            return beat + (flying - beat) * rejoin
        }
        let beat = wings(lag: 0), hind = wings(lag: FieldWings.hindLag)
        let perched = into >= touchdown && into < takeOff
        let flaring = into < touchdown
            ? FieldWings.ease((into - (touchdown - brake)) / (brake / 2)) * (1 - FieldWings.ease((into - touchdown + 0.1) / 0.1))
            : 0
        let settled = into < touchdown ? 0 : into < takeOff ? 1 : 1 - FieldWings.ease((into - takeOff) / 0.4)
        let pitch = loop.pitch * (1 - settled) * (1 - there) * (1 - flaring) + flare * flaring
        return FieldPose(x: place.x, y: place.y,
                         beat: beat, hindBeat: hind, pitch: pitch,
                         tilt: loop.tilt * (1 - there) * (1 - 0.6 * abs(turn)), turn: turn,
                         perched: perched, folded: perched && beat >= FieldWings.closed && hind >= FieldWings.closed)
    }

    /// Cruise is the butterfly in the loop: its body's place, its wings,
    /// pitch, and its lean before any turn eases it.
    struct Cruise {
        let x: Double, y: Double, beat: Double, hind: Double, pitch: Double, tilt: Double
    }

    /// The butterfly in the loop at `now` on the loop's clock.
    static func cruise(at now: TimeInterval) -> Cruise {
        let tau = 2 * .pi * now / period
        // The loop's own time runs slow twice a lap, near the flowers at x
        // 0.27 and 0.78, where the butterfly hangs, dips and turns.
        let warp = 2 * tau + 1.6
        let psi = tau + 0.32 * sin(warp)
        let speed = 1 + 0.64 * cos(warp)
        let lingering = max(0, -cos(warp))
        let place = track(at: now)

        let flap = flapping(at: now)
        let phase = beatPhase(at: now)
        let beat = flap * FieldWings.angle(phase: phase) + (1 - flap) * FieldWings.glide
        let hind = flap * FieldWings.angle(phase: phase - FieldWings.hindLag) + (1 - flap) * FieldWings.glide

        let lean = 0.75 * cos(psi) * speed / 1.64
        let wobble = 0.4 * lingering * sin(2 * .pi * now / 1.5)
        let tilt = maxTilt * min(max(lean + wobble, -1), 1)
        return Cruise(x: place.x, y: place.y + bobbing(at: now), beat: beat, hind: hind,
                      pitch: maxPitch * flap * FieldWings.pitch(phase: phase), tilt: tilt)
    }

    /// The body's path `now`, without the bob of each wingbeat: the loop's
    /// path, or on a visit the curve to the flower, the flower, and the
    /// curve back; with how far it is from the loop toward the flower
    /// (`there`, 0 in the loop, 1 on the flower).
    static func body(at now: TimeInterval) -> (path: (x: Double, y: Double), there: Double) {
        let (loopTime, visit) = clock(now)
        guard let (scheduled, into) = visit else { return (track(at: loopTime), 0) }
        let landing = scheduled.landing, leave = scheduled.handoff, rejoin = scheduled.handoff
        let flower = flowerTop(landing.flower)
        if into < landing.touchdown {
            let u = into / landing.touchdown
            return (Motion.hermite(from: leave, to: Motion(resting: flower), over: landing.touchdown, u), smooth(u))
        }
        if into < landing.takeOff { return (flower, 1) }
        let u = (into - landing.takeOff) / landing.depart
        return (Motion.hermite(from: Motion(resting: flower), to: rejoin, over: landing.depart, u), 1 - smooth(u))
    }

    /// How the body's travel `now` turns it, before smoothing: toward side
    /// profile facing the way it moves, by the share of its speed that is
    /// across the field, and seen from above when it hovers or moves mostly
    /// up or down.
    static func headingTurn(at now: TimeInterval) -> Double {
        // Its travel over the 0.24 s around `now`, so neither the bob nor a
        // hop turns it.
        let h = 0.12
        let before = body(at: now - h).path, after = body(at: now + h).path
        let vx = (after.x - before.x) * aspect / (2 * h), vy = (after.y - before.y) / (2 * h)
        let share = abs(vx) / max(hypot(vx, vy), stillSpeed)
        let side = smooth((share - sideShare.from) / (sideShare.to - sideShare.from))
        return vx >= 0 ? side : -side
    }

    /// The turn `now`: `headingTurn` averaged over `turnSmoothing` seconds
    /// centred on `now`, weighted by a raised cosine, so it changes smoothly
    /// and never faster than the window allows.
    static func flightTurn(at now: TimeInterval) -> Double {
        let taps = 9
        var sum = 0.0, weights = 0.0
        for k in 0..<taps {
            let w = pow(sin(.pi * Double(k + 1) / Double(taps + 1)), 2)
            sum += w * headingTurn(at: now + turnSmoothing * (Double(k) / Double(taps - 1) - 0.5))
            weights += w
        }
        return sum / weights
    }

    /// The loop's path at `now` on the loop's clock, without the bob of
    /// each wingbeat: the figure of eight, the dips near flowers, the hops
    /// and the sink of a glide.
    static func track(at now: TimeInterval) -> (x: Double, y: Double) {
        let tau = 2 * .pi * now / period
        let warp = 2 * tau + 1.6
        let psi = tau + 0.32 * sin(warp)
        let lingering = max(0, -cos(warp))
        let dip = 0.035 * lingering * lingering
        let hops = 0.016 * sin(11 * tau + 0.7) + 0.01 * sin(23 * tau + 2.1) + 0.006 * sin(37 * tau + 0.4)
        return (0.5 + 0.36 * sin(psi), 0.31 + 0.1 * sin(2 * psi) + dip + hops + sink * (1 - flapping(at: now)))
    }

    /// How far the body is lifted by the wingbeat at `now` on the loop's clock, as a fraction of
    /// the field's height (negative is up): it rises as the wings come down.
    static func bobbing(at now: TimeInterval) -> Double {
        -bob * flapping(at: now) * FieldWings.lift(phase: beatPhase(at: now))
    }

    /// Motion is a point of a path with its velocity and acceleration, in
    /// field units and seconds.
    struct Motion {
        let p: (x: Double, y: Double), v: (x: Double, y: Double), a: (x: Double, y: Double)

        /// At rest at `point`.
        init(resting point: (x: Double, y: Double)) {
            p = point; v = (0, 0); a = (0, 0)
        }

        /// The path `f` at `time`, its derivatives by central differences.
        init(of f: (TimeInterval) -> (x: Double, y: Double), at time: TimeInterval) {
            let h = 1e-3
            let before = f(time - h), here = f(time), after = f(time + h)
            p = here
            v = ((after.x - before.x) / (2 * h), (after.y - before.y) / (2 * h))
            a = ((after.x - 2 * here.x + before.x) / (h * h), (after.y - 2 * here.y + before.y) / (h * h))
        }

        /// The quintic Hermite curve from `start` to `end` over `duration`
        /// seconds, at `u` of the way (0 to 1): it leaves and arrives with
        /// each end's velocity and acceleration, so a hand-off between the
        /// loop, the curve and the flower never jumps in place, speed or
        /// acceleration.
        static func hermite(from start: Motion, to end: Motion, over duration: TimeInterval, _ u: Double) -> (x: Double, y: Double) {
            let u2 = u * u, u3 = u2 * u, u4 = u3 * u, u5 = u4 * u
            let h0 = 1 - 10 * u3 + 15 * u4 - 6 * u5, h5 = 10 * u3 - 15 * u4 + 6 * u5
            let h1 = u - 6 * u3 + 8 * u4 - 3 * u5, h4 = -4 * u3 + 7 * u4 - 3 * u5
            let h2 = 0.5 * u2 - 1.5 * u3 + 1.5 * u4 - 0.5 * u5, h3 = 0.5 * u3 - u4 + 0.5 * u5
            let d = duration, d2 = duration * duration
            func mix(_ p0: Double, _ v0: Double, _ a0: Double, _ p1: Double, _ v1: Double, _ a1: Double) -> Double {
                h0 * p0 + h1 * d * v0 + h2 * d2 * a0 + h3 * d2 * a1 + h4 * d * v1 + h5 * p1
            }
            return (mix(start.p.x, start.v.x, start.a.x, end.p.x, end.v.x, end.a.x),
                    mix(start.p.y, start.v.y, start.a.y, end.p.y, end.v.y, end.a.y))
        }
    }

    /// smooth is a step from 0 to 1 over 0...1 with no velocity or
    /// acceleration at either end.
    static func smooth(_ s: Double) -> Double {
        let c = min(max(s, 0), 1)
        return c * c * c * (c * (6 * c - 15) + 10)
    }

    /// The lap of the cycle `now` falls in.
    static func lapIndex(_ now: TimeInterval) -> Int {
        let lap = Int((now / period).rounded(.down)) % laps
        return lap < 0 ? lap + laps : lap
    }

    /// The time into the current lap.
    static func lapTime(_ now: TimeInterval) -> TimeInterval {
        now - (now / period).rounded(.down) * period
    }

    /// window is 1 from `start` for `hold` seconds, easing up over the
    /// `ease` seconds before and down over the `ease` seconds after with no
    /// jolt at either end (`smooth`), and 0 elsewhere.
    static func window(_ t: TimeInterval, start: TimeInterval, hold: TimeInterval, ease: TimeInterval) -> Double {
        min(smooth((t - start + ease) / ease), smooth((start + hold + ease - t) / ease))
    }
}
