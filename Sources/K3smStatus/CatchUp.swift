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
/// server runs (`StatusReport.release`), and each other node (`workers`)
/// sorted into the ones the roll moves, the ones behind, and the ones ahead.
///
/// It mirrors k3sm's update controller (`pkg/updatectl`): a node whose
/// kubelet version carries the target's k3sm part (`onTarget`) is skipped
/// and left as it is, every other node is moved; a node whose release is
/// newer than the target (`isDowngrade`) refuses the whole roll unless a
/// downgrade is allowed, which this path never asks for. The server runs
/// the target, so the roll skips it too.
public struct ClusterCatchUp: Equatable, Sendable {
    /// The release text the server's k3sm reports, exactly as printed; nil
    /// when the report carries none.
    public let serverRelease: String?
    /// That text when it is a tagged release the roll can be pinned to; nil
    /// for a developer build.
    public let tag: String?
    /// Other nodes the roll would move: every node not on the server's
    /// release, by name. Empty without a tag.
    public let moves: [String]
    /// Other nodes on an older tagged release than the server's, by name.
    public let behind: [String]
    /// Other nodes on a newer release than the server's, by name: the roll
    /// would refuse to start while any is.
    public let ahead: [String]

    public init(serverRelease: String?, tag: String?, moves: [String], behind: [String], ahead: [String]) {
        self.serverRelease = serverRelease
        self.tag = tag
        self.moves = moves
        self.behind = behind
        self.ahead = ahead
    }

    /// The catch-up a server's report describes; nil on a worker, or when
    /// the report does not say the role or list the other nodes.
    public static func decide(report: StatusReport?) -> ClusterCatchUp? {
        guard let report, NodeRole.detect(in: report) == .server, let workers = report.workers else { return nil }
        let text = report.release?.text
        guard let tag = report.release?.tag, let target = SemanticVersion(tag) else {
            return ClusterCatchUp(serverRelease: text, tag: nil, moves: [], behind: [], ahead: [])
        }
        let metadata = buildMetadata(tag)
        var moves: [String] = [], behind: [String] = [], ahead: [String] = []
        for worker in workers.sorted(by: { $0.name < $1.name }) {
            let part = k3smPart(worker.version)
            if part == nil || part != metadata { moves.append(worker.name) }
            if let release = worker.k3smRelease, !release.isUntagged, release < target { behind.append(worker.name) }
            if let from = fromRelease(worker.version).flatMap(SemanticVersion.init), target < from { ahead.append(worker.name) }
        }
        return ClusterCatchUp(serverRelease: text, tag: tag, moves: moves, behind: behind, ahead: ahead)
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
