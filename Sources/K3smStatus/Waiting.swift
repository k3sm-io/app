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

/// WaitingMark is where a tab's waiting butterfly sits: centred in the tab's
/// content area while its first read runs, or beside the tab's label while a
/// later read runs behind the list it already shows.
public enum WaitingMark: Equatable, Sendable {
    case content
    case label
}

/// Waiting is when the little butterfly that says "reading" is shown, in a
/// console tab and on the menu bar's status item. A tab's first read, and the
/// status item's read, show it only past `debounce` and then keep it at least
/// `minimumShown`, so a fast read never flashes the big mark. A later read of
/// the tab on screen lands the small mark on its label at once, keeps it
/// perched at least `labelMinimumShown` from touchdown, and takes it off once
/// the read is done, so each refresh, however quick, reads as a butterfly
/// coming to rest and leaving rather than a flicker (`Perch` is the motion).
/// The app only draws it; the timing lives here so it is tested without a GUI.
public enum Waiting {
    /// How long a read runs, in seconds, before the butterfly is shown.
    public static let debounce: TimeInterval = 0.3
    /// The least time, in seconds, the content mark and the status item's
    /// frames stay once shown.
    public static let minimumShown: TimeInterval = 0.5
    /// The least time, in seconds, the label mark stays perched, measured
    /// from touchdown: long enough to be seen on a refresh that takes a
    /// tenth of a second.
    public static let labelMinimumShown: TimeInterval = 0.8
    /// How long each status-item frame is held, in seconds.
    public static let menuFrameInterval: TimeInterval = 0.12
    /// The status item's wing angles in degrees, one per frame, in order:
    /// three distinct images, played up and back.
    public static let menuAngles: [Double] = [0, 35, 70, 35]
    /// What VoiceOver says for a shown butterfly.
    public static let accessibilityLabel = "Reading"

    /// labelLanding is how long the label mark takes to land, in seconds:
    /// `Perch.landing`, or nothing under Reduce Motion, where it appears still.
    public static func labelLanding(reduceMotion: Bool) -> TimeInterval {
        reduceMotion ? 0 : Perch.landing
    }

    /// labelTakeOff is how long the label mark takes to leave once its read
    /// is done and its perch has lasted: `Perch.takeOff`, or nothing under
    /// Reduce Motion, where it disappears still.
    public static func labelTakeOff(reduceMotion: Bool) -> TimeInterval {
        reduceMotion ? 0 : Perch.takeOff
    }

    /// shows is where a tab's butterfly is drawn, or nil while it is not.
    /// `firstReadDone` is whether the tab already had a value when the read
    /// began (a later read, shown beside the label; otherwise the first, shown
    /// in the content area). `elapsed` is how long the read has run,
    /// `shownFor` how long the butterfly has been shown, nil while it is not,
    /// and `selected` whether the tab is the one on screen. The label mark of
    /// the tab on screen appears as soon as its read begins; every other mark
    /// appears only for a read past `debounce`. Once shown a mark stays while
    /// the read runs, so a read that starts again keeps it, and until its
    /// minimum has passed: the landing (`labelLanding`) and then
    /// `labelMinimumShown` beside the label, `minimumShown` in the content
    /// area (a time that is not a number ends it). The label mark's take-off,
    /// which follows, is `WaitingTracker`'s.
    public static func shows(firstReadDone: Bool, inFlight: Bool, elapsed: TimeInterval, shownFor: TimeInterval?,
                             selected: Bool, reduceMotion: Bool = false) -> WaitingMark? {
        let mark: WaitingMark = firstReadDone ? .label : .content
        let shown = visible(inFlight: inFlight, elapsed: elapsed, shownFor: shownFor,
                            after: mark == .label && selected ? 0 : debounce,
                            minimum: mark == .label ? labelLanding(reduceMotion: reduceMotion) + labelMinimumShown : minimumShown)
        return shown ? mark : nil
    }

