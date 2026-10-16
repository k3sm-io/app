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

@Suite("waiting")
struct WaitingTests {
    @Test("a slow first read shows the butterfly in the content area once the debounce passes")
    func slowFirstReadShowsAfterDebounce() {
        for selected in [true, false] {
            #expect(Waiting.shows(firstReadDone: false, inFlight: true, elapsed: 0, shownFor: nil, selected: selected) == nil)
            #expect(Waiting.shows(firstReadDone: false, inFlight: true, elapsed: Waiting.debounce - 0.01, shownFor: nil, selected: selected) == nil)
            #expect(Waiting.shows(firstReadDone: false, inFlight: true, elapsed: Waiting.debounce, shownFor: nil, selected: selected) == .content)
            #expect(Waiting.shows(firstReadDone: false, inFlight: true, elapsed: 5, shownFor: 4.7, selected: selected) == .content)
        }
        // A later read sits beside the label.
        #expect(Waiting.shows(firstReadDone: true, inFlight: true, elapsed: Waiting.debounce, shownFor: nil, selected: false) == .label)
    }

    @Test("a first read that ends inside the debounce never shows the butterfly")
    func fastReadNeverFlashes() {
        var tracker = WaitingTracker()
        #expect(tracker.update(load: .firstRead, now: 10, selected: true) == nil)
        #expect(tracker.update(load: .firstRead, now: 10 + Waiting.debounce - 0.05, selected: true) == nil)
        #expect(tracker.update(load: .loaded(Date()), now: 10 + Waiting.debounce - 0.01, selected: true) == nil)
        #expect(tracker.update(load: .loaded(Date()), now: 20, selected: true) == nil)
        #expect(!tracker.active)
        #expect(Waiting.shows(firstReadDone: true, inFlight: false, elapsed: 0.1, shownFor: nil, selected: true) == nil)
        // A tab not on screen keeps the debounce for its later reads too.
        var hidden = WaitingTracker()
        #expect(hidden.update(load: .refreshing, now: 10, selected: false) == nil)
        #expect(hidden.update(load: .loaded(Date()), now: 10.09, selected: false) == nil)
        #expect(!hidden.active)
    }

    @Test("once shown the butterfly stays its minimum time after the read ends")
    func minimumShownTime() {
        #expect(Waiting.shows(firstReadDone: false, inFlight: false, elapsed: 0, shownFor: 0.05, selected: true) == .content)
        #expect(Waiting.shows(firstReadDone: false, inFlight: false, elapsed: 0, shownFor: Waiting.minimumShown, selected: true) == nil)
        #expect(Waiting.shows(firstReadDone: true, inFlight: false, elapsed: 0, shownFor: Waiting.labelMinimumShown - 0.01, selected: true) == .label)
        #expect(Waiting.shows(firstReadDone: true, inFlight: false, elapsed: 0, shownFor: Waiting.labelMinimumShown, selected: true) == nil)
        #expect(Waiting.shows(firstReadDone: true, inFlight: false, elapsed: 0, shownFor: .nan, selected: true) == nil)

        var tracker = WaitingTracker()
        #expect(tracker.update(load: .refreshing, now: 0, selected: false) == nil)
        #expect(tracker.update(load: .refreshing, now: 0.35, selected: false) == .label)
        // The read ends 50 ms after the butterfly appeared: it stays, as a
        // later read's mark, until the label's minimum has passed.
        #expect(tracker.update(load: .loaded(Date()), now: 0.4, selected: false) == .label)
        #expect(tracker.update(load: .loaded(Date()), now: 0.35 + Waiting.labelMinimumShown - 0.01, selected: false) == .label)
        #expect(tracker.active)
        #expect(tracker.update(load: .loaded(Date()), now: 0.35 + Waiting.labelMinimumShown + 0.001, selected: false) == nil)
        #expect(!tracker.active)
    }

    @Test("a first read's tail stays in the content area")
    func firstReadTailStaysInContent() {
        var tracker = WaitingTracker()
        _ = tracker.update(load: .firstRead, now: 0, selected: true)
        #expect(tracker.update(load: .firstRead, now: 0.3, selected: true) == .content)
        #expect(tracker.update(load: .loaded(Date()), now: 0.5, selected: true) == .content)
    }

