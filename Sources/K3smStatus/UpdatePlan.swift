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

/// UpdatePath is one of the ways k3sm moves to a newer release: the release
/// this app carries, installed over this Mac's k3sm through the checked root
/// step (the app-carried update), the managed roll `k3sm update apply`
/// starts on the server, which moves every node to the latest release, the
/// server last, or the same roll pinned to the release the server itself
/// runs, which moves only the nodes behind it (the catch-up), or the roll to
/// the release this app carries, bound to the digest its signed bundle
/// records (the bundled version set).
public enum UpdatePath: Equatable, Sendable {
    /// Install the app's payload, this release, on this Mac only.
    case payload(SemanticVersion)
    /// Roll the whole cluster to this release tag (`v0.1.9`).
    case managed(tag: String)
    /// Roll the cluster to the server's own release tag; the named nodes
    /// (every node not on it) move, the rest are left as they are.
    case catchUp(tag: String, nodes: [String])
    /// Roll the whole cluster, workers first and this server last, to the
    /// release this app carries (its `K3smPayloadTag`), bound to the archive
    /// digest its sealed `payload.release` records.
    case bundled(tag: String)

    /// The status item's menu title, which names the release.
    public var menuTitle: String {
        switch self {
        case .payload(let version): return "Update This Mac to \(version)…"
        case .managed(let tag): return "Update to \(StatusDisplay.clip(tag))…"
        case .catchUp(let tag, let nodes):
            let who = nodes.count == 1 ? StatusDisplay.clip(nodes[0]) : "\(nodes.count) Nodes"
            return StatusDisplay.clip("Update \(who) to \(tag)…")
        case .bundled(let tag): return StatusDisplay.clip("Update the Cluster to \(tag)…")
        }
    }

    /// One sentence saying what the update does.
    public var sentence: String {
        switch self {
        case .payload(let version):
            return "The update installs k3sm \(version), the release this app carries, on this Mac."
        case .managed(let tag):
            return StatusDisplay.clip("The update moves every node to k3sm \(tag), the server last.")
        case .catchUp(let tag, let nodes):
            return "The update moves \(UpdatePath.names(nodes)) to k3sm \(StatusDisplay.clip(tag)), the release installed on the server; "
                + "nodes already on it stay as they are."
        case .bundled(let tag):
            return StatusDisplay.clip("The update moves every node to k3sm \(tag), the release this app carries. Workers first, this server last.")
        }
    }

    /// The most node names a sentence lists; the rest are counted.
    public static let maxNames = 5

    /// "node-b", "node-b and node-c", "node-b, node-c and 4 more": each
    /// name clipped.
    public static func names(_ nodes: [String], mask: [String: String]? = NodeNameMask.current) -> String {
        let shown = nodes.prefix(maxNames).map { NodeNameMask.shown($0, mask: mask) }
        let more = nodes.count - shown.count
        if more > 0 { return shown.joined(separator: ", ") + " and \(more) more" }
        if shown.count <= 1 { return shown.first ?? "no node" }
        return shown.dropLast().joined(separator: ", ") + " and " + shown[shown.count - 1]
    }
}

/// ManagedUpdateState is the managed update as the plan reads it: a roll in
/// progress, the server's update check naming a newer release, or neither.
public enum ManagedUpdateState: Equatable, Sendable {
    /// No roll runs and the server's check names no newer release (the row
    /// is ok, ahead or unknown, absent, as on a worker, or names the release
    /// a roll just finished).
    case nothingNewer
    /// The server's update check found this newer release (`behind`).
    case behind(tag: String)
    /// A managed update is under way.
    case rolling

    /// The state from the full report's `update` row and the app's progress,
    /// by the managed update's own reading (`UpdateOffer.decide`).
    public init(report: StatusReport?, progress: UpdateProgress) {
        switch UpdateOffer.decide(report: report, progress: progress) {
        case .updating: self = .rolling
        case .available(let tag): self = .behind(tag: tag)
        case .hidden: self = .nothingNewer
        }
    }
}