    /// menuAnimates is whether the status item plays its waiting frames: only
    /// while the menu is open, and then by the same debounce and minimum
    /// shown time as a tab's butterfly while the full status read runs.
    /// Closing the menu stops it at once.
    public static func menuAnimates(menuOpen: Bool, readInFlight: Bool, elapsed: TimeInterval, shownFor: TimeInterval?) -> Bool {
        menuOpen && visible(inFlight: readInFlight, elapsed: elapsed, shownFor: shownFor, after: debounce, minimum: minimumShown)
    }

    /// menuFrame is the status item's wing angle `t` seconds after its frames
    /// began: `menuAngles` in turn, each held `menuFrameInterval`. Under
    /// Reduce Motion, and for a time before the start or not a number, it is
    /// 0, the still mark.
    public static func menuFrame(at t: TimeInterval, reduceMotion: Bool) -> Double {
        guard !reduceMotion, t >= 0, t.isFinite else { return 0 }
        let index = Int(t / menuFrameInterval) % menuAngles.count
        return menuAngles[index]
    }

    private static func visible(inFlight: Bool, elapsed: TimeInterval, shownFor: TimeInterval?,
                                after: TimeInterval, minimum: TimeInterval) -> Bool {
        if let shownFor {
            return inFlight || shownFor < minimum
        }
        return inFlight && elapsed >= after
    }
}

/// WaitingTracker follows one tab's reads through `Waiting.shows`: it notes
/// when a read began, whether the tab had a value then, and when the
/// butterfly appeared. The app feeds it the tab's `TabLoad`, whether the tab
/// is the one on screen, whether Reduce Motion is on, and the time, on every
/// change and on a short tick while `active`. A label mark is a `flight`:
/// when the mark's time is up it is not dropped but takes off, staying
/// `Waiting.labelTakeOff` more, and a read that begins meanwhile lands a new
/// one once the take-off ends.
public struct WaitingTracker: Equatable, Sendable {
    private var began: TimeInterval?
    private var firstReadDone = false
    private var shownAt: TimeInterval?
    private var shownMark: WaitingMark?
    /// The label mark's flight while it is shown, nil otherwise.
    public private(set) var flight: LabelFlight?

    public init() {}

    /// Whether a read is running or the butterfly is shown, so the verdict
    /// can change with time alone.
    public var active: Bool { began != nil || shownAt != nil }

    /// update records `load` at `now` (seconds on a monotonic clock), with
    /// `selected` whether the tab is on screen and `reduceMotion` the
    /// system's setting, and returns where the butterfly is drawn, or nil.
    public mutating func update(load: TabLoad, now: TimeInterval, selected: Bool,
                                reduceMotion: Bool = false) -> WaitingMark? {
        if load.inFlight {
            if began == nil {
                began = now
                firstReadDone = load != .firstRead
            }
        } else {
            began = nil
        }
        if let leftAt = flight?.leftAt {
            if now - leftAt < Waiting.labelTakeOff(reduceMotion: flight?.reduceMotion ?? reduceMotion) { return .label }
            clear()
        }
        let mark = Waiting.shows(
            firstReadDone: firstReadDone, inFlight: load.inFlight,
            elapsed: began.map { now - $0 } ?? 0, shownFor: shownAt.map { now - $0 }, selected: selected,
            reduceMotion: flight?.reduceMotion ?? reduceMotion)
        guard let mark else {
            if var leaving = flight, Waiting.labelTakeOff(reduceMotion: leaving.reduceMotion) > 0 {
                leaving.leftAt = now
                flight = leaving
                return .label
            }
            clear()
            return nil
        }
        if shownAt == nil || mark != shownMark {
            shownAt = now
            shownMark = mark
            flight = mark == .label ? LabelFlight(shownAt: now, leftAt: nil, reduceMotion: reduceMotion) : nil
        }
        return mark
    }

    private mutating func clear() {
        shownAt = nil
        shownMark = nil
        flight = nil
    }
}
