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

@Suite("the Settings Updates pane")
struct UpdatesPaneTests {
    /// A fresh, empty defaults domain of its own, so no test reads the user's.
    private static func fresh() -> UserDefaults {
        let name = "io.k3sm.app.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    static func report(_ row: StatusRow?) -> StatusReport {
        var rows = [StatusRow(name: "server", state: "running", detail: "d")]
        if let row { rows.append(row) }
        return StatusReport(schemaVersion: 1, verdict: .running, role: "server", summary: "s", rows: rows, workers: [])
    }

    static func update(_ state: String, detail: String = "d", wide: [String: String] = [:]) -> StatusReport {
        report(StatusRow(name: "update", state: state, detail: detail, wide: wide))
    }

    /// drain, allow downgrade, signature, the argv `k3sm update apply` gets.
    /// Every flag is one `cmd/k3sm/update.go` defines; the defaults add none,
    /// so the default apply is the argv the app has always run.
    @Test("the update options become fixed apply flags", arguments: [
        (false, false, UpdateSignaturePolicy.ifSigned, ["update", "apply", "--yes"]),
        (true, false, .ifSigned, ["update", "apply", "--yes", "--drain"]),
        (false, true, .ifSigned, ["update", "apply", "--yes", "--allow-downgrade"]),
        (false, false, .required, ["update", "apply", "--yes", "--signature", "required"]),
        (true, true, .required, ["update", "apply", "--yes", "--drain", "--allow-downgrade", "--signature", "required"]),
    ] as [(Bool, Bool, UpdateSignaturePolicy, [String])])
    func updateOptionsArguments(_ drain: Bool, _ downgrade: Bool, _ signature: UpdateSignaturePolicy, _ argv: [String]) {
        let options = UpdateOptions(drain: drain, allowDowngrade: downgrade, signature: signature)
        #expect(options.arguments == argv)
        #expect(UpdateOptions.defaults.arguments == K3smCLI.updateApplyArguments)
        // The popup offers the default or stricter, nothing looser.
        #expect(UpdateSignaturePolicy.allCases.map(\.rawValue) == ["if-signed", "required"])
    }

