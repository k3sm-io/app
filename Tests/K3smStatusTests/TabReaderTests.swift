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

/// ReadProbe is a read that waits until cancelled (or answers at once),
/// recording whether it started and whether it saw its cancellation, which
/// is what kills a real read's CLI child.
actor ReadProbe {
    private(set) var started = 0
    private(set) var cancelled = 0
    let blocks: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(blocks: Bool) { self.blocks = blocks }

    func read() async -> TabResult<Int> {
        started += 1
        for w in waiters { w.resume() }
        waiters = []
        if blocks {
            do { try await Task.sleep(for: .seconds(60)) } catch { cancelled += 1 }
        }
        return .value(started)
    }

    func waitStarted() async {
        if started > 0 { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

@Suite("a tab's read loop")
@MainActor
struct TabReaderTests {
    @Test("a refresh in flight is cancelled by stop and its result discarded")
    func refreshInFlightIsCancelledByStop() async {
        let probe = ReadProbe(blocks: true)
        let reader = TabReader<Int>(read: { await probe.read() }, interval: { _ in .seconds(60) })
        let refresh = Task { await reader.refresh() }
        await probe.waitStarted()
        #expect(reader.load == .firstRead)
        reader.stop()
        await refresh.value
        #expect(await probe.cancelled == 1)
        #expect(reader.value == nil)
        #expect(reader.readAt == nil)
        #expect(reader.load == .idle)
    }

    @Test("a refresh reads, and a stop keeps the value it read")
    func refreshReadsAndStopKeepsIt() async {
        let probe = ReadProbe(blocks: false)
        let reader = TabReader<Int>(read: { await probe.read() }, interval: { _ in .seconds(60) })
        var changes = 0
        reader.willChange = { changes += 1 }
        await reader.refresh()
        #expect(reader.value == 1)
        guard case .loaded(let at) = reader.load else { Issue.record("not loaded"); return }
        #expect(reader.readAt == at)
        #expect(changes >= 2)
        reader.stop()
        #expect(reader.value == 1)
        #expect(reader.load == .loaded(at))
    }

    @Test("a start reads at once and a stop cancels the loop's read")
    func startReadsAndStopCancels() async {
        let probe = ReadProbe(blocks: true)
        let reader = TabReader<Int>(read: { await probe.read() }, interval: { _ in .seconds(60) })
        reader.start()
        #expect(reader.running)
        await probe.waitStarted()
        reader.stop()
        #expect(!reader.running)
        #expect(reader.load == .idle)
        while await probe.cancelled == 0 { await Task.yield() }
        #expect(reader.value == nil)
    }
}
