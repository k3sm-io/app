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
import Synchronization
import Testing

import K3smStatus
@testable import K3smInstall

/// LAN reports built in code, shaped like the CLI's.
enum LANReports {
    static func make(_ network: LANAccess, role: String = "server", verdict: String = "running") -> StatusReport {
        StatusReport(
            schemaVersion: 1, verdict: Verdict(word: verdict), role: role, summary: "s",
            rows: [StatusRow(name: role, state: "running", detail: "d")],
            workers: [], network: network)
    }

    static let serverCovers = ["nodeports", "loadbalancers", "ingress"]
    static let serverAlwaysOn = ["apiserver", "join", "mesh"]

    static func access(_ setting: LANSetting, applied: LANApplied? = nil) -> LANAccess {
        LANAccess(setting: setting, recorded: true, covers: serverCovers, alwaysOn: serverAlwaysOn, applied: applied)
    }

    static let on = make(access(.on))
    static let off = make(access(.off))
    static let unknown = make(access(.unknown))
}

/// A runner that records scripts and returns a fixed run, error text included.
final class LANRunner: PrivilegedRunner {
    let run: PrivilegedRun
    private let seen = Mutex<[RootScript]>([])

    init(_ run: PrivilegedRun = PrivilegedRun(outcome: .succeeded)) {
        self.run = run
    }

    var scripts: [RootScript] { seen.withLock { $0 } }

    func runAsRoot(_ script: RootScript, input: Data?) async -> PrivilegedOutcome {
        await runAsRootReportingError(script, input: input).outcome
    }

    func runAsRootReportingError(_ script: RootScript, input: Data?) async -> PrivilegedRun {
        seen.withLock { $0.append(script) }
        return run
    }
}

@Suite("LAN root script")
struct LANScriptTests {
    static let team = TeamID("ABCDE12345")!

    @Test("the verb set is closed: stop, start, restart, LAN on, LAN off")
    func verbs() {
        #expect(LifecycleVerb.allCases == [.stop, .start, .restart, .lanOn, .lanOff])
        #expect(LifecycleVerb.lanVerbs == [.lanOn, .lanOff])
        #expect(LifecycleVerb.lanVerbs.allSatisfy { $0.isLAN })
        #expect(LifecycleVerb.lanVerbs.allSatisfy { $0.requiredState == nil })
    }

    @Test("the LAN verbs' argv are the constants network lan on and off")
    func argv() {
        #expect(LifecycleScriptBuilder.arguments(for: .lanOn) == ["network", "lan", "on"])
        #expect(LifecycleScriptBuilder.arguments(for: .lanOff) == ["network", "lan", "off"])
        #expect(LifecycleScriptBuilder.render(.lanOn, teamID: Self.team).text.contains("\nexec \"$k3sm\" 'network' 'lan' 'on'\n"))
        #expect(LifecycleScriptBuilder.render(.lanOff, teamID: Self.team).text.contains("\nexec \"$k3sm\" 'network' 'lan' 'off'\n"))
    }

    @Test("each LAN prompt says allow or stop allowing connections from other devices")
    func prompts() {
        let on = LifecycleScriptBuilder.render(.lanOn, teamID: Self.team)
        let off = LifecycleScriptBuilder.render(.lanOff, teamID: Self.team)
        #expect(on.prompt.contains("wants to allow connections from other devices"))
        #expect(off.prompt.contains("wants to stop allowing connections from other devices"))
        #expect(!on.readsInput && !off.readsInput)
        #expect(!on.usesStagingLock && !off.usesStagingLock)
    }

    @Test("the LAN scripts run the stop script's checks under env -i", arguments: LifecycleVerb.lanVerbs)
    func sameChecks(_ verb: LifecycleVerb) throws {
        let stop = LifecycleScriptBuilder.render(.stop, teamID: Self.team).text
        let lan = LifecycleScriptBuilder.render(verb, teamID: Self.team).text
        let head = { (t: String) in String(t[..<t.range(of: "exec \"$k3sm\"")!.lowerBound]) }
        #expect(head(lan) == head(stop))
        let line = LifecycleScriptBuilder.render(verb, teamID: Self.team).command(inputPath: "/dev/null")
        #expect(line.hasPrefix("/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/sh -c "))
    }

