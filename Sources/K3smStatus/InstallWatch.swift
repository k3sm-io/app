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

/// InstallWatch is the developer build's first run waiting for an install it
/// cannot run itself: on the review step, while the window is on screen, the
/// waiting butterfly flies a dotted path from its left end to its right end
/// in `flightTime`, and its arrival is the health check. When the check
/// returns it flies again from the left; Check Again lands it at the right
/// end at once. One check runs at a time.
///
/// | after a check | the first run |
/// |---|---|
/// | nothing installed | keeps waiting |
/// | healthy, or running a different release than the app | moves to the finished step |
/// | installed but not yet up (stopped, partly running, unreadable…) | keeps waiting up to `settleLimit` from the first such check, then moves on so the console's guided panel can help |
public struct InstallWatch: Equatable, Sendable {
    /// One flight along the path, which is the time between checks, in seconds.
    public static let flightTime: TimeInterval = 5
    /// How long an install that is on disk but not up yet is waited for, in seconds.
    public static let settleLimit: TimeInterval = 120

    /// Where the butterfly is: flying since a time, or landed at the right
    /// end while the check that began then runs.
    public enum Phase: Equatable, Sendable {
        case flying(since: TimeInterval)
        case checking(since: TimeInterval)
    }

    public private(set) var phase: Phase
    /// When a check first found k3sm on disk but not up.
    private var installedSince: TimeInterval?

    /// A watch whose first flight starts at `now`.
    public init(now: TimeInterval) {
        phase = .flying(since: now)
    }

    /// Whether the window waits for an install: a build with no Team ID pin,
    /// on the first run's review step, with the window on screen.
    public static func waits(developerBuild: Bool, firstRunShown: Bool, step: FirstRunStep, windowVisible: Bool) -> Bool {
        developerBuild && firstRunShown && step == .review && windowVisible
    }

    /// Whether a check runs.
    public var checking: Bool {
        if case .checking = phase { return true }
        return false
    }

    /// When the current flight arrives at the right end; nil while a check runs.
    public var arrival: TimeInterval? {
        if case .flying(let since) = phase { return since + Self.flightTime }
        return nil
    }

    /// How far along the path the butterfly is at `now`, 0 at the left end
    /// and 1 at the right, where it stays while a check runs.
    public func progress(at now: TimeInterval) -> Double {
        switch phase {
        case .checking: return 1
        case .flying(let since): return min(1, max(0, (now - since) / Self.flightTime))
        }
    }

    /// The arrival: true, and a check begins, when the flight has reached
    /// the right end by `now`; false otherwise and while a check runs.
    public mutating func arrive(now: TimeInterval) -> Bool {
        guard let arrival, now >= arrival else { return false }
        phase = .checking(since: now)
        return true
    }

    /// Check Again: lands the butterfly and begins a check now; false, and
    /// nothing changes, while one runs.
    public mutating func checkNow(now: TimeInterval) -> Bool {
        guard !checking else { return false }
        phase = .checking(since: now)
        return true
    }

    /// Ends the running check at `now` with the state it read and starts the
    /// next flight; true when the first run moves to the finished step.
    public mutating func end(state: HealthState?, now: TimeInterval) -> Bool {
        guard checking else { return false }
        phase = .flying(since: now)
        switch state {
        case nil, .notInstalled?:
            installedSince = nil
            return false
        case .healthy?, .versionMismatch?:
            return true
        default:
            let since = installedSince ?? now
            installedSince = since
            return now - since >= Self.settleLimit
        }
    }
}

/// InstallPathPose is the butterfly on the path: its centre in points from
/// the path's top-left corner, the direction it flies in degrees (clockwise
/// from pointing right, y down), and whether it stands landed at the right end.
public struct InstallPathPose: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let heading: Double
    public let landed: Bool
}

/// InstallPath is the dotted path the waiting butterfly flies: a low sine
/// wave across the width, `waves` periods long, `amplitude` points either
/// side of its middle.
public enum InstallPath {
    /// The path's height in points, room for the wave and the mark.
    public static let height: Double = 28
    /// The butterfly's size in points.
    public static let markSize: Double = 14
    /// How far the wave swings either side of the middle, in points.
    public static let amplitude: Double = 5
    /// How many periods of the wave span the width.
    public static let waves: Double = 1.5

    /// The path's point at `fraction` (0 to 1) of `width`, inset by half a
    /// mark at each end so the mark stays inside.
    public static func point(_ fraction: Double, width: Double) -> (x: Double, y: Double) {
        let f = min(1, max(0, fraction))
        let span = max(0, width - markSize)
        return (markSize / 2 + f * span, height / 2 - amplitude * sin(2 * .pi * waves * f))
    }

    /// One wing stroke in flight, in seconds, and its hinge angle at the top.
    public static let beatPeriod: TimeInterval = 0.3
    public static let beatPeak: Double = 55

    /// The wings' hinge angle at `now` in flight (`FlappingButterfly`'s
    /// angle): 0 flat to `beatPeak` and back once a `beatPeriod`.
    public static func beat(at now: TimeInterval) -> Double {
        beatPeak * (0.5 - 0.5 * cos(2 * .pi * now / beatPeriod))
    }

    /// The butterfly at `now` on a path `width` wide. Under Reduce Motion it
    /// is the still mark at the right end throughout.
    public static func pose(_ watch: InstallWatch, at now: TimeInterval, width: Double, reduceMotion: Bool) -> InstallPathPose {
        if reduceMotion {
            let end = point(1, width: width)
            return InstallPathPose(x: end.x, y: end.y, heading: 0, landed: true)
        }
        let f = watch.progress(at: now)
        let p = point(f, width: width)
        let span = max(1, width - markSize)
        // dy/dx of the wave at f, for the heading.
        let slope = -amplitude * 2 * .pi * waves * cos(2 * .pi * waves * f) / span
        return InstallPathPose(x: p.x, y: p.y, heading: atan(slope) * 180 / .pi, landed: watch.checking)
    }
}