/// UpdateBlock is why no update can run from the app now, as one sentence.
/// A block on a path (`path`) still names the release a control would run;
/// the others mean there is no update the app could start.
public enum UpdateBlock: Equatable, Sendable {
    /// This build of the app is not Developer ID signed, so it cannot run the
    /// checked root step.
    case appDeveloperBuild(UpdatePath)
    /// The app cannot run the root step now; the app's own sentence.
    case refused(String, UpdatePath)
    /// A worker whose control-plane address could not be read, which the
    /// app-carried update needs.
    case joinTargetUnknown(SemanticVersion)
    /// The report does not say whether this Mac is the server or a worker.
    case roleUnknown
    /// The installed k3sm reports no release (a developer build, or its
    /// version could not be read), so nothing can be compared with it.
    case installedUnknown
    /// The control plane of a cluster with other nodes (or none known): it
    /// updates only by the managed roll, and the server's check has found
    /// no newer release, although this app carries one.
    case controlPlaneWithWorkers(payload: SemanticVersion)
    /// A worker behind the control plane, with no newer release in this app:
    /// the managed update on the server moves it.
    case workerBehind
    /// This app carries an older release than the installed one; the app
    /// never installs an older k3sm over a newer one.
    case downgrade(installed: SemanticVersion, payload: SemanticVersion)
    /// A node is behind, but the server runs a developer build with no
    /// release tag, so there is no release to pin the roll to.
    case serverUntagged
    /// A node is behind, but the report does not name the server's own Node
    /// and its kubelet version, so which nodes the roll moves is not known.
    case serverNodeUnknown
    /// A node is behind the server's release, but these nodes run a newer
    /// one, and the roll to the server's release would move them back.
    case nodesAhead(tag: String, nodes: [String])
    /// The roll to this app's release waits for these nodes, which are not
    /// Ready.
    case bundledNodeNotReady([String])
    /// The node list (each node's Ready condition) could not be read, so the
    /// roll to this app's release cannot tell whether every node is Ready.
    case bundledNodesUnknown
    /// The k3sm installed on this server is at or below the last release
    /// without `update apply --pin-sha256`, so the roll to this app's release
    /// `tag` cannot be bound to its digest; the Terminal command is named.
    case bundledServerCLITooOld(installed: SemanticVersion, tag: String)
    /// The server's node runs a release whose update controller does not
    /// check a release pin, so the roll to `tag` cannot be bound.
    case bundledControllerTooOld(tag: String)
    /// The cluster is more than one minor release (or a major release)
    /// behind the release this app carries; the release to go through first
    /// is named.
    case bundledSkewTooWide(installed: SemanticVersion, set: SemanticVersion)
    /// This app carries a payload tag but no `payload.release`, so it has no
    /// digest to bind the roll to.
    case bundledNoPayloadRecord

    /// The path a disabled control would run once the block clears; nil
    /// when there is no update to run.
    public var path: UpdatePath? {
        switch self {
        case .appDeveloperBuild(let path), .refused(_, let path): return path
        case .joinTargetUnknown(let version): return .payload(version)
        case .roleUnknown, .installedUnknown, .controlPlaneWithWorkers, .workerBehind, .downgrade, .serverUntagged, .serverNodeUnknown, .nodesAhead,
             .bundledNodeNotReady, .bundledNodesUnknown, .bundledServerCLITooOld, .bundledControllerTooOld, .bundledSkewTooWide,
             .bundledNoPayloadRecord:
            return nil
        }
    }

    /// The managed update's sentence for a build that is not Developer ID signed.
    public static let managedDeveloperBuild = UpdateOffer.developerBuildReason
    /// The app-carried update's sentence for a build that is not Developer ID signed.
    public static let payloadDeveloperBuild =
        "This build of k3sm is not Developer ID signed, so it cannot install k3sm. Run the install script in Terminal."
    public static let joinTargetUnknownText =
        "The control-plane address this worker joins could not be read from its LaunchDaemon, so update it in Terminal."
    public static let roleUnknownText =
        "k3sm cannot tell this Mac's role or the release this app carries, so it cannot update from here."
    public static let installedUnknownText =
        "The installed k3sm reports no release (a developer build), so the app cannot tell what is newer."
    public static let workerBehindText =
        "This Mac joined as a worker, and the managed update runs on the server: update the cluster from the server's app or Settings, Updates there."

