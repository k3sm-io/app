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

/// Reports built in code, shaped like the CLI's.
enum Reports {
    static func make(role: String = "server", nodeState: String, verdict: String, workers: [StatusWorker]? = [],
                     stoppedBy: StoppedBy? = nil) -> StatusReport {
        StatusReport(
            schemaVersion: 1, verdict: Verdict(word: verdict), role: role, summary: "s",
            rows: [StatusRow(name: role == "agent" ? "agent" : "server", state: nodeState, detail: "d")],
            stoppedBy: stoppedBy, workers: workers)
    }

    static let running = make(nodeState: "running", verdict: "running")
    static let stopped = make(nodeState: "stopped", verdict: "stopped",
                              stoppedBy: StoppedBy(actor: "user", reason: "", at: "", phase: "stopped"))
}

@Suite("lifecycle preconditions")
struct LifecyclePreconditionTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let verb: LifecycleVerb
        let expected: LifecycleState
        let live: LifecycleState
        let proceed: Bool
        let contains: String
        var testDescription: String { "\(verb) \(expected.word) -> \(live.word)" }
    }

    static let cases: [Case] = [
        Case(verb: .stop, expected: .running, live: .running, proceed: true, contains: ""),
        Case(verb: .restart, expected: .running, live: .running, proceed: true, contains: ""),
        Case(verb: .start, expected: .stopped, live: .stopped, proceed: true, contains: ""),
        Case(verb: .stop, expected: .running, live: .stopped, proceed: false, contains: "is stopped now, not running"),
        Case(verb: .start, expected: .stopped, live: .running, proceed: false, contains: "is running now, not stopped"),
        Case(verb: .restart, expected: .running, live: .notInstalled, proceed: false, contains: "not installed now"),
        Case(verb: .stop, expected: .running, live: .unreadable, proceed: false, contains: "could not read the status"),
        Case(verb: .start, expected: .stopped, live: .unreadable, proceed: false, contains: "could not read the status"),
        Case(verb: .stop, expected: .stopped, live: .stopped, proceed: false, contains: "nothing to stop"),
        Case(verb: .start, expected: .running, live: .running, proceed: false, contains: "nothing to start"),
    ]

    @Test("a changed or wrong state refuses", arguments: cases)
    func check(_ c: Case) {
        switch LifecyclePrecondition.check(c.verb, expected: c.expected, live: c.live) {
        case .proceed:
            #expect(c.proceed)
        case .refused(let why):
            #expect(!c.proceed)
            #expect(why.contains(c.contains), "\(why)")
        }
    }
}

@Suite("stop warning")
struct StopWarningTests {
    @Test("a server with joined workers warns and names them")
    func joined() throws {
        let report = Reports.make(nodeState: "running", verdict: "running", workers: [
            StatusWorker(name: "node-a", role: "server"), StatusWorker(name: "node-b", role: "agent"),
        ])
        let text = try #require(StopWarning.text(report))
        #expect(text.hasPrefix("2 other nodes have joined this server (node-a, node-b)."))
        #expect(text.contains("halts the cluster's control plane"))
        #expect(LifecycleConfirmation(verb: .stop, report: report).warning == text)
    }

    @Test("one worker is singular, and a long list is capped")
    func counts() throws {
        let one = Reports.make(nodeState: "running", verdict: "running", workers: [StatusWorker(name: "w", role: "agent")])
        #expect(try #require(StopWarning.text(one)).hasPrefix("1 other node has joined this server (w)."))
        let many = Reports.make(nodeState: "running", verdict: "running",
                                workers: (1...8).map { StatusWorker(name: "w\($0)", role: "agent") })
        #expect(try #require(StopWarning.text(many)).contains("(w1, w2, w3, w4, w5 and 3 more)"))
    }

    @Test("an unknown workers list warns")
    func unknownList() throws {
        let report = Reports.make(nodeState: "running", verdict: "running", workers: nil)
        let text = try #require(StopWarning.text(report))
        #expect(text.contains("cannot tell whether other nodes have joined"))
    }

    @Test("an unknown role warns")
    func unknownRole() {
        let report = StatusReport(schemaVersion: 1, verdict: .running, role: "witness", summary: "s", rows: [], workers: [])
        #expect(StopWarning.text(report) == StopWarning.unknown)
    }

