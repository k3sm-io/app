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

/// PerchPhase is where a tab's label mark is in its flight: coming down onto
/// the label, standing on it, or leaving.
public enum PerchPhase: Equatable, Sendable {
    case landing
    case perched
    case takingOff
}

/// PerchPose is the label mark at one moment: its offset from the perch in
/// points (`dx` right, `dy` down), its body's tilt in degrees (clockwise,
/// leaning to the right), how far its wings are open (`opening`, 0 folded
/// upright, 1 open), the wings' hinge angle in degrees (`beat`, 0 flat, as
/// the mark's flap draws it), its opacity, how far it is turned side-on
/// (`sideOn`, 0 the flight view, 1 seen from the side with its wings closed
/// together above its back) and the closed wings' parting (`closedBeat`,
/// degrees between the two wings, 0 closed).
public struct PerchPose: Equatable, Sendable {
    public let dx: Double
    public let dy: Double
    public let rotation: Double
    public let opening: Double
    public let beat: Double
    public let opacity: Double
    public let sideOn: Double
    public let closedBeat: Double

    public init(dx: Double, dy: Double, rotation: Double, opening: Double, beat: Double, opacity: Double,
                sideOn: Double = 0, closedBeat: Double = 0) {
        self.sideOn = sideOn
        self.closedBeat = closedBeat
        self.dx = dx
        self.dy = dy
        self.rotation = rotation
        self.opening = opening
        self.beat = beat
        self.opacity = opacity
    }

    /// The wing pair's horizontal scale: `Perch.folded` with the wings
    /// folded (the pair seen nearly edge-on), 1 with them open.
    public var wingScale: Double { Perch.folded + (1 - Perch.folded) * opening }
}

/// Perch is the label mark's motion: a butterfly landing on the first
/// letter of the tab's label, standing there while the read runs, and
/// taking off when it is done. Each phase is a pure function of the time
/// into it, so the keyframes are tested without a GUI; the app samples them
/// on a timeline while the mark is shown and draws the pose.
///
/// Landing (`landing`, 0.35 s): it comes in from the upper left on a short
/// descending arc, tilted into its travel and levelling as it arrives, wings
/// open and beating fast; on touchdown it dips `dip` below the perch and
/// recovers while one slow stroke folds its wings (`settle`, the landing's
/// last 0.1 s), during which it also turns side-on (`sideOn` 0 to 1). Perched:
/// seen from the side, body level, wings closed together above its back, no
/// drift, and every `sideBeat` (one `Flap` beat) the closed wings part
/// slightly and close again (`closedBeat`); the legacy `opening` flex
/// continues underneath for the flight view. Take-off (`takeOff`,
/// 0.35 s): it turns back to the flight view within `turnTime`, the wings open within `openTime` and beat fast, and it lifts up
/// and away to the upper right, tilting slightly, fading out. Under Reduce
/// Motion the mark is `still` throughout.
public enum Perch {
    /// How long the landing takes, in seconds, touchdown's settle included.
    public static let landing: TimeInterval = 0.35
    /// The landing's last part, in seconds: the dip and the folding stroke.
    public static let settle: TimeInterval = 0.10
    /// How long the take-off takes, in seconds.
    public static let takeOff: TimeInterval = 0.35
    /// The landing's start, its arc's control point, and the take-off's end
    /// and control point, in points from the perch (y down). The landing
    /// starts within the label's leading area and the gap before it, and
    /// neither flight leaves the strip (`flightStaysInItsRoom`).
    public static let landingStart = (dx: -12.0, dy: -8.0)
    static let landingControl = (dx: -1.0, dy: -8.0)
    public static let takeOffEnd = (dx: 14.0, dy: -10.0)
    static let takeOffControl = (dx: 2.0, dy: -8.0)
    /// The body's tilt in degrees at the landing's start and the take-off's end.
    public static let landingTilt = 20.0
    public static let takeOffTilt = 15.0
    /// A fast in-flight stroke, in seconds, and its hinge angle at the top.
    public static let beatPeriod: TimeInterval = 0.125
    public static let beatPeak = 60.0
    /// The settle's one slow stroke at its top, in degrees.
    public static let settleBeat = 40.0
    /// How far below the perch the touchdown dips, in points.
    public static let dip = 0.6
    /// How long the landing fades in, in seconds.
    public static let fadeIn: TimeInterval = 0.08
    /// The fraction of the take-off after which it fades out.
    public static let fadeFrom = 0.4
    /// How long the take-off takes to open the wings, in seconds.
    public static let openTime: TimeInterval = 0.06
    /// The folded wing pair's horizontal scale, seen nearly edge-on.
    public static let folded = 0.3
    /// How long the turn out of the side view takes at take-off, in seconds
    /// (the landing's turn in takes its `settle`).
    public static let turnTime: TimeInterval = 0.06
    /// The side-on pose's closed-wing beat: one every `sideBeat` seconds (a
    /// `Flap` beat), parting the wings by `sidePeak` degrees at the top.
    public static let sideBeat: TimeInterval = Flap.duration
    public static let sidePeak = 24.0
    /// The perched flex: one every `flexPeriod` seconds, lasting
    /// `flexDuration`, opening the wings to `flexOpening`.
    public static let flexPeriod: TimeInterval = 1.2
    public static let flexDuration: TimeInterval = 0.4
    public static let flexOpening = 0.5

    /// The still perched mark: Reduce Motion's whole flight.
    public static let still = PerchPose(dx: 0, dy: 0, rotation: 0, opening: 0, beat: 0, opacity: 1)