    @Test("a LAN script's refusals stop before the CLI runs", arguments: LifecycleVerb.lanVerbs)
    func refusals(_ verb: LifecycleVerb) throws {
        for r in LifecycleScriptTests.refusals {
            let line = LifecycleScriptBuilder.render(verb, teamID: Self.team, cliPath: r.cliPath).command(inputPath: "/dev/null")
            let result = try LifecycleScriptTests.run(line)
            #expect(result.status == r.status, "\(r.name): \(result.stderr)")
            #expect(result.stderr.contains(r.message), "\(r.name): \(result.stderr)")
        }
    }

    @Test("the lifecycle driver and precondition refuse a LAN verb", arguments: LifecycleVerb.lanVerbs)
    func lifecycleRefuses(_ verb: LifecycleVerb) async {
        #expect(LifecyclePrecondition.check(verb, expected: .running, live: .running) != .proceed)
        let runner = RecordingRunner()
        let driver = LifecycleDriver(teamID: Self.team, readStatus: { Reports.running }, confirm: { _ in true }, runner: runner)
        guard case .refused = await driver.perform(verb, expected: .running) else {
            Issue.record("the lifecycle driver ran a LAN verb")
            return
        }
        #expect(runner.scripts.isEmpty)
    }

    @Test("the LAN outcome sentences", arguments: [
        (PrivilegedOutcome.succeeded, LifecycleVerb.lanOn, "can now connect"),
        (.succeeded, .lanOff, "Only this Mac and your cluster mesh"),
        (.failed(exitStatus: 1), .lanOn, "kept the previous one"),
        (.failed(exitStatus: 4), .lanOff, "could not put the previous setting back"),
        (.failed(exitStatus: 2), .lanOn, "did not accept `k3sm network lan on`"),
        (.failed(exitStatus: 3), .lanOff, "did not run as root"),
        (.failed(exitStatus: 100), .lanOn, "is not owned by root"),
        (.cancelled, .lanOff, "Nothing was changed"),
    ])
    func sentences(_ outcome: PrivilegedOutcome, _ verb: LifecycleVerb, _ contains: String) {
        #expect(LifecycleOutcome.text(outcome, verb: verb).contains(contains))
    }

    // MARK: the k3sm CLI contract

    @Test("every LAN verb and status field the app uses is one the CLI declares", .enabled(if: LifecycleScriptTests.cliDirectory != nil))
    func cliDeclares() throws {
        let cmd = try #require(LifecycleScriptTests.cliDirectory)
        let k3sm = cmd.deletingLastPathComponent().deletingLastPathComponent()
        let read = { (path: String) throws -> String in try String(contentsOf: k3sm.appending(path: path), encoding: .utf8) }
        let main = try read("cmd/k3sm/main.go")
        let network = try read("cmd/k3sm/network.go")
        let install = try read("pkg/install/networklan.go")
        let status = try read("pkg/status/network.go")
        let report = try read("pkg/status/report.go")
        #expect(main.contains("case \"network\":"), "k3sm has no network verb")
        #expect(network.contains("args[0] != \"lan\""), "k3sm network has no lan subcommand")
        #expect(network.contains("case string(install.LANOn), string(install.LANOff):"), "k3sm network lan takes no on/off")
        for verb in LifecycleVerb.lanVerbs {
            let argv = LifecycleScriptBuilder.arguments(for: verb)
            #expect(network.contains("sudo k3sm " + argv.joined(separator: " ")), "the usage does not document k3sm \(verb.command)")
            #expect(install.contains("= \"\(argv[2])\""), "\(argv[2]) is not a LAN value the CLI declares")
            #expect(argv.allSatisfy { !$0.hasPrefix("-") }, "a LAN verb passes a flag")
        }
        let flat = network.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(flat.contains("exitNetworkRestoreFailed = \(LifecycleExit.lanRestoreFailed)"))
        #expect(report.contains("`json:\"network,omitempty\"`"))
        let daemons = try read("pkg/status/daemons.go")
        #expect(daemons.contains("`json:\"network,omitempty\"`"), "the daemons probe does not carry network")
        #expect(status.contains("NetworkRecordUnreadable = \"unreadable\""), "the unreadable record word changed")
        for key in ["lan\"", "recorded\"", "recordState,omitempty\"", "covers\"", "alwaysOn\"", "applied,omitempty\"",
                    "appliedReadable,omitempty\"", "error,omitempty\""] {
            #expect(status.contains("`json:\"" + key + "`"), "pkg/status/network.go has no json:\"\(key)")
        }
        for word in ["nodeports", "loadbalancers", "ingress", "apiserver", "join", "mesh"] {
            #expect(install.contains("= \"\(word)\""), "\(word) is not a listener word the CLI declares")
        }
    }
}

