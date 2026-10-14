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

/// A CLI newer than the app may print verdict, role, state, actor and phase
/// words the app has never seen, and fields it does not know. None of them
/// may fail the report, and each lands on a defined fallback.
@Suite("tolerant enums")
struct TolerantEnumTests {
    @Test("a report full of unknown enum values decodes")
    func unknownEnumFixture() throws {
        let report = try StatusReport.decode(try fixture("tolerant-unknown-enums.json"))
        #expect(report.verdict == .unrecognized("hibernating"))
        #expect(report.verdict.word == "hibernating")
        #expect(report.role == "witness")
        #expect(NodeRole(rawValue: report.role) == nil)
        // The role word is unknown, so the role falls back to the node row.
        #expect(NodeRole.detect(in: report) == .server)
        #expect(report.rows.map(\.state) == ["paused", "draining", "entangled"])
        #expect(!report.nodeDaemonRunning)
        #expect(report.stoppedBy == StoppedBy(actor: "scheduler", reason: "nightly window", at: "2027-01-01T00:00:00Z", phase: "mothballed"))
        #expect(report.workers == [StatusWorker(name: "node-c", role: "witness", version: "v1.38.0+k3sm.0.9.0")])
        #expect(report.joinTarget == "studio.local:9345")
    }

    @Test("unknown words land on defined fallbacks")
    func fallbacks() throws {
        let report = try StatusReport.decode(try fixture("tolerant-unknown-enums.json"))
        #expect(LifecycleState(report: report) == .stopped)
        #expect(StoppedNotice.title(loginLaunch: true, report: report) == "k3sm is stopped")
        #expect(Reading.classify(exitCode: 6, stdout: try fixture("tolerant-unknown-enums.json")) == .notRunning)
    }

    @Test("an unknown verdict with a running node row still reads running")
    func unknownVerdictRunning() throws {
        let json = Data(#"{"schemaVersion":1,"verdict":"thriving","role":"agent","summary":"s","rows":[{"name":"agent","state":"running","detail":"d","severity":"brand-new"}]}"#.utf8)
        let report = try StatusReport.decode(json)
        #expect(report.verdict == .unrecognized("thriving"))
        #expect(LifecycleState(report: report) == .running)
    }
}

@Suite("lifecycle state")
struct LifecycleStateTests {
    @Test("from the vendored fixtures", arguments: [
        ("status_json_running.json", LifecycleState.running),
        ("status_daemons_json_running.json", .running),
        ("status_json_stopped-by-user.json", .stopped),
        ("status_daemons_json_stopped-clean.json", .stopped),
        ("status_daemons_json_degraded.json", .stopped),
        ("status_daemons_json_not-installed.json", .notInstalled),
        ("status_json_server-with-workers.json", .running),
    ])
    func fixtures(_ file: String, _ want: LifecycleState) throws {
        #expect(LifecycleState(report: try StatusReport.decode(try fixture(file))) == want)
    }

    @Test("no report is unreadable")
    func unreadable() {
        #expect(LifecycleState(report: nil) == .unreadable)
    }
}

@Suite("stopped notice")
struct StoppedNoticeTests {
    @Test("a login launch on a Mac you stopped")
    func byYou() throws {
        let report = try StatusReport.decode(try fixture("status_daemons_json_stopped-by-user.json"))
        #expect(StoppedNotice.title(loginLaunch: true, report: report) == "k3sm is stopped (by you)")
        #expect(StoppedNotice.title(loginLaunch: true, report: try StatusReport.decode(try fixture("status_json_stopped-by-user.json")))
            == "k3sm is stopped (by you)")
    }

    @Test("no notice unless a login launch finds a recorded stop", arguments: [
        ("status_daemons_json_stopped-by-user.json", false),
        ("status_daemons_json_stopped-clean.json", true),
        ("status_daemons_json_running.json", true),
        ("status_daemons_json_not-installed.json", true),
    ])
    func none(_ file: String, _ loginLaunch: Bool) throws {
        #expect(StoppedNotice.title(loginLaunch: loginLaunch, report: try StatusReport.decode(try fixture(file))) == nil)
        #expect(StoppedNotice.title(loginLaunch: loginLaunch, report: nil) == nil)
    }

    @Test("the title names who stopped k3sm", arguments: [
        (StoppedBy(actor: "user", reason: "maintenance", at: "", phase: "stopped"), "k3sm is stopped (by you)"),
        (StoppedBy(actor: "auto", reason: "Cafe Wi-Fi", at: "", phase: "stopped"), "k3sm is stopped (auto on Cafe Wi-Fi)"),
        (StoppedBy(actor: "auto", reason: "  ", at: "", phase: "stopped"), "k3sm is stopped (auto)"),
        (StoppedBy(actor: "user", reason: "", at: "", phase: "stopping"), "k3sm is partly stopped (by you)"),
        (StoppedBy(actor: "robot", reason: "x", at: "", phase: "stopped"), "k3sm is stopped"),
        (StoppedBy(actor: "", reason: "", at: "", phase: ""), "k3sm is stopped"),
        (StoppedBy(actor: "auto", reason: "net\nwork", at: "", phase: "stopped"), "k3sm is stopped (auto on net work)"),
    ])
    func title(_ sb: StoppedBy, _ want: String) {
        #expect(StoppedNotice.title(for: sb) == want)
    }

    @Test("a long network name is clipped")
    func clipped() {
        let title = StoppedNotice.title(for: StoppedBy(actor: "auto", reason: String(repeating: "n", count: 400), at: "", phase: "stopped"))
        #expect(title.count < 200)
        #expect(title.hasSuffix("…)"))
    }
}

@Suite("log paths")
struct LogPathTests {
    @Test("fixed paths by role")
    func paths() {
        #expect(K3smLogs.paths(for: .server) == ["/var/log/k3sm/server.log", "/var/log/k3sm/netd.log", "/Library/Logs/k3sm/copy-out.log"])
        #expect(K3smLogs.paths(for: .agent) == ["/var/log/k3sm/agent.log", "/var/log/k3sm/netd.log", "/Library/Logs/k3sm/copy-out.log"])
        #expect(K3smLogs.paths(for: nil).count == 4)
        #expect(K3smLogs.paths(for: nil).allSatisfy { $0.hasPrefix("/var/log/k3sm/") || $0.hasPrefix("/Library/Logs/k3sm/") })
    }
}
