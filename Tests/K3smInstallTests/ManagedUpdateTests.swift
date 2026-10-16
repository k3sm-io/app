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

@Suite("the managed update's root steps")
struct ManagedUpdateTests {
    static let team = TeamID("ABCDE12345")!

    static func report(latest: String?, state: String = "behind") -> StatusReport {
        var rows = [StatusRow(name: "server", state: "running", detail: "d")]
        if let latest {
            rows.append(StatusRow(name: "update", state: state, detail: "k3sm \(latest) is available; behind: a (v0.1.7)",
                                  wide: ["latest": latest]))
        }
        return StatusReport(schemaVersion: 1, verdict: .running, role: "server", summary: "s", rows: rows, workers: [])
    }

    static func driver(_ reads: StatusSequence, runner: LANRunner, answer: Bool, asked: Questions? = nil) -> UpdateDriver {
        UpdateDriver(teamID: team, readStatus: { reads.next() }, confirm: { c in
            asked?.append(c)
            return answer
        }, runner: runner)
    }

    @Test("the update verbs run the checked lifecycle script with the fixed argv")
    func scripts() {
        #expect(LifecycleVerb.updateVerbs == [.updateApply, .updateCancel])
        #expect(LifecycleVerb.updateVerbs.allSatisfy { $0.isUpdate && !$0.isLAN && $0.requiredState == nil })
        let apply = LifecycleScriptBuilder.render(.updateApply, teamID: Self.team)
        #expect(apply.text.hasSuffix("exec \"$k3sm\" 'update' 'apply' '--yes'\n"))
        #expect(apply.text.contains("/usr/bin/codesign --verify --strict"))
        #expect(apply.prompt == "k3sm wants to update k3sm on every node of this cluster.")
        #expect(!apply.readsInput && !apply.usesStagingLock)
        let cancel = LifecycleScriptBuilder.render(.updateCancel, teamID: Self.team)
        #expect(cancel.text.hasSuffix("exec \"$k3sm\" 'update' 'cancel'\n"))
        #expect(cancel.prompt == "k3sm wants to cancel the k3sm update.")
    }

    @Test("the lifecycle and LAN drivers refuse an update verb", arguments: LifecycleVerb.updateVerbs)
    func otherDriversRefuse(_ verb: LifecycleVerb) async {
        let runner = LANRunner()
        let lifecycle = LifecycleDriver(teamID: Self.team, readStatus: { Self.report(latest: "v0.1.8") }, confirm: { _ in true }, runner: runner)
        guard case .refused = await lifecycle.perform(verb, expected: .running) else {
            Issue.record("the lifecycle driver ran \(verb)")
            return
        }
        #expect(runner.scripts.isEmpty)
    }

    @Test("apply: two live reads, the question names the tag, then the script")
    func apply() async {
        let reads = StatusSequence([Self.report(latest: "v0.1.8"), Self.report(latest: "v0.1.8")])
        let runner = LANRunner()
        let asked = Questions()
        let result = await Self.driver(reads, runner: runner, answer: true, asked: asked).apply(tag: "v0.1.8")
        #expect(result == .ran(.started, .succeeded, "The update has started. Each node updates in turn, the server last."))
        #expect(reads.reads == 2)
        #expect(asked.all.map(\.title) == ["Update k3sm to v0.1.8?"])
        #expect(asked.all.first?.message == UpdateConfirmationText.apply)
        #expect(runner.scripts == [LifecycleScriptBuilder.render(.updateApply, teamID: Self.team)])
    }

    @Test("apply refuses when the live row no longer offers the tag", arguments: [
        [nil], [report(latest: nil)], [report(latest: "v0.1.8", state: "ok")], [report(latest: "v0.1.9")],
        [report(latest: "v0.1.8"), report(latest: "v0.1.8", state: "ok")],
    ] as [[StatusReport?]])
    func applyRefused(_ reports: [StatusReport?]) async {
        let runner = LANRunner()
        let result = await Self.driver(StatusSequence(reports), runner: runner, answer: true).apply(tag: "v0.1.8")
        guard case .refused = result else {
            Issue.record("not refused: \(result)")
            return
        }
        #expect(runner.scripts.isEmpty)
    }

    @Test("apply refuses while the row says an update is rolling")
    func applyWhileRolling() async {
        let rolling = StatusReport(schemaVersion: 1, verdict: .running, role: "server", summary: "s", rows: [
            StatusRow(name: "update", state: "rolling", detail: "updating", wide: ["phase": "Rolling", "latest": "v0.1.8"]),
        ], workers: [])
        let runner = LANRunner()
        let result = await Self.driver(StatusSequence([rolling]), runner: runner, answer: true).apply(tag: "v0.1.8")
        #expect(result == .refused("An update is already rolling. The window shows its progress."))
        #expect(runner.scripts.isEmpty)
    }

