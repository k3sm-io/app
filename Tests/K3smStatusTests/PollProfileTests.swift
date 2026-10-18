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

@Suite("the poll profile")
struct PollProfileTests {
    private static func fresh() -> UserDefaults {
        let name = "io.k3sm.app.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("each profile's intervals, Low power at least twice Normal everywhere, the default Normal")
    func pollProfileIntervals() {
        #expect(PollProfile.allCases == [.normal, .lowPower])
        #expect(PollProfile.defaultProfile == .normal)
        #expect(PollProfile.normal.title == "Normal")
        #expect(PollProfile.lowPower.title == "Low power")

        let normal = PollProfile.normal.intervals
        #expect(normal.visible == .seconds(15))
        #expect(normal.hidden == .seconds(60))
        #expect(normal.fast == .seconds(5))
        #expect(normal.consoleReport == .seconds(30))
        #expect(normal.consoleHeartbeat == .seconds(5 * 60))
        #expect(normal.images == .seconds(15))
        #expect(normal.objects == .seconds(15))
        #expect(normal.events == .seconds(5))
        #expect(normal.buildsReady == .seconds(15))
        #expect(normal.updateStatus == .seconds(5))
        #expect(normal.background == .seconds(30))
        #expect(normal.metrics == .seconds(15))
        #expect(normal.metricsAbsent == .seconds(60))
        #expect(normal.updateCheck == .seconds(30 * 60))

        let low = PollProfile.lowPower.intervals
        #expect(low.all.map(\.name) == normal.all.map(\.name))
        #expect(normal.all.count == 14)
        for (n, l) in zip(normal.all, low.all) {
            #expect(l.value >= n.value * 2, "\(n.name): \(l.value) is not twice \(n.value)")
        }

        // The schedule reads the current profile; the default is Normal.
        #expect(PollSchedule.intervals == normal)
        #expect(PollSchedule.visibleInterval == normal.visible)
        #expect(PollSchedule.interval(for: .workloads, engineReady: false, in: low) == .seconds(10))
        #expect(PollSchedule.interval(for: .builds, engineReady: true, in: low) == .seconds(30))
        #expect(PollSchedule.interval(visible: false, in: low) == .seconds(120))
        #expect(PollSchedule.podsInterval(selected: false, in: low) == .seconds(60))
        // Deadlines are not cadences: a profile never moves them.
        #expect(PollSchedule.killDeadline < low.visible)
        #expect(PollSchedule.listDeadline < low.consoleReport)

        // Stored as its word; anything else reads as the default.
        #expect(PollProfile.restore(from: nil) == .normal)
        #expect(PollProfile.restore(from: "low-power") == .lowPower)
        #expect(PollProfile.restore(from: "turbo") == .normal)
        #expect(PollProfile.restore(from: 2) == .normal)
        let defaults = Self.fresh()
        let prefs = AppPreferences(defaults: defaults)
        #expect(prefs.pollProfile == .normal)
        prefs.pollProfile = .lowPower
        #expect(AppPreferences(defaults: defaults).pollProfile == .lowPower)
        prefs.reset()
        #expect(prefs.pollProfile == .normal)
        #expect(defaults.object(forKey: AppPreferences.pollProfileKey) == nil)
    }
}

@Suite("the update notification")
struct UpdateNoticeTests {
    private static func v(_ text: String) -> SemanticVersion { SemanticVersion(text)! }

    @Test("only an update the app can start names a release")
    func release() {
        #expect(UpdateNotice.release(of: .payload(Self.v("0.2.0"))) == "0.2.0")
        #expect(UpdateNotice.release(of: .managed(tag: "v0.2.0")) == "0.2.0")
        #expect(UpdateNotice.release(of: .catchUp(tag: "v0.1.9", nodes: ["b"])) == "0.1.9")
        #expect(UpdateNotice.release(of: .none) == nil)
        #expect(UpdateNotice.release(of: .rolling) == nil)
        #expect(UpdateNotice.release(of: .blocked(.appDeveloperBuild(.managed(tag: "v0.2.0")))) == nil)
        #expect(UpdateNotice.release(of: .blocked(.roleUnknown)) == nil)
    }

    @Test("a notice is posted once per release, only with the preference on")
    func decide() throws {
        let plan = UpdatePlan.managed(tag: "v0.2.0")
        let notice = try #require(UpdateNotice.decide(plan: plan, enabled: true, notified: nil))
        #expect(notice.release == "0.2.0")
        #expect(notice.title == "k3sm v0.2.0 is available")
        #expect(notice.body == UpdatePath.managed(tag: "v0.2.0").sentence)
        #expect(UpdateNotice.decide(plan: plan, enabled: true, notified: "0.2.0") == nil)
        #expect(UpdateNotice.decide(plan: .managed(tag: "0.2.0"), enabled: true, notified: "0.2.0") == nil)
        #expect(UpdateNotice.decide(plan: plan, enabled: true, notified: "0.1.9") != nil)
        #expect(UpdateNotice.decide(plan: plan, enabled: false, notified: nil) == nil)
        #expect(UpdateNotice.decide(plan: .none, enabled: true, notified: nil) == nil)
        #expect(UpdateNotice.decide(plan: .rolling, enabled: true, notified: nil) == nil)
        #expect(UpdateNotice.decide(plan: .blocked(.workerBehind), enabled: true, notified: nil) == nil)
        let payload = try #require(UpdateNotice.decide(plan: .payload(Self.v("0.3.0")), enabled: true, notified: "0.2.0"))
        #expect(payload.title == "k3sm 0.3.0 is available")
    }

