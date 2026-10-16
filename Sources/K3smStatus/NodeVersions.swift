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

/// NodeVersionState is how one node's k3sm release compares with the
/// cluster's target version (`NodeVersionTarget`), in the same semver order
/// as the CLI's update row: build metadata ignored, a release above its
/// pre-releases.
public enum NodeVersionState: Equatable, Sendable {
    /// The node runs the target release.
    case current
    /// The node runs an older release than the target.
    case behind
    /// The node runs a newer release than the target (a build from a tag
    /// not yet published as a release).
    case ahead
    /// A managed update is updating this node now.
    case rolling
    /// The node reports no tagged k3sm release (a dev build, a Go
    /// pseudo-version, a build from a modified tree, no version at all), or
    /// there is no target to compare it with.
    case unknown

    /// The state in plain words, as the Version column shows it.
    public var word: String {
        switch self {
        case .current: return "current"
        case .behind: return "behind"
        case .ahead: return "ahead"
        case .rolling: return "updating"
        case .unknown: return "unknown"
        }
    }
}

/// NodeVersionTarget is the release the cluster's nodes are compared with,
/// and where it comes from.
public struct NodeVersionTarget: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        /// The release a managed update in progress moves the cluster to
        /// (the `update` row's `wide.target` while it is `rolling`).
        case roll
        /// The latest release the server's last update check found (the
        /// `update` row's `wide.latest`, else the tag its detail names).
        case latest
        /// No update check is known (a worker's report has no `update` row):
        /// the newest release a control-plane node runs.
        case server
    }

    public let version: SemanticVersion
    public let source: Source

    public init(version: SemanticVersion, source: Source) {
        self.version = version
        self.source = source
    }
}

/// NodeVersions decides the Nodes tab's version view: the cluster's target,
/// the latest release when the report knows it, each node's state against
/// the target, the header's summary line and the inspector's line. The app
/// asks no one on the network: the latest release is only what the server's
/// update check recorded in the `update` row.
public struct NodeVersions: Equatable, Sendable {
    public let target: NodeVersionTarget?
    /// The latest release from the `update` row, nil when the row does not
    /// name one (no check yet, a worker, or a roll in progress).
    public let latest: SemanticVersion?
    /// Each listed node's state, by node name.
    public let states: [String: NodeVersionState]
    /// How many of the listed nodes there are.
    public let count: Int

    /// Decides every node's state from the node list and this Mac's report.
    public static func decide(_ nodes: [ClusterNode], report: StatusReport?) -> NodeVersions {
        let row = report?.row(named: "update")
        let roll = row.flatMap(rollTarget)
        let latest = row.flatMap { $0.rowState == .rolling ? nil : UpdateOffer.latestTag(in: $0) }.flatMap(SemanticVersion.init)
        let target: NodeVersionTarget?
        if let roll {
            target = NodeVersionTarget(version: roll, source: .roll)
        } else if let latest {
            target = NodeVersionTarget(version: latest, source: .latest)
        } else if let server = nodes.filter(\.controlPlane).compactMap(tagged).max() {
            target = NodeVersionTarget(version: server, source: .server)
        } else {
            target = nil
        }
        let updating = row.flatMap(rollingNode)
        var states: [String: NodeVersionState] = [:]
        for node in nodes {
            states[node.name] = state(release: tagged(node), target: target?.version,
                                      updating: roll != nil && node.name == updating)
        }
        return NodeVersions(target: target, latest: latest, states: states, count: nodes.count)
    }

    /// One node's state: rolling while the update works on it; unknown with
    /// no tagged release or no target; else the release against the target.
    static func state(release: SemanticVersion?, target: SemanticVersion?, updating: Bool) -> NodeVersionState {
        if updating { return .rolling }
        guard let release, let target else { return .unknown }
        if release < target { return .behind }
        if target < release { return .ahead }
        return .current
    }

    /// A node's k3sm release when it is a tagged release; nil for a dev
    /// build, a Go pseudo-version or a build from a modified tree, which
    /// the CLI's update row also reports as unknown.
    public static func tagged(_ node: ClusterNode) -> SemanticVersion? {
        guard let release = node.k3smRelease, !release.isUntagged else { return nil }
        return release
    }

    /// The release a `rolling` update row moves to, nil when the row is not
    /// rolling, the roll has ended, or `wide.target` is not a release tag.
    static func rollTarget(_ row: StatusRow) -> SemanticVersion? {
        guard row.rowState == .rolling, !UpdatePhase(word: row.wide["phase"] ?? "").isFinished,
              let tag = row.wide["target"], UpdateOffer.valid(tag) else { return nil }
        return SemanticVersion(tag)
    }