    @Test("a lone server and a worker get no warning")
    func none() {
        #expect(StopWarning.text(Reports.running) == nil)
        let agent = Reports.make(role: "agent", nodeState: "running", verdict: "running", workers: nil)
        #expect(StopWarning.text(agent) == nil)
        let confirm = LifecycleConfirmation(verb: .stop, report: agent)
        #expect(confirm.warning == nil)
        #expect(confirm.message.contains("node-bound volumes stay down"))
    }

    @Test("hostile worker names are clipped and flattened")
    func hostileNames() throws {
        let report = Reports.make(nodeState: "running", verdict: "running",
                                  workers: [StatusWorker(name: "a\nb" + String(repeating: "x", count: 300), role: "agent")])
        let text = try #require(StopWarning.text(report))
        #expect(!text.contains("\n"))
        #expect(text.contains("…"))
    }

    @Test("every confirmation names its verb", arguments: LifecycleVerb.lifecycleVerbs)
    func namesVerb(_ verb: LifecycleVerb) {
        let c = LifecycleConfirmation(verb: verb, report: Reports.running)
        #expect(c.title.lowercased().hasPrefix(verb.rawValue))
        #expect(verb == .stop || c.warning == nil)
    }
}

@Suite("lifecycle outcome")
struct LifecycleOutcomeTests {
    @Test("partial stop codes name what was left", arguments: [
        (Int32(33), ["the node daemon"]),
        (Int32(38), ["pods, vm helpers or control-plane processes", "the mesh"]),
        (Int32(95), LifecycleOutcome.leftoverClasses.map(\.name)),
    ])
    func leftovers(_ status: Int32, _ want: [String]) {
        #expect(LifecycleOutcome.leftovers(exitStatus: status) == want)
        #expect(LifecycleOutcome.text(.failed(exitStatus: status), verb: .stop).contains("Stop it again to finish."))
    }

    @Test("codes outside the partial range are not leftovers", arguments: [Int32(0), 1, 2, 3, 32, 96, 100, 101])
    func notLeftovers(_ status: Int32) {
        #expect(LifecycleOutcome.leftovers(exitStatus: status) == nil)
    }

    @Test("the script's refusals sit outside the CLI's codes")
    func noCollision() {
        for code in [LifecycleExit.refusedBinary, LifecycleExit.signatureRejected] {
            #expect(code > 95)
            #expect(LifecycleOutcome.leftovers(exitStatus: code) == nil)
        }
    }

    @Test("sentences", arguments: [
        (PrivilegedOutcome.cancelled, LifecycleVerb.stop, "Nothing was changed"),
        (.failed(exitStatus: 100), .stop, "is not owned by root"),
        (.failed(exitStatus: 101), .start, "not signed by the k3sm Developer ID"),
        (.failed(exitStatus: 3), .stop, "did not run as root"),
        (.failed(exitStatus: 2), .restart, "did not accept `k3sm restart`"),
        (.failed(exitStatus: 1), .restart, "use Start instead"),
        (.failed(exitStatus: 1), .start, "exit status 1"),
        (.succeeded, .stop, "stays stopped"),
        (.couldNotStart, .start, "could not be shown"),
    ])
    func sentence(_ outcome: PrivilegedOutcome, _ verb: LifecycleVerb, _ contains: String) {
        #expect(LifecycleOutcome.text(outcome, verb: verb).contains(contains))
    }
}

@Suite("installed CLI trust")
struct InstalledCLITrustTests {
    typealias Facts = InstalledCLITrust.PathFacts
    static let dir = Facts(isSymlink: false, isDirectory: true, isRegularFile: false, ownerUID: 0, mode: 0o755)
    static let bin = Facts(isSymlink: false, isDirectory: false, isRegularFile: true, ownerUID: 0, mode: 0o755)

    static func evaluate(_ override: [String: Facts?] = [:], signature: Bool = true) -> InstalledCLITrust {
        InstalledCLITrust.evaluate(
            cliPath: K3smCLI.path,
            facts: { path in
                if let o = override[path] { return o }
                return path == K3smCLI.path ? bin : dir
            },
            linkTarget: { _ in nil },
            signatureValid: { _ in signature })
    }

