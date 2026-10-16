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
        #expect(Waiting.shows(firstReadDone: false, inFlight: true, elapsed: 0, shownFor: nil) == nil)
        #expect(Waiting.shows(firstReadDone: false, inFlight: true, elapsed: Waiting.debounce - 0.01, shownFor: nil) == nil)
        #expect(Waiting.shows(firstReadDone: false, inFlight: true, elapsed: Waiting.debounce, shownFor: nil) == .content)
        #expect(Waiting.shows(firstReadDone: false, inFlight: true, elapsed: 5, shownFor: 4.7) == .content)
        // A later read sits beside the label.
        #expect(Waiting.shows(firstReadDone: true, inFlight: true, elapsed: Waiting.debounce, shownFor: nil) == .label)
    }

    @Test("a read that ends inside the debounce never shows the butterfly")
    func fastReadNeverFlashes() {
        var tracker = WaitingTracker()
        #expect(tracker.update(load: .firstRead, now: 10) == nil)
        #expect(tracker.update(load: .firstRead, now: 10 + Waiting.debounce - 0.05) == nil)
        #expect(tracker.update(load: .loaded(Date()), now: 10 + Waiting.debounce - 0.01) == nil)
        #expect(tracker.update(load: .loaded(Date()), now: 20) == nil)
        #expect(!tracker.active)
        #expect(Waiting.shows(firstReadDone: true, inFlight: false, elapsed: 0.1, shownFor: nil) == nil)
    }

    @Test("once shown the butterfly stays the minimum time after the read ends")
    func minimumShownTime() {
        #expect(Waiting.shows(firstReadDone: false, inFlight: false, elapsed: 0, shownFor: 0.05) == .content)
        #expect(Waiting.shows(firstReadDone: true, inFlight: false, elapsed: 0, shownFor: Waiting.minimumShown - 0.01) == .label)
        #expect(Waiting.shows(firstReadDone: true, inFlight: false, elapsed: 0, shownFor: Waiting.minimumShown) == nil)
        #expect(Waiting.shows(firstReadDone: true, inFlight: false, elapsed: 0, shownFor: .nan) == nil)

        var tracker = WaitingTracker()
        _ = tracker.update(load: .refreshing, now: 0)
        #expect(tracker.update(load: .refreshing, now: 0.35) == .label)
        // The read ends 50 ms after the butterfly appeared: it stays, as a
        // later read's mark, until the minimum has passed.
        #expect(tracker.update(load: .loaded(Date()), now: 0.4) == .label)
        #expect(tracker.update(load: .loaded(Date()), now: 0.35 + Waiting.minimumShown - 0.01) == .label)
        #expect(tracker.active)
        #expect(tracker.update(load: .loaded(Date()), now: 0.35 + Waiting.minimumShown) == nil)
        #expect(!tracker.active)
    }

    @Test("a first read's tail stays in the content area")
    func firstReadTailStaysInContent() {
        var tracker = WaitingTracker()
        _ = tracker.update(load: .firstRead, now: 0)
        #expect(tracker.update(load: .firstRead, now: 0.3) == .content)
        #expect(tracker.update(load: .loaded(Date()), now: 0.5) == .content)
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