    /// The node a rolling update works on now (`wide.node`), nil when none
    /// has started or its step (`wide.node-phase`) is an end phase.
    static func rollingNode(_ row: StatusRow) -> String? {
        guard let node = row.wide["node"], !node.isEmpty,
              !UpdatePhase(word: row.wide["node-phase"] ?? "").isFinished else { return nil }
        return node
    }

    /// One node's state; unknown for a node the list did not carry.
    public func state(of node: String) -> NodeVersionState {
        states[node] ?? .unknown
    }

    /// The Version column's text: "0.1.7 · behind", the state alone when the
    /// node reports no version, "" for a node the list did not carry.
    public func columnText(_ node: ClusterNode) -> String {
        guard states[node.name] != nil else { return "" }
        let version = NodesList.versionText(node)
        let word = state(of: node.name).word
        return version.isEmpty ? word : StatusDisplay.clip(version + " · " + word)
    }

    /// The header's summary line: "Updating to 0.1.8 · 1 of 3 nodes on it"
    /// during a roll; "2 nodes on 0.1.8" when every node is current; else
    /// the nodes behind, ahead and unknown against the target ("1 node
    /// behind 0.1.8 · 1 with no tagged release"); nil with no node.
    public var summary: String? {
        guard count > 0 else { return nil }
        let counts = Dictionary(grouping: states.values, by: { $0 }).mapValues(\.count)
        func n(_ s: NodeVersionState) -> Int { counts[s] ?? 0 }
        guard let target else {
            return "No node reports a tagged k3sm release"
        }
        let tag = target.version.description
        if target.source == .roll {
            return "Updating to \(tag) · \(n(.current)) of \(Self.nodes(count)) on it"
        }
        if n(.current) == count { return "\(Self.nodes(count)) on \(tag)" }
        var parts: [String] = []
        if n(.behind) > 0 { parts.append("\(Self.nodes(n(.behind))) behind \(tag)") }
        if n(.ahead) > 0 { parts.append("\(Self.nodes(n(.ahead))) ahead of \(tag)") }
        if n(.unknown) > 0 { parts.append("\(Self.nodes(n(.unknown))) with no tagged release") }
        if n(.current) > 0 { parts.append("\(n(.current)) on it") }
        return parts.joined(separator: " · ")
    }

    /// The inspector's version fact: the state with both versions, "behind:
    /// runs 0.1.7, cluster target 0.1.8 (latest release)".
    public func inspectorText(_ node: ClusterNode) -> String {
        let runs = Self.tagged(node).map { "runs " + $0.description }
            ?? node.k3smRelease.map { "runs " + $0.description + ", not a tagged release" }
            ?? "no k3sm release reported"
        let state = state(of: node.name)
        guard let target else { return StatusDisplay.clip("\(state.word): \(runs); no target to compare with") }
        let source: String
        switch target.source {
        case .roll: source = "the update in progress"
        case .latest: source = "latest release"
        case .server: source = "the server's release"
        }
        return StatusDisplay.clip("\(state.word): \(runs), cluster target \(target.version) (\(source))")
    }

    /// The inspector's latest-release fact: the tag, or "not reported".
    public var latestText: String {
        latest?.description ?? "not reported"
    }

    /// "1 node", "3 nodes".
    static func nodes(_ n: Int) -> String {
        n == 1 ? "1 node" : "\(n) nodes"
    }
}

extension SemanticVersion {
    /// Whether the version is not a tagged release although it parses: a Go
    /// pseudo-version (a pre-release ending `<14 digits>-<12 hex>`, the
    /// build of an untagged commit) or a build from a modified tree (whose
    /// kubelet version carries a `dirty` identifier). The CLI's update row
    /// reports both as unknown, and so does the app.
    var isUntagged: Bool {
        prerelease.contains { $0 == "dirty" || Self.isPseudoIdentifier($0) }
    }

    /// `20261015120000-0123456789ab`: fourteen digits, a dash, twelve hex.
    static func isPseudoIdentifier(_ s: String) -> Bool {
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 14, parts[1].count == 12 else { return false }
        return parts[0].allSatisfy(\.isASCIIDigit) && parts[1].allSatisfy { $0.isASCIIDigit || ("a"..."f").contains($0) }
    }
}