    public static let serverUntaggedText =
        "The server runs a developer build of k3sm with no release tag, so there is no release to move the nodes behind to. "
        + "Update them in Terminal."

    public static let serverNodeUnknownText =
        "k3sm did not report this server's own node and the release its kubelet runs, so the app cannot tell which nodes the update would move."

    public static let bundledNodesUnknownText =
        "k3sm could not list the cluster's nodes and whether each is Ready, so it cannot update the cluster to this app's release now."

    public static let bundledNoPayloadRecordText =
        "This app does not carry the record of its k3sm release's digest, so it cannot bind a cluster update to it. Download k3sm.app again."

    /// The sentence the disabled control's help tag and line carry.
    public var sentence: String {
        switch self {
        case .appDeveloperBuild(.managed), .appDeveloperBuild(.catchUp), .appDeveloperBuild(.bundled): return Self.managedDeveloperBuild
        case .appDeveloperBuild(.payload): return Self.payloadDeveloperBuild
        case .refused(let why, _): return why
        case .joinTargetUnknown: return Self.joinTargetUnknownText
        case .roleUnknown: return Self.roleUnknownText
        case .installedUnknown: return Self.installedUnknownText
        case .controlPlaneWithWorkers(let payload):
            return "This Mac runs the control plane of a cluster with other nodes, so it updates only by the managed update, "
                + "and the server's update check has not found k3sm \(payload) yet."
        case .workerBehind: return Self.workerBehindText
        case .downgrade(let installed, let payload):
            return "This Mac runs k3sm \(installed), newer than the \(payload) this app carries, and the app never installs an older k3sm."
        case .serverUntagged: return Self.serverUntaggedText
        case .serverNodeUnknown: return Self.serverNodeUnknownText
        case .nodesAhead(let tag, let nodes):
            return "\(UpdatePath.names(nodes)) \(nodes.count == 1 ? "runs" : "run") a newer release than the server's "
                + "\(StatusDisplay.clip(tag)), and updating to it would move \(nodes.count == 1 ? "that node" : "them") back. Update the server first."
        case .bundledNodeNotReady(let nodes):
            return "\(UpdatePath.names(nodes)) \(nodes.count == 1 ? "is" : "are") not Ready, so the cluster cannot update to this app's release now. "
                + "Update it once every node is Ready."
        case .bundledNodesUnknown: return Self.bundledNodesUnknownText
        case .bundledServerCLITooOld(let installed, let tag):
            return "The k3sm installed on this server (\(installed)) cannot bind an update to this app's release. "
                + "Run `sudo k3sm update apply --version \(StatusDisplay.clip(tag))` in Terminal."
        case .bundledControllerTooOld(let tag):
            return "This server's node runs a k3sm release that does not check a release pin, so the app cannot bind an update to its own release. "
                + "Run `sudo k3sm update apply --version \(StatusDisplay.clip(tag))` in Terminal."
        case .bundledSkewTooWide(let installed, let set):
            if installed.major == set.major, set.minor > 0 {
                return "This cluster runs k3sm \(installed), more than one minor release behind the \(set) this app carries. "
                    + "Update it to a v\(set.major).\(set.minor - 1) release first with `sudo k3sm update apply --version <tag>` in Terminal."
            }
            return "This cluster runs k3sm \(installed), a different major release than the \(set) this app carries. "
                + "Update it one release at a time with `sudo k3sm update apply --version <tag>` in Terminal."
        case .bundledNoPayloadRecord: return Self.bundledNoPayloadRecordText
        }
    }
}

