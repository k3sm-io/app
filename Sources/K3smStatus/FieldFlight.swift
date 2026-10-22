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

/// FieldLanding is one visit to a flower: when it starts in the lap, which
/// flower, and which way the butterfly faces on it (1 head right, -1 head
/// left), the way it was flying when it set off for it.
public struct FieldLanding: Equatable, Sendable {
    public let start: TimeInterval
    public let flower: Int
    public let facing: Double
}

/// FieldFlight is the field the Alerts tab rests in when nothing is wrong
/// and the butterfly's flight over it, as pure functions of the time so the
/// view only samples them and a time always gives the same pose. The field
/// is a gentle hill line with a few flowers on it. The flight follows a
/// slow figure of eight above the flowers, one lap in `period`, that slows,
/// dips and turns near two of them; on it the butterfly flutters, after
/// recordings of real flight: the wingbeat rate drifts, every downstroke
/// lifts the body and pitches it, small irregular hops ride on the path,
/// now and then it glides with the wings held partly open, sinking a
/// little, and once a lap it turns to show its side for a moment. Once or
/// twice a lap it visits a flower (`landings`, a different flower each
/// time over a `cycle` of laps): it flies to the flower's head, brakes with
/// quick shallow beats and its nose up, turns side-on, lands with its feet
/// on the flower, closes its wings over its back, rests, slowly opens and
/// closes them once, and takes off with a burst of quick beats back into
/// the loop. Every term repeats over the cycle. Under Reduce Motion the
/// butterfly perches on the tallest flower instead and does not move.
public enum FieldFlight {
    /// One lap of the loop, in seconds.
    public static let period: TimeInterval = 24
    /// How many laps the flower visits take to repeat.
    public static let laps = 3
    /// The whole flight repeats every `cycle` seconds.
    public static var cycle: TimeInterval { period * Double(laps) }
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
    /// The side-on turns in flight, one a lap: when each starts in its lap
    /// and how far it turns (1 fully side-on, less a three-quarter view).
    /// It turns the way it is flying.
    public static let turns: [(start: TimeInterval, depth: Double)] = [(16.5, 1), (11.0, 0.7), (2.0, 0.85)]
    /// A turn's ease in and out, and how long it holds between, in seconds.
    public static let turnEase: TimeInterval = 0.6
    public static let turnHold: TimeInterval = 1.0
    /// The flower visits of each lap of the cycle: when each starts in its
    /// lap and the flower.
    public static let visits: [[(start: TimeInterval, flower: Int)]] = [
        [(6.0, 3)], [(3.0, 1), (15.0, 4)], [(9.0, 2), (17.0, 5)],
    ]
    /// A visit's parts, in seconds: the approach to the flower (`approach`,
    /// the last `brake` of it in quick shallow beats with the nose up), the
    /// wings closing after touchdown (`fold`), the rest on the flower
    /// (`rest`, with one slow open-and-close of `openClose` starting
    /// `openAt` into it, the wings opening down to `openAngle`), and the
    /// departure back to the loop (`depart`, the first `burst` of it in
    /// quick beats).
    public static let approach: TimeInterval = 1.4
    public static let brake: TimeInterval = 0.5
    public static let fold: TimeInterval = 0.3
    public static let rest: TimeInterval = 3.0
    public static let openAt: TimeInterval = 0.8
    public static let openClose: TimeInterval = 1.6
    public static let openAngle: Double = 35
    public static let depart: TimeInterval = 1.2
    public static let burst: TimeInterval = 0.6
    /// The quick beat of braking and take-off, in seconds.
    public static let quickBeat: TimeInterval = 0.16
    /// A whole visit, from leaving the loop to rejoining it.
    public static var visit: TimeInterval { approach + fold + rest + depart }
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

    /// How many beats the wings have made `now` seconds into the flight:
    /// the mean rate with two slow drifts on it, integrated, so the rate
    /// changes smoothly and never stops.
    public static func beatPhase(at now: TimeInterval) -> Double {
        let w1 = 2 * .pi * 7 / period, w2 = 2 * .pi * 19 / period
        return (now - 0.16 / w1 * cos(w1 * now) - 0.09 / w2 * cos(w2 * now + 1.3)) / beatPeriod
    }

