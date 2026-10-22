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
/// in the field's unit square (x right, y down): its centre; its forewings'
/// and hindwings' hinge angles (`beat`, `hindBeat`), in degrees above level,
/// so 0 is the flat mark, a positive angle raises the wings over the back
/// and a negative one lowers them below the body; its pitch (`pitch`, nose
/// up positive) and its lean (`tilt`), in degrees; and whether it is
/// perched, drawn side-on and still.
public struct FieldPose: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let beat: Double
    public let hindBeat: Double
    public let pitch: Double
    public let tilt: Double
    public let perched: Bool
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
    /// The share of a beat the downstroke takes; the upstroke takes the rest.
    public static let downstroke: Double = 0.42
    /// How far the hindwings trail the forewings, in beats.
    public static let hindLag: Double = 0.07
    /// The angle the wings are held at in a glide, in degrees: partly open,
    /// in a shallow V.
    public static let glide: Double = 20
    /// How far up the screen a wing point rises per unit of its height
    /// above the wing plane: the tangent of the view's elevation behind the
    /// butterfly, so 0 is straight down from above.
    public static let rise: Double = 0.6
    /// How much nearer a raised wing point comes, per unit of its height
    /// above the wing plane over the mark's size: a little perspective, so
    /// a raised wing grows slightly and a lowered one shrinks.
    public static let depth: Double = 0.3

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

    /// ease is a smooth step from 0 to 1 over 0...1.
    static func ease(_ s: Double) -> Double {
        0.5 - 0.5 * cos(.pi * min(max(s, 0), 1))
    }
}

/// WingProjection is how one half of the mark is drawn with its wing at a
/// hinge angle: a 3 by 3 projective transform in the row-vector form of
/// SwiftUI's `ProjectionTransform` (a point (x, y, 1) times the matrix, then
/// divided by the third coordinate), in the mark's own coordinates, a
/// `size` by `size` square with y down and the hinge on its vertical centre
/// line. A wing point at distance u from the hinge, raised by `angle`, is
/// u cos(angle) from the hinge across the screen and u sin(angle) above
/// the wing plane, which moves it up the screen by `FieldWings.rise` times
/// that and nearer, by `FieldWings.depth`, about the mark's centre. At 0 it
/// is the identity, so the flat pose is exactly the mark.
public struct WingProjection: Equatable, Sendable {
    public let m11: Double, m12: Double, m13: Double
    public let m21: Double, m22: Double, m23: Double
    public let m31: Double, m32: Double, m33: Double

    /// The transform for the left (`left`) or right half of a mark `size`
    /// points square with its wing at `angle` degrees.
    public static func of(angle: Double, left: Bool, size: Double) -> WingProjection {
        let theta = angle * .pi / 180
        // A left-half point lies at u < 0 from the hinge; mirror the right.
        let side: Double = left ? 1 : -1
        let c = size / 2
        let a = side * FieldWings.depth / size * sin(theta)
        let b = side * FieldWings.rise * sin(theta)
        let mx = c * a + cos(theta)
        let my = c * a + b
        return WingProjection(m11: mx, m12: my, m13: a,
                              m21: 0, m22: 1, m23: 0,
                              m31: c - c * mx, m32: -c * my, m33: 1 - a * c)
    }

    /// Where the point (`x`, `y`) of the mark is drawn.
    public func apply(x: Double, y: Double) -> (x: Double, y: Double) {
        let w = x * m13 + y * m23 + m33
        return ((x * m11 + y * m21 + m31) / w, (x * m12 + y * m22 + m32) / w)
    }
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
/// little, before the next burst. Every term repeats over the lap. Under
/// Reduce Motion the butterfly perches on the tallest flower instead and
/// does not move.
public enum FieldFlight {
    /// One lap of the loop, in seconds.
    public static let period: TimeInterval = 18
    /// The mean wingbeat, in seconds; the rate drifts about 25 % either way.
    /// `period` holds a whole number of mean beats, so a lap ends on the
    /// beat it started on.
    public static let beatPeriod: TimeInterval = 0.3
    /// The most the butterfly leans into a turn, in degrees.
    public static let maxTilt: Double = 16
    /// The most the body pitches on a beat, in degrees.
    public static let maxPitch: Double = 6
    /// How far the body rises on a downstroke, as a fraction of the field's height.
    public static let bob: Double = 0.016
    /// How far it sinks in a glide, as a fraction of the field's height.
    public static let sink: Double = 0.03
    /// The glides in a lap: when each one is held from, and for how long,
    /// in seconds. The wings settle into and out of each over `glideEase`.
    public static let glides: [(start: TimeInterval, length: TimeInterval)] = [
        (4.2, 0.6), (8.1, 0.4), (14.2, 0.7), (16.7, 0.35),
    ]
    /// How long the wings take to settle into a glide and to start beating
    /// again, in seconds.
    public static let glideEase: TimeInterval = 0.2
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

    /// How much the wings are beating `now`: 1 in flapping flight, 0 held
    /// in a glide, easing between the two.
    public static func flapping(at now: TimeInterval) -> Double {
        let t = now - (now / period).rounded(.down) * period
        var held = 0.0
        for glide in glides {
            let into = FieldWings.ease((t - glide.start + glideEase) / glideEase)
            let out = FieldWings.ease((glide.start + glide.length + glideEase - t) / glideEase)
            held = max(held, min(into, out))
        }
        return 1 - held
    }

    /// The pose `now` seconds into the flight; perched and still under
    /// `reduceMotion`.
    public static func pose(at now: TimeInterval, reduceMotion: Bool) -> FieldPose {
        if reduceMotion {
            let top = flowerTop(perch)
            return FieldPose(x: top.x, y: top.y, beat: 0, hindBeat: 0, pitch: 0, tilt: 0, perched: true)
        }
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

        let lean = 0.75 * cos(psi) * speed / 1.64
        let turn = 0.4 * lingering * sin(2 * .pi * now / 1.5)
        let tilt = maxTilt * min(max(lean + turn, -1), 1)
        return FieldPose(x: x, y: y, beat: beat, hindBeat: hind,
                         pitch: maxPitch * flap * FieldWings.pitch(phase: phase), tilt: tilt, perched: false)
    }
}
