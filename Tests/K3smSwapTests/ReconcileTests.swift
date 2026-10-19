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
import K3smSwap
import Testing

@Suite("swap reconcile and launch arguments")
struct ReconcileTests {
    static let original = FileIdentity(volume: "V", ino: 100, dev: 1)
    static let incoming = FileIdentity(volume: "V", ino: 200, dev: 1)
    static let other = FileIdentity(volume: "V", ino: 300, dev: 1)

    static func journal(_ state: JournalState, incoming: FileIdentity? = ReconcileTests.incoming) -> SwapJournal {
        var j = SwapJournal(request: SwapRequest(mode: .update, target: "/Applications/k3sm.app", stagedName: ".k3sm.app.update-abcdefgh",
                                                 expectedTag: "v1.1.0", token: String(repeating: "a", count: 64),
                                                 app: ProcessIdentity(pid: 1, start: ProcessStart(seconds: 1, microseconds: 0))),
                            state: state)
        j.original = original
        j.incoming = incoming
        j.outgoingTag = "v1.0.0"
        j.previousName = "k3sm-v1.0.0.previous"
        return j
    }

    struct Row: Sendable, CustomTestStringConvertible {
        let state: JournalState
        let at: FileIdentity?
        let lock: Bool
        let running: Bool
        let outgoing: Bool
        let want: ReconcileAction
        var testDescription: String { "\(state) at:\(at.map { String($0.ino) } ?? "none") lock:\(lock) running:\(running) outgoing:\(outgoing)" }
    }

    static let o = ReconcileTests.original, i = ReconcileTests.incoming, x = ReconcileTests.other

    static let table: [Row] = [
        // A live helper is left alone, whatever the journal says.
        Row(state: .swapped, at: i, lock: true, running: false, outgoing: true, want: .nothing),
        Row(state: .launched, at: i, lock: true, running: true, outgoing: true, want: .nothing),
        // Before the swap: the original is in place, nothing happened.
        Row(state: .staged, at: o, lock: false, running: false, outgoing: true, want: .discard),
        Row(state: .verified, at: o, lock: false, running: false, outgoing: true, want: .discard),
        // Written before its act: `swapped` with the original in place.
        Row(state: .swapped, at: o, lock: false, running: false, outgoing: true, want: .discard),
        Row(state: .launched, at: o, lock: false, running: true, outgoing: true, want: .discard),
        // The new bundle is in place.
        Row(state: .swapped, at: i, lock: false, running: true, outgoing: true, want: .commit),
        Row(state: .launched, at: i, lock: false, running: true, outgoing: false, want: .commit),
        Row(state: .launched, at: i, lock: false, running: false, outgoing: true, want: .swapBack),
        Row(state: .launched, at: i, lock: false, running: false, outgoing: false, want: .leave),
        // A rollback written but not done is finished.
        Row(state: .rolledBack, at: i, lock: false, running: true, outgoing: true, want: .swapBack),
        Row(state: .rolledBack, at: i, lock: false, running: true, outgoing: false, want: .commit),
        Row(state: .rolledBack, at: i, lock: false, running: false, outgoing: false, want: .leave),
        Row(state: .rolledBack, at: o, lock: false, running: false, outgoing: true, want: .discard),
        // Something else at the target, or nothing.
        Row(state: .launched, at: x, lock: false, running: false, outgoing: true, want: .forget),
        Row(state: .swapped, at: nil, lock: false, running: false, outgoing: true, want: .forget),
        // Done.
        Row(state: .committed, at: i, lock: false, running: true, outgoing: true, want: .nothing),
        Row(state: .committed, at: x, lock: false, running: false, outgoing: false, want: .nothing),
    ]

    @Test(arguments: table)
    func reconcileDecisionTable(_ row: Row) {
        let facts = ReconcileFacts(lockHeld: row.lock, atTarget: row.at, runningTag: row.running ? "v1.1.0" : "v1.0.0",
                                   runningSelfCheck: true, outgoingVerifies: row.outgoing)
        #expect(SwapReconciler.decide(journal: Self.journal(row.state), facts: facts) == row.want)
    }

    @Test func reconcileDecisionEdges() {
        let facts = ReconcileFacts(lockHeld: false, atTarget: Self.incoming, runningTag: "v1.1.0", runningSelfCheck: false, outgoingVerifies: true)
        // The right tag with a failing self check is not the new app running.
        #expect(SwapReconciler.decide(journal: Self.journal(.launched), facts: facts) == .swapBack)
        #expect(SwapReconciler.decide(journal: nil, facts: facts) == .nothing)
        // A finished rollback (incoming cleared) needs nothing more.
        let done = ReconcileFacts(lockHeld: false, atTarget: Self.original, runningTag: "v1.0.0", runningSelfCheck: true, outgoingVerifies: true)
        #expect(SwapReconciler.decide(journal: Self.journal(.rolledBack, incoming: nil), facts: done) == .nothing)
    }

    @Test func launchArguments() {
        let a = SwapLaunchArguments(arguments: ["/x/k3sm-app", "--updated-from", "v1.0.0", "--handshake"])
        #expect(a.answersHandshake)
        #expect(a.updatedFromTag == "v1.0.0")
        #expect(a.updateFailedTag == nil)
        let b = SwapLaunchArguments(arguments: ["/x/k3sm-app", "--update-failed", "v1.1.0-rc.2"])
        #expect(!b.answersHandshake)
        #expect(b.updateFailedTag == "v1.1.0-rc.2")
        let c = SwapLaunchArguments(arguments: ["--handshake", "--update-failed", "1.1.0;id", "--updated-from"])
        #expect(!c.answersHandshake)   // the executable slot is never read
        #expect(c.updateFailedTag == nil)
        #expect(c.updatedFromTag == nil)
    }

    @Test func pathsAndNames() {
        let p = SwapPaths(home: "/Users/u", applicationsRoots: ["/Applications", "/Users/u/Applications"])
        #expect(p.privateDirectory == "/Users/u/Library/Application Support/io.k3sm.app/update")
        #expect(p.previousDirectory == "/Users/u/Library/Application Support/io.k3sm.app/previous")
        #expect(p.allowedTargets == ["/Applications/k3sm.app", "/Users/u/Applications/k3sm.app"])
        #expect(!p.privateDirectory.hasPrefix("/Library/"))
        #expect(SwapPaths.isStagingName(".k3sm.app.update-abcDEF12"))
        #expect(!SwapPaths.isStagingName(".k3sm.app.update-abc"))
        #expect(!SwapPaths.isStagingName(".k3sm.app.update-abcdefgh/.."))
        #expect(!SwapPaths.isStagingName(".k3sm.app.update-" + String(repeating: "a", count: 33)))
        #expect(SwapPaths.isStagingName(SwapPaths.newStagingName()))
        #expect(SwapPaths.stagingDirectory(target: "/Applications/k3sm.app", name: ".k3sm.app.update-abcdefgh")
            == "/Applications/.k3sm.app.update-abcdefgh")
        #expect(p.refusal(target: "/Volumes/k3sm/k3sm.app") != nil)
        #expect(p.refusal(target: "/private/var/folders/x/AppTranslocation/y/d/k3sm.app") == .translocated)
        #expect(SwapPaths.previousName(tag: "v1.2.3-rc.1") == "k3sm-v1.2.3-rc.1.previous")
        #expect(SwapPaths.tag(ofPreviousName: "k3sm-../x.previous") == nil)
    }
}