@Suite("LAN checkbox")
struct LANToggleTests {
    static let now = Date(timeIntervalSince1970: 2_000_000_000)

    static func evaluate(_ report: StatusReport?, age: TimeInterval = 5, failed: Bool = false,
                         trust: String? = nil, blocked: String? = nil) -> LANToggle {
        LANToggle.evaluate(report: report, readAt: report == nil ? nil : now.addingTimeInterval(-age), now: now,
                           lastReadFailed: failed, trustRefusal: trust, blocked: blocked)
    }

    @Test("the checkbox is tri-state: on, off, unknown")
    func triState() {
        let on = Self.evaluate(LANReports.on)
        #expect(on.visible && on.enabled && on.value == .on && on.clickVerb == .lanOff)
        let off = Self.evaluate(LANReports.off)
        #expect(off.visible && off.enabled && off.value == .off && off.clickVerb == .lanOn)
        let unknown = Self.evaluate(LANReports.unknown)
        #expect(unknown.visible && !unknown.enabled && unknown.value == .unknown && unknown.clickVerb == nil)
        #expect(unknown.disabledReason?.contains("does not know") == true)
        #expect(LANToggle.title == "Allow connections from other devices")
        #expect(LANToggle.subtitle == "Off: only this Mac and your cluster mesh")
    }

    @Test("a failed, stale or untrusted read disables it with the reason and drives nothing")
    func disabled() {
        let failed = Self.evaluate(LANReports.off, failed: true)
        #expect(!failed.enabled && failed.value == .unknown && failed.clickVerb == nil)
        #expect(failed.disabledReason?.contains("could not read the status") == true)
        let none = Self.evaluate(nil)
        #expect(none.visible && !none.enabled && none.value == .unknown)
        let stale = Self.evaluate(LANReports.off, age: LANToggle.maxAge + 1)
        #expect(!stale.enabled && stale.value == .unknown && stale.disabledReason?.contains("out of date") == true)
        let future = Self.evaluate(LANReports.off, age: -60)
        #expect(!future.enabled)
        let untrusted = Self.evaluate(LANReports.off, trust: "/Library/k3sm is a symlink")
        #expect(!untrusted.enabled && untrusted.value == .unknown)
        #expect(untrusted.disabledReason?.contains("will not run the installed k3sm: /Library/k3sm is a symlink") == true)
        let blocked = Self.evaluate(LANReports.off, blocked: "Another change is running.")
        #expect(!blocked.enabled && blocked.value == .off && blocked.disabledReason == "Another change is running.")
    }

