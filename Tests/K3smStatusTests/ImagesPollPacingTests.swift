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

/// CountingRead answers at once and counts its runs.
private actor CountingRead {
    private(set) var runs = 0
    func read() -> TabResult<Int> {
        runs += 1
        return .value(runs)
    }
}

@Suite("ImagesPollPacing")
@MainActor
struct ImagesPollPacingTests {
    @Test("the Images tab reads every 60 s, 120 s in low power")
    func imagesIntervals() {
        #expect(PollProfile.normal.intervals.images == .seconds(60))
        #expect(PollProfile.lowPower.intervals.images == .seconds(120))
    }

    @Test("a paused reader makes no timed read, and resumes with one at once")
    func pausesWhileHiddenAndResumesWhenVisible() async throws {
        let probe = CountingRead()
        let reader = TabReader<Int>(read: { await probe.read() }, interval: { _ in .milliseconds(100) })
        reader.start()
        try await Task.sleep(for: .milliseconds(350))
        #expect(await probe.runs >= 2)

        reader.setPaused(true)
        try await Task.sleep(for: .milliseconds(200))
        let held = await probe.runs
        try await Task.sleep(for: .milliseconds(500))
        #expect(await probe.runs == held, "no timed read while paused")
        #expect(reader.paused)

        reader.setPaused(false)
        try await Task.sleep(for: .milliseconds(40))
        #expect(await probe.runs == held + 1, "one immediate read on resume")
        reader.stop()
    }

    @Test("a refresh still reads while paused")
    func refreshReadsWhilePaused() async {
        let probe = CountingRead()
        let reader = TabReader<Int>(read: { await probe.read() }, interval: { _ in .seconds(60) })
        reader.setPaused(true)
        await reader.refresh()
        #expect(await probe.runs == 1)
    }

    @Test("a resume with the last read still younger than the interval waits it out")
    func freshReadIsNotRepeated() async throws {
        let probe = CountingRead()
        let reader = TabReader<Int>(read: { await probe.read() }, interval: { _ in .seconds(60) })
        reader.start()
        try await Task.sleep(for: .milliseconds(50))
        reader.setPaused(true)
        reader.setPaused(false)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await probe.runs == 1)
        reader.stop()
    }
}
