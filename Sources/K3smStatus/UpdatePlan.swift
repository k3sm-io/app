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

/// UpdatePath is one of the two ways k3sm on this Mac moves to a newer
/// release: the release this app carries, installed over this Mac's k3sm
/// through the checked root step (the app-carried update), or the managed
/// roll `k3sm update apply` starts on the server, which moves every node to
/// the latest release, the server last.
public enum UpdatePath: Equatable, Sendable {
    /// Install the app's payload, this release, on this Mac only.
    case payload(SemanticVersion)
    /// Roll the whole cluster to this release tag (`v0.1.9`).
    case managed(tag: String)

    /// The status item's menu title, which names the release.
    public var menuTitle: String {
        switch self {
        case .payload(let version): return "Update This Mac to \(version)…"
        case .managed(let tag): return "Update to \(StatusDisplay.clip(tag))…"
        }
    }

    /// One sentence saying what the update does.
    public var sentence: String {
        switch self {
        case .payload(let version):
            return "The update installs k3sm \(version), the release this app carries, on this Mac."
        case .managed(let tag):
            return StatusDisplay.clip("The update moves every node to k3sm \(tag), the server last.")
        }
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

    /// The path a disabled control would run once the block clears; nil
    /// when there is no update to run.
    public var path: UpdatePath? {
        switch self {
        case .appDeveloperBuild(let path), .refused(_, let path): return path
        case .joinTargetUnknown(let version): return .payload(version)
        case .roleUnknown, .installedUnknown, .controlPlaneWithWorkers, .workerBehind, .downgrade: return nil
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

    /// The sentence the disabled control's help tag and line carry.
    public var sentence: String {
        switch self {
        case .appDeveloperBuild(.managed): return Self.managedDeveloperBuild
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

    public init(role: NodeRole?, installed: SemanticVersion?, payload: SemanticVersion?,
                managed: ManagedUpdateState = .nothingNewer, workers: Int? = nil, controlPlane: SemanticVersion? = nil,
                joinTargetReadable: Bool = true, developerBuild: Bool = false,
                refusal: String? = nil, managedRefusal: String? = nil) {
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
    }

    /// The facts from the app's reads: the full report (role, `update` row,
    /// `workers`), the progress it follows, the two versions and the node list.
    public init(report: StatusReport?, progress: UpdateProgress, installed: SemanticVersion?, payload: SemanticVersion?,
                nodes: [ClusterNode]?, joinTargetReadable: Bool, developerBuild: Bool,
                refusal: String?, managedRefusal: String?) {
        self.init(role: report.flatMap(NodeRole.detect(in:)), installed: installed, payload: payload,
                  managed: ManagedUpdateState(report: report, progress: progress),
                  workers: report?.workers?.count,
                  controlPlane: nodes?.filter(\.controlPlane).compactMap(NodeVersions.tagged).max(),
                  joinTargetReadable: joinTargetReadable, developerBuild: developerBuild,
                  refusal: refusal, managedRefusal: managedRefusal)
    }
}

/// UpdatePlan is the one decision of which update applies to this Mac.
/// Every place that offers Update (the status item's menu, the console's
/// strip button, the popover's version line, the Settings Updates pane, the
/// node inspector and the guided panel) reads this plan, so no two offer
/// different updates.
public enum UpdatePlan: Equatable, Sendable {
    /// Nothing to update: this Mac runs the release it should.
    case none
    /// Install the app's payload on this Mac.
    case payload(SemanticVersion)
    /// Start the managed roll to this tag, from this server.
    case managed(tag: String)
    /// A managed roll is under way: show it, offer nothing new.
    case rolling
    /// No update can run from the app; the block says why.
    case blocked(UpdateBlock)

    /// Decides the plan. The order is the contract:
    ///
    ///  1. A managed roll under way: rolling.
    ///  2. No role: blocked.
    ///  3. A server: the payload when it is the only node and the payload
    ///     is newer than the install; else the managed roll when the server's
    ///     check found a newer release; else, with a newer payload, blocked
    ///     (the control plane of a multi-node cluster updates only by the roll).
    ///  4. A worker: the payload when it is newer than the install; else
    ///     blocked when the control plane runs a newer release (update from
    ///     the server).
    ///  5. A payload older than the install: blocked (a downgrade); an
    ///     install with no release: blocked; otherwise none.
    ///
    /// A path found in 3 or 4 is then blocked when this build cannot run the
    /// root step, or cannot now, or (a worker's payload) lacks the address
    /// its worker joins.
    public static func decide(_ facts: UpdatePlanFacts) -> UpdatePlan {
        if facts.managed == .rolling { return .rolling }
        guard let role = facts.role else { return .blocked(.roleUnknown) }
        let payloadNewer: SemanticVersion? = {
            guard let payload = facts.payload, let installed = facts.installed, payload > installed else { return nil }
            return payload
        }()
        let path: UpdatePath?
        switch role {
        case .server:
            if let payload = payloadNewer, facts.workers == 0 {
                path = .payload(payload)
            } else if case .behind(let tag) = facts.managed {
                path = .managed(tag: tag)
            } else if let payload = payloadNewer {
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
        case .payload(let version):
            if role == .agent, !facts.joinTargetReadable { return .blocked(.joinTargetUnknown(version)) }
            return .payload(version)
        }
    }

    /// The path the plan runs, or a disabled control would; nil when none.
    public var path: UpdatePath? {
        switch self {
        case .payload(let version): return .payload(version)
        case .managed(let tag): return .managed(tag: tag)
        case .blocked(let block): return block.path
        case .none, .rolling: return nil
        }
    }

    /// Whether Update can be clicked.
    public var isEnabled: Bool {
        switch self {
        case .payload, .managed: return true
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
        case .none, .payload, .managed: return nil
        }
    }

    /// The one line the plan shows beside its control: what the update does,
    /// or why it cannot run; nil when there is nothing to update.
    public var line: String? {
        switch self {
        case .payload, .managed: return path?.sentence
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
