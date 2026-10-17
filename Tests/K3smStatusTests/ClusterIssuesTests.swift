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

    @Test("the running fixture is clean: its unknown and skipped checks are not listed")
    func runningFixtureIsClean() throws {
        let issues = ClusterIssues.of(try StatusReport.decode(try fixture("status_json_running.json")))
        #expect(issues.isClean)
        #expect(issues.headline == ClusterIssues.cleanText)
        #expect(issues.groups.isEmpty)
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

    @Test("the degraded fixture lists only its two warnings")
    func degradedFixture() throws {
        let issues = ClusterIssues.of(try StatusReport.decode(try fixture("status_json_degraded.json")))
        #expect(issues.headline == "2 checks need attention.")
        #expect(!issues.rests(withCard: false))
        #expect(issues.groups.map(\.level) == [.warning])
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

    @Test("groups run failing, needs attention, reported, whatever the report's order; the stopped fixture lists only its failing rows")
    func groupingOrder() throws {
        let issues = ClusterIssues.of(try StatusReport.decode(try fixture("status_json_stopped-by-user.json")))
        #expect(issues.groups.map(\.level) == [.failing])
        #expect(issues.groups[0].issues.map(\.name) == ["netd", "server", "apiserver"])
        #expect(issues.groups[0].issues[1].remedy.count == 2)
        #expect(IssueLevel.allCases.sorted() == [.failing, .warning, .reported])

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

    @Test("a skipped, unknown or unmarked row is not listed and is not a fault")
    func skippedAndUnknownAreNotListed() {
        let rows = [
            StatusRow(name: "datastore", state: "skip", detail: "no state.db yet", severity: "skip"),
            StatusRow(name: "runtimed", state: "needs-admin", detail: "", severity: "skip"),
            StatusRow(name: "update", state: "unknown", detail: "", severity: "unknown"),
            StatusRow(name: "node", state: "down", detail: "an older k3sm printed no severity", severity: ""),
        ]
        let issues = ClusterIssues.of(StatusReport(schemaVersion: 1, verdict: .running, role: "server", summary: "", rows: rows))
        #expect(issues.groups.isEmpty)
        #expect(issues.isClean)
        #expect(issues.headline == ClusterIssues.cleanText)
        for row in rows { #expect(IssueLevel(row: row) == nil, "\(row.name)") }
        #expect(IssueLevel(row: StatusRow(name: "x", state: "x", detail: "", severity: "grave")) == .reported)
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

    @Test("before any report the tab says it has none; a verdict that is not running with no listed row is never clean")
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
        // Nothing is listed, but an unknown verdict is not healthy: no field.
        #expect(issues.groups.isEmpty)
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
}