    @Test("a role with no switch hides it")
    func hidden() {
        #expect(!Self.evaluate(LANReports.make(LANReports.access(.off), verdict: "not-installed")).visible)
        #expect(!Self.evaluate(LANReports.make(LANReports.access(.on), role: "witness")).visible)
        #expect(!Self.evaluate(LANReports.make(LANReports.access(.on), role: "witness")).showsIndicator)
        #expect(Self.evaluate(LANReports.make(LANReports.access(.off), role: "agent")).visible)
    }

    @Test("an absent field shows on, not recorded, with the indicator")
    func absentField() {
        let t = Self.evaluate(LANReports.make(.absentField))
        #expect(t.value == .on && t.enabled && t.showsIndicator)
        #expect(t.notes.contains { $0.contains("no setting is recorded") })
    }

    @Test("the indicator shows only while LAN access is on")
    func indicator() {
        #expect(Self.evaluate(LANReports.on).showsIndicator)
        #expect(!Self.evaluate(LANReports.off).showsIndicator)
        #expect(!Self.evaluate(LANReports.unknown).showsIndicator)
        // The daemon still serving on keeps the indicator, whatever is recorded.
        #expect(Self.evaluate(LANReports.make(LANReports.access(.off, applied: LANApplied(setting: .on)))).showsIndicator)
    }

    @Test("a recorded value the daemon does not serve, and a refused change, are noted")
    func mismatch() {
        let mismatch = Self.evaluate(LANReports.make(LANReports.access(.off, applied: LANApplied(setting: .on))))
        #expect(mismatch.value == .off)
        #expect(mismatch.notes == ["The setting is off, but k3sm still serves on."])
        let refused = Self.evaluate(LANReports.make(LANReports.access(.off, applied: LANApplied(
            setting: .on, error: "ingress: bind\u{1B}[2J\n:80 in use\u{202E}" + String(repeating: "x", count: 600)))))
        #expect(refused.notes.count == 1)
        let note = refused.notes.first ?? ""
        #expect(note.hasPrefix("The last change was refused, and k3sm still serves on: ingress: bind [2J :80 in usexxx"))
        #expect(!note.unicodeScalars.contains { $0.properties.generalCategory == .control || $0.properties.generalCategory == .format })
        #expect(note.hasSuffix("…"))
        #expect(note.count < StatusDisplay.maxErrorLength + 80)
        let agreed = Self.evaluate(LANReports.make(LANReports.access(.on, applied: LANApplied(setting: .on))))
        #expect(agreed.notes.isEmpty)
    }
}

@Suite("LAN confirmation")
struct LANConfirmationTests {
    @Test("turning on names what becomes reachable and what the switch does not cover")
    func on() {
        let c = LifecycleConfirmation(verb: .lanOn, report: LANReports.off)
        #expect(c.title == "Allow connections from other devices?")
        #expect(c.message.contains("The NodePort, LoadBalancer and ingress listeners"))
        #expect(c.message.contains("on every network this Mac is on, and any device on those networks can reach them"))
        #expect(c.message.contains("does not change the API server (this Mac and the cluster mesh only), the worker join port (every request needs a join token) and the wireguard mesh port (it answers only cluster peers)."))
        #expect(c.cancelIsDefault)
        #expect(c.warning == nil)
    }

    @Test("a worker's confirmation renders its own families and alwaysOn")
    func worker() {
        let report = LANReports.make(LANAccess(setting: .off, recorded: true, covers: ["nodeports", "loadbalancers"], alwaysOn: ["mesh"]), role: "agent")
        let c = LifecycleConfirmation(verb: .lanOn, report: report)
        #expect(c.message.contains("The NodePort and LoadBalancer listeners"))
        #expect(c.message.contains("does not change the wireguard mesh port"))
        #expect(!c.message.contains("API server"))
    }

