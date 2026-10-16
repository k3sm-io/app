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
/// console tab and on the menu bar's status item. A read that ends within
/// `debounce` never shows it, and once shown it stays at least
/// `minimumShown`, so a fast read never flashes. The app only draws it; the
/// timing lives here so it is tested without a GUI.
public enum Waiting {
    /// How long a read runs, in seconds, before the butterfly is shown.
    public static let debounce: TimeInterval = 0.3
    /// The least time, in seconds, the butterfly stays once shown.
    public static let minimumShown: TimeInterval = 0.5
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
    /// in the content area). `elapsed` is how long the read has run and
    /// `shownFor` how long the butterfly has been shown, nil while it is not.
    /// Once shown it stays while the read runs and until `minimumShown` has
    /// passed (a time that is not a number ends it); before that it appears
    /// only for a read past `debounce`.
    public static func shows(firstReadDone: Bool, inFlight: Bool, elapsed: TimeInterval, shownFor: TimeInterval?) -> WaitingMark? {
        visible(inFlight: inFlight, elapsed: elapsed, shownFor: shownFor) ? (firstReadDone ? .label : .content) : nil
    }

    /// menuAnimates is whether the status item plays its waiting frames: only
    /// while the menu is open, and then by the same debounce and minimum
    /// shown time as a tab's butterfly while the full status read runs.
    /// Closing the menu stops it at once.
    public static func menuAnimates(menuOpen: Bool, readInFlight: Bool, elapsed: TimeInterval, shownFor: TimeInterval?) -> Bool {
        menuOpen && visible(inFlight: readInFlight, elapsed: elapsed, shownFor: shownFor)
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

    private static func visible(inFlight: Bool, elapsed: TimeInterval, shownFor: TimeInterval?) -> Bool {
        if let shownFor {
            return inFlight || shownFor < minimumShown
        }
        return inFlight && elapsed >= debounce
    }
}

/// WaitingTracker follows one tab's reads through `Waiting.shows`: it notes
/// when a read began, whether the tab had a value then, and when the
/// butterfly appeared. The app feeds it the tab's `TabLoad` and the time,
/// on every change and on a short tick while `active`.
public struct WaitingTracker: Equatable, Sendable {
    private var began: TimeInterval?
    private var firstReadDone = false
    private var shownAt: TimeInterval?

    public init() {}

    /// Whether a read is running or the butterfly is shown, so the verdict
    /// can change with time alone.
    public var active: Bool { began != nil || shownAt != nil }

    /// update records `load` at `now` (seconds on a monotonic clock) and
    /// returns where the butterfly is drawn, or nil.
    public mutating func update(load: TabLoad, now: TimeInterval) -> WaitingMark? {
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
            elapsed: began.map { now - $0 } ?? 0, shownFor: shownAt.map { now - $0 })
        if mark == nil {
            shownAt = nil
        } else if shownAt == nil {
            shownAt = now
        }
        return mark
    }
}