    /// pose is the mark `t` seconds into `phase`, a time outside the phase
    /// held at its ends and one that is not a number giving `still`. A
    /// take-off opens the wings from `from`, how open they were when it began,
    /// and parts the closed wings from `closed`, how far apart they were.
    public static func pose(_ phase: PerchPhase, at t: TimeInterval, from opening: Double = 0,
                            closed: Double = 0) -> PerchPose {
        guard !t.isNaN else { return still }
        switch phase {
        case .landing: return landingPose(at: min(max(t, 0), landing))
        case .perched: return perchedPose(at: max(t, 0))
        case .takingOff: return takeOffPose(at: min(max(t, 0), takeOff), from: min(max(opening, 0), 1), closed: closed)
        }
    }

    private static func landingPose(at t: TimeInterval) -> PerchPose {
        guard t < landing else { return perchedPose(at: 0) }
        let flight = landing - settle
        if t < flight {
            let u = t / flight
            let s = 1 - (1 - u) * (1 - u)
            let p = arc(landingStart, landingControl, (0, 0), s)
            return PerchPose(dx: p.dx, dy: p.dy, rotation: landingTilt * (1 - s), opening: 1,
                             beat: stroke(t), opacity: min(1, t / fadeIn))
        }
        let v = (t - flight) / settle
        return PerchPose(dx: 0, dy: dip * sin(.pi * v), rotation: 0, opening: 1 - smooth(v),
                         beat: settleBeat * sin(.pi * v), opacity: 1, sideOn: smooth(v))
    }

    private static func perchedPose(at t: TimeInterval) -> PerchPose {
        guard t.isFinite else { return still }
        let tau = t.truncatingRemainder(dividingBy: flexPeriod)
        let into = tau - (flexPeriod - flexDuration)
        let opening = into >= 0 ? flexOpening * (1 - cos(2 * .pi * into / flexDuration)) / 2 : 0
        return PerchPose(dx: 0, dy: 0, rotation: 0, opening: opening, beat: 0, opacity: 1,
                         sideOn: 1, closedBeat: closedBeat(at: t))
    }

    /// The closed wings' parting `t` seconds into the perch: flat at the
    /// start of each `sideBeat`, `sidePeak` at its middle.
    static func closedBeat(at t: TimeInterval) -> Double {
        sidePeak * (1 - cos(2 * .pi * t / sideBeat)) / 2
    }

    private static func takeOffPose(at t: TimeInterval, from opening: Double, closed: Double) -> PerchPose {
        let u = t / takeOff
        let s = u * u
        let p = arc((0, 0), takeOffControl, takeOffEnd, s)
        let fade = u < fadeFrom ? 1 : 1 - smooth((u - fadeFrom) / (1 - fadeFrom))
        return PerchPose(dx: p.dx, dy: p.dy, rotation: takeOffTilt * s,
                         opening: opening + (1 - opening) * smooth(t / openTime), beat: stroke(t), opacity: fade,
                         sideOn: 1 - smooth(t / turnTime), closedBeat: closed * (1 - smooth(t / turnTime)))
    }

    /// The in-flight hinge angle `t` seconds into a flight: flat at the
    /// start of each `beatPeriod`, `beatPeak` at its middle.
    private static func stroke(_ t: TimeInterval) -> Double {
        beatPeak * (1 - cos(2 * .pi * t / beatPeriod)) / 2
    }

    /// A point `s` along the quadratic arc from `a` through control `c` to `b`.
    private static func arc(_ a: (dx: Double, dy: Double), _ c: (dx: Double, dy: Double), _ b: (dx: Double, dy: Double),
                            _ s: Double) -> (dx: Double, dy: Double) {
        let p = (1 - s) * (1 - s), q = 2 * (1 - s) * s, r = s * s
        return (p * a.dx + q * c.dx + r * b.dx, p * a.dy + q * c.dy + r * b.dy)
    }

    /// Smoothstep of `x` clamped to 0...1.
    private static func smooth(_ x: Double) -> Double {
        let v = min(max(x, 0), 1)
        return v * v * (3 - 2 * v)
    }
}

/// LabelFlight is one showing of a tab's label mark on the monotonic clock:
/// when it began to land (`shownAt`), when it began to take off (`leftAt`,
/// nil until then), and whether Reduce Motion was on when it appeared, in
/// which case it is the still perched mark throughout.
public struct LabelFlight: Equatable, Sendable {
    public let shownAt: TimeInterval
    public var leftAt: TimeInterval?
    public let reduceMotion: Bool

    public init(shownAt: TimeInterval, leftAt: TimeInterval?, reduceMotion: Bool) {
        self.shownAt = shownAt
        self.leftAt = leftAt
        self.reduceMotion = reduceMotion
    }

    /// phase is where the flight is at `now`.
    public func phase(at now: TimeInterval) -> PerchPhase {
        if let leftAt, now >= leftAt { return .takingOff }
        if reduceMotion { return .perched }
        return now - shownAt < Perch.landing ? .landing : .perched
    }

    /// pose is the mark at `now`: the landing from `shownAt`, the perch from
    /// touchdown, and the take-off from `leftAt`, opening the wings from
    /// where the perch had them then.
    public func pose(at now: TimeInterval) -> PerchPose {
        if reduceMotion { return Perch.still }
        switch phase(at: now) {
        case .landing: return Perch.pose(.landing, at: now - shownAt)
        case .perched: return Perch.pose(.perched, at: now - shownAt - Perch.landing)
        case .takingOff:
            let left = leftAt ?? now
            let held = Perch.pose(.perched, at: left - shownAt - Perch.landing)
            return Perch.pose(.takingOff, at: now - left, from: held.opening, closed: held.closedBeat)
        }
    }
}