/// UpdatePlanFacts is everything the update plan reads: this Mac's role,
/// the installed release, the app's payload, the managed update's state (the
/// server-recorded latest release, or a roll), the cluster's other nodes,
/// the control plane's release, and whether the app can run the root step.
public struct UpdatePlanFacts: Equatable, Sendable {
    public var role: NodeRole?
    /// The installed CLI's release; nil when unknown or a developer build.
    public var installed: SemanticVersion?
    /// The release bundled in the app; nil for an unstamped build.
    public var payload: SemanticVersion?
    public var managed: ManagedUpdateState
    /// On a server, how many other nodes the cluster has; nil when unknown.
    public var workers: Int?
    /// The newest tagged release a control-plane node runs, from the node
    /// list; nil when the list is not read or names none.
    public var controlPlane: SemanticVersion?
    /// False only once a worker's control-plane address failed to read.
    public var joinTargetReadable: Bool
    /// Whether this build of the app has no Team ID pin.
    public var developerBuild: Bool
    /// Why no root step may start now (another change runs, no administrator
    /// rights), nil when one may.
    public var refusal: String?
    /// Why the app will not run the installed CLI as root (its trust check),
    /// which the managed update runs and the app-carried update does not.
    public var managedRefusal: String?
    /// On a server, the roll pinned to the server's own release
    /// (`ClusterCatchUp`), from the report; nil on a worker or unknown.
    public var catchUp: ClusterCatchUp?
    /// The nodes the Nodes tab marks behind the cluster's target
    /// (`NodeVersions`), by name; empty when the node list is not read.
    public var listedBehind: [String]
    /// The exact payload tag this app carries (`AppVersion.payloadTag`, the
    /// sealed `K3smPayloadTag`), never the short-version fallback; nil for a
    /// build without one.
    public var payloadTag: String?
    /// Whether the bundle carries `Contents/Resources/payload.release`, the
    /// sealed record of its release's archive digest.
    public var payloadRecord: Bool
    /// The listed nodes that are not Ready (no Ready condition, or not
    /// True), by name; nil when the node list was not read.
    public var notReady: [String]?
    /// The release the server's own Node runs (`v` and its kubelet
    /// version's `+k3sm.` part, `ClusterCatchUp.serverRunning`), which is the
    /// release of the update controller, as text; nil when the report does
    /// not say.
    public var serverRunning: String?
    /// The release text the server's installed k3sm reports
    /// (`StatusRelease.tag`: nil for a modified tree's build or a
    /// pseudo-version); the release pin is judged on this exact text.
    public var installedTag: String?
    /// On a server, the roll to `payloadTag` as the controller would sort
    /// the nodes (`ClusterCatchUp.decide(report:target:)`); nil when there is
    /// no payload tag, on a worker, or when the report lists no nodes.
    public var bundledRoll: ClusterCatchUp?

    public init(role: NodeRole?, installed: SemanticVersion?, payload: SemanticVersion?,
                managed: ManagedUpdateState = .nothingNewer, workers: Int? = nil, controlPlane: SemanticVersion? = nil,
                joinTargetReadable: Bool = true, developerBuild: Bool = false,
                refusal: String? = nil, managedRefusal: String? = nil,
                catchUp: ClusterCatchUp? = nil, listedBehind: [String] = [],
                payloadTag: String? = nil, payloadRecord: Bool = false, notReady: [String]? = nil,
                serverRunning: String? = nil, installedTag: String? = nil, bundledRoll: ClusterCatchUp? = nil) {
        self.role = role
        self.installed = installed
        self.payload = payload
        self.managed = managed
        self.workers = workers
        self.controlPlane = controlPlane
        self.joinTargetReadable = joinTargetReadable
        self.developerBuild = developerBuild
        self.refusal = refusal
        self.managedRefusal = managedRefusal
        self.catchUp = catchUp
        self.listedBehind = listedBehind
        self.payloadTag = payloadTag
        self.payloadRecord = payloadRecord
        self.notReady = notReady
        self.serverRunning = serverRunning
        self.installedTag = installedTag
        self.bundledRoll = bundledRoll
    }