    /// How much the wings are beating `now` in the loop: 1 in flapping
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
        let lap = Int((now / period).rounded(.down)) % laps
        let index = lap < 0 ? lap + laps : lap
        let t = lapTime(now)
        for visit in visits[index] where t >= visit.start && t < visit.start + self.visit {
            let leaving = cruise(at: now - (t - visit.start))
            let facing: Double = flowers[visit.flower].x >= leaving.x ? 1 : -1
            return (FieldLanding(start: visit.start, flower: visit.flower, facing: facing), t - visit.start)
        }
        return nil
    }

    /// The pose `now` seconds into the flight; perched and still under
    /// `reduceMotion`.
    public static func pose(at now: TimeInterval, reduceMotion: Bool) -> FieldPose {
        if reduceMotion {
            let top = flowerTop(perch)
            return FieldPose(x: top.x, y: top.y, beat: 0, hindBeat: 0, pitch: 0, tilt: 0, turn: 0, perched: true, folded: true)
        }
        let loop = cruise(at: now)
        guard let (landing, into) = landing(at: now) else {
            return FieldPose(x: loop.x, y: loop.y, beat: loop.beat, hindBeat: loop.hind, pitch: loop.pitch,
                             tilt: loop.tilt, turn: loop.turn, perched: false, folded: false)
        }
        let flower = flowerTop(landing.flower)
        let touchdown = approach, takeOff = approach + fold + rest
        // How far it has left the loop for the flower.
        let there = into < touchdown ? FieldWings.ease(into / approach)
            : into < takeOff ? 1 : 1 - FieldWings.ease((into - takeOff) / depart)
        // How far it has turned side-on, facing the flower's way.
        let side = into < touchdown ? FieldWings.ease((into - 0.2) / (approach - 0.4))
            : into < takeOff ? 1 : 1 - FieldWings.ease((into - takeOff) / depart)
        let turn = loop.turn + (landing.facing - loop.turn) * side

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
        let flaring = into < touchdown ? FieldWings.ease((into - (touchdown - brake)) / brake) * (1 - FieldWings.ease((into - touchdown + 0.1) / 0.1))
            : 0
        let settled = into < touchdown ? 0 : into < takeOff ? 1 : 1 - FieldWings.ease((into - takeOff) / 0.4)
        let pitch = loop.pitch * (1 - settled) * (1 - there) + flare * flaring
        return FieldPose(x: loop.x + (flower.x - loop.x) * there, y: loop.y + (flower.y - loop.y) * there,
                         beat: beat, hindBeat: hind, pitch: pitch, tilt: loop.tilt * (1 - there), turn: turn,
                         perched: perched, folded: perched && beat >= FieldWings.closed && hind >= FieldWings.closed)
    }

    /// Cruise is the butterfly in the loop: its body's place, its wings,
    /// pitch, lean and turn.
    struct Cruise {
        let x: Double, y: Double, beat: Double, hind: Double, pitch: Double, tilt: Double, turn: Double
    }

    /// The butterfly in the loop `now` seconds into the flight.
    static func cruise(at now: TimeInterval) -> Cruise {
        let tau = 2 * .pi * now / period
        // The loop's own time runs slow twice a lap, near the flowers at x
        // 0.27 and 0.78, where the butterfly hangs, dips and turns.
        let warp = 2 * tau + 1.6
        let psi = tau + 0.32 * sin(warp)
        let speed = 1 + 0.64 * cos(warp)
        let lingering = max(0, -cos(warp))
        let x = 0.5 + 0.36 * sin(psi)
        let loop = 0.31 + 0.1 * sin(2 * psi)
        let dip = 0.035 * lingering * lingering
        let hops = 0.016 * sin(11 * tau + 0.7) + 0.01 * sin(23 * tau + 2.1) + 0.006 * sin(37 * tau + 0.4)

        let flap = flapping(at: now)
        let phase = beatPhase(at: now)
        let beat = flap * FieldWings.angle(phase: phase) + (1 - flap) * FieldWings.glide
        let hind = flap * FieldWings.angle(phase: phase - FieldWings.hindLag) + (1 - flap) * FieldWings.glide
        let y = loop + dip + hops + sink * (1 - flap) - bob * flap * FieldWings.lift(phase: phase)

        // Once a lap it turns to show its side, the way it is flying.
        let lap = Int((now / period).rounded(.down)) % laps
        let sideways = turns[lap < 0 ? lap + laps : lap]
        let middle = now - lapTime(now) + sideways.start + turnEase + turnHold / 2
        let heading: Double = cos(2 * .pi * middle / period + 0.32 * sin(4 * .pi * middle / period + 1.6)) >= 0 ? 1 : -1
        let turn = heading * sideways.depth * window(lapTime(now), start: sideways.start + turnEase, hold: turnHold, ease: turnEase)

        let lean = 0.75 * cos(psi) * speed / 1.64
        let wobble = 0.4 * lingering * sin(2 * .pi * now / 1.5)
        let tilt = maxTilt * min(max(lean + wobble, -1), 1) * (1 - 0.6 * abs(turn))
        return Cruise(x: x, y: y, beat: beat, hind: hind, pitch: maxPitch * flap * FieldWings.pitch(phase: phase),
                      tilt: tilt, turn: turn)
    }

    /// The time into the current lap.
    static func lapTime(_ now: TimeInterval) -> TimeInterval {
        now - (now / period).rounded(.down) * period
    }

    /// window is 1 from `start` for `hold` seconds, easing up over the
    /// `ease` seconds before and down over the `ease` seconds after, and 0
    /// elsewhere.
    static func window(_ t: TimeInterval, start: TimeInterval, hold: TimeInterval, ease: TimeInterval) -> Double {
        min(FieldWings.ease((t - start + ease) / ease), FieldWings.ease((start + hold + ease - t) / ease))
    }
}
