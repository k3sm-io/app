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
    /// The last Repair or Update was refused because the installed k3sm does not
    /// resolve to a binary of its install tree (`UnresolvableInstall`), so
    /// running Repair again cannot work: the install script repairs it.
    /// `payload` is the release the app carries, which the script pins.
    case installedUnresolvable(payload: SemanticVersion?)

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
        case .installedUnresolvable(let payload):
            return UnresolvableInstall.sentence(for: .repair, payload: payload)
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
    /// root step and the payload first, then the state. `unresolvable` is
    /// whether the last Repair ended on k3sm's unresolvable-install refusal
    /// (`UnresolvableInstall.refused`); it holds only while the state is
    /// still a repairable one, so a Mac the install script has repaired
    /// offers Repair again when it next needs it.
    public static func refusal(health: HealthState?, rootStep: Bool, payload: SemanticVersion?,
                               unresolvable: Bool = false) -> RepairRefusal? {
        guard rootStep else { return .noRootStep }
        guard payload != nil else { return .payloadUnknown }
        guard let health else { return .healthUnknown }
        if health.repairable { return unresolvable ? .installedUnresolvable(payload: payload) : nil }
        switch health {
        case .notInstalled: return .notInstalled
        case .versionMismatch(_, _, .older): return .installedNewer
        default: return .notHalfInstalled
        }
    }
}

/// UnresolvableInstall recognises k3sm's refusal of `install --from-staging`
/// when the installed k3sm's entry point does not resolve to a binary of its
/// install tree (a dangling compat link, a loop, or a target outside the
/// tree). k3sm keeps refusing that install, so neither Repair nor the app's
/// Update, which both run it, can work, and the refusal itself names the
/// install script as the repair.
///
/// The copy-out log is the CLI's output, untrusted: it is only compared with
/// the fixed line shape below, and the user sees the app's own sentence
/// (`sentence(for:payload:)`), never the log's text.
public enum UnresolvableInstall {
    /// The recovery k3sm appends to the refusal, verbatim (k3sm
    /// `pkg/install` `installedUnresolvableRecovery`, printed on stderr as
    /// `install: <cause>; <recovery>`). A test compares it with the k3sm
    /// source when a k3sm checkout is at hand.
    public static let recoveryPhrase = "repair the install with the install script, "
        + "curl -fsSL https://k3sm.io/install.sh | sh "
        + "(K3SM_INSTALL_VERSION=vX.Y.Z after the pipe pins a release), then update again"

    /// How the refusal's line starts in the copy-out log: k3sm's main prints
    /// a failed install as `k3sm install: <err>`, and the refusal's error
    /// starts `install: ` (k3sm `cmd/k3sm/main.go`, `pkg/install`
    /// `preflightFromStaging`).
    public static let linePrefix = "k3sm install: install: "

    /// Whether `action` runs `k3sm install --from-staging`, the install k3sm
    /// refuses over an unresolvable installed k3sm.
    public static func runsFromStaging(_ action: CopyOutAction) -> Bool {
        switch action {
        case .repair, .update: return true
        case .startServer, .join, .uninstall: return false
        }
    }

    /// Whether a finished root step for `action` was a Repair or an Update
    /// that k3sm refused with the unresolvable-install recovery: `log` holds
    /// a whole line (ended by a newline) that starts with `linePrefix` and
    /// ends with `; ` and `recoveryPhrase`, byte for byte. A changed case, a
    /// different URL, a line the log's tail window cut, or the phrase
    /// anywhere else is not the refusal.
    public static func refused(_ outcome: PrivilegedOutcome, action: CopyOutAction, log: String) -> Bool {
        guard runsFromStaging(action), case .failed = outcome else { return false }
        let suffix = "; " + recoveryPhrase
        // The last piece is the unterminated rest of the log, never a whole line.
        let lines = log.split(separator: "\n", omittingEmptySubsequences: false).dropLast()
        return lines.contains { line in
            line.count > linePrefix.count + suffix.count
                && line.hasPrefix(linePrefix) && line.hasSuffix(suffix)
        }
    }