    /// The facts from the app's reads: the full report (role, `update` row,
    /// `workers`, the server's own Node), the progress it follows, the two
    /// versions, the node list (and each node's Ready condition), and the
    /// app's own payload tag and whether its payload record is present.
    public init(report: StatusReport?, progress: UpdateProgress, installed: SemanticVersion?, payload: SemanticVersion?,
                nodes: [ClusterNode]?, joinTargetReadable: Bool, developerBuild: Bool,
                refusal: String?, managedRefusal: String?,
                payloadTag: String? = nil, payloadRecord: Bool = false) {
        self.init(role: report.flatMap(NodeRole.detect(in:)), installed: installed, payload: payload,
                  managed: ManagedUpdateState(report: report, progress: progress),
                  workers: report?.workers?.count,
                  controlPlane: nodes?.filter(\.controlPlane).compactMap(NodeVersions.tagged).max(),
                  joinTargetReadable: joinTargetReadable, developerBuild: developerBuild,
                  refusal: refusal, managedRefusal: managedRefusal,
                  catchUp: ClusterCatchUp.decide(report: report),
                  listedBehind: nodes.map { list in
                      let versions = NodeVersions.decide(list, report: report)
                      return list.map(\.name).filter { versions.state(of: $0) == .behind }.sorted()
                  } ?? [],
                  payloadTag: payloadTag, payloadRecord: payloadRecord,
                  notReady: nodes.map { $0.filter { $0.ready != true }.map(\.name).sorted() },
                  serverRunning: ClusterCatchUp.serverRunning(report: report),
                  installedTag: report?.release?.tag,
                  bundledRoll: payloadTag.flatMap { ClusterCatchUp.decide(report: report, target: $0) })
    }
}

/// UpdatePlan is the one decision of which update applies to this Mac.
/// Every place that offers Update (the status item's menu, the console's
/// Alerts tab's update card, the popover's version line, the Settings Updates pane, the
/// node inspector and the guided panel) reads this plan, so no two offer
/// different updates.
public enum UpdatePlan: Equatable, Sendable {
    /// Nothing to update: this Mac runs the release it should.
    case none
    /// Install the app's payload on this Mac.
    case payload(SemanticVersion)
    /// Start the managed roll to this tag, from this server.
    case managed(tag: String)
    /// Start the managed roll pinned to this server's own release, which
    /// moves the named nodes (those not on it) and leaves the rest.
    case catchUp(tag: String, nodes: [String])
    /// Start the managed roll to this app's own release, bound to its sealed
    /// digest through the checked root step (`BundledRollDriver`).
    case bundled(tag: String)
    /// A managed roll is under way: show it, offer nothing new.
    case rolling
    /// No update can run from the app; the block says why.
    case blocked(UpdateBlock)

