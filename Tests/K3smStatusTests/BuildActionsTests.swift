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

@Suite("the Builds tab's actions")
struct BuildActionsTests {
    static func record(_ id: String, status: String, tag: String = "web:dev") throws -> BuildRecord {
        let json = #"[{"id":"\#(id)","status":"\#(status)","tag":"\#(tag)","startedAt":"2026-10-16T07:00:00Z"}]"#
        return try #require(try BuildHistory.decode(Data(json.utf8)).first)
    }

    struct StatusCase: Sendable, CustomTestStringConvertible {
        let status: BuildStatus
        let want: [BuildAction]
        var testDescription: String { status.word }
    }

    static let statusCases: [StatusCase] = [
        StatusCase(status: .running, want: [.showLog, .cancel]),
        StatusCase(status: .succeeded, want: [.showLog, .delete]),
        StatusCase(status: .failed, want: [.showLog, .delete]),
        StatusCase(status: .cancelled, want: [.showLog, .delete]),
        StatusCase(status: .other("queued"), want: [.showLog]),
        StatusCase(status: .other(""), want: [.showLog]),
    ]

    @Test("a build offers Cancel only while it runs and Delete only once it has finished", arguments: statusCases)
    func buildActionsForStatus(_ c: StatusCase) {
        let actions = BuildActions.actionsForBuild(status: c.status)
        #expect(actions == c.want)
        #expect(actions.contains(.cancel) == (c.status == .running))
        #expect(actions.contains(.delete) == c.status.finished)
    }

    @Test("the row menu follows the status: kinds, titles, the Delete key and the log's follow")
    func rowMenu() throws {
        let running = BuildActions.menu(for: try Self.record("aaaaaaaaaaaa", status: "running"))
        #expect(running.local.map(\.title) == ["Show Log"])
        #expect(running.items.map(\.title) == ["Cancel Build…"])
        #expect(running.items.map(\.kind) == [.change])
        #expect(running.deleteKeyItem == nil)
        let id = try #require(BuildRecordID("aaaaaaaaaaaa"))
        #expect(running.local.first?.action == .showBuildLog(BuildLogTarget(id: id, title: "web:dev", follow: true)))
        let cancel = try #require(running.items.first?.request as? BuildActionRequest)
        #expect(cancel.arguments == ["build", "cancel", "aaaaaaaaaaaa"])
        #expect(cancel.section == .builds && cancel.rowKey == "aaaaaaaaaaaa")
        #expect(cancel.deadline == PollSchedule.buildCancelDeadline)

        let done = BuildActions.menu(for: try Self.record("bbbbbbbbbbbb", status: "succeeded"))
        #expect(done.local.map(\.title) == ["Show Log"])
        #expect(done.items.map(\.title) == ["Delete Record…"])
        let delete = try #require(done.deleteKeyItem?.request as? BuildActionRequest)
        #expect(delete.kind == .delete && delete.confirmation.destructive)
        #expect(delete.arguments == ["build", "rm", "bbbbbbbbbbbb"])
        #expect(done.local.first?.action == .showBuildLog(BuildLogTarget(id: try #require(BuildRecordID("bbbbbbbbbbbb")), title: "web:dev", follow: false)))
    }

