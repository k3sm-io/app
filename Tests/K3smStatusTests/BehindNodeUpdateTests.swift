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

/// A node behind the cluster's release gets Update on the server's app: the
/// one update plan gains the catch-up, the managed roll pinned to the release
/// the server itself runs, which moves only the nodes not on it. The rendered
/// apply script for the behind-worker case is pinned in K3smInstallTests
/// (`BehindNodeUpdateScriptTests`), where the root step lives.
@Suite("an Update for a node behind the cluster's release")
struct BehindNodeUpdateTests {
    static let v016 = SemanticVersion("0.1.6")!
    static let v017 = SemanticVersion("0.1.7")!

    struct Case: CustomTestStringConvertible, Sendable {
        let name: String
        let report: StatusReport
        let nodes: [ClusterNode]
        var progress = UpdateProgress()
        var installed: SemanticVersion? = v017
        var payload: SemanticVersion? = v017
        let plan: UpdatePlan
        /// node-b's row control: nil for none, else (enabled, reason).
        let control: NodeUpdateControl?
        var testDescription: String { name }
    }

    /// A report as `k3sm status -o json` prints it on a server (or, with
    /// `role: "agent"`, a worker): its k3sm's release, its own Node in the
    /// `node` row (`node-a`, with `serverKubelet`; no row when nil), the other
    /// nodes, and an `update` row when given.
    static func report(role: String = "server", release: String? = "v0.1.7", dirty: Bool = false,
                       serverKubelet: String? = "v1.36.2+k3sm.0.1.7",
                       workers: [StatusWorker]? = [StatusWorker(name: "node-b", role: "agent", version: "v1.36.2+k3sm.0.1.6")],
                       update: StatusRow? = nil) -> StatusReport {
        var rows = [StatusRow(name: role, state: "running", detail: "d")]
        if let serverKubelet {
            rows.append(StatusRow(name: "node", state: "ready", detail: "d", wide: ["node": "node-a", "kubelet": serverKubelet]))
        }
        if let update { rows.append(update) }
        return StatusReport(schemaVersion: 1, verdict: .running, role: role, summary: "s", rows: rows,
                            workers: role == "server" ? workers : nil,
                            release: release.map { StatusRelease(text: $0, dirty: dirty) })
    }

    static func node(_ name: String, _ version: String, server: Bool = false) -> ClusterNode {
        ClusterNode(name: name, ready: true, kubeletVersion: version, controlPlane: server)
    }

    static let pair = [node("node-a", "v1.36.2+k3sm.0.1.7", server: true), node("node-b", "v1.36.2+k3sm.0.1.6")]

    /// The `update` row a fresh check that found `latest` prints.
    static func checked(latest: String, state: String) -> StatusRow {
        StatusRow(name: "update", state: state, detail: "k3sm \(latest) is available; behind: node-b (v0.1.6)", wide: ["latest": latest])
    }

    static let enabled = NodeUpdateControl(enabled: true, reason: nil)

