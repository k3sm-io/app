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

/// The catch-up's root step: a node behind the release installed on the
/// server is moved by `k3sm update apply --yes --version <that release>`, the
/// same checked apply script, after the live report says (before and after
/// the question) that the server's k3sm reports exactly that tag, and which
/// nodes are not on it by their Node's kubelet version, the server's own
/// included. The plan's table is `K3smStatusTests.BehindNodeUpdateTests`.
@Suite("the behind node's update, pinned to the server's release")
struct BehindNodeUpdateScriptTests {
    static let team = ManagedUpdateTests.team

    /// A server's live report: its k3sm's release, its own Node (`my-mac`)
    /// in the `node` row with `kubelet` (no row when nil), and the others.
    static func server(release: String? = "v0.1.7", dirty: Bool = false, kubelet: String? = "v1.36.2+k3sm.0.1.7",
                       workers: [StatusWorker]? = [StatusWorker(name: "node-b", role: "agent", version: "v1.36.2+k3sm.0.1.6")],
                       role: String = "server", rows extra: [StatusRow] = []) -> StatusReport {
        var rows = [StatusRow(name: role, state: "running", detail: "d")]
        if let kubelet { rows.append(StatusRow(name: "node", state: "ready", detail: "d", wide: ["node": "my-mac", "kubelet": kubelet])) }
        return StatusReport(schemaVersion: 1, verdict: .running, role: role, summary: "s", rows: rows + extra,
                            workers: workers, release: release.map { StatusRelease(text: $0, dirty: dirty) })
    }