    /// The app's sentence for the refusal of `action` (Repair or Update):
    /// the install script, pinned to `payload`, the release the app carries
    /// (unpinned for none and for a development build's `0.0.0`).
    public static func sentence(for action: CopyOutAction, payload: SemanticVersion?) -> String {
        let step = if case .update = action { "Update" } else { "Repair" }
        return "The installed k3sm command does not lead to a k3sm in its install tree, so \(step) cannot run it. "
            + "Repair the install with the install script in Terminal, "
            + GuidedSteps.installScriptCommand(version: payload)
            + ", then click Refresh."
    }
}

/// RefreshSource is what asked for a read of k3sm's state, and decides which
/// reads lift the hold `UnresolvableInstallMark` keeps (`liftsUnresolvableHold`).
public enum RefreshSource: CaseIterable, Sendable {
    /// The guided panel's Refresh.
    case guidedPanel
    /// The menu's Refresh.
    case menu
    /// The status popover's Refresh.
    case popover
    /// Check Again on the first run.
    case firstRunCheckAgain
    /// The read after a root step finished.
    case afterRootStep
    /// The first run's install watch.
    case installWatch
    /// A status stream frame, or any read on the app's own schedule.
    case automatic

    /// Whether this read lifts the hold: only a read the user asked for. The
    /// refusal's sentence ends on the user's Refresh, after the install
    /// script; a read the app makes on its own, the one right after the
    /// refused step above all, never lifts it.
    /// What a bare `refresh()` is: a read the app makes on its own, so it
    /// never lifts the hold. A change of this default is a change of the
    /// decision, and `RepairUnresolvableTests` pins it.
    public static let bareRefresh: RefreshSource = .automatic

    public var liftsUnresolvableHold: Bool {
        switch self {
        case .guidedPanel, .menu, .popover, .firstRunCheckAgain: return true
        case .afterRootStep, .installWatch, .automatic: return false
        }
    }
}

/// UnresolvableInstallMark is whether the app holds Repair and the app's
/// Update back after k3sm's unresolvable-install refusal
/// (`RepairPolicy.refusal`'s `unresolvable`, the update plan's refusal). A
/// failed Repair or Update with the refusal in its log sets it; one that
/// failed otherwise or was cancelled clears it. It clears on a read the user
/// asked for (`RefreshSource.liftsUnresolvableHold`), on any root step that
/// succeeds, and on a read of a state that is neither a repairable one nor
/// the state the refused step ran on.
public struct UnresolvableInstallMark: Equatable, Sendable {
    public private(set) var isSet = false
    /// The state the refused step ran on, when known.
    private var refusedOn: HealthState?

    public init() {}

    /// A copy-out root step (install, join, update, repair, uninstall)
    /// finished with `outcome`, leaving `log`; `state` is the state it ran on.
    public mutating func rootStepFinished(_ outcome: PrivilegedOutcome, action: CopyOutAction, log: String,
                                          state: HealthState? = nil) {
        if outcome == .succeeded {
            clear()
        } else if UnresolvableInstall.runsFromStaging(action) {
            isSet = UnresolvableInstall.refused(outcome, action: action, log: log)
            refusedOn = isSet ? state : nil
        }
    }

    /// Why the app's Update is held back, nil when it is not: the app's
    /// sentence for the refusal, pinned to `payload`, the release it carries.
    public func updateRefusal(payload: SemanticVersion?) -> String? {
        isSet ? UnresolvableInstall.sentence(for: .update(.server), payload: payload) : nil
    }

    /// A read of the state was asked for by `source`.
    public mutating func refreshed(_ source: RefreshSource) {
        if source.liftsUnresolvableHold { clear() }
    }

    /// A health check read `state`; nil, no state yet, changes nothing.
    public mutating func stateRead(_ state: HealthState?) {
        guard let state, !state.repairable, state != refusedOn else { return }
        clear()
    }

    private mutating func clear() {
        isSet = false
        refusedOn = nil
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

    /// `developerMode` (the root step runs under `TrustPolicy.developer`)
    /// adds `DeveloperMode.warning` as the message's last paragraph.
    public init(payload: SemanticVersion, role: NodeRole?, developerMode: Bool = false) {
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
            + (developerMode ? "\n\n" + DeveloperMode.warning : "")
        proceedTitle = "Repair"
        cancelTitle = "Cancel"
    }
}