    static let cases: [Case] = [
        Case(name: "a server current with a behind worker, no newer release found",
             report: report(), nodes: pair,
             plan: .catchUp(tag: "v0.1.7", nodes: ["node-b"]), control: enabled),
        Case(name: "a server current with a behind worker, the check naming its release",
             report: report(update: checked(latest: "v0.1.7", state: "behind")), nodes: pair,
             plan: .managed(tag: "v0.1.7"), control: enabled),
        Case(name: "a server behind the latest release",
             report: report(workers: [StatusWorker(name: "node-b", role: "agent", version: "v1.36.2+k3sm.0.1.6")],
                            update: checked(latest: "v0.1.8", state: "behind")),
             nodes: pair, plan: .managed(tag: "v0.1.8"), control: enabled),
        Case(name: "a server on a developer build",
             report: report(release: "v0.1.8-0.20261015120000-0123456789ab",
                            update: StatusRow(name: "update", state: "unknown", detail: "the last update check ran 30h0m0s ago",
                                              wide: ["latest": "v0.1.7"])),
             nodes: [node("node-a", "v1.36.2+k3sm.0.1.8-0.20261015120000-0123456789ab", server: true), node("node-b", "v1.36.2+k3sm.0.1.6")],
             installed: nil, plan: .blocked(.serverUntagged),
             control: NodeUpdateControl(enabled: false, reason: UpdateBlock.serverUntaggedText)),
        Case(name: "a server whose binary was built from a modified tree",
             report: report(dirty: true), nodes: pair, plan: .blocked(.serverUntagged),
             control: NodeUpdateControl(enabled: false, reason: UpdateBlock.serverUntaggedText)),
        Case(name: "a roll already running",
             report: report(update: StatusRow(name: "update", state: "rolling", detail: "updating to v0.1.7",
                                              wide: ["target": "v0.1.7", "phase": "Rolling"])),
             nodes: pair, plan: .rolling, control: NodeUpdateControl(enabled: false, reason: UpdatePlan.rollingReason)),
        Case(name: "a roll the app follows",
             report: report(), nodes: pair, progress: UpdateProgress(stage: .rolling(nil)),
             plan: .rolling, control: NodeUpdateControl(enabled: false, reason: UpdatePlan.rollingReason)),
        Case(name: "a node ahead of the server",
             report: report(workers: [StatusWorker(name: "node-b", role: "agent", version: "v1.36.2+k3sm.0.1.6"),
                                      StatusWorker(name: "node-c", role: "agent", version: "v1.36.2+k3sm.0.1.9")]),
             nodes: pair + [node("node-c", "v1.36.2+k3sm.0.1.9")],
             plan: .blocked(.nodesAhead(tag: "v0.1.7", nodes: ["node-c"])),
             control: NodeUpdateControl(enabled: false, reason: "node-c runs a newer release than the server's v0.1.7, "
                 + "and updating to it would move that node back. Update the server first.")),
        Case(name: "a dev-build worker beside a behind one moves too, and the question names it",
             report: report(workers: [StatusWorker(name: "node-b", role: "agent", version: "v1.36.2+k3sm.0.1.6"),
                                      StatusWorker(name: "node-d", role: "agent", version: "v1.36.2+k3sm.0.1.5-dirty")]),
             nodes: pair + [node("node-d", "v1.36.2+k3sm.0.1.5-dirty")],
             plan: .catchUp(tag: "v0.1.7", nodes: ["node-b", "node-d"]), control: enabled),
        Case(name: "the server's own node behind its k3sm, every worker on the release",
             report: report(serverKubelet: "v1.36.2+k3sm.0.1.6",
                            workers: [StatusWorker(name: "node-b", role: "agent", version: "v1.36.2+k3sm.0.1.7")]),
             nodes: [node("node-a", "v1.36.2+k3sm.0.1.6", server: true), node("node-b", "v1.36.2+k3sm.0.1.7")],
             plan: .catchUp(tag: "v0.1.7", nodes: ["node-a"]), control: nil),
        Case(name: "the server's own node behind its k3sm, a worker behind too: the server moves last",
             report: report(serverKubelet: "v1.36.2+k3sm.0.1.6"),
             nodes: [node("node-a", "v1.36.2+k3sm.0.1.6", server: true), node("node-b", "v1.36.2+k3sm.0.1.6")],
             plan: .catchUp(tag: "v0.1.7", nodes: ["node-b", "node-a"]), control: nil),
        Case(name: "the server's own node not reported",
             report: report(serverKubelet: nil), nodes: pair, plan: .blocked(.serverNodeUnknown),
             control: NodeUpdateControl(enabled: false, reason: UpdateBlock.serverNodeUnknownText)),
        Case(name: "the server's own node ahead of its k3sm",
             report: report(serverKubelet: "v1.36.2+k3sm.0.1.8"),
             nodes: [node("node-a", "v1.36.2+k3sm.0.1.8", server: true), node("node-b", "v1.36.2+k3sm.0.1.6")],
             plan: .blocked(.nodesAhead(tag: "v0.1.7", nodes: ["node-a"])),
             control: NodeUpdateControl(enabled: false, reason: "node-a runs a newer release than the server's v0.1.7, "
                 + "and updating to it would move that node back. Update the server first.")),
        Case(name: "a worker's app",
             report: report(role: "agent"), nodes: pair, installed: v016, payload: v016,
             plan: .blocked(.workerBehind), control: nil),
        Case(name: "a worker's app with a newer release in it",
             report: report(role: "agent"), nodes: pair, installed: v016, payload: v017,
             plan: .payload(v017), control: nil),
        Case(name: "a single node",
             report: report(workers: []), nodes: [node("node-a", "v1.36.2+k3sm.0.1.7", server: true)],
             plan: .none, control: nil),
        Case(name: "every node on the server's release, the latest newer but its check stale",
             report: report(workers: [StatusWorker(name: "node-b", role: "agent", version: "v1.36.2+k3sm.0.1.7")],
                            update: StatusRow(name: "update", state: "unknown", detail: "the last update check ran 30h0m0s ago",
                                              wide: ["latest": "v0.1.8"])),
             nodes: [node("node-a", "v1.36.2+k3sm.0.1.7", server: true), node("node-b", "v1.36.2+k3sm.0.1.7")],
             plan: .none, control: NodeUpdateControl(enabled: false, reason: NodeUpdateControl.notOfferedReason)),
    ]

