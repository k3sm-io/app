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

/// GuidedAction is the one primary step a guided panel offers. Start and
/// Restart run the existing lifecycle verbs, Update the existing app-carried
/// update, all through the checked root step; Refresh reads the status again.
public enum GuidedAction: String, CaseIterable, Equatable, Sendable {
    case start
    case restart
    case update
    case refresh

    /// The panel's primary button.
    public var title: String {
        switch self {
        case .start: return "Start k3sm"
        case .restart: return "Restart k3sm"
        case .update: return "Update k3sm"
        case .refresh: return "Refresh"
        }
    }

    /// Whether the step runs through the checked root step, which a
    /// developer build (no Team ID pin) cannot run.
    public var needsRootStep: Bool { self != .refresh }
}

/// GuidedPlan is what the console shows for one health state that is not
/// healthy: the banner across its top (the state's line and the button that
/// opens the panel), and the guided panel (a title, a short numbered step
/// list, one primary button, and the Terminal command to run instead where
/// the app cannot run the step itself).
public struct GuidedPlan: Equatable, Sendable {
    public let state: HealthState
    /// The banner's one sentence: the state's own line.
    public let banner: String
    /// The banner's button, which opens the panel and names the next step.
    public let bannerButton: String
    /// The panel's title.
    public let title: String
    /// The numbered steps, in order.
    public let steps: [String]
    /// The primary button; nil when the app offers no step of its own.
    public let primary: GuidedAction?
    /// The exact command to run in Terminal, shown with a Copy button: in a
    /// developer build in place of a root step, and where no repair path exists.
    public let terminalCommand: String?
    /// Whether the panel offers Open Logs.
    public let opensLogs: Bool
    /// Whether the panel offers Refresh beside a primary that is not Refresh,
    /// or alone (after a step run in Terminal).
    public let offersRefresh: Bool
}

/// GuidedSteps maps each health state to its guided plan. It is pure: the
/// app passes the state, whether it can run the checked root step, this
/// Mac's role and the release the app carries; this decides. Healthy and not
/// installed (the first run) have no plan.
///
/// | state | primary | in a developer build |
/// |---|---|---|
/// | stopped | Start | `sudo k3sm start` in Terminal |
/// | partly running, node daemon up | Restart | `sudo k3sm restart` in Terminal |
/// | partly running, node daemon down | Start (Restart refuses a stopped node) | `sudo k3sm start` |
/// | behind the app | Update | the install script pinned to the app's release, or on a worker `sudo k3sm update apply` on the control plane |
/// | ahead of the app | none, an explanation | the same |
/// | command missing or untrusted | none: the install script in Terminal, then Refresh | the same |
/// | status unreadable | Refresh, and Open Logs | the same |
public enum GuidedSteps {
    /// The Terminal command that starts k3sm.
    public static let startCommand = "sudo k3sm start"
    /// The Terminal command that restarts k3sm.
    public static let restartCommand = "sudo k3sm restart"
    /// The Terminal command that rolls the managed update over every node,
    /// run on the control-plane Mac.
    public static let managedUpdateCommand = "sudo k3sm update apply"
    /// The documented install script, the script channel's install, upgrade
    /// and repair path.
    public static let installScriptURL = "https://k3sm.io/install.sh"
    /// Where every k3sm release is listed.
    public static let releasesURL = "https://k3sm.io/releases/"

    /// The install script's command line, pinned to `version` when known
    /// (a repair pins the release; an unpinned run installs the latest).
    public static func installScriptCommand(version: SemanticVersion?) -> String {
        guard let version else { return "curl -fsSL \(installScriptURL) | sh" }
        return "curl -fsSL \(installScriptURL) | K3SM_INSTALL_VERSION=v\(version) sh"
    }

    /// The step a partly running Mac takes: Restart while the node daemon
    /// runs (netd is the one down), Start while the node daemon is down,
    /// since the lifecycle gate refuses Restart on a stopped node.
    public static func partlyRunningAction(down: [String]) -> GuidedAction {
        down == [HealthClassifier.netdLabel] ? .restart : .start
    }

    /// The plan for `state`, nil when healthy or not installed.
    /// `rootStep` is whether this build can run the checked root step (a
    /// Team ID is pinned); `payload` is the release the app carries.
    public static func plan(for state: HealthState, rootStep: Bool, role: NodeRole?, payload: SemanticVersion?) -> GuidedPlan? {
        guard let banner = state.line, !state.showsFirstRun else { return nil }
        switch state {
        case .notInstalled, .healthy:
            return nil
        case .installedStopped:
            return lifecycle(.start, state: state, banner: banner, rootStep: rootStep, why: [
                "k3sm is stopped, so this Mac runs no pods and serves nothing. It stays stopped until it is started.",
            ])
        case .partlyRunning(let down):
            let action = partlyRunningAction(down: down)
            let labels = down.map(StatusDisplay.clip).joined(separator: " and ")
            let what = labels.isEmpty ? "Part of k3sm is not running." : "\(labels) \(down.count == 1 ? "is" : "are") not running, so k3sm is only partly up."
            return lifecycle(action, state: state, banner: banner, rootStep: rootStep, why: [what])
        case .versionMismatch(let payloadVersion, let installed, let relation):
            if relation == .older {
                return GuidedPlan(
                    state: state, banner: banner, bannerButton: "What This Means…",
                    title: "This Mac runs a newer k3sm",
                    steps: [
                        "This Mac runs k3sm \(installed), a newer release than the \(payloadVersion) this app carries.",
                        "k3sm keeps running as it is. The app never installs an older k3sm over a newer one.",
                        "To match them, download the k3sm app for \(installed) from \(releasesURL).",
                    ],
                    primary: nil, terminalCommand: nil, opensLogs: false, offersRefresh: false)
            }
            return update(state: state, banner: banner, rootStep: rootStep, role: role, payload: payloadVersion, installed: installed)
        case .cliMissing:
            return repair(state: state, banner: banner, payload: payload, why: "/Library/k3sm is here, but the k3sm command in it is missing.")
        case .cliUntrusted(let why):
            return repair(state: state, banner: banner, payload: payload,
                          why: "The installed k3sm failed the app's check: \(StatusDisplay.clip(why)). The app runs nothing until it passes.")
        case .statusUnreadable:
            return GuidedPlan(
                state: state, banner: banner, bannerButton: "Read It Again…",
                title: "Read k3sm's status again",
                steps: [
                    "k3sm is installed, but `k3sm status` printed nothing this app could read.",
                    "Click Refresh to read it again.",
                    "If it still fails, open the logs to see why.",
                ],
                primary: .refresh, terminalCommand: nil, opensLogs: true, offersRefresh: false)
        }
    }