    @Test("a root-owned, signed install is trusted")
    func trusted() {
        #expect(Self.evaluate() == .trusted)
    }

    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let path: String
        let facts: Facts?
        let contains: String
        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(name: "missing directory", path: "/Library/k3sm", facts: nil, contains: "/Library/k3sm does not exist"),
        Case(name: "symlinked directory", path: "/Library/k3sm",
             facts: Facts(isSymlink: true, isDirectory: false, isRegularFile: false, ownerUID: 0, mode: 0o755), contains: "is a symlink"),
        Case(name: "user-owned directory", path: "/Library/k3sm",
             facts: Facts(isSymlink: false, isDirectory: true, isRegularFile: false, ownerUID: 501, mode: 0o755), contains: "not owned by root"),
        Case(name: "group-writable binary", path: "/Library/k3sm/k3sm",
             facts: Facts(isSymlink: false, isDirectory: false, isRegularFile: true, ownerUID: 0, mode: 0o775), contains: "writable by group"),
        Case(name: "other-writable root", path: "/",
             facts: Facts(isSymlink: false, isDirectory: true, isRegularFile: false, ownerUID: 0, mode: 0o757), contains: "writable by group"),
        Case(name: "symlinked binary", path: "/Library/k3sm/k3sm",
             facts: Facts(isSymlink: true, isDirectory: false, isRegularFile: false, ownerUID: 0, mode: 0o755), contains: "is a symlink"),
        Case(name: "binary is a directory", path: "/Library/k3sm/k3sm", facts: dir, contains: "not a regular file"),
        Case(name: "ancestor is a file", path: "/Library", facts: bin, contains: "not a directory"),
        Case(name: "ACL on the binary", path: "/Library/k3sm/k3sm",
             facts: Facts(isSymlink: false, isDirectory: false, isRegularFile: true, ownerUID: 0, mode: 0o755, hasACL: true),
             contains: "/Library/k3sm/k3sm carries an ACL"),
        Case(name: "ACL on a directory", path: "/Library/k3sm",
             facts: Facts(isSymlink: false, isDirectory: true, isRegularFile: false, ownerUID: 0, mode: 0o755, hasACL: true),
             contains: "/Library/k3sm carries an ACL"),
    ]

    @Test("refusals", arguments: cases)
    func refused(_ c: Case) {
        guard case .refused(let why) = Self.evaluate([c.path: c.facts]) else {
            Issue.record("want refused"); return
        }
        #expect(why.contains(c.contains), "\(why)")
    }

    @Test("a bad signature is refused, and is checked only after the paths")
    func signature() {
        #expect(Self.evaluate(signature: false) == .refused("the installed k3sm is not signed by the k3sm Developer ID"))
        var checked = false
        _ = InstalledCLITrust.evaluate(cliPath: K3smCLI.path, facts: { _ in nil }, linkTarget: { _ in nil },
                                       signatureValid: { _ in checked = true; return true })
        #expect(!checked)
    }
}

@Suite("lifecycle feature detection")
struct LifecycleSupportTests {
    @Test("versions after 0.1.7 have k3sm stop", arguments: [
        ("0.1.8", true), ("0.1.8-rc.1", true), ("0.2.0", true), ("1.0.0", true),
        ("0.1.7", false), ("0.1.7-rc.1", false), ("0.1.6", false), ("0.0.9", false),
    ])
    func versions(_ v: String, _ has: Bool) throws {
        let version = try #require(SemanticVersion(v))
        #expect(LifecycleSupport.versionHasLifecycle(version) == has)
        let got = LifecycleSupport.evaluate(trust: .trusted, version: version)
        #expect((got == .available) == has)
    }

    @Test("an older CLI degrades to the window with a note naming its version")
    func olderNote() {
        guard case .unavailable(let note) = LifecycleSupport.evaluate(trust: .trusted, version: SemanticVersion("0.1.7")) else {
            Issue.record("want unavailable"); return
        }
        #expect(note.contains("(0.1.7) has no stop command"))
    }

    @Test("an unknown version is not support")
    func unknownVersion() {
        guard case .unavailable(let note) = LifecycleSupport.evaluate(trust: .trusted, version: nil) else {
            Issue.record("want unavailable"); return
        }
        #expect(note.contains("sudo k3sm stop"))
    }

    @Test("an untrusted CLI is never support, whatever its version")
    func untrusted() {
        guard case .unavailable(let note) = LifecycleSupport.evaluate(trust: .refused("/Library/k3sm is a symlink"), version: SemanticVersion("9.0.0")) else {
            Issue.record("want unavailable"); return
        }
        #expect(note.contains("/Library/k3sm is a symlink"))
    }
}
