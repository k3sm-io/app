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

import K3smStatus
@testable import K3smInstall

/// The catch-up's root step: a node behind the server's own release is moved
/// by `k3sm update apply --yes --version <the server's release>`, the same
/// checked apply script, after the live report says (before and after the
/// question) that the server runs exactly that tag and that the confirmed
/// nodes are the ones not on it. The plan's table is
/// `K3smStatusTests.BehindNodeUpdateTests`.
@Suite("the behind node's update, pinned to the server's release")
struct BehindNodeUpdateScriptTests {
    static let team = ManagedUpdateTests.team

    static func server(release: String? = "v0.1.7", dirty: Bool = false,
                       workers: [StatusWorker]? = [StatusWorker(name: "node-b", role: "agent", version: "v1.36.2+k3sm.0.1.6")],
                       role: String = "server", rows extra: [StatusRow] = []) -> StatusReport {
        StatusReport(schemaVersion: 1, verdict: .running, role: role, summary: "s",
                     rows: [StatusRow(name: role, state: "running", detail: "d")] + extra,
                     workers: workers, release: release.map { StatusRelease(text: $0, dirty: dirty) })
    }

    /// The apply script for the behind-worker case, byte for byte: the
    /// checked lifecycle script with the server's release after --version.
    static let goldenCatchUp = UpdateVersionPinTests.goldenApply.replacingOccurrences(of: "'v0.1.8'", with: "'v0.1.7'")