    /// The apply script for the behind-worker case, byte for byte.
    static let goldenCatchUp = #"""
        set -eu
        umask 077
        cd /
        k3sm='/Library/k3sm/k3sm'
        refuse() {
        	echo "k3sm app: refused: $1" >&2
        	exit 100
        }
        nl='
        '
        acl_check() {
        	listing=$(/bin/ls -led "$1") || refuse "$1 could not be checked"
        	case "${listing%% *}" in *+) refuse "$1 carries an ACL" ;; esac
        	case "$listing" in *"$nl"*) refuse "$1 carries an ACL" ;; esac
        }
        for p in '/' '/Library' '/Library/k3sm' '/Library/k3sm/k3sm'; do
        	if [ -L "$p" ]; then refuse "$p is a symlink"; fi
        	if [ ! -e "$p" ]; then refuse "$p does not exist"; fi
        	bad=$(/usr/bin/find "$p" -maxdepth 0 \( ! -user 0 -o -perm -0020 -o -perm -0002 \) -print) || refuse "$p could not be checked"
        	if [ -n "$bad" ]; then refuse "$p is not owned by root, or is writable by group or others"; fi
        	acl_check "$p"
        done
        if [ ! -f "$k3sm" ]; then refuse "$k3sm is not a regular file"; fi
        if ! /usr/bin/codesign --verify --strict '-R=anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = "ABCDE12345"' "$k3sm"; then
        	echo 'k3sm app: refused: the installed k3sm is not signed by the k3sm Developer ID' >&2
        	exit 101
        fi
        exec "$k3sm" 'update' 'apply' '--yes' '--version' 'v0.1.7'

        """#

    @Test("a worker behind a current server is moved by the apply pinned to the server's release")
    func behindNodeUpdate() async throws {
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
        // The question names the release and the node that moves, says the
        // server stays only because its Node is on the release, says the
        // server decides the final set, and offers no downgrade (the
        // downgrade answer above is ignored).
        try #require(asked.all.count == 1)
        let q = asked.all[0]
        #expect(q.verb == .updateApply && !q.offersDowngrade && q.update == .defaults)
        #expect(q.title == "Update node-b to k3sm v0.1.7?")
        #expect(q.message == "k3sm moves node-b to v0.1.7, the release the server runs, one node at a time. "
            + "Nodes already on it, the server too, are left as they are. "
            + "The server decides the final set when the update starts: a node that joins or changes before then moves to v0.1.7 too. "
            + "Pods on each node that moves restart as it updates. "
            + "The window shows the progress, and the update can be cancelled from there.")
    }

    @Test("a server whose own node runs an older release than its k3sm moves last, and the question says so")
    func serverNodeBehindMovesLast() async throws {
        let lagging = Self.server(kubelet: "v1.36.2+k3sm.0.1.6")
        #expect(UpdatePrecondition.serverRelease(tag: "v0.1.7", live: lagging)
            == .proceed(ReleaseTag("v0.1.7")!, nodes: ["node-b", "my-mac"], server: "my-mac"))
        let reads = StatusSequence([lagging, lagging])
        let runner = LANRunner()
        let asked = Questions()
        _ = await ManagedUpdateTests.driver(reads, runner: runner, answer: true, asked: asked).apply(tag: "v0.1.7", target: .serverRelease)
        try #require(runner.scripts.count == 1 && asked.all.count == 1)
        #expect(runner.scripts[0].text == Self.goldenCatchUp)
        #expect(asked.all[0].title == "Update 2 nodes to k3sm v0.1.7?")
        #expect(asked.all[0].message == "k3sm moves node-b to v0.1.7, the release installed on the server, one node at a time, "
            + "and then this server, my-mac, whose node still runs an older release: the server restarts last. "
            + "Nodes already on it are left as they are. "
            + "The server decides the final set when the update starts: a node that joins or changes before then moves to v0.1.7 too. "
            + "Pods on each node that moves restart as it updates. "
            + "The window shows the progress, and the update can be cancelled from there.")

        // Only the server's own node behind: it alone moves.
        let alone = Self.server(kubelet: "v1.36.2+k3sm.0.1.6",
                                workers: [StatusWorker(name: "node-b", role: "agent", version: "v1.36.2+k3sm.0.1.7")])
        let reads2 = StatusSequence([alone, alone])
        let asked2 = Questions()
        _ = await ManagedUpdateTests.driver(reads2, runner: LANRunner(), answer: true, asked: asked2).apply(tag: "v0.1.7", target: .serverRelease)
        try #require(asked2.all.count == 1)
        #expect(asked2.all[0].title == "Update my-mac to k3sm v0.1.7?")
        #expect(asked2.all[0].message == "k3sm moves this server, my-mac, whose node still runs an older release, to v0.1.7, "
            + "the release installed on it; the server restarts. Nodes already on it are left as they are. "
            + "The server decides the final set when the update starts: a node that joins or changes before then moves to v0.1.7 too. "
            + "Pods on each node that moves restart as it updates. "
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
        let first: StatusReport?
        var second: StatusReport? = nil
        let why: String
        var testDescription: String { name }
    }

    static let refusals: [Refusal] = [
        Refusal(name: "the status unreadable", first: nil,
                why: "k3sm could not read the status of this Mac just now, so it did not start the update."),
        Refusal(name: "a roll running",
                first: server(rows: [StatusRow(name: "update", state: "rolling", detail: "d", wide: ["target": "v0.1.7", "phase": "Rolling"])]),
                why: "An update is already rolling. The window shows its progress."),
        Refusal(name: "no longer the server", first: server(workers: nil, role: "agent"),
                why: "This Mac no longer reports itself as the server, so it did not start the update. Nothing was changed."),
        Refusal(name: "the other nodes not listed", first: server(workers: nil),
                why: "k3sm could not list the cluster's other nodes just now, so it did not start the update. Nothing was changed."),
        Refusal(name: "a developer build", first: server(release: "dev"),
                why: "The server no longer runs k3sm v0.1.7 as a tagged release. Nothing was changed."),
        Refusal(name: "untagged: a pseudo-version", first: server(release: "v0.1.8-0.20261015120000-0123456789ab"),
                why: "The server no longer runs k3sm v0.1.7 as a tagged release. Nothing was changed."),
        Refusal(name: "dirty: built from a modified tree", first: server(dirty: true),
                why: "The server no longer runs k3sm v0.1.7 as a tagged release. Nothing was changed."),
        Refusal(name: "no release field", first: server(release: nil),
                why: "The server no longer runs k3sm v0.1.7 as a tagged release. Nothing was changed."),
        Refusal(name: "another release", first: server(release: "v0.1.8"),
                why: "The server no longer runs k3sm v0.1.7 as a tagged release. Nothing was changed."),
        Refusal(name: "the same version spelled otherwise", first: server(release: "0.1.7"),
                why: "The server no longer runs k3sm v0.1.7 as a tagged release. Nothing was changed."),
        Refusal(name: "the same version with build metadata", first: server(release: "v0.1.7+x"),
                why: "The server no longer runs k3sm v0.1.7 as a tagged release. Nothing was changed."),
        Refusal(name: "the server's own node not reported", first: server(kubelet: nil),
                why: "k3sm did not report this server's own node and the release its kubelet runs, "
                    + "so the app cannot tell which nodes the update would move. Nothing was changed."),
        Refusal(name: "every node on it",
                first: server(workers: [StatusWorker(name: "node-b", role: "agent", version: "v1.36.2+k3sm.0.1.7")]),
                why: "Every node runs k3sm v0.1.7 now, so there is nothing to update. Nothing was changed."),
        Refusal(name: "a node ahead",
                first: server(workers: [StatusWorker(name: "node-b", role: "agent", version: "v1.36.2+k3sm.0.1.6"),
                                        StatusWorker(name: "node-c", role: "agent", version: "v1.36.2+k3sm.0.1.9")]),
                why: "node-c runs a newer release than the server's v0.1.7, and updating to it would move that node back. "
                    + "Update the server first. Nothing was changed."),
        Refusal(name: "the server's own node ahead of its k3sm", first: server(kubelet: "v1.36.2+k3sm.0.1.8"),
                why: "my-mac runs a newer release than the server's v0.1.7, and updating to it would move that node back. "
                    + "Update the server first. Nothing was changed."),
        Refusal(name: "the server's release changed while the question was open",
                first: server(), second: server(release: "v0.1.8"),
                why: "The server no longer runs k3sm v0.1.7 as a tagged release. Nothing was changed."),
        Refusal(name: "a changed moved set: a node joined behind while the question was open", first: server(),
                second: server(workers: [StatusWorker(name: "node-b", role: "agent", version: "v1.36.2+k3sm.0.1.6"),
                                         StatusWorker(name: "node-e", role: "agent", version: "v1.36.2+k3sm.0.1.5")]),
                why: "The nodes behind k3sm v0.1.7 changed while the question was open. Nothing was changed."),
        Refusal(name: "a changed moved set: the server's own node fell behind while the question was open", first: server(),
                second: server(kubelet: "v1.36.2+k3sm.0.1.6"),
                why: "The nodes behind k3sm v0.1.7 changed while the question was open. Nothing was changed."),
        Refusal(name: "a roll started elsewhere while the question was open", first: server(),
                second: server(rows: [StatusRow(name: "update", state: "rolling", detail: "d", wide: ["target": "v0.1.7"])]),
                why: "An update is already rolling. The window shows its progress."),
        Refusal(name: "no longer the server after the question", first: server(), second: server(workers: nil, role: "agent"),
                why: "This Mac no longer reports itself as the server, so it did not start the update. Nothing was changed."),
    ]

    @Test("the catch-up refuses, with nothing run, unless the server still runs exactly the confirmed release",
          arguments: refusals)
    func refused(_ r: Refusal) async {
        let reads = StatusSequence([r.first, r.second ?? r.first])
        let runner = LANRunner()
        let asked = Questions()
        let result = await ManagedUpdateTests.driver(reads, runner: runner, answer: true, asked: asked)
            .apply(tag: "v0.1.7", target: .serverRelease)
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
            == .proceed(ReleaseTag("v0.1.7")!, nodes: ["node-b"], server: "my-mac"))
        // The latest-release check does not pass the catch-up: no update row names v0.1.7.
        #expect(UpdatePrecondition.release(tag: "v0.1.7", live: Self.server()) != .proceed(ReleaseTag("v0.1.7")!))
    }

    /// The app target cannot be imported by a test, so its wiring is read
    /// as source: the update driver's `readStatus` is `readFullReport`, which
    /// runs `K3smCLI.reportArguments` (`status -o json`) through the
    /// trust-checked CLI at `K3smCLI.path` on this Mac, never a report read
    /// from another Mac or the network.
    @Test("the update driver's status read is this Mac's own k3sm status -o json")
    func readStatusIsLocal() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appending(path: "Sources/K3smApp/AppModel.swift"), encoding: .utf8)
        func body(_ marker: String) throws -> String {
            let start = try #require(source.range(of: marker), "no \(marker) in AppModel.swift")
            let rest = source[start.upperBound...]
            let end = rest.range(of: "\n    }\n") ?? (rest.endIndex..<rest.endIndex)
            return String(rest[..<end.lowerBound])
        }
        let driver = try body("private func updateDriver(_ teamID: TeamID) -> UpdateDriver {")
        #expect(driver.contains("readStatus: { await self.readFullReport() },"), "\(driver)")
        #expect(try body("func readFullReport() async -> StatusReport? {").trimmingCharacters(in: .whitespacesAndNewlines)
            == "await fullRead()")
        #expect(try body("private func fullRead() async -> StatusReport? {").contains("await runCLI(K3smCLI.reportArguments)"))
        #expect(try body("private var cli: TrustedCLI<CLIOutcome> {").contains("CLIProcess.run(path: K3smCLI.path, arguments: arguments"))
        #expect(K3smCLI.reportArguments == ["status", "-o", "json"])
        #expect(K3smCLI.path == "/Library/k3sm/k3sm")
    }
}
