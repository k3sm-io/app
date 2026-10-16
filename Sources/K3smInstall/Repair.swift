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

import K3smStatus

/// RepairRefusal is why the app does not run Repair (`CopyOutAction.repair`)
/// now. Each is decided by the app before any prompt; the CLI's own refusals
/// (no daemon plist on disk, both roles on disk, an older release, a worker
/// with no valid node credential, a build signed by another team) come back
/// in the copy-out log.
public enum RepairRefusal: Equatable, Sendable {
    /// This build has no Team ID pin, so it cannot run the checked root step.
    case noRootStep
    /// The app carries no stamped release, so there is no payload to repair from.
    case payloadUnknown
    /// The health check has not run yet.
    case healthUnknown
    /// Nothing is installed: the first run applies, not a repair.
    case notInstalled
    /// The installed k3sm is newer than the app's, and Repair never downgrades.
    case installedNewer
    /// The state is not a half-installed one (`HealthState.repairable`).
    case notHalfInstalled

    /// The line shown as the disabled Repair button's help tag, and as the
    /// panel's failure line when Repair is clicked anyway.
    public var text: String {
        switch self {
        case .noRootStep:
            return "This build of k3sm is not Developer ID signed, so it cannot run the administrator step."
        case .payloadUnknown:
            return "The release this app carries is unknown, so it cannot repair k3sm from it."
        case .healthUnknown:
            return "k3sm on this Mac has not been checked yet."
        case .notInstalled:
            return "k3sm is not installed on this Mac, so there is nothing to repair."
        case .installedNewer:
            return "The installed k3sm is newer than this app's, and Repair never installs an older release."
        case .notHalfInstalled:
            return "Repair is for a k3sm whose command is missing or untrusted, or whose daemons are partly down."
        }
    }
}

/// RepairPolicy decides whether the app offers Repair. It is pure: the app
/// passes the health state, whether it can run the root step and the
/// release it carries. Repair runs the same copy-out as an install or an
/// update (the bundle copied, refused if unsafe, its Developer ID signature
/// verified, then the staged CLI run), so the trust path is the existing one.
public enum RepairPolicy {
    /// nil when Repair may run, else why not. The order is the contract: the
    /// root step and the payload first, then the state.
    public static func refusal(health: HealthState?, rootStep: Bool, payload: SemanticVersion?) -> RepairRefusal? {
        guard rootStep else { return .noRootStep }
        guard payload != nil else { return .payloadUnknown }
        guard let health else { return .healthUnknown }
        if health.repairable { return nil }
        switch health {
        case .notInstalled: return .notInstalled
        case .versionMismatch(_, _, .older): return .installedNewer
        default: return .notHalfInstalled
        }
    }
}

/// RepairConfirmation is the question asked before Repair's administrator
/// prompt: what Repair does, what it keeps for this Mac's role, and when k3sm
/// refuses it. Fixed text, but for the release the app carries, which is the
/// app's own stamp.
///
/// What each role keeps is exactly what `k3sm install --from-staging <dir>`
/// with no other flag carries over (k3sm `pkg/install` `ResolveInPlace`,
/// `installedServerArgs`, `installedAgentArgs`):
///
/// - a server: the role, and the server arguments from its installed plist
///   or, without one, from its arguments record; the admin kubeconfig is
///   written again for the owner of the kubeconfig that record names;
/// - a worker: the role, the `--server` its agent plist names, its node
///   credential (it rejoins with no token), and every other argument on its
///   plist except `--node-ip`, which the install renders only from its own
///   flag; on a worker that is only an assertion of the mesh address the
///   control plane assigns, so the worker keeps using the assigned one.
///
/// With the role unknown (no report, as when the command is missing) the
/// question names both.
public struct RepairConfirmation: Equatable, Sendable {
    public let title: String
    public let message: String
    /// The button that runs Repair.
    public let proceedTitle: String
    public let cancelTitle: String

    /// What a control-plane Mac keeps.
    public static let serverKeeps = "This Mac stays the control plane, with the server arguments its last install recorded, "
        + "and the cluster's data is kept. The admin kubeconfig is written again for the account the server's record names, "
        + "which may not be the account running this app."
    /// What a worker keeps.
    public static let agentKeeps = "This Mac stays a worker of the control plane its daemon joins, with its node credential "
        + "and the other arguments its daemon runs with, and its data is kept. An explicit node IP it was installed with is not "
        + "passed again: the worker uses the address the control plane assigned it."
    /// When k3sm refuses, which the app cannot check first.
    public static let refusals = "k3sm refuses the repair, and the log says why, when no daemon on this Mac says which role it has, "
        + "when the installed release is newer than this app's or its version cannot be read or is not a release, "
        + "when the installed command is signed by another team, or when a worker's node credential is no longer valid. "
        + "Repair names no account, so k3sm also refuses when both daemon plists are on disk, because the role is ambiguous "
        + "(uninstall, then install the role this Mac should have), and, on a control plane, when its arguments record names no admin "
        + "kubeconfig, or the owner of that kubeconfig cannot be read or is root (run the install again from Terminal with --user)."

    public init(payload: SemanticVersion, role: NodeRole?) {
        title = "Repair k3sm on this Mac?"
        let keeps: String
        switch role {
        case .server: keeps = Self.serverKeeps
        case .agent: keeps = Self.agentKeeps
        case nil: keeps = "On a control-plane Mac: " + Self.serverKeeps + "\n\nOn a worker: " + Self.agentKeeps
        }
        message = "k3sm \(payload), the release this app carries, is installed again over the k3sm on this Mac: "
            + "its command, its helpers, its daemons and the k3sm link, and the daemons restart.\n\n"
            + keeps + "\n\n" + Self.refusals
        proceedTitle = "Repair"
        cancelTitle = "Cancel"
    }
}
