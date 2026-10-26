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

/// ClusterCatchUp is what a managed update pinned to the server's own
/// release would do, read from a server's status report: the release the
/// server's k3sm reports (`StatusRelease`), the server's own Node (the `node`
/// row's `wide.node` and `wide.kubelet`, from the node list the report read),
/// and each other node (`workers`), sorted into the ones the roll moves, the
/// ones behind, and the ones ahead.
///
/// It mirrors k3sm's update controller (`pkg/updatectl`), and reads every
/// node, the server's own included, by its Node's kubelet version, the fact
/// the controller acts on: a node whose kubelet version carries the target's
/// k3sm part (`onTarget`) is skipped and left as it is, every other node is
/// moved, the server last; a node whose release is newer than the target
/// (`isDowngrade`) refuses the whole roll unless a downgrade is allowed,
/// which this path never asks for. The controller lists the nodes again when
/// the update starts, so this is the set as the report saw it.
public struct ClusterCatchUp: Equatable, Sendable {
    /// The release text the server's k3sm reports, exactly as printed; nil
    /// when the report carries none.
    public let serverRelease: String?
    /// That text when it is a tagged release the roll can be pinned to; nil
    /// for a developer build.
    public let tag: String?
    /// The server's own Node name, from the `node` row; nil when the row
    /// does not name it.
    public let server: String?
    /// Whether the server's own Node and its kubelet version were read; the
    /// sets below do not cover the server when false.
    public let serverKnown: Bool
    /// The nodes the roll would move, in the controller's order: the
    /// workers, then the other servers, by name, then this server when its
    /// Node is not on the release. Empty without a tag.
    public let moves: [String]
    /// The nodes on an older tagged release than the roll's tag (the server's
    /// k3sm, or the target passed to `decide(report:target:)`), by name (this
    /// server's Node included when it is).
    public let behind: [String]
    /// The nodes on a newer release than the roll's tag, by name: the
    /// roll would refuse to start while any is.
    public let ahead: [String]

    public init(serverRelease: String?, tag: String?, server: String?, serverKnown: Bool,
                moves: [String], behind: [String], ahead: [String]) {
        self.serverRelease = serverRelease
        self.tag = tag
        self.server = server
        self.serverKnown = serverKnown
        self.moves = moves
        self.behind = behind
        self.ahead = ahead
    }

    /// Whether this server's own Node is among the nodes the roll moves.
    public var serverMoves: Bool {
        server.map(moves.contains) ?? false
    }

    /// The catch-up a server's report describes; nil on a worker, or when
    /// the report does not say the role or list the other nodes.
    public static func decide(report: StatusReport?) -> ClusterCatchUp? {
        decide(report: report, tag: report?.release?.tag)
    }

    /// The same reading of a server's report for a roll to `target`, a
    /// release tag other than the server's own: the version set this app
    /// carries. The sets are sorted against `target` exactly as the
    /// controller would sort them for an Update to it; nil as above.
    public static func decide(report: StatusReport?, target: String) -> ClusterCatchUp? {
        decide(report: report, tag: target)
    }

    private static func decide(report: StatusReport?, tag: String?) -> ClusterCatchUp? {
        guard let report, NodeRole.detect(in: report) == .server, let workers = report.workers else { return nil }
        let text = report.release?.text
        let nodeRow = report.row(named: "node")
        let serverName = nodeRow?.wide["node"].flatMap { $0.isEmpty ? nil : $0 }
        let serverKubelet = nodeRow?.wide["kubelet"].flatMap { $0.isEmpty ? nil : $0 }
        let serverKnown = serverName != nil && serverKubelet != nil && !workers.contains { $0.name == serverName }
        guard let tag, let target = SemanticVersion(tag) else {
            return ClusterCatchUp(serverRelease: text, tag: nil, server: serverName, serverKnown: serverKnown,
                                  moves: [], behind: [], ahead: [])
        }
        let metadata = buildMetadata(tag)
        let ordered = workers.filter { $0.role != NodeRole.server.rawValue }.sorted { $0.name < $1.name }
            + workers.filter { $0.role == NodeRole.server.rawValue }.sorted { $0.name < $1.name }
        var nodes = ordered.map { (name: $0.name, kubelet: $0.version) }
        if serverKnown, let serverName { nodes.append((name: serverName, kubelet: serverKubelet)) }
        var moves: [String] = [], behind: [String] = [], ahead: [String] = []
        for node in nodes {
            let part = k3smPart(node.kubelet)
            if part == nil || part != metadata { moves.append(node.name) }
            if let release = part.flatMap(SemanticVersion.init), !release.isUntagged, release < target { behind.append(node.name) }
            if let from = fromRelease(node.kubelet).flatMap(SemanticVersion.init), target < from { ahead.append(node.name) }
        }
        return ClusterCatchUp(serverRelease: text, tag: tag, server: serverName, serverKnown: serverKnown,
                              moves: moves, behind: behind.sorted(), ahead: ahead.sorted())
    }
    /// The release the server's own Node runs, from the report's `node`
    /// row: `v` and the k3sm part of its kubelet version (the controller's
    /// `fromRelease`), which names the release of the daemon that runs the
    /// update controller. A release tag reads back as itself (`v0.1.8`,
    /// `v0.1.9-rc.1`); a modified or developer build does not (its `+` became
    /// `.`). Nil when the row, its kubelet version or the `+k3sm.` marker is
    /// missing. The text is untrusted: callers check it as a release tag.
    public static func serverRunning(report: StatusReport?) -> String? {
        let kubelet = report?.row(named: "node")?.wide["kubelet"]
        return k3smPart(kubelet).map { "v" + $0 }
    }

    /// The k3sm part of a kubelet version, after `+k3sm.`, as the
    /// controller's `nodeRelease` reads it; nil with no marker.
    static func k3smPart(_ kubelet: String?) -> String? {
        guard let kubelet, let marker = kubelet.range(of: "+k3sm.") else { return nil }
        return String(kubelet[marker.upperBound...])
    }

    /// The release a node runs as the controller's `fromRelease` reads it:
    /// `v` and the k3sm part, else the kubelet version as printed.
    static func fromRelease(_ kubelet: String?) -> String? {
        if let part = k3smPart(kubelet) { return "v" + part }
        return kubelet
    }

    /// The k3sm part a node on `tag` reports, as the controller's
    /// `buildMetadata` writes it: the leading `v` dropped, `+` turned into
    /// `.`, any other character outside `[0-9A-Za-z.-]` turned into `-`.
    static func buildMetadata(_ tag: String) -> String {
        var s = Substring(tag)
        if s.first == "v" { s = s.dropFirst() }
        return String(s.map { c -> Character in
            if c == "+" { return "." }
            if c.isASCII, c.isLetter || c.isNumber || c == "." || c == "-" { return c }
            return "-"
        })
    }
}