    @Test("the build verbs' argument lists are fixed")
    func argumentGoldens() throws {
        let id = try #require(BuildRecordID("0123456789ab"))
        #expect(K3smCLI.buildCancelArguments(id: id) == ["build", "cancel", "0123456789ab"])
        #expect(K3smCLI.buildRemoveArguments(id: id) == ["build", "rm", "0123456789ab"])
        #expect(K3smCLI.buildLogsArguments(id: id, follow: false) == ["build", "logs", "0123456789ab"])
        #expect(K3smCLI.buildLogsArguments(id: id, follow: true) == ["build", "logs", "-f", "0123456789ab"])
        let engine = BuildEngineAction.allCases.map { BuildEngineRequest($0).runs }
        #expect(engine == [[["builder", "up"]], [["builder", "down"]], [["builder", "delete"]], [["builder", "up"]],
                           [["build", "prune"]], [["build", "prune", "--force"]]])
        // No engine verb names a work dir: the CLI picks the user's kubeconfig as `k3sm kubectl` does.
        #expect(engine.joined().joined().allSatisfy { !$0.hasPrefix("--work-dir") && !$0.contains("/") })
    }

    @Test("a hostile record id never becomes a BuildRecordID", arguments: [
        "", "-f", "--all", "0123456789a", "0123456789abc", "0123456789AB", "0123456789ag", "../../../etc",
        "01234567 89a", "0123456789a\n", "-123456789ab", "0123456789a\u{0}", "０１２３４５６７８９ab",
        "0123456789a\u{0301}", "0123456789a\u{202E}", "--force=true", "aaaaaaaaaaaa;rm", "aaaaaaaaaaa/",
    ])
    func hostileIDs(_ raw: String) {
        #expect(BuildRecordID(raw) == nil)
    }

    @Test("a row whose id the guard refuses offers no action, so its id reaches no argument list")
    func hostileRowOffersNothing() throws {
        for id in ["--all", "AAAAAAAAAAAA", "aaaaaaaaaaa", "aaaa aaaaaaa"] {
            let row = try Self.record(id, status: "succeeded")
            #expect(row.id == nil)
            #expect(BuildActions.menu(for: row).isEmpty)
        }
    }

    @Test("the toolbar offers the engine's actions by its state")
    func toolbar() throws {
        let ready = try BuildEngine.decode(fixture("kubectl_builder_ready.json"))
        #expect(BuildActions.engineActions(nil) == [])
        #expect(BuildActions.engineActions(ready) == [.prunePlan, .stop, .reset])
        let absent = BuildEngine(state: .absent, podName: nil, nodeName: nil, cache: nil)
        #expect(BuildActions.engineActions(absent) == [.start])
        let cached = BuildEngine(state: .absent, podName: nil, nodeName: nil, cache: BuildCache(name: "k3sm-builder", phase: "Bound", capacityBytes: nil))
        #expect(BuildActions.engineActions(cached) == [.start, .reset])
        #expect(BuildActions.engineActions(BuildEngine(state: .pending(""), podName: "p", nodeName: nil, cache: nil)) == [.stop, .reset])
        #expect(BuildActions.engineActions(BuildEngine(state: .failed("x"), podName: "p", nodeName: nil, cache: nil)) == [.start, .stop, .reset])
        #expect(BuildActions.toolbar(ready).map(\.title) == ["Prune Cache…", "Stop Engine…", "Reset Engine…"])
    }

    @Test("Stop, Reset and the prune ask first, Reset is the one delete, and up gets more than its five-minute wait")
    func engineRequests() {
        #expect(BuildEngineAction.allCases.filter { BuildEngineRequest($0).asksFirst } == [.stop, .reset, .prune])
        #expect(BuildEngineRequest(.start).deadline > .seconds(300) && BuildEngineRequest(.resetStart).deadline > .seconds(300))
        #expect(BuildEngineAction.allCases.filter { BuildEngineRequest($0).kind == .delete } == [.reset])
        #expect(BuildEngineRequest(.reset).confirmation.destructive)
        #expect(BuildEngineAction.allCases.allSatisfy { BuildEngineRequest($0).rowKey == InspectorDetails.engineRow })
    }

    @Test("an engine action reports in one line, with the CLI's own text, an older CLI's included")
    func engineReports() {
        let start = BuildEngineRequest(.start)
        #expect(start.report(.exited(status: 0, output: Data())) == .succeeded("The build engine is ready."))
        // A CLI from before the builder verbs read the user's kubeconfig says so itself.
        let old = Data("k3sm: kubeconfig /Users/a/server/kubeconfig not found \u{2014} run `k3sm server` first\n".utf8)
        #expect(start.report(.exited(status: 1, output: old)) == .failed("Start failed. k3sm said: k3sm: kubeconfig /Users/a/server/kubeconfig not found \u{2014} run `k3sm server` first"))
        let none = Data("k3sm: no kubeconfig for the build engine: run with sudo, or copy the admin kubeconfig into yours with `sudo k3sm kubeconfig --write`\n".utf8)
        #expect(BuildEngineRequest(.prunePlan).report(.exited(status: 1, output: none)).text.hasSuffix("`sudo k3sm kubeconfig --write`"))
        #expect(start.report(.refused("not owned by root")) == .failed("Start failed: the installed k3sm failed the app's check (not owned by root), so it was not run."))
    }

    @Test("a reset deletes, then starts the engine only once the delete succeeded")
    func resetChain() throws {
        let reset = BuildEngineRequest(.reset)
        let start = try #require(reset.next(after: .exited(status: 0, output: Data())) as? BuildEngineRequest)
        #expect(start.action == .resetStart && !start.asksFirst && start.arguments == ["builder", "up"])
        #expect(start.next(after: .exited(status: 0, output: Data())) == nil)
        #expect(start.report(.exited(status: 0, output: Data())) == .succeeded("The build engine was reset and is ready, with an empty cache."))
        #expect(reset.next(after: .exited(status: 1, output: Data("k3sm: delete failed\n".utf8))) == nil)
        #expect(reset.next(after: .noAnswer) == nil)
        #expect(reset.report(.exited(status: 1, output: Data("k3sm: delete failed\n".utf8))) == .failed("Reset failed. k3sm said: k3sm: delete failed"))
    }

    static let planOutput = Data("would reclaim 1.2 GiB (1288490188 bytes) from 34 cache record(s)\n(dry run; pass --force to prune)\n".utf8)

    @Test("the dry run leads to the prune, which carries its figure into the confirmation")
    func pruneChain() throws {
        let plan = BuildEngineRequest(.prunePlan)
        let next = try #require(plan.next(after: .exited(status: 0, output: Self.planOutput)) as? BuildEngineRequest)
        #expect(next.action == .prune && next.estimate == PruneEstimate(bytes: 1_288_490_188, records: 34))
        #expect(next.arguments == ["build", "prune", "--force"] && next.asksFirst)
        #expect(next.confirmation.message.hasPrefix("A prune reclaims about 1.2 GB from 34 cache records."))
        // A line ending in a carriage return still reads.
        let cr = Data("would reclaim 1.0 MiB (1048576 bytes) from 1 cache record(s)\r(dry run; pass --force to prune)".utf8)
        #expect((plan.next(after: .exited(status: 0, output: cr)) as? BuildEngineRequest)?.estimate == PruneEstimate(bytes: 1_048_576, records: 1))
        // Nothing to reclaim, a failure, or an unreadable line leads nowhere.
        let zero = Data("would reclaim 0 B (0 bytes) from 0 cache record(s)\n".utf8)
        #expect(plan.next(after: .exited(status: 0, output: zero)) == nil)
        #expect(plan.report(.exited(status: 0, output: zero)) == .succeeded("The build cache has nothing to reclaim."))
        #expect(plan.next(after: .exited(status: 1, output: Self.planOutput)) == nil)
        #expect(plan.next(after: .exited(status: 0, output: Data("something else".utf8))) == nil)
        #expect(plan.report(.exited(status: 0, output: Data("something else".utf8))).failed)
        #expect(BuildEngineRequest(.prune).next(after: .exited(status: 0, output: Self.planOutput)) == nil)
    }

    @Test("the prune's report gives the freed size in the app's own words")
    func pruneReport() {
        let prune = BuildEngineRequest(.prune, estimate: PruneEstimate(bytes: 10, records: 1))
        let out = Data("reclaimed 512.0 MiB (536870912 bytes) from 7 cache record(s)\n".utf8)
        #expect(prune.report(.exited(status: 0, output: out)) == .succeeded("Reclaimed 512 MB from 7 cache records."))
        let hostile = Data("reclaimed \u{202E}evil (536870912 bytes) from 7 cache record(s)\n".utf8)
        #expect(prune.report(.exited(status: 0, output: hostile)) == .succeeded("Reclaimed 512 MB from 7 cache records."))
        #expect(prune.report(.exited(status: 1, output: Data("k3sm: builder not ready\n".utf8))) == .failed("Prune failed. k3sm said: k3sm: builder not ready"))
        #expect(prune.report(.noAnswer).failed)
    }

    @Test("a cancel or delete reports in one line, with the CLI's text cleaned")
    func rowReports() throws {
        let id = try #require(BuildRecordID("aaaaaaaaaaaa"))
        let cancel = BuildActionRequest(action: .cancel, buildID: id, rowKey: id.value, title: "web:dev")
        #expect(cancel.report(.exited(status: 0, output: Data())) == .succeeded("Cancelled build aaaaaaaaaaaa."))
        #expect(cancel.report(.exited(status: 1, output: Data("k3sm: build aaaaaaaaaaaa already finished\u{1B}[31m\n".utf8)))
            == .failed("Cancel failed. k3sm said: k3sm: build aaaaaaaaaaaa already finished [31m"))
        #expect(cancel.report(.noAnswer).failed)
        let delete = BuildActionRequest(action: .delete, buildID: id, rowKey: id.value, title: "web:dev")
        #expect(delete.report(.exited(status: 0, output: Data())) == .succeeded("Deleted the record of build aaaaaaaaaaaa."))
        #expect(delete.confirmation.title == "Delete the record of web:dev?")
    }

    @Test("the log sheet's status line says how the read stands")
    func logStatus() throws {
        let id = try #require(BuildRecordID("aaaaaaaaaaaa"))
        #expect(BuildLog.status(.reading, follow: true, id: id, empty: true) == "Following the build while it runs…")
        #expect(BuildLog.status(.exited(0), follow: true, id: id, empty: false) == "The build finished.")
        #expect(BuildLog.status(.exited(0), follow: false, id: id, empty: true) == "The build has logged nothing.")
        #expect(BuildLog.status(.truncated, follow: false, id: id, empty: false).contains("k3sm build logs aaaaaaaaaaaa"))
        #expect(BuildLog.text(Data("a\r\nb\u{1B}c\u{202E}".utf8)) == "a\nbc")
    }
}
