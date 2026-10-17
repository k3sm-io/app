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

@Suite("the Cluster tab's issues")
struct ClusterIssuesTests {
    private static let checked = Date(timeIntervalSince1970: 1_788_600_600) // 2026-09-05T09:30:00Z

    private static func report(_ json: String) throws -> StatusReport {
        try StatusReport.decode(Data(json.utf8))
    }

    @Test("a report with every row ok has no issues, rests in the field and says so with its check time")
    func allOk() throws {
        let report = try Self.report("""
        {"schemaVersion": 1, "verdict": "running", "role": "server", "summary": "k3sm is running",
         "rows": [{"name": "netd", "state": "running", "severity": "ok", "detail": "pid 12"},
                  {"name": "dns", "state": "ok", "severity": "ok", "detail": "answered"},
                  {"name": "datastore", "state": "skip", "severity": "skip", "detail": "no state.db yet"}],
         "next": ["k3sm kubectl get pods -A"], "timestamp": "2026-09-05T09:30:00Z"}
        """)
        let issues = ClusterIssues.of(report)
        #expect(issues.groups.isEmpty)
        #expect(issues.isClean)
        #expect(issues.headline == "Nothing needs attention.")
        #expect(issues.summary == nil)
        #expect(issues.checkedAt == Self.checked)
        #expect(issues.checkedLine(now: Self.checked.addingTimeInterval(2)) == "Last checked just now")
        #expect(issues.checkedLine(now: Self.checked.addingTimeInterval(40)) == "Last checked 40 s ago")
        #expect(issues.checkedLine(now: Self.checked.addingTimeInterval(180)) == "Last checked 3 min ago")
        #expect(issues.checkedLine(now: Self.checked.addingTimeInterval(7200)) == "Last checked 2 h ago")
        #expect(issues.checkedLine(now: Self.checked.addingTimeInterval(-60)) == "Last checked just now")
        #expect(issues.next == [RemedyStep(text: "k3sm kubectl get pods -A", command: "k3sm kubectl get pods -A")])
        // With no update card the tab rests: one sentence, with the check time.
        #expect(issues.rests(withCard: false))
        #expect(!issues.rests(withCard: true))
        #expect(issues.healthyLine(now: Self.checked.addingTimeInterval(180)) == "Everything is healthy, last checked 3 min ago.")
        #expect(issues.healthyLine(now: Self.checked.addingTimeInterval(1)) == "Everything is healthy, last checked just now.")
        let untimed = ClusterIssues.of(StatusReport(schemaVersion: 1, verdict: .running, role: "server", summary: "", rows: []))
        #expect(untimed.rests(withCard: false))
        #expect(untimed.healthyLine() == "Everything is healthy.")
    }

    @Test("the running fixture is clean and rests: its unknown and needs-admin checks are listed under the field, not as faults")
    func runningFixtureIsClean() throws {
        let issues = ClusterIssues.of(try StatusReport.decode(try fixture("status_json_running.json")))
        #expect(issues.isClean)
        #expect(issues.headline == ClusterIssues.cleanText)
        #expect(issues.groups.map(\.level) == [.unknown, .needsAdmin])
        #expect(issues.groups.flatMap(\.issues).map(\.name) == ["update", "runtimed"])
        #expect(issues.groups.map(\.heading) == ["Could not check (1)", "Only an administrator can check (1)"])
        #expect(issues.rests(withCard: false))
        #expect(issues.checkedAt == Self.checked)
    }