    @Test("a declined question runs nothing")
    func declined() async {
        let runner = LANRunner()
        #expect(await Self.driver(StatusSequence([Self.report(latest: "v0.1.8")]), runner: runner, answer: false).apply(tag: "v0.1.8") == .declined)
        #expect(await Self.driver(StatusSequence([]), runner: runner, answer: false).cancel() == .declined)
        #expect(runner.scripts.isEmpty)
    }

    @Test("an apply refused as already rolling is followed as a roll")
    func alreadyRolling() async {
        let runner = LANRunner(PrivilegedRun(outcome: .failed(exitStatus: 1), errorOutput: "k3sm: an update is already rolling (Rolling)\n"))
        let reads = StatusSequence([Self.report(latest: "v0.1.8"), Self.report(latest: "v0.1.8")])
        let result = await Self.driver(reads, runner: runner, answer: true).apply(tag: "v0.1.8")
        #expect(result == .ran(.alreadyRolling, .failed(exitStatus: 1), "An update is already rolling. The window shows its progress."))
    }

    @Test("the CLI's own refusal for an unfinished Update is followed as a roll")
    func alreadyRollingAsLanded() {
        let text = "k3sm update apply: the Update current to v0.1.8 is Rolling; follow it with `k3sm update status --watch`, or stop it with `k3sm update cancel`\n"
        #expect(UpdateDriver.classify(PrivilegedRun(outcome: .failed(exitStatus: 1), errorOutput: text), verb: .updateApply)
            == .ran(.alreadyRolling, .failed(exitStatus: 1), "An update is already rolling. The window shows its progress."))
    }

    @Test("other outcomes start nothing and show cleaned CLI text")
    func classify() {
        #expect(UpdateDriver.classify(PrivilegedRun(outcome: .cancelled), verb: .updateApply)
            == .ran(.notStarted, .cancelled, "Cancelled. Nothing was changed."))
        #expect(UpdateDriver.classify(PrivilegedRun(outcome: .failed(exitStatus: 1), errorOutput: "k3sm: no\u{202E} release\n"), verb: .updateApply)
            == .ran(.notStarted, .failed(exitStatus: 1), "k3sm update apply --yes failed: k3sm: no release"))
        #expect(UpdateDriver.classify(PrivilegedRun(outcome: .failed(exitStatus: 101)), verb: .updateApply)
            == .ran(.notStarted, .failed(exitStatus: 101), "The installed k3sm is not signed by the k3sm Developer ID, so nothing was run."))
        // The already-rolling words from a cancel are not a started roll.
        #expect(UpdateDriver.classify(PrivilegedRun(outcome: .failed(exitStatus: 1), errorOutput: "an update is already rolling"), verb: .updateCancel)
            == .ran(.notStarted, .failed(exitStatus: 1), "k3sm update cancel failed: an update is already rolling"))
        #expect(UpdateDriver.classify(PrivilegedRun(outcome: .succeeded), verb: .updateCancel)
            == .ran(.notStarted, .succeeded, "k3sm is cancelling the update."))
    }

    @Test("cancel asks, with Keep Updating as the answer no, then runs the cancel script")
    func cancel() async {
        let runner = LANRunner()
        let asked = Questions()
        let result = await Self.driver(StatusSequence([]), runner: runner, answer: true, asked: asked).cancel()
        #expect(result == .ran(.notStarted, .succeeded, "k3sm is cancelling the update."))
        #expect(asked.all.map(\.title) == ["Cancel the update?"])
        #expect(asked.all.first?.cancelTitle == "Keep Updating")
        #expect(runner.scripts == [LifecycleScriptBuilder.render(.updateCancel, teamID: Self.team)])
    }

    @Test("the update verbs the app runs are ones the CLI declares", .enabled(if: LifecycleScriptTests.cliDirectory.map {
        (try? String(contentsOf: $0.appending(path: "update.go"), encoding: .utf8))?.contains("\"apply\"") == true
    } ?? false))
    func declared() throws {
        let dir = try #require(LifecycleScriptTests.cliDirectory)
        let update = try String(contentsOf: dir.appending(path: "update.go"), encoding: .utf8)
        for word in ["\"apply\"", "\"cancel\"", "\"status\"", "\"yes\""] {
            #expect(update.contains(word), "cmd/k3sm/update.go declares no \(word)")
        }
        // The refusal the app follows, and the status fields it reads.
        #expect(update.contains(UpdateDriver.alreadyRollingMarkers[0]), "the apply's refusal text moved")
        for tag in ["json:\"phase\"", "json:\"version\"", "json:\"resolved\"", "json:\"nodes\"", "json:\"conditions\"",
                    "json:\"name,omitempty\"", "json:\"finished,omitempty\"", "json:\"lastProgress,omitempty\""] {
            #expect(update.contains(tag), "cmd/k3sm/update.go has no \(tag)")
        }
    }
}
