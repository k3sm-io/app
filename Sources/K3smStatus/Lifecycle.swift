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

/// LifecycleState is what a lifecycle verb needs to know about this Mac,
/// read from one status report: whether the node daemon serves, whether k3sm
/// is installed and idle, or whether the report could not be read at all.
/// Unknown verdict, state or role words never fail it: a report whose node
/// daemon row does not read `running` is `stopped` unless the verdict says
/// k3sm is not installed.
public enum LifecycleState: Equatable, Sendable {
    case running
    case stopped
    case notInstalled
    case unreadable

    /// Classifies a report; nil (no report, or one that did not decode) is
    /// `unreadable`.
    public init(report: StatusReport?) {
        guard let report else {
            self = .unreadable
            return
        }
        if report.nodeDaemonRunning {
            self = .running
        } else if report.verdict == .notInstalled {
            self = .notInstalled
        } else {
            self = .stopped
        }
    }

    /// The word a refusal message uses.
    public var word: String {
        switch self {
        case .running: return "running"
        case .stopped: return "stopped"
        case .notInstalled: return "not installed"
        case .unreadable: return "unreadable"
        }
    }
}

/// StoppedNotice is the notification the app posts at login while k3sm is
/// stopped: "k3sm is stopped (by you)" or "k3sm is stopped (auto on
/// <network>)", with a Start action. It is posted only for a login-item
/// launch, only when the node daemon is not running, and only when the CLI
/// recorded who stopped it (`stoppedBy`).
public enum StoppedNotice {
    /// The identifier of the notification's Start action.
    public static let startAction = "io.k3sm.app.start"
    /// The notification category that carries the Start action.
    public static let category = "io.k3sm.app.stopped"
    /// The body under the title.
    public static let body = "Start it from here or from the k3sm window."

    /// The notification title for this launch, or nil when none is due.
    public static func title(loginLaunch: Bool, report: StatusReport?) -> String? {
        guard loginLaunch, let report, LifecycleState(report: report) == .stopped, let sb = report.stoppedBy else {
            return nil
        }
        return title(for: sb)
    }

    /// The title for one recorded stop. The actor and phase words the app
    /// does not know get the plain form, never an error.
    ///
    /// The status JSON has no network field: an automatic stop's reason is
    /// shown as its network, clipped like every other CLI string.
    public static func title(for sb: StoppedBy) -> String {
        let head = sb.phase == "stopping" ? "k3sm is partly stopped" : "k3sm is stopped"
        switch sb.actor {
        case "user":
            return head + " (by you)"
        case "auto":
            let reason = StatusDisplay.clip(sb.reason.trimmingCharacters(in: .whitespaces))
            return reason.isEmpty ? head + " (auto)" : head + " (auto on \(reason))"
        default:
            return head
        }
    }
}

/// K3smLogs is the fixed set of log files the menu opens: the node daemon's
/// log for this Mac's role, netd's log, and the app's own copy-out log. The
/// node and netd logs are k3sm's (`pkg/install`: `LogDir`, group admin, files
/// 0640); the copy-out log is the app's. None of the paths comes from the
/// CLI's output.
public enum K3smLogs {
    public static let directory = "/var/log/k3sm"
    public static let netd = "/var/log/k3sm/netd.log"
    public static let copyOut = "/Library/Logs/k3sm/copy-out.log"

    /// The node daemon's log for a role.
    public static func node(_ role: NodeRole) -> String {
        switch role {
        case .server: return "/var/log/k3sm/server.log"
        case .agent: return "/var/log/k3sm/agent.log"
        }
    }

    /// The logs the menu opens for a role: the node daemon's first. With the
    /// role unknown, both node logs are candidates.
    public static func paths(for role: NodeRole?) -> [String] {
        let nodes = role.map { [node($0)] } ?? NodeRole.allCases.map(node)
        return nodes + [netd, copyOut]
    }
}