    @Test("a node behind gets Update from the one plan, pinned to the server's release", arguments: cases)
    func behindNodeUpdate(_ c: Case) {
        let facts = UpdatePlanFacts(report: c.report, progress: c.progress, installed: c.installed, payload: c.payload,
                                    nodes: c.nodes, joinTargetReadable: true, developerBuild: false,
                                    refusal: nil, managedRefusal: nil)
        let plan = UpdatePlan.decide(facts)
        #expect(plan == c.plan)
        let versions = NodeVersions.decide(c.nodes, report: c.report)
        let control = c.nodes.first { $0.name == "node-b" }
            .flatMap { NodeUpdateControl.decide($0, versions: versions, report: c.report, plan: plan) }
        #expect(control == c.control)
        // The header's control is the row's whenever node-b is the node behind.
        if c.control != nil, versions.state(of: "node-a") != .behind {
            #expect(NodeUpdateControl.header(c.nodes, versions: versions, report: c.report, plan: plan) == c.control)
        }
        // Every control reads the same plan: enabled exactly when the plan is.
        if let control = c.control { #expect(control.enabled == plan.isEnabled) }
        if case .catchUp(let tag, let nodes) = plan {
            #expect(plan.menuTitle == (nodes.count == 1 ? "Update \(nodes[0]) to \(tag)…" : "Update \(nodes.count) Nodes to \(tag)…"))
            #expect(plan.buttonTitle == "Update" && plan.disabledReason == nil)
            #expect(plan.line == "The update moves \(UpdatePath.names(nodes)) to k3sm \(tag), the release installed on the server; "
                + "nodes already on it stay as they are.")
            #expect(Help.Strip.update(plan) == "Move the nodes behind to the server's k3sm \(tag)")
        }
    }

    @Test("the catch-up is blocked like the managed roll by a developer build of the app and the CLI's trust check")
    func catchUpBlocks() {
        let base = UpdatePlanFacts(report: Self.report(), progress: UpdateProgress(), installed: Self.v017, payload: Self.v017,
                                   nodes: Self.pair, joinTargetReadable: true, developerBuild: true,
                                   refusal: nil, managedRefusal: nil)
        let path = UpdatePath.catchUp(tag: "v0.1.7", nodes: ["node-b"])
        #expect(UpdatePlan.decide(base) == .blocked(.appDeveloperBuild(path)))
        #expect(UpdateBlock.appDeveloperBuild(path).sentence == UpdateBlock.managedDeveloperBuild)
        var trust = base
        trust.developerBuild = false
        trust.managedRefusal = "Untrusted."
        #expect(UpdatePlan.decide(trust) == .blocked(.refused("Untrusted.", path)))
        var busy = base
        busy.developerBuild = false
        busy.refusal = "Another change is running."
        #expect(UpdatePlan.decide(busy) == .blocked(.refused("Another change is running.", path)))
    }

    @Test("the report's own release decodes from version.version, a developer build reads as no tag")
    func serverReleaseDecodes() throws {
        let fixture = try StatusReport.decode(fixture("status_json_server-with-workers.json"))
        #expect(fixture.release == StatusRelease(text: "v0.1.7", dirty: false))
        #expect(fixture.release?.tag == "v0.1.7")
        for text in ["dev", "v0.1.8-0.20261015120000-0123456789ab", "0.1.7 ", "v0.1.7;id", ""] {
            #expect(StatusRelease(text: text).tag == nil, "\(text)")
        }
        #expect(StatusRelease(text: "v0.1.7", dirty: true).tag == nil)
        #expect(StatusRelease(text: "v0.2.0-rc.1").tag == "v0.2.0-rc.1")
        let missing = #"{"schemaVersion":1,"verdict":"running","role":"server","summary":"s","rows":[],"version":"v0.1.7"}"#
        #expect(try StatusReport.decode(Data(missing.utf8)).release == nil)
    }