    /// Decides the plan. The order is the contract:
    ///
    ///  1. A managed roll under way: rolling.
    ///  2. No role: blocked.
    ///  3. A server: the payload when it is the only node and the payload
    ///     is newer than the install; else the roll to the version set this
    ///     app carries (`bundledStep`) when its exact payload tag is newer
    ///     than the installed release and the installed CLI and the running
    ///     controller both know the release pin, the skew is at most one minor
    ///     release, and the node list was read: before the managed roll and
    ///     the catch-up, so a `behind` row naming the same tag still takes
    ///     the pinned path; else the managed roll when the server's
    ///     check found a newer release; else, when a node is behind (in the
    ///     report against the server's release, or on the Nodes tab), the
    ///     catch-up: the roll pinned to the server's own release, blocked when
    ///     the server has no release tag, its own Node is not reported, or a
    ///     node (the server's own Node included) is ahead of it, nothing when
    ///     every node already runs it; else, with a newer payload, blocked
    ///     (the control plane of a multi-node cluster updates only by the roll),
    ///     naming the command line when the version set's roll could not be
    ///     offered (a CLI or controller without the pin, a wide skew).
    ///  4. A worker: the payload when it is newer than the install; else
    ///     blocked when the control plane runs a newer release (update from
    ///     the server).
    ///  5. A payload older than the install: blocked (a downgrade); an
    ///     install with no release: blocked; otherwise none.
    ///
    /// A path found in 3 or 4 is then blocked when this build cannot run the
    /// root step, or cannot now, or (a worker's payload) lacks the address
    /// its worker joins, or (the version set's roll) a node is not Ready or
    /// unknown, a node is ahead of the set, or the payload record is missing.
    public static func decide(_ facts: UpdatePlanFacts) -> UpdatePlan {
        if facts.managed == .rolling { return .rolling }
        guard let role = facts.role else { return .blocked(.roleUnknown) }
        let payloadNewer: SemanticVersion? = {
            guard let payload = facts.payload, let installed = facts.installed, payload > installed else { return nil }
            return payload
        }()
        let path: UpdatePath?
        var bundledBlock: UpdateBlock?
        switch role {
        case .server:
            let bundled: BundledStep = facts.workers == 0 ? .none : bundledStep(facts)
            if let payload = payloadNewer, facts.workers == 0 {
                path = .payload(payload)
            } else if case .offer(let tag, let block) = bundled {
                path = .bundled(tag: tag)
                bundledBlock = block
            } else if case .behind(let tag) = facts.managed {
                path = .managed(tag: tag)
            } else if let step = catchUpStep(facts) {
                switch step {
                case .success(let found): path = found
                case .failure(let block): return .blocked(block.block)
                }
            } else if let payload = payloadNewer {
                if case .fallback(let block) = bundled { return .blocked(block) }
                return .blocked(.controlPlaneWithWorkers(payload: payload))
            } else {
                path = nil
            }
        case .agent:
            if let payload = payloadNewer {
                path = .payload(payload)
            } else if let installed = facts.installed, let server = facts.controlPlane, installed < server {
                return .blocked(.workerBehind)
            } else {
                path = nil
            }
        }
        guard let path else {
            guard let installed = facts.installed else { return .blocked(.installedUnknown) }
            if let payload = facts.payload, payload < installed {
                return .blocked(.downgrade(installed: installed, payload: payload))
            }
            return .none
        }
        if facts.developerBuild { return .blocked(.appDeveloperBuild(path)) }
        if let refusal = facts.refusal { return .blocked(.refused(refusal, path)) }
        switch path {
        case .managed(let tag):
            if let why = facts.managedRefusal { return .blocked(.refused(why, path)) }
            return .managed(tag: tag)
        case .catchUp(let tag, let nodes):
            if let why = facts.managedRefusal { return .blocked(.refused(why, path)) }
            return .catchUp(tag: tag, nodes: nodes)
        case .bundled(let tag):
            if let why = facts.managedRefusal { return .blocked(.refused(why, path)) }
            if let block = bundledBlock { return .blocked(block) }
            return .bundled(tag: tag)
        case .payload(let version):
            if role == .agent, !facts.joinTargetReadable { return .blocked(.joinTargetUnknown(version)) }
            return .payload(version)
        }
    }

    /// The catch-up step of a server's plan: nil when no node is behind or
    /// every node already runs the server's release (the plan goes on as if
    /// there were none); else the roll pinned to the server's release, or why
    /// it cannot run.
    static func catchUpStep(_ facts: UpdatePlanFacts) -> Result<UpdatePath, CatchUpBlock>? {
        guard let catchUp = facts.catchUp, !catchUp.behind.isEmpty || !facts.listedBehind.isEmpty else { return nil }
        guard let tag = catchUp.tag else { return .failure(CatchUpBlock(block: .serverUntagged)) }
        guard catchUp.serverKnown else { return .failure(CatchUpBlock(block: .serverNodeUnknown)) }
        if !catchUp.ahead.isEmpty { return .failure(CatchUpBlock(block: .nodesAhead(tag: tag, nodes: catchUp.ahead))) }
        guard !catchUp.moves.isEmpty else { return nil }
        return .success(.catchUp(tag: tag, nodes: catchUp.moves))
    }