    /// The steps that confirm and authenticate a root step, or run it in Terminal.
    private static func rootSteps(_ action: GuidedAction, rootStep: Bool) -> [String] {
        if rootStep {
            return [
                "Click \(action.title) and confirm.",
                "Enter an administrator's name and password when macOS asks. The panel follows the step and says how it ended.",
            ]
        }
        return [
            "This build of k3sm is not Developer ID signed, so it cannot run the administrator step. Run the command below in Terminal.",
            "When it ends, click Refresh.",
        ]
    }

    private static func lifecycle(_ action: GuidedAction, state: HealthState, banner: String, rootStep: Bool, why: [String]) -> GuidedPlan {
        let command = action == .restart ? restartCommand : startCommand
        return GuidedPlan(
            state: state, banner: banner, bannerButton: action.title + "…",
            title: action.title,
            steps: why + rootSteps(action, rootStep: rootStep),
            primary: rootStep ? action : nil, terminalCommand: rootStep ? nil : command,
            opensLogs: false, offersRefresh: !rootStep)
    }

    private static func update(state: HealthState, banner: String, rootStep: Bool, role: NodeRole?,
                               payload: SemanticVersion, installed: SemanticVersion) -> GuidedPlan {
        var steps = ["This Mac runs k3sm \(installed); this app carries \(payload), a newer release."]
        if role == .server {
            steps.append("This Mac runs the control plane, so update every worker first.")
        }
        let command: String
        if role == .agent {
            command = managedUpdateCommand
        } else {
            command = installScriptCommand(version: payload)
        }
        if rootStep {
            steps += rootSteps(.update, rootStep: true)
        } else if role == .agent {
            steps += [
                "This build of k3sm is not Developer ID signed, so it cannot run the administrator step. Run the command below on the control-plane Mac; it updates every node, this one included.",
                "When it ends, click Refresh.",
            ]
        } else {
            steps += rootSteps(.update, rootStep: false)
        }
        return GuidedPlan(
            state: state, banner: banner, bannerButton: GuidedAction.update.title + "…",
            title: GuidedAction.update.title, steps: steps,
            primary: rootStep ? .update : nil, terminalCommand: rootStep ? nil : command,
            opensLogs: false, offersRefresh: !rootStep)
    }

    private static func repair(state: HealthState, banner: String, payload: SemanticVersion?, why: String) -> GuidedPlan {
        GuidedPlan(
            state: state, banner: banner, bannerButton: "How to Repair…",
            title: "Repair k3sm",
            steps: [
                why,
                "The app cannot repair this itself yet. Reinstall k3sm by running the command below in Terminal.",
                "On a worker, rejoin instead, as k3sm's multi-node guide describes.",
                "When it ends, click Refresh.",
            ],
            primary: nil, terminalCommand: installScriptCommand(version: payload),
            opensLogs: false, offersRefresh: true)
    }
}

/// GuidedUpdateBlock is why the panel's Update cannot run yet, from the same
/// decision the status popover's update follows.
public enum GuidedUpdateBlock: Equatable, Sendable {
    /// The role or the release the app carries is unknown.
    case unknown
    /// These workers run an older release and update first.
    case waitForWorkers([String])
    /// The control plane updates last; the user confirms the workers first.
    case confirmWorkers
    /// A worker whose control-plane address could not be read.
    case joinTargetUnknown
    /// The release this app carries is not newer than the installed one.
    case notNewer

    /// The line the panel shows under the disabled Update.
    public var text: String {
        switch self {
        case .unknown:
            return "k3sm cannot tell this Mac's role or the release this app carries, so it cannot update from here."
        case .waitForWorkers(let names):
            return "Update these workers first: " + names.map(StatusDisplay.clip).joined(separator: ", ") + "."
        case .confirmWorkers:
            return "Confirm below that every worker already runs the new release."
        case .joinTargetUnknown:
            return "The control-plane address this worker joins could not be read from its LaunchDaemon, so update it in Terminal."
        case .notNewer:
            return "The release this app carries is not newer than the installed one, so there is nothing to update."
        }
    }
}

/// GuidedRun is the guided panel's step as it runs: idle, running, or
/// finished with a plain success or failure line and the step's own message.
public enum GuidedRun: Equatable, Sendable {
    case idle
    case running(GuidedAction)
    case finished(GuidedAction, succeeded: Bool, message: String)

    /// Whether a step is running.
    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    /// The line the panel ends on, nil before a step finished. The message
    /// passes `StatusDisplay.errorText`, since a step's message can carry
    /// the CLI's words.
    public var line: String? {
        guard case .finished(_, let succeeded, let message) = self else { return nil }
        let text = StatusDisplay.errorText(message)
        let head = succeeded ? "Done" : "Failed"
        return text.isEmpty ? head + "." : head + ": " + text
    }
}
