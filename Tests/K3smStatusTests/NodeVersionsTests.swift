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

/// Each node's k3sm release against the cluster's target: the target from
/// the `update` row (a roll's, else the latest release) or the server's own
/// release, the per-node state, the summary line and the inspector's text.
@Suite("per-node versions on the Nodes tab")
struct NodeVersionsTests {
    /// mac-a (control plane) 0.1.8, mac-b 0.1.7, mac-c a dev build's
    /// pseudo-version of 0.1.9, mac-d 0.1.9, mac-e no k3sm release, mac-f
    /// "dev", mac-g a dirty 0.1.8.
    static func nodes() throws -> [ClusterNode] {
        try Nodes.decode(try fixture("kubectl_nodes_versions.json"))
    }

    static func report(_ rows: [StatusRow]) -> StatusReport {
        StatusReport(schemaVersion: 1, verdict: .running, role: "server", summary: "7/7 nodes ready", rows: rows)
    }

    static let behind = StatusRow(name: "update", state: "behind",
                                  detail: "k3sm v0.1.8 is available; behind: mac-b (v1.36.2+k3sm.0.1.7)",
                                  remedy: "curl -fsSL https://k3sm.io/install.sh | sh", wide: ["latest": "v0.1.8"])
    static func rolling(node: String = "mac-b", nodePhase: String = "Updating", phase: String = "Rolling",
                        target: String = "v0.1.8") -> StatusRow {
        StatusRow(name: "update", state: "rolling", detail: "updating the cluster to k3sm \(target): \(phase)",
                  wide: ["target": target, "phase": phase, "node": node, "node-phase": nodePhase])
    }

    struct Case: CustomTestStringConvertible, Sendable {
        let name: String
        let report: StatusReport?
        let only: [String]?
        let target: NodeVersionTarget?
        let latest: String?
        let states: [String: NodeVersionState]
        let summary: String?
        var testDescription: String { name }
    }

    static func release(_ s: String) -> SemanticVersion { SemanticVersion(s)! }
    static let latestStates: [String: NodeVersionState] = [
        "mac-a": .current, "mac-b": .behind, "mac-c": .ahead, "mac-d": .ahead,
        "mac-e": .unknown, "mac-f": .unknown, "mac-g": .unknown,
    ]

    static let cases: [Case] = [
        Case(name: "a behind row: compared with the latest release", report: report([behind]), only: nil,
             target: NodeVersionTarget(version: release("0.1.8"), source: .latest), latest: "0.1.8", states: latestStates,
             summary: "1 node behind 0.1.8 · 2 nodes ahead of 0.1.8 · 3 nodes with no tagged release · 1 on it"),
        Case(name: "the latest tag from the detail when the row carries no wide.latest",
             report: report([StatusRow(name: "update", state: "behind", detail: "k3sm v0.1.9 is available; behind: mac-a")]),
             only: ["mac-a", "mac-d"], target: NodeVersionTarget(version: release("0.1.9"), source: .latest), latest: "0.1.9",
             states: ["mac-a": .behind, "mac-d": .current], summary: "1 node behind 0.1.9 · 1 on it"),
        Case(name: "a node mid-roll is updating; the others against the roll's target",
             report: report([rolling()]), only: nil,
             target: NodeVersionTarget(version: release("0.1.8"), source: .roll), latest: nil,
             states: latestStates.merging(["mac-b": .rolling]) { $1 }, summary: "Updating to 0.1.8 · 1 of 7 nodes on it"),
        Case(name: "a node whose roll step ended is compared, not updating",
             report: report([rolling(nodePhase: "Succeeded")]), only: ["mac-a", "mac-b"],
             target: NodeVersionTarget(version: release("0.1.8"), source: .roll), latest: nil,
             states: ["mac-a": .current, "mac-b": .behind], summary: "Updating to 0.1.8 · 1 of 2 nodes on it"),
        Case(name: "an ended roll falls back to the server's release",
             report: report([rolling(phase: "Succeeded", target: "v0.1.9")]), only: ["mac-a", "mac-b"],
             target: NodeVersionTarget(version: release("0.1.8"), source: .server), latest: nil,
             states: ["mac-a": .current, "mac-b": .behind], summary: "1 node behind 0.1.8 · 1 on it"),
        Case(name: "a roll target that is not a release tag is ignored",
             report: report([rolling(target: "v0.1.8;x")]), only: ["mac-a", "mac-b"],
             target: NodeVersionTarget(version: release("0.1.8"), source: .server), latest: nil,
             states: ["mac-a": .current, "mac-b": .behind], summary: "1 node behind 0.1.8 · 1 on it"),
        Case(name: "no update row (a worker's report): the control plane's release", report: nil, only: nil,
             target: NodeVersionTarget(version: release("0.1.8"), source: .server), latest: nil, states: latestStates,
             summary: "1 node behind 0.1.8 · 2 nodes ahead of 0.1.8 · 3 nodes with no tagged release · 1 on it"),
        Case(name: "an untagged build reads behind the release it precedes",
             report: report([StatusRow(name: "update", state: "behind", detail: "k3sm v0.1.9 is available")]),
             only: ["mac-c", "mac-d", "mac-f"], target: NodeVersionTarget(version: release("0.1.9"), source: .latest), latest: "0.1.9",
             states: ["mac-c": .behind, "mac-d": .current, "mac-f": .unknown],
             summary: "1 node behind 0.1.9 · 1 node with no tagged release · 1 on it"),
        Case(name: "an untagged build reads ahead of the release before it",
             report: report([behind]), only: ["mac-a", "mac-c", "mac-g"],
             target: NodeVersionTarget(version: release("0.1.8"), source: .latest), latest: "0.1.8",
             states: ["mac-a": .current, "mac-c": .ahead, "mac-g": .unknown],
             summary: "1 node ahead of 0.1.8 · 1 node with no tagged release · 1 on it"),
        Case(name: "every node current", report: report([behind]), only: ["mac-a"],
             target: NodeVersionTarget(version: release("0.1.8"), source: .latest), latest: "0.1.8",
             states: ["mac-a": .current], summary: "1 node on 0.1.8"),
        Case(name: "no tagged release anywhere: no target, every node unknown", report: nil, only: ["mac-c", "mac-f"],
             target: nil, latest: nil, states: ["mac-c": .unknown, "mac-f": .unknown],
             summary: "No node reports a tagged k3sm release"),
        Case(name: "no node: no summary", report: report([behind]), only: [],
             target: NodeVersionTarget(version: release("0.1.8"), source: .latest), latest: "0.1.8", states: [:], summary: nil),
    ]

