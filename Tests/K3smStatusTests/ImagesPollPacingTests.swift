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

/// CountingRead answers at once and counts its runs; `waitRuns` returns when
/// the count reaches a number, with no clock involved.
private actor CountingRead {
    private(set) var runs = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    func read() -> TabResult<Int> {
        runs += 1
        for (n, c) in waiters where runs >= n { c.resume() }
        waiters.removeAll { runs >= $0.0 }
        return .value(runs)
    }
    func waitRuns(_ n: Int) async {
        if runs >= n { return }
        await withCheckedContinuation { waiters.append((n, $0)) }
    }
}

/// ManualSleep stands in for the reader's wait: each wait suspends until the
/// test ends it, so no assertion depends on the wall clock.
private actor ManualSleep {
    private var pending: [CheckedContinuation<Void, Never>] = []
    private var watchers: [CheckedContinuation<Void, Never>] = []
    func sleep() async {
        await withCheckedContinuation { c in
            pending.append(c)
            for w in watchers { w.resume() }
            watchers = []
        }
    }
    func waitPending() async {
        if !pending.isEmpty { return }
        await withCheckedContinuation { watchers.append($0) }
    }
    func end() {
        guard !pending.isEmpty else { return }
        pending.removeFirst().resume()
    }
    func endAll() {
        for c in pending { c.resume() }
        pending = []
    }
}

@MainActor
private func settle(_ condition: () -> Bool) async {
    while !condition() { await Task.yield() }
}

@Suite("ImagesPollPacing")
@MainActor
struct ImagesPollPacingTests {
    @Test("the Images tab reads every 60 s, 120 s in low power")
    func imagesIntervals() {
        #expect(PollProfile.normal.intervals.images == .seconds(60))
        #expect(PollProfile.lowPower.intervals.images == .seconds(120))
    }

    private func make() -> (TabReader<Int>, CountingRead, ManualSleep) {
        let probe = CountingRead()
        let nap = ManualSleep()
        let reader = TabReader<Int>(read: { await probe.read() }, interval: { _ in .seconds(60) })
        reader.sleep = { _ in await nap.sleep() }
        return (reader, probe, nap)
    }

    @Test("a paused reader makes no timed read, and resumes with one at once")
    func pausesWhileHiddenAndResumesWhenVisible() async {
        let (reader, probe, nap) = make()
        reader.start()
        await probe.waitRuns(1)
        await nap.waitPending()

        reader.setPaused(true)
        #expect(reader.paused)
        await nap.end()
        await settle { reader.heldWaits == 1 }
        #expect(await probe.runs == 1, "no timed read while paused")

        reader.setPaused(false)
        await probe.waitRuns(2)
        #expect(await probe.runs == 2, "one immediate read on resume")
        await nap.waitPending()
        reader.stop()
        await nap.endAll()
    }

    @Test("a refresh still reads while paused")
    func refreshReadsWhilePaused() async {
        let (reader, probe, _) = make()
        reader.setPaused(true)
        await reader.refresh()
        #expect(await probe.runs == 1)
    }

    @Test("a resume before the wait ends does not read early")
    func freshReadIsNotRepeated() async {
        let (reader, probe, nap) = make()
        reader.start()
        await probe.waitRuns(1)
        await nap.waitPending()
        reader.setPaused(true)
        reader.setPaused(false)
        for _ in 0..<50 { await Task.yield() }
        #expect(await probe.runs == 1)
        await nap.end()
        await probe.waitRuns(2)
        reader.stop()
        await nap.endAll()
    }
}