    @Test("one warn row with a remedy: its card carries the detail and a copyable command")
    func oneWarnWithRemedy() throws {
        let report = try Self.report("""
        {"schemaVersion": 1, "verdict": "degraded", "role": "server", "summary": "kubeconfig: missing",
         "rows": [{"name": "netd", "state": "running", "severity": "ok", "detail": "pid 12"},
                  {"name": "kubeconfig", "state": "missing", "severity": "warn",
                   "detail": "~/.kube/config has no k3sm context", "remedy": "k3sm kubeconfig --write"}],
         "next": ["k3sm kubeconfig --write"], "timestamp": "2026-09-05T09:30:00.123456Z"}
        """)
        let issues = ClusterIssues.of(report)
        #expect(!issues.isClean)
        #expect(issues.headline == "1 check needs attention.")
        #expect(issues.summary == "kubeconfig: missing")
        #expect(issues.groups.count == 1)
        #expect(issues.groups.first?.heading == "Needs attention (1)")
        #expect(issues.groups.first?.issues == [ClusterIssue(
            name: "kubeconfig", state: "missing", detail: "~/.kube/config has no k3sm context", level: .warning,
            remedy: [RemedyStep(text: "k3sm kubeconfig --write", command: "k3sm kubeconfig --write")])])
        #expect(issues.next.map(\.command) == ["k3sm kubeconfig --write"])
        // Fractional seconds parse too.
        #expect(issues.checkedAt.map { abs($0.timeIntervalSince(Self.checked) - 0.123456) < 0.001 } == true)
    }

    @Test("the degraded fixture counts only its two warnings, then lists its unknown and needs-admin checks")
    func degradedFixture() throws {
        let issues = ClusterIssues.of(try StatusReport.decode(try fixture("status_json_degraded.json")))
        #expect(issues.headline == "2 checks need attention.")
        #expect(!issues.rests(withCard: false))
        #expect(issues.groups.map(\.level) == [.warning, .unknown, .needsAdmin])
        #expect(issues.groups[0].issues.map(\.name) == ["netd", "server"])
        #expect(issues.groups[0].issues[0].remedy.map(\.command) == ["sudo launchctl kickstart -k system/io.k3sm.netd"])
        #expect(issues.next.count == 4)
    }

    @Test("a failing row and workers: failing first, a multi-line remedy is one step per line, workers add no rows")
    func failingRowAndWorkers() throws {
        let report = try Self.report("""
        {"schemaVersion": 1, "verdict": "degraded", "role": "server", "summary": "server: stopped",
         "rows": [{"name": "update", "state": "behind", "severity": "warn", "detail": "node-b runs v0.1.6",
                   "remedy": "k3sm update"},
                  {"name": "server", "state": "stopped", "severity": "fail", "detail": "launchd reports it stopped",
                   "remedy": "sudo launchctl kickstart -k system/io.k3sm.server\\nk3sm status logs server"},
                  {"name": "datastore", "state": "skip", "severity": "skip", "detail": "no state.db yet"},
                  {"name": "mystery", "state": "odd", "severity": "grave", "detail": "a new severity word"}],
         "workers": [{"name": "node-a", "role": "server", "version": "v1.36.2+k3sm.0.1.7"},
                     {"name": "node-b", "role": "agent", "version": "v1.36.2+k3sm.0.1.6"}],
         "next": ["sudo launchctl kickstart -k system/io.k3sm.server", 7, "find out why   # by hand"],
         "timestamp": "not a time"}
        """)
        #expect(report.workers?.count == 2)
        let issues = ClusterIssues.of(report)
        #expect(issues.groups.map(\.level) == [.failing, .warning, .reported])
        #expect(issues.groups.map(\.heading) == ["Failing (1)", "Needs attention (1)", "Reported (1)"])
        #expect(issues.groups.flatMap(\.issues).map(\.name) == ["server", "update", "mystery"])
        #expect(issues.groups[0].issues[0].remedy == [
            RemedyStep(text: "sudo launchctl kickstart -k system/io.k3sm.server",
                       command: "sudo launchctl kickstart -k system/io.k3sm.server"),
            RemedyStep(text: "k3sm status logs server", command: "k3sm status logs server"),
        ])
        #expect(issues.headline == "3 checks need attention.")
        // A mistyped next entry is dropped; prose is shown but not copyable.
        #expect(issues.next == [
            RemedyStep(text: "sudo launchctl kickstart -k system/io.k3sm.server",
                       command: "sudo launchctl kickstart -k system/io.k3sm.server"),
            RemedyStep(text: "find out why   # by hand", command: nil),
        ])
        #expect(issues.checkedAt == nil)
        #expect(issues.checkedLine() == ClusterIssues.checkedUnknown)
    }

    @Test("groups run failing, needs attention, reported, could not check, needs an administrator, whatever the report's order")
    func groupingOrder() throws {
        let issues = ClusterIssues.of(try StatusReport.decode(try fixture("status_json_stopped-by-user.json")))
        #expect(issues.groups.map(\.level) == [.failing, .unknown, .needsAdmin])
        #expect(issues.groups[0].issues.map(\.name) == ["netd", "server", "apiserver"])
        #expect(issues.groups[1].issues.map(\.name) == ["node", "update"])
        #expect(issues.groups[0].issues[1].remedy.count == 2)
        #expect(IssueLevel.allCases.sorted() == [.failing, .warning, .reported, .unknown, .needsAdmin])

        let reversed = StatusReport(schemaVersion: 1, verdict: .degraded, role: "server", summary: "", rows: [
            StatusRow(name: "c", state: "odd", detail: "", severity: "grave"),
            StatusRow(name: "b", state: "behind", detail: "", severity: "warn"),
            StatusRow(name: "a", state: "down", detail: "", severity: "fail"),
            StatusRow(name: "d", state: "down", detail: "", severity: "fail"),
        ])
        let ordered = ClusterIssues.of(reversed)
        #expect(ordered.groups.map(\.level) == [.failing, .warning, .reported])
        #expect(ordered.groups.flatMap(\.issues).map(\.name) == ["a", "d", "b", "c"])
    }

    @Test("the workloads row is never listed, in any state: its own tabs are that check")
    func workloadsRowIsNeverListed() {
        for severity in ["fail", "warn", "grave", "unknown", "skip", "ok", ""] {
            let rows = [StatusRow(name: "workloads", state: "degraded", detail: "2 pods failing", remedy: "k3sm kubectl get pods -A",
                                  severity: severity)]
            let running = ClusterIssues.of(StatusReport(schemaVersion: 1, verdict: .running, role: "server", summary: "", rows: rows))
            #expect(running.groups.isEmpty, "severity \(severity)")
            #expect(running.isClean, "severity \(severity)")
            let withFault = ClusterIssues.of(StatusReport(schemaVersion: 1, verdict: .degraded, role: "server", summary: "",
                                                          rows: rows + [StatusRow(name: "netd", state: "failed", detail: "", severity: "fail")]))
            #expect(withFault.groups.flatMap(\.issues).map(\.name) == ["netd"], "severity \(severity)")
            #expect(withFault.headline == "1 check needs attention.")
        }
        #expect(ClusterIssues.workloadsRow == "workloads")
    }

    @Test("unknown and needs-admin rows are listed but are not faults; a plain skip or unmarked row is not listed")
    func unknownAndNeedsAdminAreListed() {
        let rows = [
            StatusRow(name: "datastore", state: "skip", detail: "no state.db yet", severity: "skip"),
            StatusRow(name: "runtimed", state: "needs-admin", detail: "needs sudo", severity: "skip"),
            StatusRow(name: "update", state: "unknown", detail: "", severity: "unknown"),
            StatusRow(name: "node", state: "down", detail: "an older k3sm printed no severity", severity: ""),
        ]
        let issues = ClusterIssues.of(StatusReport(schemaVersion: 1, verdict: .running, role: "server", summary: "", rows: rows))
        #expect(issues.groups.map(\.level) == [.unknown, .needsAdmin])
        #expect(issues.groups.flatMap(\.issues).map(\.name) == ["update", "runtimed"])
        // Neither counts as a fault: the report stays clean, its headline says so, and the tab rests.
        #expect(issues.isClean)
        #expect(issues.headline == ClusterIssues.cleanText)
        #expect(issues.rests(withCard: false))
        #expect(IssueLevel(row: rows[0]) == nil)
        #expect(IssueLevel(row: rows[1]) == .needsAdmin)
        #expect(IssueLevel(row: rows[2]) == .unknown)
        #expect(IssueLevel(row: rows[3]) == nil)
        #expect(IssueLevel(row: StatusRow(name: "x", state: "x", detail: "", severity: "grave")) == .reported)
        // needs-admin is read from the state word, whatever the severity.
        #expect(IssueLevel(row: StatusRow(name: "x", state: "needs-admin", detail: "", severity: "")) == .needsAdmin)
        #expect(IssueLevel.allCases.filter(\.isFault) == [.failing, .warning, .reported])
        // A fault beside them still makes the headline and stops the rest.
        let fault = ClusterIssues.of(StatusReport(schemaVersion: 1, verdict: .degraded, role: "server", summary: "",
                                                  rows: rows + [StatusRow(name: "netd", state: "failed", detail: "", severity: "fail")]))
        #expect(fault.headline == "1 check needs attention.")
        #expect(!fault.rests(withCard: false))
    }

    @Test("the field's butterfly loops above the flowers and, under Reduce Motion, perches still on the tallest")
    func fieldFlight() throws {
        let perched = FieldFlight.pose(at: 3, reduceMotion: true)
        #expect(perched.perched && perched.beat == 0 && perched.tilt == 0)
        #expect(FieldFlight.pose(at: 700, reduceMotion: true) == perched)
        let top = FieldFlight.flowerTop(FieldFlight.perch)
        #expect(perched.x == top.x && perched.y == top.y)
        #expect(FieldFlight.flowers.map(\.height).max() == FieldFlight.flowers[FieldFlight.perch].height)

        let highestFlowerTop = try #require(FieldFlight.flowers.indices.map { FieldFlight.flowerTop($0).y }.min())
        for step in 0..<360 {
            let t = Double(step) * FieldFlight.period / 360
            let pose = FieldFlight.pose(at: t, reduceMotion: false)
            #expect(!pose.perched)
            #expect(pose.x > 0.05 && pose.x < 0.95)
            #expect(pose.y > 0.1 && pose.y < highestFlowerTop - 0.05)
            #expect(pose.beat >= 0 && pose.beat <= FieldFlight.beatPeak)
            #expect(abs(pose.tilt) <= FieldFlight.maxTilt)
        }
        // One lap brings it back to where it started.
        let start = FieldFlight.pose(at: 0, reduceMotion: false)
        let lap = FieldFlight.pose(at: FieldFlight.period, reduceMotion: false)
        #expect(abs(start.x - lap.x) < 1e-9 && abs(start.y - lap.y) < 1e-9 && abs(start.beat - lap.beat) < 1e-6)
    }

    @Test("node-reported text is clipped, and a clipped command is never copyable")
    func clipped() throws {
        let long = "sudo k3sm " + String(repeating: "x", count: 300)
        let row = StatusRow(name: "a\u{202E}b", state: "fail\nword", detail: String(repeating: "d", count: 300),
                            remedy: long, severity: "fail")
        let report = StatusReport(schemaVersion: 1, verdict: .degraded, role: "server", summary: "", rows: [row])
        let issue = try #require(ClusterIssues.of(report).groups.first?.issues.first)
        #expect(issue.name == "ab")
        #expect(issue.state == "fail word")
        #expect(issue.detail.count == StatusDisplay.maxLength)
        #expect(issue.remedy.count == 1)
        #expect(issue.remedy[0].text.count == StatusDisplay.maxLength)
        #expect(issue.remedy[0].command == nil)
    }

    @Test("before any report the tab says it has none; a verdict that is not running with no fault is never clean")
    func emptyStates() {
        let none = ClusterIssues.of(nil)
        #expect(none.headline == ClusterIssues.notRead)
        #expect(!none.isClean)
        #expect(!none.rests(withCard: false))
        #expect(none.groups.isEmpty && none.next.isEmpty)
        let row = StatusRow(name: "node", state: "unknown", detail: "not read", severity: "unknown")
        let report = StatusReport(schemaVersion: 1, verdict: .unknown, role: "server", summary: "unknown", rows: [row])
        let issues = ClusterIssues.of(report)
        #expect(!issues.isClean)
        // Only the unknown row is listed, and an unknown verdict is not healthy: no field.
        #expect(issues.groups.map(\.level) == [.unknown])
        #expect(!issues.rests(withCard: false))
        #expect(issues.headline == "Unknown, with no failing check.")
        #expect(issues.summary == "unknown")
    }

    @Test("the Alerts tab is last in the strip, after Stats, keeps its stored id, reads no list of its own and lists no rows")
    func tab() {
        #expect(ConsoleSection.allCases.last == .cluster)
        #expect(ConsoleSection.allCases.suffix(2) == [.stats, .cluster])
        #expect(ConsoleSection.cluster.title == "Alerts")
        // A choice an earlier build stored as "cluster" still restores the tab.
        #expect(ConsoleSection.cluster.rawValue == "cluster")
        #expect(ConsoleTabs.restore(from: "cluster") == .cluster)
        #expect(Help.Strip.tab(.cluster).label == "Alerts")
        #expect(TabHeader.placement(.cluster) == .none)
        #expect(ConsoleRow(section: .cluster, key: "x").section == .cluster)
        #expect(InspectorDetails.emptyText(.cluster) == ClusterIssues.inspectorText)
    }

    @Test("the update card is the strip's old button: shown when the plan offers Update, with its title and state")
    func updateCard() throws {
        let workers = try StatusReport.decode(try fixture("status_json_server-with-workers.json"))
        #expect(UpdateCard.of(plan: .none, report: workers) == nil)
        #expect(UpdateCard.of(plan: .blocked(.workerBehind), report: workers) == nil)

        let catchUp = try #require(UpdateCard.of(plan: .catchUp(tag: "v0.1.7", nodes: ["node-b"]), report: workers))
        #expect(catchUp.title == "1 node behind v0.1.7")
        #expect(catchUp.buttonTitle == "Update" && catchUp.isEnabled)
        #expect(catchUp.detail == UpdatePlan.catchUp(tag: "v0.1.7", nodes: ["node-b"]).line.map(StatusDisplay.clip))

        // The server (v0.1.7) and both workers (0.1.7, 0.1.6) are behind v0.1.9.
        let managed = try #require(UpdateCard.of(plan: .managed(tag: "v0.1.9"), report: workers))
        #expect(managed.title == "3 nodes behind v0.1.9")
        #expect(UpdateCard.of(plan: .managed(tag: "v0.1.9"), report: nil)?.title == "k3sm v0.1.9 is available")

        let version = try #require(SemanticVersion("0.1.9"))
        let payload = try #require(UpdateCard.of(plan: .payload(version), report: nil))
        #expect(payload.title == "This Mac is behind 0.1.9")

        let rolling = try #require(UpdateCard.of(plan: .rolling, report: workers))
        #expect(rolling.title == UpdateCard.rollingTitle)
        #expect(rolling.buttonTitle == "Updating…" && !rolling.isEnabled)
        #expect(rolling.detail == StatusDisplay.clip(UpdatePlan.rollingReason))

        let blocked = try #require(UpdateCard.of(plan: .blocked(.appDeveloperBuild(.managed(tag: "v0.1.9"))), report: workers))
        #expect(blocked.title == "3 nodes behind v0.1.9")
        #expect(!blocked.isEnabled)
        #expect(blocked.detail == StatusDisplay.clip(UpdateBlock.managedDeveloperBuild))
    }

    // MARK: Alerts

    @Test("alert rows from the real goldens show cause, evidence, numbered steps with Copy, marks, since and the guide link")
    func alertRowsFromGoldens() throws {
        let issues = ClusterIssues.of(try StatusReport.decode(try fixture("status_json_stopped-by-user.json")))
        let server = try #require(issues.groups.flatMap(\.issues).first { $0.name == "server" })
        let alert = try #require(server.alert)
        #expect(alert.cause.hasPrefix("k3sm was stopped on this Mac on purpose (by user: maintenance window)"))
        #expect(alert.cause.count <= StatusDisplay.maxLength)
        // Seven evidence entries: six shown, then "and 1 more".
        #expect(alert.evidence == ["loaded but not running (3 runs)", "label: io.k3sm.server",
                                   "plist: /Library/LaunchDaemons/io.k3sm.server.plist", "pid: 0", "runs: 3", "last-exit: 0"])
        #expect(alert.moreEvidence == "and 1 more")
        #expect(alert.evidenceTitle == "Evidence (7)")
        #expect(alert.steps == [IssueStep(number: 1, text: "Start k3sm again", command: "sudo k3sm start", copy: "sudo k3sm start",
                                          needsAdmin: true, confirm: false)])
        #expect(alert.steps[0].numberText == "1.")
        #expect(alert.moreSteps == nil)
        #expect(alert.since == "Since 2026-09-05 09:28 UTC")
        #expect(alert.docs?.absoluteString == "https://k3sm.io/docs/stop-start/#a-stop-survives-reboot")
        // The row's own detail and remedy are still decoded beside the alert.
        #expect(server.remedy.count == 2)

        let runtimed = try #require(issues.groups.last?.issues.first)
        #expect(runtimed.level == .needsAdmin && runtimed.name == "runtimed")
        #expect(runtimed.alert?.docs?.absoluteString == "https://k3sm.io/docs/troubleshooting/#checks-that-need-sudo")
        #expect(runtimed.alert?.since == nil)

        // The agent's steps: a confirm step, a step done by hand (no command, no Copy), a plain step.
        let waiting = ClusterIssues.of(try StatusReport.decode(try fixture("status_json_agent-waiting.json")))
        let agent = try #require(waiting.groups.flatMap(\.issues).first { $0.name == "agent" }?.alert)
        #expect(agent.steps.map(\.number) == [1, 2, 3])
        #expect(agent.steps.map(\.copy) == ["k3sm token create", nil, "k3sm status logs agent"])
        #expect(agent.steps.map(\.command) == ["k3sm token create", nil, "k3sm status logs agent"])
        #expect(agent.steps.map(\.confirm) == [true, false, false])
        #expect(agent.steps.map(\.needsAdmin) == [false, true, false])
        #expect(agent.evidenceTitle == "Evidence (9)" && agent.evidence.count == IssueAlert.maxEvidence)
        #expect(agent.moreEvidence == "and 3 more")
    }

    @Test("every vendored status golden decodes an alert on exactly the rows k3sm says need one")
    func goldensCarryAlerts() throws {
        let names = ["agent-join-target", "agent-waiting", "degraded", "network-absent", "network-applied-unreadable",
                     "network-recorded", "network-unreadable", "not-installed", "running-interconnect", "running",
                     "server-with-workers", "stopped-by-user", "stopped-clean", "unknown"]
        for name in names {
            let report = try StatusReport.decode(try fixture("status_json_\(name).json"))
            for row in report.rows {
                let needs = ["warn", "fail", "unknown"].contains(row.severity) || row.state == "needs-admin"
                #expect((row.alert != nil) == needs, "\(name) \(row.name)")
                if let alert = row.alert {
                    #expect(!alert.cause.isEmpty && !alert.fix.isEmpty, "\(name) \(row.name)")
                    #expect(AlertDocs.url(alert.docs) != nil, "\(name) \(row.name) \(alert.docs)")
                }
            }
        }
    }

    @Test("Copy is offered only for the producer's exact command: newline, bidi, zero-width, control and overlong commands are text only")
    func copyRefused() {
        #expect(AlertCommand.copyable("sudo launchctl kickstart -k system/io.k3sm.server"))
        #expect(AlertCommand.copyable("k3sm kubectl delete pod -n default web-1 --grace-period=0 --force"))
        let refused = [
            "ls /Users/jos\u{E9}/k3sm",
            "kubectl get p\u{043E}ds -A",   // a Cyrillic o
            "\u{FF4B}3sm start",             // a fullwidth k
            "k3sm start\nrm -rf ~", "k3sm start\r", "k3sm start\u{2028}x",
            "k3sm start \u{202E}trats", "k3sm \u{2066}start\u{2069}", "k3sm\u{200F} start",
            "k3sm\u{200B} start", "k3sm\u{200D}start", "\u{FEFF}k3sm start", "k3sm start\u{2060}",
            "k3sm\tstart", "k3sm\u{00A0}start", "k3sm \u{1B}[2Jstart", "k3sm start\u{7F}",
            "k3sm \u{E000}", "", "   ",
            "k3sm " + String(repeating: "x", count: AlertCommand.maxBytes),
        ]
        for command in refused {
            #expect(!AlertCommand.copyable(command), "\(command.unicodeScalars.map { String($0.value, radix: 16) })")
            let step = IssueStep.of(StatusFixStep(step: "do it", command: command, needsAdmin: false, confirm: false), number: 1)
            #expect(step.copy == nil)
            if let shown = step.command {
                #expect(shown == StatusDisplay.clip(command))
                #expect(shown.count <= StatusDisplay.maxLength)
            }
        }
        // At the limit it is still copyable, and what is shown is what is copied, unclipped.
        let long = "k3sm " + String(repeating: "x", count: AlertCommand.maxBytes - 5)
        #expect(long.utf8.count == AlertCommand.maxBytes)
        let step = IssueStep.of(StatusFixStep(step: "s", command: long, needsAdmin: true, confirm: true), number: 2)
        #expect(step.copy == long && step.command == long)
        #expect(step.needsAdmin && step.confirm)
    }

    @Test("only a plain page reference links to the guide; a URL, a path or a scheme gives no link")
    func docsLink() {
        #expect(AlertDocs.url("troubleshooting.md#checks-that-need-sudo")?.absoluteString
            == "https://k3sm.io/docs/troubleshooting/#checks-that-need-sudo")
        #expect(AlertDocs.url("install.md")?.absoluteString == "https://k3sm.io/docs/install/")
        #expect(AlertDocs.siteBase == "https://k3sm.io/docs/")
        let hostile = [
            "https://evil", "https://evil.example/x.md", "../x.md", "javascript:alert(1)", "javascript:x.md",
            "/etc/passwd.md", "x/../y.md", "Troubleshooting.md", "x.md#", "x.md#a#b", "x.md#A", ".md", "x.MD",
            "x.md?q=1", "x.md#a b", "x\u{202E}.md", "file:///x.md", "//evil/x.md", "", "x.markdown",
            String(repeating: "a", count: 300) + ".md",
        ]
        for docs in hostile { #expect(AlertDocs.url(docs) == nil, "\(docs)") }
        let alert = IssueAlert.of(StatusAlert(cause: "c", fix: [StatusFixStep(step: "s")], docs: "https://evil"))
        #expect(alert.docs == nil)
    }

    @Test("a row with no alert keeps its detail and remedy; a missing, malformed or partial alert never fails the report")
    func noAlertFallbackAndLenientDecode() throws {
        let report = try Self.report("""
        {"schemaVersion": 1, "verdict": "degraded", "role": "server", "summary": "s", "future": {"x": 1},
         "rows": [{"name": "old", "state": "down", "severity": "fail", "detail": "an older k3sm", "remedy": "k3sm start"},
                  {"name": "notobject", "state": "down", "severity": "fail", "detail": "d", "alert": "text"},
                  {"name": "nocause", "state": "down", "severity": "fail", "detail": "d", "alert": {"fix": []}},
                  {"name": "partial", "state": "down", "severity": "warn", "detail": "d",
                   "alert": {"cause": "the cause", "newField": [1, 2], "evidence": ["one", 2, null, "three"],
                             "fix": [{"step": "a", "command": "k3sm a", "needsAdmin": false, "confirm": false, "extra": true},
                                     {"command": "no step text"},
                                     {"step": "b", "command": 7},
                                     {"step": "c", "command": ""}],
                             "docs": 5, "since": "not a time"}},
                  {"name": "mistyped", "state": "down", "severity": "warn", "detail": "d",
                   "alert": {"cause": "c", "evidence": "one", "fix": {"step": "x"}}}]}
        """)
        #expect(report.rows.count == 5)
        let issues = ClusterIssues.of(report).groups.flatMap(\.issues)
        let old = try #require(issues.first { $0.name == "old" })
        #expect(old.alert == nil)
        #expect(old.detail == "an older k3sm")
        #expect(old.remedy == [RemedyStep(text: "k3sm start", command: "k3sm start")])
        #expect(report.rows[1].alert == nil)
        #expect(report.rows[2].alert == nil)

        let partial = try #require(report.rows[3].alert)
        #expect(partial.cause == "the cause")
        #expect(partial.evidence == ["one", "three"])
        // A step without text is dropped; a mistyped or empty command is a step done by hand;
        // a missing flag reads as the cautious mark.
        #expect(partial.fix == [
            StatusFixStep(step: "a", command: "k3sm a", needsAdmin: false, confirm: false),
            StatusFixStep(step: "b", command: nil, needsAdmin: true, confirm: true),
            StatusFixStep(step: "c", command: nil, needsAdmin: true, confirm: true),
        ])
        #expect(partial.docs == "" && partial.since == "not a time")
        let shown = IssueAlert.of(partial)
        #expect(shown.since == nil && shown.docs == nil)
        #expect(shown.steps.map(\.number) == [1, 2, 3])

        let mistyped = try #require(report.rows[4].alert)
        #expect(mistyped.evidence.isEmpty && mistyped.fix.isEmpty)
    }

    @Test("alert text is clipped, evidence capped at six, steps at eight, and every shown string is one clean line")
    func alertTextClippedAndCapped() {
        let hostile = "a\u{202E}b\nc\u{200B}d" + String(repeating: "z", count: 400)
        let alert = StatusAlert(
            cause: hostile,
            evidence: (1...20).map { "e\($0)\n\u{2066}" + String(repeating: "x", count: 300) },
            fix: (1...11).map { StatusFixStep(step: "step \($0)\r\u{202D}" + String(repeating: "s", count: 300)) },
            docs: "faq.md")
        let shown = IssueAlert.of(alert)
        #expect(shown.cause == StatusDisplay.clip(hostile))
        #expect(shown.cause.hasPrefix("ab cd"))
        #expect(shown.cause.count == StatusDisplay.maxLength)
        #expect(shown.evidence.count == IssueAlert.maxEvidence)
        #expect(shown.moreEvidence == "and 14 more")
        #expect(shown.evidenceTitle == "Evidence (20)")
        #expect(shown.steps.count == ClusterIssues.maxSteps)
        #expect(shown.moreSteps == "and 3 more")
        for line in shown.evidence + shown.steps.map(\.text) + [shown.cause] {
            #expect(line.count <= StatusDisplay.maxLength)
            #expect(line == StatusDisplay.clip(line))
            #expect(!line.unicodeScalars.contains { $0.properties.generalCategory == .format || $0 == "\n" || $0 == "\r" })
        }
        #expect(shown.steps[0].text.hasPrefix("step 1 "))
    }

    @Test("k3sm alerts -o json decodes into the same rows and alerts")
    func alertsReportDecodes() throws {
        let full = try StatusReport.decode(try fixture("status_json_degraded.json"))
        let rows = full.rows.filter { $0.alert != nil }
        let encodedRows = try String(decoding: JSONSerialization.data(withJSONObject: rawRows("status_json_degraded.json")), as: UTF8.self)
        let report = try AlertsReport.decode(Data("""
        {"schemaVersion": 1, "verdict": "degraded", "role": "server", "summary": "netd: unknown", "node": "my-mac",
         "alerts": \(encodedRows), "version": {"version": "v0.1.7", "kubeVersion": "v1.36.2"},
         "timestamp": "2026-10-01T09:30:00Z", "later": true}
        """.utf8))
        #expect(report.verdict == .degraded && report.role == "server" && report.node == "my-mac")
        #expect(report.alerts == rows)
        #expect(report.release?.text == "v0.1.7")
        #expect(report.timestamp == "2026-10-01T09:30:00Z")
        let empty = try AlertsReport.decode(Data(#"{"schemaVersion": 1, "verdict": "running", "alerts": []}"#.utf8))
        #expect(empty.alerts.isEmpty && empty.node == nil && empty.role == "")
        #expect(throws: StatusDecodeError.unsupportedSchema(2)) {
            try AlertsReport.decode(Data(#"{"schemaVersion": 2, "verdict": "running", "alerts": []}"#.utf8))
        }
        #expect(throws: StatusDecodeError.malformed) { try AlertsReport.decode(Data("not json".utf8)) }
    }

    @Test("a fail or warn row with the needs-admin state word stays a fault; only skip, unknown or no severity makes it needs-admin")
    func needsAdminOnlyWhenNotAFault() {
        func level(_ severity: String) -> IssueLevel? {
            IssueLevel(row: StatusRow(name: "runtimed", state: "needs-admin", detail: "", severity: severity))
        }
        #expect(level("fail") == .failing)
        #expect(level("warn") == .warning)
        #expect(level("grave") == .reported)
        #expect(level("skip") == .needsAdmin)
        #expect(level("unknown") == .needsAdmin)
        #expect(level("") == .needsAdmin)
        let issues = ClusterIssues.of(StatusReport(schemaVersion: 1, verdict: .degraded, role: "server", summary: "", rows: [
            StatusRow(name: "runtimed", state: "needs-admin", detail: "", severity: "fail"),
        ]))
        #expect(issues.groups.map(\.level) == [.failing])
        #expect(issues.headline == "1 check needs attention.")
        #expect(!issues.isClean)
    }

    @Test("a legacy remedy or next line is copyable only under the same predicate as a fix step, and only as a command")
    func legacyRemedyCopyUsesThePredicate() {
        #expect(RemedyStep.of("k3sm kubeconfig --write")?.command == "k3sm kubeconfig --write")
        for line in ["kubectl get p\u{043E}ds -A", "k3sm \u{FF53}tart", "sudo k3sm start \u{00E9}", "k3sm\u{200B} start"] {
            let step = RemedyStep.of(line)
            #expect(step?.command == nil, "\(line)")
            #expect(step?.text == StatusDisplay.clip(line))
            #expect(!AlertCommand.copyable(line))
        }
        // The first-word rule still applies on top: a copyable line that is not a command is text.
        #expect(AlertCommand.copyable("find out why"))
        #expect(RemedyStep.of("find out why")?.command == nil)
        let report = StatusReport(schemaVersion: 1, verdict: .degraded, role: "server", summary: "",
                                  rows: [StatusRow(name: "x", state: "down", detail: "", remedy: "k3sm st\u{0430}rt", severity: "fail")],
                                  next: ["kubectl get p\u{043E}ds"])
        let issues = ClusterIssues.of(report)
        #expect(issues.groups.first?.issues.first?.remedy.map(\.command) == [nil])
        #expect(issues.next.map(\.command) == [nil])
    }

    @Test("an alert with no fix step shows the row's remedy lines under its cause; with steps, or without a remedy, none")
    func emptyFixFallsBackToRemedy() throws {
        let report = try Self.report("""
        {"schemaVersion": 1, "verdict": "degraded", "role": "server", "summary": "s",
         "rows": [{"name": "nofix", "state": "down", "severity": "fail", "detail": "d",
                   "remedy": "k3sm start\\nk3sm status logs server", "alert": {"cause": "the cause", "fix": []}},
                  {"name": "withfix", "state": "down", "severity": "fail", "detail": "d", "remedy": "k3sm start",
                   "alert": {"cause": "c", "fix": [{"step": "s", "command": "k3sm start", "needsAdmin": false, "confirm": false}]}},
                  {"name": "bare", "state": "down", "severity": "fail", "detail": "d", "alert": {"cause": "c"}},
                  {"name": "old", "state": "down", "severity": "fail", "detail": "d", "remedy": "k3sm start"}]}
        """)
        let issues = ClusterIssues.of(report).groups.flatMap(\.issues)
        #expect(issues.map(\.name) == ["nofix", "withfix", "bare", "old"])
        #expect(issues[0].alert?.cause == "the cause")
        #expect(issues[0].alert?.steps.isEmpty == true)
        #expect(issues[0].remedyLines == [RemedyStep(text: "k3sm start", command: "k3sm start"),
                                          RemedyStep(text: "k3sm status logs server", command: "k3sm status logs server")])
        #expect(issues[1].remedyLines.isEmpty)
        #expect(issues[2].remedyLines.isEmpty)
        #expect(issues[3].alert == nil && issues[3].remedyLines == [RemedyStep(text: "k3sm start", command: "k3sm start")])
    }

    @Test("a fix step built in code defaults to the cautious marks, as decoding does")
    func fixStepDefaultsAreCautious() throws {
        let built = StatusFixStep(step: "s", command: "k3sm start")
        #expect(built.needsAdmin && built.confirm)
        let decoded = try JSONDecoder().decode(StatusFixStep.self, from: Data(#"{"step": "s", "command": "k3sm start"}"#.utf8))
        #expect(decoded == built)
    }

    /// The fixture's rows that carry an alert, as JSON objects.
    private func rawRows(_ name: String) throws -> [Any] {
        let object = try JSONSerialization.jsonObject(with: try fixture(name)) as? [String: Any]
        let rows = object?["rows"] as? [[String: Any]] ?? []
        return rows.filter { $0["alert"] != nil }
    }
}
