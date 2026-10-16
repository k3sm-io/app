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

@Suite("a console tab's read state")
struct TabLoadTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test("a read begins as a first read without a value and a refresh with one")
    func begin() {
        #expect(TabLoad.begin(hasValue: false) == .firstRead)
        #expect(TabLoad.begin(hasValue: true) == .refreshing)
        #expect(TabLoad.firstRead.inFlight && TabLoad.refreshing.inFlight)
        #expect(!TabLoad.idle.inFlight && !TabLoad.loaded(t0).inFlight)
    }

    @Test("a finished read carries only cleaned text")
    func finished() {
        #expect(TabLoad.finished(TabResult<Int>.value(1), at: t0) == .loaded(t0))
        #expect(TabLoad.finished(TabResult<Int>.failed("bad\u{202E}\n\nthing"), at: t0) == .failed("bad thing"))
        #expect(TabLoad.finished(TabResult<Int>.unavailable("gone\u{0007}"), at: t0) == .unavailable("gone "))
    }

    @Test("a stop puts a cancelled read back and keeps every other state")
    func stopKeepsTheLastResult() {
        #expect(TabLoad.stopped(.refreshing, readAt: t0) == .loaded(t0))
        #expect(TabLoad.stopped(.firstRead, readAt: nil) == .idle)
        #expect(TabLoad.stopped(.refreshing, readAt: nil) == .idle)
        #expect(TabLoad.stopped(.loaded(t0), readAt: t0) == .loaded(t0))
        #expect(TabLoad.stopped(.failed("x"), readAt: t0) == .failed("x"))
    }

    @Test("only a failed or impossible read counts as one")
    func failedOrUnavailable() {
        #expect(TabLoad.failed("x").failedOrUnavailable && TabLoad.unavailable("y").failedOrUnavailable)
        #expect(![TabLoad.idle, .firstRead, .refreshing, .loaded(t0)].contains { $0.failedOrUnavailable })
    }

    @Test("a tab says how old its read is")
    func age() {
        #expect(TabLoad.age(since: t0, now: t0.addingTimeInterval(2)) == "read just now")
        #expect(TabLoad.age(since: t0, now: t0.addingTimeInterval(40)) == "read 40 s ago")
        #expect(TabLoad.age(since: t0, now: t0.addingTimeInterval(200)) == "read 3 min ago")
        #expect(TabLoad.age(since: t0, now: t0.addingTimeInterval(7300)) == "read 2 h ago")
        #expect(TabLoad.age(since: t0, now: t0.addingTimeInterval(-5)) == "read just now")
    }

    @Test("a pod-list run maps onto the tab result as the list showed it")
    func workloadsResult() throws {
        let listed = Workloads.tabResult(exitCode: 0, stdout: try fixture("kubectl_pods_running.json"))
        guard case .value(let w) = listed else { Issue.record("not listed"); return }
        #expect(!w.pods.isEmpty)
        #expect(Workloads.tabResult(exitCode: 1, stdout: Data()) == .failed("k3sm kubectl exited 1"))
    }
}
