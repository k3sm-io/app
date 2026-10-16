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
/// the tab on screen lands the small mark on its label at once and keeps it
/// at least `labelMinimumShown`, so each refresh, however quick, reads as a
/// brief perch rather than a flicker. The app only draws it; the timing lives
/// here so it is tested without a GUI.
public enum Waiting {
    /// How long a read runs, in seconds, before the butterfly is shown.
    public static let debounce: TimeInterval = 0.3
    /// The least time, in seconds, the content mark and the status item's
    /// frames stay once shown.
    public static let minimumShown: TimeInterval = 0.5
    /// The least time, in seconds, the label mark stays once shown: long
    /// enough to be seen on a refresh that takes a tenth of a second.
    public static let labelMinimumShown: TimeInterval = 0.8
    /// How long each status-item frame is held, in seconds.
    public static let menuFrameInterval: TimeInterval = 0.12
    /// The status item's wing angles in degrees, one per frame, in order:
    /// three distinct images, played up and back.
    public static let menuAngles: [Double] = [0, 35, 70, 35]
    /// What VoiceOver says for a shown butterfly.
    public static let accessibilityLabel = "Reading"

    /// shows is where a tab's butterfly is drawn, or nil while it is not.
    /// `firstReadDone` is whether the tab already had a value when the read
    /// began (a later read, shown beside the label; otherwise the first, shown
    /// in the content area). `elapsed` is how long the read has run,
    /// `shownFor` how long the butterfly has been shown, nil while it is not,
    /// and `selected` whether the tab is the one on screen. The label mark of
    /// the tab on screen appears as soon as its read begins; every other mark
    /// appears only for a read past `debounce`. Once shown a mark stays while
    /// the read runs, so a read that starts again keeps it, and until its
    /// minimum has passed: `labelMinimumShown` beside the label,
    /// `minimumShown` in the content area (a time that is not a number ends
    /// it).
    public static func shows(firstReadDone: Bool, inFlight: Bool, elapsed: TimeInterval, shownFor: TimeInterval?,
                             selected: Bool) -> WaitingMark? {
        let mark: WaitingMark = firstReadDone ? .label : .content
        let shown = visible(inFlight: inFlight, elapsed: elapsed, shownFor: shownFor,
                            after: mark == .label && selected ? 0 : debounce,
                            minimum: mark == .label ? labelMinimumShown : minimumShown)
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
/// is the one on screen, and the time, on every change and on a short tick
/// while `active`.
public struct WaitingTracker: Equatable, Sendable {
    private var began: TimeInterval?
    private var firstReadDone = false
    private var shownAt: TimeInterval?

    public init() {}

    /// Whether a read is running or the butterfly is shown, so the verdict
    /// can change with time alone.
    public var active: Bool { began != nil || shownAt != nil }

    /// update records `load` at `now` (seconds on a monotonic clock), with
    /// `selected` whether the tab is on screen, and returns where the
    /// butterfly is drawn, or nil.
    public mutating func update(load: TabLoad, now: TimeInterval, selected: Bool) -> WaitingMark? {
        if load.inFlight {
            if began == nil {
                began = now
                firstReadDone = load != .firstRead
            }
        } else {
            began = nil
        }
        let mark = Waiting.shows(
            firstReadDone: firstReadDone, inFlight: load.inFlight,
            elapsed: began.map { now - $0 } ?? 0, shownFor: shownAt.map { now - $0 }, selected: selected)
        if mark == nil {
            shownAt = nil
        } else if shownAt == nil {
            shownAt = now
        }
        return mark
    }
}
