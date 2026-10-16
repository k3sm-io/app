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

@Suite("health classifier")
struct HealthClassifierTests {
    static let v017 = SemanticVersion("0.1.7")!
    static let v018 = SemanticVersion("0.1.8")!

    /// The facts of an installed, trusted Mac whose CLI printed `report`.
    static func installed(_ report: StatusReport?, payload: SemanticVersion? = v018, installed: SemanticVersion? = v018) -> HealthFacts {
        HealthFacts(installRootExists: true, cliPresent: true, cliTrust: .trusted, report: report,
                    payloadVersion: payload, installedVersion: installed)
    }

    static func report(_ name: String) -> StatusReport {
        try! StatusReport.decode(try! fixture(name))
    }

    /// A running server report with one row's state replaced.
    static func running(_ row: String, state: String) -> StatusReport {
        let base = report("status_json_running.json")
        let rows = base.rows.map { $0.name == row ? StatusRow(name: $0.name, state: state, detail: $0.detail, severity: "fail") : $0 }
        return StatusReport(schemaVersion: 1, verdict: .degraded, role: base.role, summary: base.summary, rows: rows)
    }

    static let stoppedByUser = report("status_json_stopped-by-user.json").stoppedBy

    static let cases: [(String, HealthFacts, HealthState)] = [
        ("no install root", HealthFacts(installRootExists: false, cliPresent: false, cliTrust: .unchecked, report: nil,
                                        payloadVersion: v018, installedVersion: nil), .notInstalled),
        ("the CLI's own not-installed verdict", installed(report("status_json_not-installed.json"), installed: nil), .notInstalled),
        ("a recorded stop", installed(report("status_json_stopped-by-user.json")), .installedStopped(stoppedByUser)),
        ("both daemons down, no record", installed(report("status_json_stopped-clean.json")), .installedStopped(nil)),
        ("the daemons not loaded", installed(running("server", state: "not-loaded").replacing("netd", state: "not-loaded")), .installedStopped(nil)),
        ("netd up, the node daemon down", installed(running("server", state: "stopped")), .partlyRunning(down: ["io.k3sm.server"])),
        ("the node daemon up, netd down", installed(running("netd", state: "failed")), .partlyRunning(down: ["io.k3sm.netd"])),
        ("a worker waiting for its join is up", installed(report("status_json_agent-waiting.json")), .healthy),
        ("the CLI gone under /Library/k3sm", HealthFacts(installRootExists: true, cliPresent: false, cliTrust: .refused("/Library/k3sm/k3sm does not exist"),
                                                          report: nil, payloadVersion: v018, installedVersion: nil), .cliMissing),
        ("the CLI fails its trust check", HealthFacts(installRootExists: true, cliPresent: true, cliTrust: .refused("/Library/k3sm/k3sm is a symlink"),
                                                       report: nil, payloadVersion: v018, installedVersion: nil), .cliUntrusted("/Library/k3sm/k3sm is a symlink")),
        ("the install behind the payload", installed(report("status_json_running.json"), installed: v017),
         .versionMismatch(payload: v018, installed: v017, relation: .newer)),
        ("the install ahead of the payload", installed(report("status_json_running.json"), payload: v017),
         .versionMismatch(payload: v017, installed: v018, relation: .older)),
        ("a newer CLI's unreadable report", installed(nil, payload: v017), .versionMismatch(payload: v017, installed: v018, relation: .older)),
        ("an unreadable report, same versions", installed(nil), .statusUnreadable),
        ("a stop outranks a mismatch", installed(report("status_json_stopped-clean.json"), installed: v017), .installedStopped(nil)),
        ("running", installed(report("status_json_running.json")), .healthy),
        ("an unknown version is no mismatch", installed(report("status_json_server-with-workers.json"), installed: nil), .healthy),
        ("an unknown phase is still a recorded stop", installed(report("tolerant-unknown-enums.json")),
         .installedStopped(report("tolerant-unknown-enums.json").stoppedBy)),
        ("an unknown daemon word claims nothing", installed(running("server", state: "hibernating")), .healthy),
        ("a report this user cannot read", installed(report("status_json_unknown.json")), .healthy),
    ]

    @Test("every state, from the fixtures and synthetic facts")
    func healthClassifierStates() {
        for (name, facts, want) in Self.cases {
            #expect(HealthClassifier.classify(facts) == want, "\(name)")
        }
        let states = Set(Self.cases.map { "\(HealthClassifier.classify($0.1))".prefix(while: { $0 != "(" }) })
        #expect(states == ["notInstalled", "installedStopped", "partlyRunning", "cliMissing", "cliUntrusted",
                           "statusUnreadable", "versionMismatch", "healthy"])
    }

    @Test("only not installed shows the first run")
    func screenFollowsHealth() {
        for (name, facts, _) in Self.cases {
            let state = HealthClassifier.classify(facts)
            #expect(state.showsFirstRun == (state == .notInstalled), "\(name)")
        }
    }

    @Test("each state's line")
    func lines() {
        #expect(HealthState.healthy.line == nil)
        #expect(HealthState.installedStopped(Self.stoppedByUser).line == "k3sm is stopped (by you).")
        #expect(HealthState.partlyRunning(down: ["io.k3sm.netd"]).line == "k3sm is partly running: io.k3sm.netd is not running.")
        #expect(HealthState.versionMismatch(payload: Self.v018, installed: Self.v017, relation: .newer).line
                == "The installed k3sm (0.1.7) is older than this app's (0.1.8).")
        #expect(HealthState.versionMismatch(payload: Self.v017, installed: Self.v018, relation: .older).line
                == "The installed k3sm (0.1.8) is newer than this app's (0.1.7).")
        #expect(HealthState.installedStopped(nil).statusLine == nil)
        #expect(HealthState.healthy.statusLine == nil)
        #expect(HealthState.cliMissing.statusLine == "k3sm is installed, but /Library/k3sm/k3sm is missing.")
        #expect(HealthState.cliUntrusted("bad\nline").line == "The app will not run the installed k3sm: bad line.")
    }
}

extension StatusReport {
    /// The report with one row's state replaced.
    fileprivate func replacing(_ row: String, state: String) -> StatusReport {
        StatusReport(schemaVersion: schemaVersion, verdict: verdict, role: role, summary: summary,
                     rows: rows.map { $0.name == row ? StatusRow(name: $0.name, state: state, detail: $0.detail) : $0 })
    }
}