    @Test("an unknown covers or alwaysOn word is shown without control or format characters")
    func hostileWords() {
        let report = LANReports.make(LANAccess(setting: .off, recorded: true, covers: ["node\u{202E}ports2\u{1B}[2J"],
                                               alwaysOn: ["\u{2066}dns\u{2069}\n53"]))
        let c = LifecycleConfirmation(verb: .lanOn, report: report)
        #expect(c.message.contains("The nodeports2 [2J listeners"))
        #expect(c.message.contains("does not change dns 53."))
        #expect(!c.message.unicodeScalars.contains { $0.properties.generalCategory == .format || ($0.properties.generalCategory == .control && $0 != "\n") })
        let untrusted = LANToggleTests.evaluate(LANReports.off, trust: "/Library/k3sm\u{202E}kcol is a symlink")
        #expect(untrusted.disabledReason == "The app will not run the installed k3sm: /Library/k3smkcol is a symlink.")
    }

    @Test("a long covers or alwaysOn list is capped")
    func capped() {
        let words = (1...30).map { "family\($0)" }
        let c = LifecycleConfirmation(verb: .lanOn, report: LANReports.make(LANAccess(setting: .off, recorded: true, covers: words, alwaysOn: words)))
        #expect(c.message.contains("family1, family2, family3, family4, family5, family6, family7, family8 and 22 more listeners"))
        #expect(c.message.contains("family8 and 22 more."))
        #expect(!c.message.contains("family9"))
        #expect(c.message.count < 600)
    }

    @Test("an unknown alwaysOn is said, never guessed")
    func unknownAlwaysOn() {
        let c = LifecycleConfirmation(verb: .lanOn, report: LANReports.make(.absentField))
        #expect(c.message.contains("k3sm did not say which listeners this setting leaves alone."))
    }

    @Test("Cancel is the default only for turning on")
    func defaults() {
        for verb in LifecycleVerb.allCases {
            #expect(LifecycleConfirmation(verb: verb, report: LANReports.on).cancelIsDefault == (verb == .lanOn))
        }
    }
}

@Suite("LAN driver")
struct LANDriverTests {
    static let team = TeamID("ABCDE12345")!

    static func driver(_ reads: StatusSequence, runner: LANRunner, answer: Bool, asked: Questions? = nil) -> LANDriver {
        LANDriver(teamID: team, readStatus: { reads.next() }, confirm: { c in
            asked?.append(c)
            return answer
        }, runner: runner)
    }

    @Test("on: live read, confirm, re-read, the lan-on script, then a confirming read")
    func onRuns() async throws {
        let reads = StatusSequence([LANReports.off, LANReports.off, LANReports.on])
        let runner = LANRunner()
        let asked = Questions()
        let result = await Self.driver(reads, runner: runner, answer: true, asked: asked).perform(.lanOn, expected: .off)
        #expect(result == .ran(.succeeded, LifecycleOutcome.text(.succeeded, verb: .lanOn), confirmed: .on))
        #expect(reads.reads == 3)
        #expect(asked.all.map(\.verb) == [.lanOn])
        #expect(runner.scripts == [LifecycleScriptBuilder.render(.lanOn, teamID: Self.team)])
    }

    @Test("off runs without a question")
    func offRuns() async {
        let reads = StatusSequence([LANReports.on, LANReports.off])
        let runner = LANRunner()
        let asked = Questions()
        let result = await Self.driver(reads, runner: runner, answer: false, asked: asked).perform(.lanOff, expected: .on)
        #expect(result == .ran(.succeeded, LifecycleOutcome.text(.succeeded, verb: .lanOff), confirmed: .off))
        #expect(asked.all.isEmpty)
        #expect(runner.scripts == [LifecycleScriptBuilder.render(.lanOff, teamID: Self.team)])
    }

    @Test("a declined question runs nothing")
    func declined() async {
        let runner = LANRunner()
        let result = await Self.driver(StatusSequence([LANReports.off]), runner: runner, answer: false).perform(.lanOn, expected: .off)
        #expect(result == .declined)
        #expect(runner.scripts.isEmpty)
    }