    /// An `UpdateBlock` as a `Result` failure.
    struct CatchUpBlock: Error {
        let block: UpdateBlock
    }

    /// BundledStep is what the version set this app carries means for a
    /// server's plan.
    enum BundledStep: Equatable {
        /// No version-set roll: no payload tag, the install is not older
        /// than it, or every node already runs it.
        case none
        /// The roll cannot be bound here (a CLI or controller without the
        /// pin, or a wide skew): the plan goes on as before, and this block
        /// replaces `.controlPlaneWithWorkers` at its end.
        case fallback(UpdateBlock)
        /// The roll to `tag` is the path; `block`, when set, is the live
        /// precondition it fails now, applied after the root-step checks.
        case offer(tag: String, block: UpdateBlock?)
    }

    /// The version set's step of a server's plan with other nodes (or an
    /// unknown count). It applies when this app's exact payload tag names a
    /// release newer than the installed one. The pin must be known to both
    /// the installed CLI and the running controller, and the installed
    /// release must be in the set's major release and at most one minor
    /// behind; otherwise there is no offer (`fallback`). Then the server's
    /// own Node must be read, the payload record present, every listed node
    /// Ready (the node list read), and no node ahead of the set; otherwise
    /// the offer is blocked. With nothing to move there is no offer.
    static func bundledStep(_ facts: UpdatePlanFacts) -> BundledStep {
        guard let tag = facts.payloadTag, BundledRollSupport.isReleaseTag(tag), let set = SemanticVersion(tag),
              let installed = facts.installed, installed < set
        else { return .none }
        guard BundledRollSupport.hasPin(tag: facts.installedTag) else {
            return .fallback(.bundledServerCLITooOld(installed: installed, tag: tag))
        }
        guard BundledRollSupport.skewAllowed(installed: installed, set: set) else {
            return .fallback(.bundledSkewTooWide(installed: installed, set: set))
        }
        guard let running = facts.serverRunning else { return .offer(tag: tag, block: .serverNodeUnknown) }
        guard BundledRollSupport.hasPin(tag: running) else { return .fallback(.bundledControllerTooOld(tag: tag)) }
        guard facts.payloadRecord else { return .offer(tag: tag, block: .bundledNoPayloadRecord) }
        guard let notReady = facts.notReady else { return .offer(tag: tag, block: .bundledNodesUnknown) }
        guard notReady.isEmpty else { return .offer(tag: tag, block: .bundledNodeNotReady(notReady)) }
        guard let roll = facts.bundledRoll else { return .offer(tag: tag, block: .bundledNodesUnknown) }
        guard roll.serverKnown else { return .offer(tag: tag, block: .serverNodeUnknown) }
        if !roll.ahead.isEmpty { return .offer(tag: tag, block: .nodesAhead(tag: tag, nodes: roll.ahead)) }
        guard !roll.moves.isEmpty else { return .none }
        return .offer(tag: tag, block: nil)
    }

    /// The path the plan runs, or a disabled control would; nil when none.
    public var path: UpdatePath? {
        switch self {
        case .payload(let version): return .payload(version)
        case .managed(let tag): return .managed(tag: tag)
        case .catchUp(let tag, let nodes): return .catchUp(tag: tag, nodes: nodes)
        case .bundled(let tag): return .bundled(tag: tag)
        case .blocked(let block): return block.path
        case .none, .rolling: return nil
        }
    }

    /// Whether Update can be clicked.
    public var isEnabled: Bool {
        switch self {
        case .payload, .managed, .catchUp, .bundled: return true
        case .none, .rolling, .blocked: return false
        }
    }

    /// The rolling plan's reason, as the managed update says it.
    public static let rollingReason = "An update is rolling; the window shows its progress."
    /// The guided panel's line when the plan has nothing to update.
    public static let nothingToUpdate = "This Mac runs the release it should, so there is nothing to update."

