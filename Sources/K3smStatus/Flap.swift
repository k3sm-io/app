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

/// Flap is the wordmark butterfly's wing beat: how often it plays while the
/// console is on screen and how far the wings swing at each frame. The app
/// only draws the frames; the timing lives here so it is tested without a GUI.
///
/// The wings are hinged at the body. A beat swings both toward the viewer
/// and back twice, the second time shallower, and ends with the wings flat.
/// The wait between beats is random, so the butterfly seems to rest rather
/// than tick like a clock. Nothing plays while the system's Reduce Motion
/// setting is on.
public enum Flap {
    /// The shortest and longest wait between beats, in seconds.
    public static let restMin: TimeInterval = 6
    public static let restMax: TimeInterval = 18
    /// How long one beat lasts, in seconds.
    public static let duration: TimeInterval = 0.8
    /// Frames per second while a beat plays.
    public static let frameRate: Double = 30
    /// The hinge angle, in degrees, at the top of the first stroke; the
    /// second stroke reaches `secondDepth` of it.
    public static let peak: Double = 70
    public static let secondDepth: Double = 0.6

    /// angle is the hinge angle in degrees `t` seconds into a beat: 0 (flat)
    /// at and outside both ends, `peak` a quarter of the way in.
    public static func angle(at t: TimeInterval) -> Double {
        guard t > 0, t < duration else { return 0 }
        let phase = t / duration * 2
        let swing = (1 - cos(2 * Double.pi * phase)) / 2
        return peak * (phase < 1 ? 1 : secondDepth) * swing
    }

    /// frames is every angle of one beat at `frameRate`, first and last flat.
    public static func frames() -> [Double] {
        let count = Int((duration * frameRate).rounded())
        return (0...count).map { angle(at: Double($0) / frameRate) }
    }

    /// plays is whether a beat that has come due plays: not while the
    /// system's Reduce Motion setting is on, and not while the window is
    /// miniaturized or fully covered, where nobody would see it.
    public static func plays(reduceMotion: Bool, windowVisible: Bool) -> Bool {
        !reduceMotion && windowVisible
    }

    /// The least time, in seconds, from the end of one beat to a beat a hover
    /// starts, so a pointer wobbling on the mark's edge cannot chain beats.
    public static let hoverCooldown: TimeInterval = 1.5

    /// hoverStartsBeat is whether the pointer entering the mark starts a beat
    /// at once: only while the beats are scheduled (`started`, the console is
    /// up), not while one is already playing, not within `hoverCooldown` of
    /// the last beat's end (`sinceLastBeat`, nil before any beat), and only
    /// when `plays` would let a timed beat play (Reduce Motion off, the
    /// window visible).
    public static func hoverStartsBeat(
        inFlight: Bool, reduceMotion: Bool, windowVisible: Bool, sinceLastBeat: TimeInterval?, started: Bool = true
    ) -> Bool {
        if let since = sinceLastBeat, !(since >= hoverCooldown) { return false }
        return started && !inFlight && plays(reduceMotion: reduceMotion, windowVisible: windowVisible)
    }

    /// rest is the wait before the next beat for `unit` in 0...1 (a random
    /// draw), from `restMin` to `restMax`; a value outside is clamped.
    public static func rest(unit: Double) -> TimeInterval {
        restMin + min(max(unit, 0), 1) * (restMax - restMin)
    }
}