    /// The reads of the visible tab, one row each: whether the tab had a
    /// value when the read began, how long the read ran, and then, sampled
    /// at `at` seconds after it began, where the butterfly is drawn.
    @Test("the visible tab's later read perches on its label at once and stays; a first read keeps the debounce", arguments: [
        // A 90 ms later read shows the label mark at once and keeps it 0.8 s.
        (true, 0.09, 0.0, WaitingMark?.some(.label)),
        (true, 0.09, 0.05, .label),
        (true, 0.09, 0.5, .label),
        (true, 0.09, Waiting.labelMinimumShown - 0.01, .label),
        (true, 0.09, Waiting.labelMinimumShown + 0.005, nil),
        // A 90 ms first read shows no content mark.
        (false, 0.09, 0.0, nil),
        (false, 0.09, 0.05, nil),
        (false, 0.09, 0.5, nil),
        // A 400 ms first read shows the content mark past the debounce, for the minimum.
        (false, 0.4, 0.29, nil),
        (false, 0.4, 0.305, .content),
        (false, 0.4, 0.75, .content),
        (false, 0.4, 0.3 + Waiting.minimumShown + 0.015, nil),
    ] as [(Bool, TimeInterval, TimeInterval, WaitingMark?)])
    func visibleTabReads(_ hadValue: Bool, _ duration: TimeInterval, _ at: TimeInterval, _ want: WaitingMark?) {
        var tracker = WaitingTracker()
        let reading: TabLoad = hadValue ? .refreshing : .firstRead
        var mark: WaitingMark?
        // Fed as the app feeds it: on the change that starts the read, on a
        // 10 ms tick, and on the change that ends it.
        for tick in 0... {
            let t = Double(tick) * 0.01
            guard t < at else { break }
            mark = tracker.update(load: t < duration ? reading : .loaded(Date()), now: 100 + t, selected: true)
        }
        mark = tracker.update(load: at < duration ? reading : .loaded(Date()), now: 100 + at, selected: true)
        #expect(mark == want)
    }

    @Test("a later read of a tab not on screen keeps the debounce")
    func hiddenTabKeepsTheDebounce() {
        #expect(Waiting.shows(firstReadDone: true, inFlight: true, elapsed: 0.09, shownFor: nil, selected: false) == nil)
        #expect(Waiting.shows(firstReadDone: true, inFlight: true, elapsed: Waiting.debounce, shownFor: nil, selected: false) == .label)
        #expect(Waiting.shows(firstReadDone: true, inFlight: true, elapsed: 0, shownFor: nil, selected: true) == .label)
        #expect(Waiting.shows(firstReadDone: false, inFlight: true, elapsed: 0.09, shownFor: nil, selected: true) == nil)
        #expect(Waiting.labelMinimumShown >= 0.8)
    }

    @Test("a refresh that comes back while the label mark is shown keeps it")
    func refreshWhileShownStays() {
        var tracker = WaitingTracker()
        #expect(tracker.update(load: .refreshing, now: 0, selected: true) == .label)
        #expect(tracker.update(load: .loaded(Date()), now: 0.09, selected: true) == .label)
        #expect(tracker.update(load: .refreshing, now: 0.5, selected: true) == .label)
        #expect(tracker.update(load: .refreshing, now: 2, selected: true) == .label)
        #expect(tracker.update(load: .loaded(Date()), now: 2.1, selected: true) == nil)
    }

    /// menuOpen, readInFlight, elapsed, shownFor, and the verdict.
    @Test("the status item animates only while the menu is open and its read runs past the debounce", arguments: [
        (true, true, 0.0, nil, false),
        (true, true, Waiting.debounce, nil, true),
        (false, true, 2.0, 1.7, false),
        (false, false, 0.0, 0.1, false),
        (true, false, 0.0, nil, false),
        (true, false, 0.0, 0.1, true),
        (true, false, 0.0, Waiting.minimumShown, false),
    ] as [(Bool, Bool, TimeInterval, TimeInterval?, Bool)])
    func menuAnimatesOnlyWhileOpenAndReading(
        _ open: Bool, _ reading: Bool, _ elapsed: TimeInterval, _ shownFor: TimeInterval?, _ want: Bool
    ) {
        #expect(Waiting.menuAnimates(menuOpen: open, readInFlight: reading, elapsed: elapsed, shownFor: shownFor) == want)
    }

    @Test("the status item's frames cycle its wing angles and Reduce Motion pins them flat")
    func reduceMotionPinsTheFrame() {
        let step = Waiting.menuFrameInterval
        let played = (0..<8).map { Waiting.menuFrame(at: (Double($0) + 0.5) * step, reduceMotion: false) }
        #expect(played == [0, 35, 70, 35, 0, 35, 70, 35])
        #expect(Set(Waiting.menuAngles).count == 3)
        for i in 0..<8 {
            #expect(Waiting.menuFrame(at: (Double(i) + 0.5) * step, reduceMotion: true) == 0)
        }
        #expect(Waiting.menuFrame(at: -1, reduceMotion: false) == 0)
        #expect(Waiting.menuFrame(at: .nan, reduceMotion: false) == 0)
        #expect(Waiting.menuFrame(at: .infinity, reduceMotion: false) == 0)
    }
}