    @Test("drain and the signature policy are stored, off by default, and reset puts them back")
    func updateOptionsPreferences() {
        let defaults = Self.fresh()
        let prefs = AppPreferences(defaults: defaults)
        #expect(prefs.updateOptions == .defaults)
        prefs.updateDrain = true
        prefs.updateSignature = .required
        #expect(AppPreferences(defaults: defaults).updateOptions
            == UpdateOptions(drain: true, allowDowngrade: false, signature: .required))
        // A stored word this build does not know reads as the default.
        defaults.set("sometimes", forKey: AppPreferences.updateSignatureKey)
        #expect(prefs.updateSignature == .ifSigned)
        defaults.set(3, forKey: AppPreferences.updateSignatureKey)
        #expect(prefs.updateSignature == .ifSigned)
        prefs.updateSignature = .required
        prefs.reset()
        #expect(prefs.updateOptions == .defaults)
        #expect(defaults.object(forKey: AppPreferences.updateSignatureKey) == nil)
    }

    @Test("the Updates pane is listed after Network")
    func paneListed() {
        #expect(SettingsPane.shown == [.general, .network, .updates, .advanced])
        #expect(SettingsPane.updates.title == "Updates")
        #expect(SettingsPane.updates.symbol == "arrow.triangle.2.circlepath")
        #expect(SettingsPane.restore(from: "updates") == .updates)
    }

    @Test("the versions and the state read in plain words, by row state")
    func facts() {
        let installed = SemanticVersion("v0.1.8")
        let behind = UpdatesPaneFacts.decide(report: Self.update("behind", detail: "k3sm v0.1.9 is available; behind: a (v0.1.8)",
                                                                  wide: ["latest": "v0.1.9"]), installed: installed)
        #expect(behind == UpdatesPaneFacts(installed: "v0.1.8", available: "v0.1.9",
                                           state: "k3sm v0.1.9 is available; at least one node runs an older release."))
        let ok = UpdatesPaneFacts.decide(report: Self.update("ok", wide: ["latest": "v0.1.8"]), installed: installed)
        #expect(ok == UpdatesPaneFacts(installed: "v0.1.8", available: "v0.1.8", state: "This cluster runs the latest release."))
        let ahead = UpdatesPaneFacts.decide(report: Self.update("ahead", wide: ["latest": "v0.1.7"]), installed: installed)
        #expect(ahead.state == "A node runs a release newer than the latest one.")
        #expect(ahead.available == "v0.1.7")
        let rolling = UpdatesPaneFacts.decide(report: Self.update("rolling", wide: ["target": "v0.1.9", "phase": "Rolling"]),
                                              installed: installed)
        #expect(rolling.state == "An update to v0.1.9 is rolling.")
        #expect(rolling.available == "v0.1.9")
        let unknown = UpdatesPaneFacts.decide(report: Self.update("unknown", detail: "no update check is recorded yet"),
                                              installed: nil)
        #expect(unknown == UpdatesPaneFacts(installed: "unknown", available: "not known",
                                            state: "Not known: no update check is recorded yet."))
        let odd = UpdatesPaneFacts.decide(report: Self.update("sideways", detail: "x"), installed: installed)
        #expect(odd.state == "The update check says sideways: x.")
        #expect(UpdatesPaneFacts.decide(report: Self.report(nil), installed: installed).state
            == "This k3sm reports no update check.")
        #expect(UpdatesPaneFacts.decide(report: nil, installed: installed).state
            == "The status of this Mac has not been read yet.")
        // A latest that is not a release tag never reaches the pane.
        let bad = UpdatesPaneFacts.decide(report: Self.update("ok", wide: ["latest": "v0.1.9\u{202E}evil"]), installed: installed)
        #expect(bad.available == "not known")
    }

    @Test("a downgrade is offered only for a behind row that names a newer node")
    func downgradeOffer() {
        let mixed = Self.update("behind", detail: "k3sm v0.1.8 is available; behind: a (v0.1.7); newer than the latest release: b (v0.2.0)",
                                wide: ["latest": "v0.1.8"])
        #expect(UpdateOffer.offersDowngrade(in: mixed))
        #expect(!UpdateOffer.offersDowngrade(in: Self.update("behind", detail: "k3sm v0.1.8 is available; behind: a (v0.1.7)")))
        #expect(!UpdateOffer.offersDowngrade(in: Self.update("ahead", detail: "k3sm v0.1.8 is the latest; newer than the latest release: b (v0.2.0)")))
        #expect(!UpdateOffer.offersDowngrade(in: nil))
    }

    @Test("Update Now is enabled only when the update plan has a path that can run, and says why not")
    func updateNow() {
        let offered = UpdateNowControl.decide(plan: .managed(tag: "v0.1.9"), report: nil)
        #expect(offered == UpdateNowControl(enabled: true, reason: nil))
        let payload = UpdateNowControl.decide(plan: .payload(SemanticVersion("0.1.9")!), report: nil)
        #expect(payload == UpdateNowControl(enabled: true, reason: nil))
        let blockedPlan = UpdatePlan.blocked(.refused("Another change is running.", .managed(tag: "v0.1.9")))
        let blocked = UpdateNowControl.decide(plan: blockedPlan, report: nil)
        #expect(blocked == UpdateNowControl(enabled: false, reason: "Another change is running."))
        let rolling = UpdateNowControl.decide(plan: .rolling, report: nil)
        #expect(!rolling.enabled && rolling.reason == UpdatePlan.rollingReason)
        #expect(UpdateNowControl.decide(plan: .blocked(.workerBehind), report: nil).reason == UpdateBlock.workerBehindText)
        #expect(UpdateNowControl.decide(plan: .none, report: Self.update("ok")).reason
            == UpdateNowControl.latestReason)
        #expect(UpdateNowControl.decide(plan: .none, report: Self.update("ahead")).reason
            == UpdateNowControl.aheadReason)
        #expect(UpdateNowControl.decide(plan: .none, report: Self.update("unknown")).reason
            == UpdateNowControl.unknownReason)
        #expect(UpdateNowControl.decide(plan: .none, report: nil).reason == UpdateNowControl.unknownReason)
        #expect(UpdateNowControl.decide(plan: .none, report: Self.update("behind", wide: ["latest": "v0.1.9"])).reason
            == UpdateNowControl.finishedReason)
        #expect(UpdateNowControl.title == "Update Now")
        #expect(Help.Updates.updateNow(offered, plan: .managed(tag: "v0.1.9")) == "Update every node to k3sm v0.1.9, the server last")
        #expect(Help.Updates.updateNow(payload, plan: .payload(SemanticVersion("0.1.9")!))
            == "Install k3sm 0.1.9 from this app on this Mac, as an administrator")
        #expect(Help.Updates.updateNow(blocked, plan: blockedPlan) == "Another change is running.")
    }
}
