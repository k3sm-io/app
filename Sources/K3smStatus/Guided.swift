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

/// GuidedAction is a step a guided panel offers. Start and Restart run the
/// existing lifecycle verbs, Update whatever the one update plan
/// (`UpdatePlan`) runs (the app-carried update or the managed roll), Repair
/// the install again from the app's payload, all through the checked root
/// step; Refresh reads the status again.
public enum GuidedAction: String, CaseIterable, Equatable, Sendable {
    case start
    case restart
    case update
    case repair
    case refresh

    /// The panel's primary button.
    public var title: String {
        switch self {
        case .start: return "Start k3sm"
        case .restart: return "Restart k3sm"
        case .update: return "Update k3sm"
        case .repair: return "Repair k3sm"
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
    /// A second step beside the primary (Repair, beside Start or Restart on
    /// a partly running Mac); nil when there is none.
    public let secondary: GuidedAction?
    /// The exact command to run in Terminal, shown with a Copy button: in a
    /// developer build in place of a root step, and for a missing or
    /// untrusted command when the app cannot run Repair.
    public let terminalCommand: String?
    /// The `.command` script Run in Terminal opens for an install command
    /// (`TerminalScript.install`), nil for every other command.
    public let terminalScript: String?
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
/// | partly running, either (beside the primary) | Repair | none |
/// | command missing or untrusted | Repair | the install script in Terminal, then Refresh |
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

    /// The install script's command line, pinned to `version` when it is a
    /// release (a repair pins the release; an unpinned run installs the
    /// latest). A development build's `0.0.0` names no release, so it pins
    /// nothing (`releasePin`).
    public static func installScriptCommand(version: SemanticVersion?) -> String {
        guard let version = releasePin(version) else { return "curl -fsSL \(installScriptURL) | sh" }
        return "curl -fsSL \(installScriptURL) | K3SM_INSTALL_VERSION=v\(version) sh"
    }

    /// The release `version` names, nil for none and for `0.0.0`, which a
    /// development build carries in place of a release (`AppVersion`): no
    /// release of that number exists to download.
    public static func releasePin(_ version: SemanticVersion?) -> SemanticVersion? {
        guard let version, version != SemanticVersion("0.0.0") else { return nil }
        return version
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
    /// `payloadCLI` is the k3sm inside the app's payload, which a Terminal
    /// install runs in place of the install script when the bundle has one.
    public static func plan(for state: HealthState, rootStep: Bool, role: NodeRole?, payload: SemanticVersion?,
                            payloadCLI: TerminalScript.Payload? = nil) -> GuidedPlan? {
        guard let banner = state.line, !state.showsFirstRun else { return nil }
        switch state {
        case .notInstalled, .healthy:
            return nil
        case .installedStopped:
            return lifecycle(.start, state: state, banner: banner, rootStep: rootStep, repair: false, why: [
                "k3sm is stopped, so this Mac runs no pods and serves nothing. It stays stopped until it is started.",
            ])
        case .partlyRunning(let down):
            let action = partlyRunningAction(down: down)
            let labels = down.map(StatusDisplay.clip).joined(separator: " and ")
            let what = labels.isEmpty ? "Part of k3sm is not running." : "\(labels) \(down.count == 1 ? "is" : "are") not running, so k3sm is only partly up."
            return lifecycle(action, state: state, banner: banner, rootStep: rootStep,
                             repair: rootStep && payload != nil, why: [what])
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
                    primary: nil, secondary: nil, terminalCommand: nil, terminalScript: nil, opensLogs: false, offersRefresh: false)
            }
            return update(state: state, banner: banner, rootStep: rootStep, role: role, payload: payloadVersion, installed: installed,
                          payloadCLI: payloadCLI)
        case .cliMissing:
            return repair(state: state, banner: banner, rootStep: rootStep, role: role, payload: payload, payloadCLI: payloadCLI,
                          why: "/Library/k3sm is here, but the k3sm command in it is missing.")
        case .cliUntrusted(let why):
            return repair(state: state, banner: banner, rootStep: rootStep, role: role, payload: payload, payloadCLI: payloadCLI,
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
                primary: .refresh, secondary: nil, terminalCommand: nil, terminalScript: nil, opensLogs: true, offersRefresh: false)
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

    /// Whether the panel offers Run in Terminal for its install command:
    /// only in a build that cannot run the root step, and only on a known
    /// server. The install is a plain `k3sm install`, a server's install; on
    /// a worker, or a Mac whose role is unknown, it could start a second
    /// cluster, so those keep the command to read and the rejoin line.
    public static func runsInTerminal(rootStep: Bool, role: NodeRole?) -> Bool {
        !rootStep && role == .server
    }

    /// The line a partly running Mac's panel adds when it offers Repair.
    public static let repairBesideLine =
        "If it does not come back, click Repair k3sm: it installs this app's release again over this one and keeps the cluster's data."

    /// The line that says what Repair does, on the panel that offers it first.
    public static let repairWhatLine =
        "Repair installs the k3sm release this app carries again, in the role this Mac already has, and keeps the cluster's data."

    private static func lifecycle(_ action: GuidedAction, state: HealthState, banner: String, rootStep: Bool,
                                  repair: Bool, why: [String]) -> GuidedPlan {
        let command = action == .restart ? restartCommand : startCommand
        return GuidedPlan(
            state: state, banner: banner, bannerButton: action.title + "…",
            title: action.title,
            steps: why + rootSteps(action, rootStep: rootStep) + (repair ? [repairBesideLine] : []),
            primary: rootStep ? action : nil, secondary: repair ? .repair : nil,
            terminalCommand: rootStep ? nil : command, terminalScript: nil,
            opensLogs: false, offersRefresh: !rootStep)
    }

    private static func update(state: HealthState, banner: String, rootStep: Bool, role: NodeRole?,
                               payload: SemanticVersion, installed: SemanticVersion, payloadCLI: TerminalScript.Payload?) -> GuidedPlan {
        var steps = ["This Mac runs k3sm \(installed); this app carries \(payload), a newer release."]
        if role == .server {
            steps.append("This Mac runs the control plane, so update every worker first.")
        }
        let command: String
        var script: String?
        if role == .agent {
            command = managedUpdateCommand
        } else {
            command = TerminalScript.installCommand(version: payload, payload: payloadCLI)
            script = runsInTerminal(rootStep: rootStep, role: role)
                ? TerminalScript.install(version: payload, payload: payloadCLI) : nil
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
            primary: rootStep ? .update : nil, secondary: nil, terminalCommand: rootStep ? nil : command,
            terminalScript: script, opensLogs: false, offersRefresh: !rootStep)
    }

    /// The plan for a missing or untrusted command: Repair, the install run
    /// again from the app's verified payload, when this build can run the
    /// root step and knows the release it carries; else the install script
    /// in Terminal, then Refresh.
    private static func repair(state: HealthState, banner: String, rootStep: Bool, role: NodeRole?, payload: SemanticVersion?,
                               payloadCLI: TerminalScript.Payload?, why: String) -> GuidedPlan {
        if rootStep, payload != nil {
            return GuidedPlan(
                state: state, banner: banner, bannerButton: GuidedAction.repair.title + "…",
                title: GuidedAction.repair.title,
                steps: [why, repairWhatLine] + rootSteps(.repair, rootStep: true),
                primary: .repair, secondary: nil, terminalCommand: nil, terminalScript: nil,
                opensLogs: false, offersRefresh: false)
        }
        let first = rootStep
            ? "The release this app carries is unknown, so it cannot repair k3sm itself. Reinstall k3sm by running the command below in Terminal."
            : "This build of k3sm is not Developer ID signed, so it cannot run the administrator step. Reinstall k3sm by running the command below in Terminal."
        return GuidedPlan(
            state: state, banner: banner, bannerButton: "How to Repair…",
            title: GuidedAction.repair.title,
            steps: [
                why,
                first,
                "On a worker, rejoin instead, as k3sm's multi-node guide describes.",
                "When it ends, click Refresh.",
            ],
            primary: nil, secondary: nil,
            terminalCommand: TerminalScript.installCommand(version: payload, payload: payloadCLI),
            terminalScript: runsInTerminal(rootStep: rootStep, role: role)
                ? TerminalScript.install(version: payload, payload: payloadCLI) : nil,
            opensLogs: false, offersRefresh: true)
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