    @Test("each node's state against the cluster's target", arguments: cases)
    func nodeVersionStates(_ c: Case) throws {
        let all = try Self.nodes()
        let nodes = c.only.map { names in all.filter { names.contains($0.name) } } ?? all
        let versions = NodeVersions.decide(nodes, report: c.report)
        #expect(versions.target == c.target)
        #expect(versions.latest?.description == c.latest)
        #expect(versions.states == c.states)
        #expect(versions.summary == c.summary)
        #expect(versions.state(of: "not-listed") == .unknown)
    }

    @Test("a pseudo-version and a dirty build are not tagged releases; a release and a pre-release are")
    func untagged() throws {
        #expect(SemanticVersion("0.1.9-0.20261015120000-0123456789ab")!.isUntagged)
        #expect(SemanticVersion("0.0.0-20261015120000-0123456789ab")!.isUntagged)
        #expect(SemanticVersion("0.1.9-rc.1.0.20261015120000-0123456789ab")!.isUntagged)
        #expect(SemanticVersion("0.1.8-0.20261015120000-0123456789ab.dirty")!.isUntagged)
        #expect(!SemanticVersion("0.1.8")!.isUntagged)
        #expect(!SemanticVersion("0.2.0-rc.1")!.isUntagged)
        #expect(!SemanticVersion("0.2.0-20261015120000-0123456789AB")!.isUntagged)
        // a pseudo-version ranks between the release before it and the one it precedes; a dirty build is not ranked.
        let pseudo = SemanticVersion("0.1.8-0.20261024120000-0123456789ab")!
        #expect(pseudo.isRankable && SemanticVersion("0.1.7")! < pseudo && pseudo < SemanticVersion("0.1.8")!)
        #expect(SemanticVersion("0.1.8-rc.1")! < SemanticVersion("0.1.8-rc.1.0.20261024120000-0123456789ab")!)
        #expect(!SemanticVersion("0.1.8-0.20261015120000-0123456789ab.dirty")!.isRankable)
        #expect(NodeVersions.state(release: pseudo, target: SemanticVersion("0.1.7"), updating: false) == .ahead)
        #expect(NodeVersions.state(release: pseudo, target: SemanticVersion("0.1.8"), updating: false) == .behind)
    }

    @Test("the Version column and the inspector show the state in words with both versions")
    func columnAndInspector() throws {
        let nodes = try Self.nodes()
        let versions = NodeVersions.decide(nodes, report: Self.report([Self.behind]))
        func node(_ name: String) throws -> ClusterNode { try #require(nodes.first { $0.name == name }) }
        #expect(versions.columnText(try node("mac-b")) == "0.1.7 · behind")
        #expect(versions.columnText(try node("mac-e")) == "v1.36.2 · unknown")
        #expect(versions.columnText(ClusterNode(name: "other", ready: true)) == "")
        #expect(versions.inspectorText(try node("mac-b")) == "behind: runs 0.1.7, cluster target 0.1.8 (latest release)")
        #expect(versions.inspectorText(try node("mac-c"))
            == "ahead: runs 0.1.9-0.20261015120000-0123456789ab, not a tagged release, cluster target 0.1.8 (latest release)")
        #expect(versions.columnText(try node("mac-c")) == "0.1.9-0.20261015120000-0123456789ab · ahead, untagged")
        #expect(versions.columnText(try node("mac-d")) == "0.1.9 · ahead")
        #expect(versions.inspectorText(try node("mac-f")) == "unknown: no k3sm release reported, cluster target 0.1.8 (latest release)")
        #expect(versions.latestText == "0.1.8")

        let roll = NodeVersions.decide(nodes, report: Self.report([Self.rolling()]))
        #expect(roll.columnText(try node("mac-b")) == "0.1.7 · updating")
        #expect(roll.inspectorText(try node("mac-b")) == "updating: runs 0.1.7, cluster target 0.1.8 (the update in progress)")
        #expect(roll.latestText == "not reported")

        let none = NodeVersions.decide([try node("mac-f")], report: nil)
        #expect(none.inspectorText(try node("mac-f")) == "unknown: no k3sm release reported; no target to compare with")

        let rows = NodesList.rows(nodes, report: Self.report([Self.behind]), metrics: MetricsState())
        #expect(rows.map(\.versionState) == [.current, .behind, .ahead, .ahead, .unknown, .unknown, .unknown])
    }
}
