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

import Testing

@testable import K3smStatus

@Suite("live views")
struct LiveViewTests {
    static let binary = LiveTopProbe.Identity(device: 1, inode: 42, size: 9000, modified: 100, modifiedNanos: 5, changed: 100, changedNanos: 5)
    static let replaced = LiveTopProbe.Identity(device: 1, inode: 43, size: 9000, modified: 100, modifiedNanos: 5, changed: 100, changedNanos: 5)

    @Test("the views' argument lists, titles and menu items")
    func views() {
        #expect(LiveView.status.arguments == ["status", "-o", "wide", "--watch=2s"])
        #expect(LiveView.top.arguments == ["status", "top", "--watch=2s"])
        #expect(LiveView.status.menuTitle == "Live Status in Terminal")
        #expect(LiveView.top.menuTitle == "Live Top in Terminal")
        #expect(LiveView.status.liveTitle == "k3sm status (live)")
        #expect(LiveView.top.liveTitle == "k3sm top (live)")
        #expect(LiveView.status.hint == "k3sm status, live: refreshes every 2 s. Control-C to stop.")
        #expect(LiveTopProbe.arguments == ["status", "top", "--help"])
    }

    @Test("Live Top is offered only when the help run exits 0", arguments: [
        (LiveTopProbe.Outcome.exited(0), true),
        (.exited(2), false),
        (.exited(1), false),
        (.exited(130), false),
        (.noAnswer, false),
    ])
    func liveTopProbeDecision(_ outcome: LiveTopProbe.Outcome, _ offered: Bool) {
        #expect(LiveTopProbe.offered(outcome) == offered)
        var cache = LiveTopProbe.Cache()
        let shown1 = cache.record(outcome, for: Self.binary)
        #expect(shown1 == offered)
    }

    @Test("an answer is kept for one binary, and probed again when the binary changes")
    func liveTopProbeCache() {
        var cache = LiveTopProbe.Cache()
        #expect(cache.offered(for: Self.binary) == nil)
        let first = cache.record(.exited(0), for: Self.binary)
        #expect(first)
        #expect(cache.offered(for: Self.binary) == true)
        #expect(cache.offered(for: Self.replaced) == nil)
        #expect(cache.offered(for: nil) == nil)
        let second = cache.record(.exited(2), for: Self.replaced)
        #expect(!second)
        #expect(cache.offered(for: Self.replaced) == false)
        #expect(cache.offered(for: Self.binary) == nil)
    }

    @Test("a run that gave no answer, or a binary that cannot be identified, is not kept")
    func liveTopProbeNoAnswer() {
        var cache = LiveTopProbe.Cache()
        _ = cache.record(.exited(0), for: Self.binary)
        let noAnswer = cache.record(.noAnswer, for: Self.binary)
        #expect(!noAnswer)
        #expect(cache.offered(for: Self.binary) == nil)
        let unidentified = cache.record(.exited(0), for: nil)
        #expect(unidentified)
        #expect(cache.offered(for: nil) == nil)
    }
}