    @Test("a changed, unknown, unreadable or switchless status refuses before the prompt", arguments: [
        ([LANReports.on], LifecycleVerb.lanOn, LANSetting.off, "is on now, not off"),
        ([LANReports.unknown], .lanOff, .on, "does not know"),
        ([nil], .lanOff, .on, "could not read the status"),
        ([LANReports.make(LANReports.access(.on), verdict: "not-installed")], .lanOff, .on, "no k3sm node"),
        ([LANReports.on], .lanOn, .on, "already on"),
        ([LANReports.off, LANReports.on], .lanOn, .off, "is on now, not off"),
    ] as [([StatusReport?], LifecycleVerb, LANSetting, String)])
    func refuses(_ reads: [StatusReport?], _ verb: LifecycleVerb, _ expected: LANSetting, _ contains: String) async {
        let runner = LANRunner()
        let result = await Self.driver(StatusSequence(reads), runner: runner, answer: true).perform(verb, expected: expected)
        guard case .refused(let why) = result else {
            Issue.record("not refused: \(result)")
            return
        }
        #expect(why.contains(contains), "\(why)")
        #expect(runner.scripts.isEmpty)
    }

    @Test("a covers or alwaysOn change between the question and the prompt refuses", arguments: [
        LANAccess(setting: .off, recorded: true, covers: ["nodeports"], alwaysOn: LANReports.serverAlwaysOn),
        LANAccess(setting: .off, recorded: true, covers: LANReports.serverCovers, alwaysOn: ["mesh"]),
        LANAccess(setting: .off, recorded: true, covers: LANReports.serverCovers, alwaysOn: nil),
    ])
    func staleConsent(_ changed: LANAccess) async {
        let runner = LANRunner()
        let asked = Questions()
        let result = await Self.driver(StatusSequence([LANReports.off, LANReports.make(changed)]), runner: runner, answer: true, asked: asked)
            .perform(.lanOn, expected: .off)
        #expect(result == .refused(LANDriver.changedWhileAsking))
        #expect(asked.all.count == 1)
        #expect(runner.scripts.isEmpty)
    }

    @Test("the result shows the confirmed value, not the requested one")
    func confirmedValue() async {
        let reads = StatusSequence([LANReports.on, LANReports.on])
        let result = await Self.driver(reads, runner: LANRunner(), answer: true).perform(.lanOff, expected: .on)
        guard case .ran(.succeeded, let text, let confirmed) = result else {
            Issue.record("did not run: \(result)")
            return
        }
        #expect(confirmed == .on)
        #expect(text.contains("the status now reads on"))
        let unread = await Self.driver(StatusSequence([LANReports.on, nil]), runner: LANRunner(), answer: true).perform(.lanOff, expected: .on)
        guard case .ran(_, _, let after) = unread else {
            Issue.record("did not run: \(unread)")
            return
        }
        #expect(after == .unknown)
    }

    @Test("the CLI's error text is shown with control characters stripped and truncated")
    func errorText() async {
        let raw = "k3sm network lan on: ingress\u{1B}]0;pwned\u{7}: bind\r\nfailed\u{202E}" + String(repeating: "z", count: 900)
        let runner = LANRunner(PrivilegedRun(outcome: .failed(exitStatus: 1), errorOutput: raw))
        let result = await Self.driver(StatusSequence([LANReports.on, LANReports.on]), runner: runner, answer: true)
            .perform(.lanOff, expected: .on)
        guard case .ran(.failed(exitStatus: 1), let text, let confirmed) = result else {
            Issue.record("did not run: \(result)")
            return
        }
        #expect(confirmed == .on)
        #expect(text.contains("kept the previous one"))
        #expect(text.contains("k3sm said: k3sm network lan on: ingress ]0;pwned : bind failed"))
        #expect(text.hasSuffix("The setting is on."))
        #expect(!text.unicodeScalars.contains { $0.properties.generalCategory == .control || $0.properties.generalCategory == .format })
        #expect(text.count < LifecycleOutcome.text(.failed(exitStatus: 1), verb: .lanOff).count + StatusDisplay.maxErrorLength + 40)
    }
}