    @Test("the catch-up mirrors the controller: on-target nodes stay, every other moves, a newer one refuses")
    func catchUpMirrorsController() {
        #expect(ClusterCatchUp.buildMetadata("v0.1.7") == "0.1.7")
        #expect(ClusterCatchUp.buildMetadata("v0.2.0-rc.1+build.5") == "0.2.0-rc.1.build.5")
        #expect(ClusterCatchUp.buildMetadata("v1_2") == "1-2")
        let workers = [
            StatusWorker(name: "on", role: "agent", version: "v1.36.2+k3sm.0.1.7"),
            StatusWorker(name: "old", role: "agent", version: "v1.36.2+k3sm.0.1.6"),
            StatusWorker(name: "none", role: "agent", version: nil),
            StatusWorker(name: "new", role: "agent", version: "v1.36.2+k3sm.0.2.0"),
            StatusWorker(name: "pseudo", role: "agent", version: "v1.36.2+k3sm.0.1.8-0.20261015120000-0123456789ab"),
        ]
        let catchUp = ClusterCatchUp.decide(report: Self.report(workers: workers))
        #expect(catchUp == ClusterCatchUp(serverRelease: "v0.1.7", tag: "v0.1.7", server: "node-a", serverKnown: true,
                                          moves: ["new", "none", "old", "pseudo"], behind: ["old"], ahead: ["new", "pseudo"]))
        #expect(catchUp?.serverMoves == false)
        // The server's own Node is read by its kubelet version, the fact the
        // controller acts on, not by its k3sm's version: behind, it moves, last,
        // after the workers and the other servers.
        let servers = [StatusWorker(name: "srv-b", role: "server", version: "v1.36.2+k3sm.0.1.6"),
                       StatusWorker(name: "wrk-z", role: "agent", version: "v1.36.2+k3sm.0.1.6")]
        let lagging = ClusterCatchUp.decide(report: Self.report(serverKubelet: "v1.36.2+k3sm.0.1.6", workers: servers))
        #expect(lagging?.moves == ["wrk-z", "srv-b", "node-a"] && lagging?.serverMoves == true)
        #expect(lagging?.behind == ["node-a", "srv-b", "wrk-z"])
        // An untagged server Node moves (not on the target) and a newer one refuses.
        #expect(ClusterCatchUp.decide(report: Self.report(serverKubelet: "v1.36.2"))?.ahead == ["node-a"])
        #expect(ClusterCatchUp.decide(report: Self.report(serverKubelet: "v1.36.2+k3sm.0.1.7-dirty"))?.serverMoves == true)
        // Not reported, or named among the workers: not known.
        #expect(ClusterCatchUp.decide(report: Self.report(serverKubelet: nil))?.serverKnown == false)
        #expect(ClusterCatchUp.decide(report: Self.report(workers: [StatusWorker(name: "node-a", role: "agent", version: "v1.36.2+k3sm.0.1.6")]))?
            .serverKnown == false)
        #expect(ClusterCatchUp.decide(report: Self.report(role: "agent")) == nil)
        #expect(ClusterCatchUp.decide(report: Self.report(workers: nil)) == nil)
        #expect(ClusterCatchUp.decide(report: Self.report(release: "dev"))
            == ClusterCatchUp(serverRelease: "dev", tag: nil, server: "node-a", serverKnown: true, moves: [], behind: [], ahead: []))
    }

    @Test("names are clipped, joined and counted")
    func names() {
        #expect(UpdatePath.names(["a"]) == "a")
        #expect(UpdatePath.names(["a", "b"]) == "a and b")
        #expect(UpdatePath.names(["a", "b", "c"]) == "a, b and c")
        #expect(UpdatePath.names(["a", "b", "c", "d", "e", "f", "g"]) == "a, b, c, d, e and 2 more")
        #expect(UpdatePath.names(["x\u{202E}y\nz"]) == "xy z")
    }
}