    @Test("a release tag from the cluster is clipped in the notice")
    func clipped() throws {
        let notice = try #require(UpdateNotice.decide(plan: .managed(tag: "v1\u{202E}\nx"), enabled: true, notified: nil))
        #expect(!notice.title.contains("\u{202E}"))
        #expect(!notice.title.contains("\n"))
        #expect(!notice.release.contains("\n"))
    }

    @Test("permission is asked once, while macOS has no answer")
    func permission() {
        #expect(UpdateNotice.step(.notDetermined) == .ask)
        #expect(UpdateNotice.step(.authorized) == .post)
        #expect(UpdateNotice.step(.denied) == .skip)
    }

    @Test("the preference is on by default, and the notified release survives a reset")
    func preference() {
        let name = "io.k3sm.app.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let prefs = AppPreferences(defaults: defaults)
        #expect(prefs.notifyUpdate == true)
        #expect(prefs.updateNotifiedRelease == nil)
        prefs.notifyUpdate = false
        prefs.updateNotifiedRelease = "0.2.0"
        prefs.reset()
        #expect(prefs.notifyUpdate == true)
        #expect(prefs.updateNotifiedRelease == "0.2.0")
    }
}

@Suite("the Cluster pane's kubeconfig")
struct KubeconfigFileTests {
    private static func report(_ wide: String) throws -> StatusReport {
        try StatusReport.decode(Data(#"{"schemaVersion":1,"verdict":"running","rows":[{"name":"admin-kubeconfig","state":"ok","severity":"ok","detail":"","wide":{"kubeconfig":\#(wide)}}]}"#.utf8))
    }

    @Test("the path is the one install recorded when the report names it, else this account's")
    func path() throws {
        #expect(KubeconfigFile.path(home: "/Users/a", report: nil) == "/Users/a/.kube/config")
        #expect(KubeconfigFile.path(home: "/Users/a/", report: nil) == "/Users/a/.kube/config")
        #expect(KubeconfigFile.path(home: "/Users/a", report: try Self.report(#""/Users/b/.kube/k3sm""#)) == "/Users/b/.kube/k3sm")
        #expect(KubeconfigFile.path(home: "/Users/a", report: try Self.report(#""kube/config""#)) == "/Users/a/.kube/config")
        #expect(KubeconfigFile.path(home: "/Users/a", report: try Self.report(#""/Users/b/\u0007x""#)) == "/Users/a/.kube/config")
        #expect(KubeconfigFile.path(home: nil, report: nil) == nil)
        #expect(KubeconfigFile.path(home: "", report: nil) == nil)
    }

    @Test("a readable file is copied and shown; an unreadable one says it needs an administrator")
    func decide() {
        let ok = KubeconfigFile.decide(path: "/Users/a/.kube/config", exists: true, readable: true)
        #expect(ok == KubeconfigFile(value: "/Users/a/.kube/config", copyText: "/Users/a/.kube/config",
                                     revealPath: "/Users/a/.kube/config", note: nil))
        let locked = KubeconfigFile.decide(path: "/Users/a/.kube/config", exists: true, readable: false)
        #expect(locked.copyText == "/Users/a/.kube/config")
        #expect(locked.revealPath == "/Users/a/.kube/config")
        #expect(locked.note?.contains(StatusDisplay.needsAdminText) == true)
        let missing = KubeconfigFile.decide(path: "/Users/a/.kube/config", exists: false, readable: false)
        #expect(missing.copyText == nil)
        #expect(missing.revealPath == nil)
        #expect(missing.note == KubeconfigFile.missingNote)
        let unknown = KubeconfigFile.decide(path: nil, exists: false, readable: false)
        #expect(unknown.value == "Unknown")
        #expect(unknown.copyText == nil)
        #expect(unknown.revealPath == nil)
    }
}

@Suite("the Network pane's interconnect")
struct InterconnectSettingTests {
    @Test("the checkbox shows the armed state, read-only, with how to change it")
    func decide() throws {
        #expect(InterconnectSetting.decide(nil) == nil)
        #expect(InterconnectSetting.decide(try StatusReport.decode(try fixture("status_json_not-installed.json"))) == nil)

        let absent = try #require(InterconnectSetting.decide(try StatusReport.decode(try fixture("status_json_running.json"))))
        #expect(absent.state == .unknown)
        #expect(absent.lines == [InterconnectSetting.absentLine])
        #expect(absent.note == InterconnectSetting.readOnlyNote)
        #expect(!absent.changeable)

        let armed = try #require(InterconnectSetting.decide(try StatusReport.decode(try fixture("status_json_running-interconnect.json"))))
        #expect(armed.state == .on)
        #expect(armed.lines.contains(InterconnectCard.plaintextWarning))
        #expect(armed.lines.first?.hasPrefix("Now: on") == true)

        let unarmed = Data(#"{"schemaVersion":1,"verdict":"running","role":"server","rows":[{"name":"server","state":"running","severity":"ok","detail":""}],"interconnect":{"name":"thunderbolt","armed":false,"members":2}}"#.utf8)
        let off = try #require(InterconnectSetting.decide(try StatusReport.decode(unarmed)))
        #expect(off.state == .off)
        #expect(off.lines == ["Now: off"])
    }
}