    /// Why Update is disabled; nil when it is enabled or there is nothing to do.
    public var disabledReason: String? {
        switch self {
        case .blocked(let block): return block.sentence
        case .rolling: return Self.rollingReason
        case .none, .payload, .managed, .catchUp, .bundled: return nil
        }
    }

    /// The one line the plan shows beside its control: what the update does,
    /// or why it cannot run; nil when there is nothing to update.
    public var line: String? {
        switch self {
        case .payload, .managed, .catchUp, .bundled: return path?.sentence
        case .rolling, .blocked: return disabledReason
        case .none: return nil
        }
    }

    /// The status item's menu title: the path's, enabled or not, or
    /// "Updating…"; nil (the item hidden) when there is no update to run.
    public var menuTitle: String? {
        if self == .rolling { return "Updating…" }
        return path?.menuTitle
    }

    /// The console strip's and the popover's button title; nil when hidden.
    public var buttonTitle: String? {
        if self == .rolling { return "Updating…" }
        return path == nil ? nil : "Update"
    }
}

/// BundledRollSupport is when the roll to the version set this app carries
/// can be bound to its sealed digest: both the installed CLI, which writes
/// the release pin (`k3sm update apply --pin-sha256`), and the update
/// controller the server's daemon runs, which enforces it, must be newer
/// than the last release without the pin, and the cluster at most one minor
/// release behind the set, in the same major release (worker-ahead skew is
/// bounded at one release). The tag is the strict release grammar the app's
/// release stamps into `K3smPayloadTag` and `payload.release`.
public enum BundledRollSupport {
    /// The last k3sm release without the release pin. The pin ships in the
    /// release after it, so any version above it (its pre-releases included)
    /// has it.
    public static let lastReleaseWithoutPin = SemanticVersion("0.1.7")!

    /// Whether the k3sm that reports `tag` has the release pin: only an
    /// exact release tag in the strict grammar (`isReleaseTag`) above
    /// `lastReleaseWithoutPin`. Anything else counts as no pin: nil, a
    /// pre-release outside `-rc.N`, a git-describe, modified or developer
    /// build's version, or text that does not parse. Such a build may lack
    /// the pin whatever number it carries, so it is never trusted to have it.
    /// The installed tag is the CLI's self-report, bounded by the strict
    /// grammar: a hint that decides what the app offers, not a trust anchor.
    public static func hasPin(tag: String?) -> Bool {
        guard let tag, isReleaseTag(tag), let version = SemanticVersion(tag) else { return false }
        return version > lastReleaseWithoutPin
    }

    /// Whether the cluster's release `installed` may roll to `set` in one
    /// step: the same major release, at most one minor release apart.
    public static func skewAllowed(installed: SemanticVersion, set: SemanticVersion) -> Bool {
        installed.major == set.major && set.minor - installed.minor <= 1
    }

    /// Whether `tag` is a release tag in the strict grammar, the shell's
    /// `^v(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})(-rc\.(0|[1-9][0-9]{0,3}))?$`,
    /// checked byte by byte.
    public static func isReleaseTag(_ tag: String) -> Bool {
        var bytes = Array(tag.utf8)[...]
        guard bytes.popFirst() == UInt8(ascii: "v") else { return false }
        func number(maxDigits: Int) -> Bool {
            let digits = bytes.prefix { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }
            guard (1...maxDigits).contains(digits.count), digits.count == 1 || digits.first != UInt8(ascii: "0") else { return false }
            bytes = bytes.dropFirst(digits.count)
            return true
        }
        guard number(maxDigits: 9), bytes.popFirst() == UInt8(ascii: "."),
              number(maxDigits: 9), bytes.popFirst() == UInt8(ascii: "."),
              number(maxDigits: 9)
        else { return false }
        if bytes.isEmpty { return true }
        guard Array(bytes.prefix(4)) == Array("-rc.".utf8) else { return false }
        bytes = bytes.dropFirst(4)
        return number(maxDigits: 4) && bytes.isEmpty
    }
}