    @Test("a worker behind a current server is moved by the apply pinned to the server's release")
    func behindNodeUpdate() async throws {
        #expect(Self.goldenCatchUp.hasSuffix("exec \"$k3sm\" 'update' 'apply' '--yes' '--version' 'v0.1.7'\n"))
        let reads = StatusSequence([Self.server(), Self.server()])
        let runner = LANRunner()
        let asked = Questions()
        let result = await ManagedUpdateTests.driver(reads, runner: runner, answer: true, downgrade: true, asked: asked)
            .apply(tag: "v0.1.7", target: .serverRelease)
        #expect(result == .ran(.started, .succeeded, "The update has started. Each node updates in turn, the server last."))
        #expect(reads.reads == 2)
        try #require(runner.scripts.count == 1)
        #expect(runner.scripts[0].text == Self.goldenCatchUp)
        #expect(runner.scripts[0].prompt == "k3sm wants to update k3sm on every node of this cluster.")
        #expect(try UpdateVersionPinTests.shellArgv(runner.scripts[0]) == ["update", "apply", "--yes", "--version", "v0.1.7"])
        // The question names the release and the node that moves, and offers no downgrade
        // (the downgrade answer above is ignored).
        try #require(asked.all.count == 1)
        let q = asked.all[0]
        #expect(q.verb == .updateApply && !q.offersDowngrade && q.update == .defaults)
        #expect(q.title == "Update node-b to k3sm v0.1.7?")
        #expect(q.message == "k3sm moves node-b to v0.1.7, the release the server runs, one node at a time. "
            + "Nodes already on it, the server too, are left as they are. Pods on each node that moves restart as it updates. "
            + "The window shows the progress, and the update can be cancelled from there.")
    }

    @Test("the options the question names are the ones the run passes, never a downgrade")
    func optionsFrozen() async throws {
        let reads = StatusSequence([Self.server(), Self.server()])
        let runner = LANRunner()
        let asked = Questions()
        _ = await ManagedUpdateTests.driver(reads, runner: runner, answer: true, downgrade: true, asked: asked)
            .apply(tag: "v0.1.7", target: .serverRelease,
                   options: UpdateOptions(drain: true, allowDowngrade: true, signature: .required))
        try #require(runner.scripts.count == 1)
        #expect(try UpdateVersionPinTests.shellArgv(runner.scripts[0])
            == ["update", "apply", "--yes", "--drain", "--signature", "required", "--version", "v0.1.7"])
        #expect(asked.all.first?.update == UpdateOptions(drain: true, allowDowngrade: false, signature: .required))
    }

    struct Refusal: CustomTestStringConvertible, Sendable {
        let name: String
        let tag: String
        let first: StatusReport?
        var second: StatusReport? = nil
        let why: String
        var testDescription: String { name }
    }

    static let notTagged = "The server no longer runs k3sm v0.1.7 as a tagged release. Nothing was changed."
    static let refusals: [Refusal] = [
        Refusal(name: "the status unreadable", tag: "v0.1.7", first: nil,
                why: "k3sm could not read the status of this Mac just now, so it did not start the update."),
        Refusal(name: "a roll running", tag: "v0.1.7",
                first: server(rows: [StatusRow(name: "update", state: "rolling", detail: "d", wide: ["target": "v0.1.7", "phase": "Rolling"])]),
                why: "An update is already rolling. The window shows its progress."),
        Refusal(name: "a worker", tag: "v0.1.7", first: server(workers: nil, role: "agent"),
                why: "This Mac no longer reports itself as the server, so it did not start the update. Nothing was changed."),
        Refusal(name: "the other nodes not listed", tag: "v0.1.7", first: server(workers: nil),
                why: "k3sm could not list the cluster's other nodes just now, so it did not start the update. Nothing was changed."),
        Refusal(name: "a developer build", tag: "v0.1.7", first: server(release: "dev"), why: notTagged),
        Refusal(name: "a pseudo-version", tag: "v0.1.7", first: server(release: "v0.1.8-0.20261015120000-0123456789ab"), why: notTagged),
        Refusal(name: "a modified tree", tag: "v0.1.7", first: server(dirty: true), why: notTagged),
        Refusal(name: "no release field", tag: "v0.1.7", first: server(release: nil), why: notTagged),
        Refusal(name: "another release", tag: "v0.1.7", first: server(release: "v0.1.8"), why: notTagged),
        Refusal(name: "the same version spelled otherwise", tag: "v0.1.7", first: server(release: "0.1.7"), why: notTagged),
        Refusal(name: "the same version with build metadata", tag: "v0.1.7", first: server(release: "v0.1.7+x"), why: notTagged),
        Refusal(name: "every node on it", tag: "v0.1.7",
                first: server(workers: [StatusWorker(name: "node-b", role: "agent", version: "v1.36.2+k3sm.0.1.7")]),
                why: "Every node runs k3sm v0.1.7 now, so there is nothing to update. Nothing was changed."),
        Refusal(name: "a node ahead", tag: "v0.1.7",
                first: server(workers: [StatusWorker(name: "node-b", role: "agent", version: "v1.36.2+k3sm.0.1.6"),
                                        StatusWorker(name: "node-c", role: "agent", version: "v1.36.2+k3sm.0.1.9")]),
                why: "node-c runs a newer release than the server's v0.1.7, and updating to it would move that node back. "
                    + "Update the server first. Nothing was changed."),
        Refusal(name: "the server's release changed while the question was open", tag: "v0.1.7",
                first: server(), second: server(release: "v0.1.8"), why: notTagged),
        Refusal(name: "a node joined behind while the question was open", tag: "v0.1.7", first: server(),
                second: server(workers: [StatusWorker(name: "node-b", role: "agent", version: "v1.36.2+k3sm.0.1.6"),
                                         StatusWorker(name: "node-e", role: "agent", version: "v1.36.2+k3sm.0.1.5")]),
                why: "The nodes behind k3sm v0.1.7 changed while the question was open. Nothing was changed."),
        Refusal(name: "a roll started elsewhere while the question was open", tag: "v0.1.7", first: server(),
                second: server(rows: [StatusRow(name: "update", state: "rolling", detail: "d", wide: ["target": "v0.1.7"])]),
                why: "An update is already rolling. The window shows its progress."),
    ]

    @Test("the catch-up refuses, with nothing run, unless the server still runs exactly the confirmed release",
          arguments: refusals)
    func refused(_ r: Refusal) async {
        let reads = StatusSequence([r.first, r.second ?? r.first])
        let runner = LANRunner()
        let asked = Questions()
        let result = await ManagedUpdateTests.driver(reads, runner: runner, answer: true, asked: asked)
            .apply(tag: r.tag, target: .serverRelease)
        #expect(result == .refused(r.why))
        #expect(runner.scripts.isEmpty)
        #expect(asked.all.count == (r.second == nil ? 0 : 1))
    }

    @Test("a declined question runs nothing, and an invalid tag reads nothing")
    func declinedAndInvalid() async {
        let reads = StatusSequence([Self.server(), Self.server()])
        let runner = LANRunner()
        #expect(await ManagedUpdateTests.driver(reads, runner: runner, answer: false).apply(tag: "v0.1.7", target: .serverRelease) == .declined)
        #expect(runner.scripts.isEmpty && reads.reads == 1)
        let untouched = StatusSequence([Self.server()])
        #expect(await ManagedUpdateTests.driver(untouched, runner: runner, answer: true).apply(tag: "v0.1.7;id", target: .serverRelease)
            == .refused(UpdateDriver.invalidTagText))
        #expect(untouched.reads == 0 && runner.scripts.isEmpty)
    }

    @Test("a passed check pins the server's own text and names the nodes that move")
    func pinsServerText() {
        #expect(UpdatePrecondition.serverRelease(tag: "v0.1.7", live: Self.server())
            == .proceed(ReleaseTag("v0.1.7")!, nodes: ["node-b"]))
        // The latest-release check does not pass the catch-up: no update row names v0.1.7.
        #expect(UpdatePrecondition.release(tag: "v0.1.7", live: Self.server()) != .proceed(ReleaseTag("v0.1.7")!))
    }
}
