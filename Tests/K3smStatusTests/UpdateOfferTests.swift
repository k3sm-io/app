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

@Suite("the managed update offer and progress")
struct UpdateOfferTests {
    static func report(_ row: StatusRow?) -> StatusReport {
        StatusReport(schemaVersion: 1, verdict: .running, role: "server", summary: "2/2 nodes ready",
                     rows: [StatusRow(name: "server", state: "running", detail: "d")] + (row.map { [$0] } ?? []))
    }

    static let behind = StatusRow(
        name: "update", state: "behind", detail: "k3sm v0.1.8 is available; behind: mac-2 (v0.1.7)",
        remedy: "curl -fsSL https://k3sm.io/install.sh | sh", wide: ["latest": "v0.1.8", "checked": "2026-10-15T09:00:00Z"])

    static func decide(_ row: StatusRow?, progress: UpdateProgress = UpdateProgress()) -> UpdateOffer {
        UpdateOffer.decide(report: report(row), progress: progress)
    }

    @Test("a release is offered only when the row is behind with a tag; a roll reads as updating")
    func updateMenuItemShowsOnlyWhenNewer() throws {
        // behind with a latest tag: that release.
        #expect(Self.decide(Self.behind) == .available(tag: "v0.1.8"))

        // ok, ahead, unknown and no row: nothing.
        for row in [
            StatusRow(name: "update", state: "ok", detail: "every node runs k3sm v0.1.8", wide: ["latest": "v0.1.8"]),
            StatusRow(name: "update", state: "ahead", detail: "newer than the latest release: mac-1 (v0.1.9)", wide: ["latest": "v0.1.8"]),
            StatusRow(name: "update", state: "unknown", detail: "no update check is recorded yet", remedy: "sudo k3sm update check"),
            nil,
        ] {
            #expect(Self.decide(row) == .hidden)
        }

        // rolling: updating, whatever the row says.
        var progress = UpdateProgress()
        progress.applyStarted()
        for row in [Self.behind, nil] {
            #expect(Self.decide(row, progress: progress) == .updating)
        }
        #expect(UpdateOffer.developerBuildReason.contains("not Developer ID signed"))

        // the progress decode.
        let status = try UpdateStatus.decode(try fixture("update-status-rolling.json"))
        #expect(status.phase == .rolling)
        #expect(status.target == "v0.1.8")
        #expect(status.nodes.map(\.name) == ["mac-2", "mac-1"])
        #expect(status.nodes[0] == UpdateNode(name: "mac-2", from: "v0.1.7", to: "v0.1.8", phase: "Succeeded",
                                              message: "updated", lastProgress: "2026-10-15T10:00:00Z"))
        #expect(status.conditions == [UpdateCondition(type: "Progressing", status: "True", reason: "NodeUpdated", message: "1 of 2 nodes updated")])
    }

    @Test("the tag comes from wide.latest, else the detail, and must be a release version")
    func tag() {
        #expect(UpdateOffer.latestTag(in: Self.behind) == "v0.1.8")
        let detailOnly = StatusRow(name: "update", state: "behind", detail: "k3sm v0.2.0-rc.1 is available; behind: a (v0.1.7)")
        #expect(UpdateOffer.latestTag(in: detailOnly) == "v0.2.0-rc.1")
        for bad in ["", "latest", "v0.1.8\u{202E}", "v0.1.8 && rm", "v" + String(repeating: "1", count: 50) + ".0.0", "v０.1.8"] {
            let row = StatusRow(name: "update", state: "behind", detail: "k3sm \(bad) is available", wide: ["latest": bad])
            #expect(UpdateOffer.latestTag(in: row) == nil, "accepted \(bad)")
        }
        // A behind row with no usable tag offers nothing.
        #expect(Self.decide(StatusRow(name: "update", state: "behind", detail: "behind: a (v0.1.7)")) == .hidden)
    }

    @Test("wide decodes string values only and never fails the row")
    func wideDecode() throws {
        let json = #"{"name":"update","state":"behind","detail":"d","wide":{"latest":"v0.1.8","n":3,"o":{}}}"#
        let row = try JSONDecoder().decode(StatusRow.self, from: Data(json.utf8))
        #expect(row.wide == ["latest": "v0.1.8"])
        let mistyped = try JSONDecoder().decode(StatusRow.self, from: Data(#"{"name":"a","state":"ok","detail":"d","wide":"x"}"#.utf8))
        #expect(mistyped.wide.isEmpty)
    }

    @Test("the vendored server reports, with no check recorded, offer nothing", arguments: UpdateRowTests.serverReports)
    func fixtures(_ file: String) throws {
        let report = try StatusReport.decode(try fixture(file))
        #expect(UpdateOffer.decide(report: report, progress: UpdateProgress()) == .hidden)
    }

    @Test("the state machine: apply, reads, finish, dismiss")
    func stateMachine() throws {
        let rolling = try UpdateStatus.decode(try fixture("update-status-rolling.json"))
        let succeeded = try UpdateStatus.decode(try fixture("update-status-succeeded.json"))
        let failed = try UpdateStatus.decode(try fixture("update-status-failed.json"))

        var p = UpdateProgress()
        #expect(!p.isRolling && p.panel == nil)
        #expect(p.readsStatus(offerShown: true) && !p.readsStatus(offerShown: false))
        p.applyStarted()
        #expect(p.isRolling && !p.readsStatus(offerShown: true))
        #expect(p.panel?.title == "Starting the update…")
        p.applyFinished(.started)
        #expect(p.stage == .rolling(nil) && p.readsStatus(offerShown: false) && p.canCancel)
        p.read(rolling)
        #expect(p.stage == .rolling(rolling))
        let panel = try #require(p.panel)
        #expect(panel.title == "Updating to v0.1.8 · Rolling")
        #expect(panel.showsCancel && !panel.showsDismiss)
        #expect(panel.nodes.map(\.versions) == ["v0.1.7 → v0.1.8", "v0.1.7 → v0.1.8"])
        p.read(succeeded)
        #expect(p.stage == .succeeded(succeeded) && !p.isRolling && !p.canCancel)
        #expect(p.panel?.title == "Updated to v0.1.8.")
        #expect(p.panel?.showsDismiss == true)
        #expect(!p.readsStatus(offerShown: true))
        // The stale behind row is not offered again for the release just applied.
        #expect(Self.decide(Self.behind, progress: p) == .hidden)
        p.dismiss()
        #expect(p.stage == .idle && p.panel == nil)
        #expect(Self.decide(Self.behind, progress: p) == .hidden)
        #expect(Self.decide(StatusRow(name: "update", state: "behind", detail: "d", wide: ["latest": "v0.1.9"]), progress: p)
            == .available(tag: "v0.1.9"))

        // A failed roll shows the failed node's message and the remedy.
        var f = UpdateProgress(stage: .rolling(nil))
        f.read(failed)
        let fp = try #require(f.panel)
        #expect(fp.title == "The update to v0.1.8 failed.")
        #expect(fp.detail == "mac-2: install exited 1")
        #expect(fp.remedy == "Fix the node that failed, then use Abort Update to release every node before trying again.")
        #expect(fp.showsDismiss && !fp.showsCancel)

        // Idle: a roll found running is followed; a finished one is not brought up.
        var idle = UpdateProgress()
        idle.read(succeeded)
        #expect(idle.stage == .idle)
        idle.read(failed)
        #expect(idle.stage == .idle)
        idle.read(rolling)
        #expect(idle.stage == .rolling(rolling) && idle.isRolling)

        // An apply that started nothing returns to idle; already rolling follows the roll.
        var none = UpdateProgress()
        none.applyStarted()
        none.applyFinished(.notStarted)
        #expect(none.stage == .idle)
        none.applyStarted()
        none.applyFinished(.alreadyRolling)
        #expect(none.stage == .rolling(nil))
    }

    @Test("Abort is offered while a roll runs and after it failed, and a successful abort is followed to Cancelled")
    func abortStates() throws {
        let rolling = try UpdateStatus.decode(try fixture("update-status-rolling.json"))
        let succeeded = try UpdateStatus.decode(try fixture("update-status-succeeded.json"))
        let failed = try UpdateStatus.decode(try fixture("update-status-failed.json"))
        // What `k3sm update abort` leaves: the same Update, now Cancelled.
        let aborted = try UpdateStatus.decode(Data(#"{"name":"current","phase":"Cancelled","version":"v0.1.8","nodes":[{"name":"mac-2","phase":"Failed"},{"name":"mac-1","phase":"Cancelled","message":"aborted by k3sm update abort"}],"finished":true}"#.utf8))

        // Not offered before a roll, while the apply's step runs, or once a roll succeeded or was cancelled.
        #expect(!UpdateProgress().canAbort && UpdateProgress().panel == nil)
        #expect(!UpdateProgress(stage: .applying).canAbort && UpdateProgress(stage: .applying).panel?.showsAbort == false)
        #expect(!UpdateProgress(stage: .succeeded(succeeded)).canAbort && UpdateProgress(stage: .succeeded(succeeded)).panel?.showsAbort == false)
        #expect(!UpdateProgress(stage: .cancelled(aborted)).canAbort && UpdateProgress(stage: .cancelled(aborted)).panel?.showsAbort == false)

        // While it rolls: beside Cancel, the first progress report or not.
        for stage in [UpdateProgress.Stage.rolling(nil), .rolling(rolling)] {
            let p = UpdateProgress(stage: stage)
            #expect(p.canAbort && p.panel?.showsAbort == true && p.panel?.showsCancel == true)
        }
        // After a failure: the recovery, with Dismiss and no Cancel.
        var p = UpdateProgress(stage: .rolling(nil))
        p.read(failed)
        let fp = try #require(p.panel)
        #expect(p.canAbort && fp.showsAbort && fp.showsDismiss && !fp.showsCancel)

        // An abort that did not succeed leaves the failure on screen.
        p.abortFinished(succeeded: false)
        #expect(p.stage == .failed(failed))
        // One that succeeded is followed, and the next read shows it cancelled.
        p.abortFinished(succeeded: true)
        #expect(p.stage == .rolling(failed) && p.readsStatus(offerShown: false))
        p.read(aborted)
        #expect(p.stage == .cancelled(aborted) && !p.canAbort)
        #expect(p.panel?.title == "The update to v0.1.8 was cancelled.")
        #expect(p.panel?.showsDismiss == true && p.panel?.showsAbort == false)

        // Aborting a running roll: the next read ends it the same way.
        var r = UpdateProgress(stage: .rolling(rolling))
        r.abortFinished(succeeded: true)
        #expect(r.stage == .rolling(rolling))
        r.read(aborted)
        #expect(r.stage == .cancelled(aborted))
        // A finished stage is never moved back by an abort.
        var s = UpdateProgress(stage: .succeeded(succeeded))
        s.abortFinished(succeeded: true)
        #expect(s.stage == .succeeded(succeeded))
    }

    @Test("the update status decode is tolerant of everything but the phase")
    func decodeTolerant() throws {
        let minimal = try UpdateStatus.decode(Data(#"{"phase":"Pending"}"#.utf8))
        #expect(minimal == UpdateStatus(phase: .pending, version: "", name: ""))
        #expect(!minimal.present)
        let odd = try UpdateStatus.decode(Data(#"{"name":"current","phase":"Draining","version":7,"resolved":"x","nodes":{},"conditions":[{"type":1}],"finished":"yes"}"#.utf8))
        #expect(odd.phase == .unrecognized("Draining") && !odd.phase.isFinished)
        #expect(odd.version == "" && odd.resolved == nil && odd.nodes.isEmpty && !odd.finished && odd.present)
        #expect(odd.conditions == [UpdateCondition(type: "", status: "")])
        #expect(throws: StatusDecodeError.malformed) { try UpdateStatus.decode(Data(#"{"version":"v1"}"#.utf8)) }
        #expect(throws: StatusDecodeError.malformed) { try UpdateStatus.decode(Data("not json".utf8)) }
        #expect(UpdateStatus.tabResult(exitCode: 1, stdout: Data()) == .failed("k3sm update status exited 1"))
        #expect(UpdateStatus.tabResult(exitCode: 0, stdout: Data("{}".utf8)) == .failed("the update status could not be read"))
        // An unknown phase reads as still rolling.
        var p = UpdateProgress(stage: .rolling(nil))
        p.read(odd)
        #expect(p.isRolling && p.canCancel)
    }

    @Test("no Update is nothing to follow, and never reads as rolling")
    func noUpdate() throws {
        let none = try UpdateStatus.decode(try fixture("update-status-none.json"))
        #expect(!none.present && none.ended == nil)
        var idle = UpdateProgress()
        idle.read(none)
        #expect(idle.stage == .idle && !idle.isRolling)
        #expect(UpdateOfferTests.decide(UpdateOfferTests.behind, progress: idle) == .available(tag: "v0.1.8"))
        // A followed roll whose Update is gone (deleted) ends with nothing shown.
        var following = UpdateProgress(stage: .rolling(nil))
        following.read(none)
        #expect(following.stage == .idle)
        // An Update the controller has not reconciled yet has no phase: pending.
        let fresh = try UpdateStatus.decode(Data(#"{"name":"current","phase":"","version":"v0.1.8","resolved":null,"nodes":[],"conditions":[]}"#.utf8))
        #expect(fresh.present && fresh.phase == .pending)
        idle.read(fresh)
        #expect(idle.stage == .rolling(fresh) && idle.canCancel)
    }

    @Test("finished, not the phase, ends a roll; the Progressing reason names how")
    func finishedPredicate() {
        // A display phase that says Succeeded before finished is set still rolls.
        var p = UpdateProgress(stage: .rolling(nil))
        p.read(UpdateStatus(phase: .succeeded, version: "v0.1.8"))
        #expect(p.isRolling)
        let byReason = UpdateStatus(phase: .rolling, version: "v0.1.8",
                                    conditions: [UpdateCondition(type: "Progressing", status: "False", reason: "Cancelled")], finished: true)
        #expect(byReason.ended == .cancelled)
        p.read(byReason)
        #expect(p.stage == .cancelled(byReason))
        #expect(p.panel?.title == "The update to v0.1.8 was cancelled.")
        let unknown = UpdateStatus(phase: .unrecognized("Odd"), version: "v0.1.8", finished: true)
        #expect(unknown.ended == .failed)
    }

    static let rotatedJSON = #"""
    {"phase":"Succeeded","version":"v0.1.8","resolved":{"version":"v0.1.8","digest":"sha256:11"},
     "nodes":[
      {"name":"mac-2","from":"v0.1.7","to":"v0.1.8","phase":"Succeeded","message":"updated"},
      {"name":"mac-1","from":"v0.1.7","to":"v0.1.8","phase":"Succeeded","message":"updated; the admin credential was re-minted: copy the admin kubeconfig again","adminTokenRotated":true},
      {"name":"mac-3","phase":"Succeeded","adminTokenRotated":"yes"}],
     "conditions":[{"type":"Succeeded","status":"True","reason":"Succeeded","message":"admin credential re-minted on mac-1"}],
     "name":"current","finished":true}
    """#

    @Test("adminTokenRotated decodes true when set, false when absent or mistyped, and names its nodes")
    func adminTokenRotatedDecode() throws {
        let status = try UpdateStatus.decode(Data(Self.rotatedJSON.utf8))
        #expect(status.nodes.map(\.adminTokenRotated) == [false, true, false])
        #expect(status.adminTokenRotatedNodes == ["mac-1"])
        let plain = try UpdateStatus.decode(try fixture("update-status-succeeded.json"))
        #expect(plain.nodes.allSatisfy { !$0.adminTokenRotated })
        #expect(plain.adminTokenRotatedNodes.isEmpty)
        #expect(UpdateNode(name: "a").adminTokenRotated == false)
    }

    @Test("the panel shows the credential notice while the Update that carries it is shown, done included")
    func credentialNotice() throws {
        let status = try UpdateStatus.decode(Data(Self.rotatedJSON.utf8))
        let text = "The admin credential was re-minted on mac-1. Copy the admin kubeconfig again to every other Mac or tool that uses it."
        let rolling = UpdateStatus(phase: .rolling, version: "v0.1.8", nodes: status.nodes)
        var p = UpdateProgress(stage: .rolling(nil))
        #expect(p.panel?.credentialNotice == nil)
        p.read(rolling)
        #expect(p.panel?.credentialNotice == text)
        p.read(status)
        #expect(p.stage == .succeeded(status))
        #expect(p.panel?.credentialNotice == text)
        p.dismiss()
        #expect(p.panel == nil)

        // No flagged node, no notice.
        var q = UpdateProgress(stage: .rolling(nil))
        q.read(try UpdateStatus.decode(try fixture("update-status-succeeded.json")))
        #expect(q.panel != nil && q.panel?.credentialNotice == nil)

        // Several nodes join with ", "; names are clipped and capped so the instruction survives.
        let two = UpdateStatus(phase: .failed, version: "v0.1.8",
                               nodes: [UpdateNode(name: "a\nb", adminTokenRotated: true), UpdateNode(name: "c", adminTokenRotated: true)],
                               finished: true)
        #expect(UpdatePanel.credentialNotice(two)?.hasPrefix("The admin credential was re-minted on a b, c. Copy") == true)
        let long = UpdateStatus(phase: .rolling, version: "v1", nodes: [UpdateNode(name: String(repeating: "n", count: 300), adminTokenRotated: true)])
        let notice = try #require(UpdatePanel.credentialNotice(long))
        #expect(notice.hasSuffix("Copy the admin kubeconfig again to every other Mac or tool that uses it."))
        #expect(!notice.contains(String(repeating: "n", count: UpdatePanel.maxNoticeNames)))
        let nameless = UpdateStatus(phase: .rolling, version: "v1", nodes: [UpdateNode(name: "", adminTokenRotated: true)])
        #expect(UpdatePanel.credentialNotice(nameless)?.contains("re-minted on a control-plane node.") == true)
    }

    @Test("the panel's cluster strings are clipped to one line")
    func clipped() {
        let s = UpdateStatus(phase: .failed, version: "v0.1.8\n\u{202E}x",
                             nodes: [UpdateNode(name: "a\nb", from: "v1", to: "", phase: "Failed", message: String(repeating: "m", count: 400))],
                             finished: true)
        var p = UpdateProgress(stage: .rolling(nil))
        p.read(s)
        let panel = p.panel!
        #expect(!panel.title.contains("\n") && !panel.title.unicodeScalars.contains("\u{202E}"))
        #expect(panel.nodes[0].name == "a b")
        #expect(panel.nodes[0].versions == "v1")
        #expect(panel.nodes[0].message.count == StatusDisplay.maxLength)
        #expect(panel.detail!.count <= StatusDisplay.maxLength)
    }

    @Test("the update argument lists are fixed")
    func argv() {
        #expect(K3smCLI.updateStatusArguments == ["update", "status", "-o", "json"])
        #expect(K3smCLI.updateApplyArguments == ["update", "apply", "--yes"])
        #expect(K3smCLI.updateCancelArguments == ["update", "cancel"])
        #expect(K3smCLI.updateAbortArguments == ["update", "abort"])
        #expect(PollSchedule.updateStatusInterval == .seconds(5))
    }
}
