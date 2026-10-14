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

/// LifecyclePrecondition decides, from a status report read just now,
/// whether a verb may go ahead. The state the user acted on and the live
/// state must agree, and the live state must be the verb's starting state;
/// anything else, an unreadable report included, refuses with nothing done.
public enum LifecyclePrecondition {
    public enum Verdict: Equatable, Sendable {
        case proceed
        case refused(String)
    }

    public static func check(_ verb: LifecycleVerb, expected: LifecycleState, live: LifecycleState) -> Verdict {
        guard let required = verb.requiredState else {
            return .refused("\(verb.title) is not a lifecycle verb. Nothing was changed.")
        }
        if live == .unreadable {
            return .refused("k3sm could not read the status of this Mac just now, so it did not \(verb.rawValue) k3sm.")
        }
        guard live == expected else {
            return .refused("k3sm is \(live.word) now, not \(expected.word) as it was when you chose \(verb.title). Nothing was changed.")
        }
        guard live == required else {
            return .refused("k3sm is \(live.word), so there is nothing to \(verb.rawValue). Nothing was changed.")
        }
        return .proceed
    }
}

/// LifecycleConfirmation is the question the app asks before the
/// administrator prompt: it names the verb and, for Stop, carries the
/// multi-node warning.
public struct LifecycleConfirmation: Equatable, Sendable {
    public let verb: LifecycleVerb
    public let title: String
    public let message: String
    /// The multi-node warning, shown with emphasis; nil when none applies.
    public let warning: String?
    /// Whether Cancel, not the verb, is the default button.
    public let cancelIsDefault: Bool

    public init(verb: LifecycleVerb, report: StatusReport) {
        self.verb = verb
        cancelIsDefault = verb == .lanOn
        switch verb {
        case .stop:
            title = "Stop k3sm on this Mac?"
            message = "Every pod on this Mac stops, and k3sm stays stopped, across restarts too, until you start it."
                + (NodeRole.detect(in: report) == .agent
                    ? " Pods move to other nodes after the cluster's eviction timeouts; pods with node-bound volumes stay down until you start this Mac again."
                    : "")
            warning = StopWarning.text(report)
        case .start:
            title = "Start k3sm on this Mac?"
            message = "k3sm starts its daemons again and clears the recorded stop."
            warning = nil
        case .restart:
            title = "Restart k3sm on this Mac?"
            message = "k3sm restarts its daemons. Pods keep running."
            warning = nil
        case .lanOn:
            title = LANConfirmationText.title
            message = LANConfirmationText.reachable(report.network) + "\n\n" + LANConfirmationText.notCovered(report.network)
            warning = nil
        case .lanOff:
            title = "Stop allowing connections from other devices?"
            message = "Workload listeners answer only on this Mac and your cluster mesh."
            warning = nil
        }
    }
}

/// StopWarning is the multi-node warning for stopping this Mac, read from the
/// live report's `workers` list: a server with joined nodes halts their
/// control plane, and a server whose list is unknown cannot say it has none.
/// A worker, or a server whose list is empty, gets no warning.
public enum StopWarning {
    /// The most node names the warning lists.
    public static let maxNames = 5

    public static func text(_ report: StatusReport) -> String? {
        switch NodeRole.detect(in: report) {
        case .agent:
            return nil
        case .server:
            guard let workers = report.workers else { return unknown }
            guard !workers.isEmpty else { return nil }
            let names = workers.prefix(maxNames).map { StatusDisplay.clip($0.name) }
            let more = workers.count > maxNames ? " and \(workers.count - maxNames) more" : ""
            let count = workers.count == 1 ? "1 other node has" : "\(workers.count) other nodes have"
            return "\(count) joined this server (\(names.joined(separator: ", "))\(more)). Stopping it halts the cluster's control plane: they lose the API server until you start this Mac again."
        case nil:
            return unknown
        }
    }

    static let unknown = "k3sm cannot tell whether other nodes have joined this Mac's cluster. If this Mac is a server with joined workers, stopping it halts the control plane for all of them until you start it again."
}

/// LifecycleDriver runs one lifecycle verb from a click to its outcome:
/// re-read the status live and refuse a changed state, ask the user (naming
/// the verb, with the Stop warning from the live workers list), re-read the
/// status again and refuse if it changed while the question was open, and
/// only then hand the lifecycle script to the administrator prompt. Every
/// run is a fresh prompt; nothing is remembered between runs.
public struct LifecycleDriver: Sendable {
    public enum Result: Equatable, Sendable {
        /// The verb was refused before any prompt; the sentence says why.
        case refused(String)
        /// The user answered no to the confirmation.
        case declined
        /// The administrator prompt ran; the sentence is the outcome.
        case ran(PrivilegedOutcome, String)
    }

    let teamID: TeamID
    let readStatus: @Sendable () async -> StatusReport?
    let confirm: @MainActor @Sendable (LifecycleConfirmation) async -> Bool
    let runner: any PrivilegedRunner

    public init(
        teamID: TeamID,
        readStatus: @escaping @Sendable () async -> StatusReport?,
        confirm: @escaping @MainActor @Sendable (LifecycleConfirmation) async -> Bool,
        runner: any PrivilegedRunner
    ) {
        self.teamID = teamID
        self.readStatus = readStatus
        self.confirm = confirm
        self.runner = runner
    }

    public func perform(_ verb: LifecycleVerb, expected: LifecycleState) async -> Result {
        guard !verb.isLAN else { return .refused("\(verb.title) is not a lifecycle verb. Nothing was changed.") }
        let first = await readStatus()
        if case .refused(let why) = LifecyclePrecondition.check(verb, expected: expected, live: LifecycleState(report: first)) {
            return .refused(why)
        }
        guard let first else { return .refused("k3sm could not read the status of this Mac just now.") }
        guard await confirm(LifecycleConfirmation(verb: verb, report: first)) else {
            return .declined
        }
        let second = await readStatus()
        if case .refused(let why) = LifecyclePrecondition.check(verb, expected: expected, live: LifecycleState(report: second)) {
            return .refused(why)
        }
        let outcome = await runner.runAsRoot(LifecycleScriptBuilder.render(verb, teamID: teamID), input: nil)
        return .ran(outcome, LifecycleOutcome.text(outcome, verb: verb))
    }
}

/// InstalledCLITrust is whether the app will run the installed CLI as root,
/// or ask it which verbs it has: the same checks the lifecycle script makes,
/// done by the app before either.
public enum InstalledCLITrust: Equatable, Sendable {
    case trusted
    case refused(String)

    /// PathFacts is what `lstat` says about one checked path.
    public struct PathFacts: Equatable, Sendable {
        public let isSymlink: Bool
        public let isDirectory: Bool
        public let isRegularFile: Bool
        public let ownerUID: UInt32
        /// The permission bits (`st_mode & 0o7777`).
        public let mode: UInt16
        /// Whether the path carries an extended ACL with any entry.
        public let hasACL: Bool

        public init(isSymlink: Bool, isDirectory: Bool, isRegularFile: Bool, ownerUID: UInt32, mode: UInt16, hasACL: Bool = false) {
            self.isSymlink = isSymlink
            self.isDirectory = isDirectory
            self.isRegularFile = isRegularFile
            self.ownerUID = ownerUID
            self.mode = mode
            self.hasACL = hasACL
        }
    }

    /// Decides trust from `lstat` of every path in `checkedPaths` order (nil
    /// for a path that does not exist) and the binary's signature check. The
    /// first failing path names the reason.
    public static func evaluate(cliPath: String, facts: (String) -> PathFacts?, signatureValid: () -> Bool) -> InstalledCLITrust {
        for path in LifecycleScriptBuilder.checkedPaths(cliPath: cliPath) {
            guard let f = facts(path) else { return .refused("\(path) does not exist") }
            if f.isSymlink { return .refused("\(path) is a symlink") }
            if f.ownerUID != 0 || f.mode & 0o022 != 0 {
                return .refused("\(path) is not owned by root, or is writable by group or others")
            }
            if f.hasACL { return .refused("\(path) carries an ACL") }
            if path == cliPath, !f.isRegularFile { return .refused("\(path) is not a regular file") }
            if path != cliPath, !f.isDirectory { return .refused("\(path) is not a directory") }
        }
        return signatureValid() ? .trusted : .refused("the installed k3sm is not signed by the k3sm Developer ID")
    }
}

/// LifecycleSupport is whether the menu and the window offer Stop, Start and
/// Restart, and if not, the note the window shows. The installed CLI must
/// pass `InstalledCLITrust` before the app runs it at all; then the version
/// it reports must be one that has `k3sm stop`.
public enum LifecycleSupport: Equatable, Sendable {
    case available
    case unavailable(note: String)

    /// The last k3sm release without the lifecycle verbs. `k3sm stop`,
    /// `start` and `restart` ship in the release after it, so any version
    /// above it (its pre-releases included) has them.
    public static let lastReleaseWithout = SemanticVersion("0.1.7")!

    public static let developerBuildNote =
        "This build of k3sm is not Developer ID signed, so it cannot stop or start k3sm. Use `sudo k3sm stop` and `sudo k3sm start` in Terminal."

    /// Whether a version has the lifecycle verbs.
    public static func versionHasLifecycle(_ version: SemanticVersion) -> Bool {
        version > lastReleaseWithout
    }

    public static func evaluate(trust: InstalledCLITrust, version: SemanticVersion?) -> LifecycleSupport {
        if case .refused(let why) = trust {
            return .unavailable(note: "The app will not run the installed k3sm as root: \(why). Use `sudo k3sm stop` in Terminal.")
        }
        guard let version else {
            return .unavailable(note: "k3sm could not read the installed version, so Stop and Start are available only in Terminal: `sudo k3sm stop`, `sudo k3sm start`.")
        }
        guard versionHasLifecycle(version) else {
            return .unavailable(note: "The installed k3sm (\(version)) has no stop command. Update k3sm to stop and start it from the app.")
        }
        return .available
    }
}

/// TrustedCLI runs the installed CLI, unprivileged, only after a fresh trust
/// check made immediately before that run. No verdict is cached: a CLI that
/// passed once and was then replaced, re-owned or given an ACL is refused on
/// its next run, not trusted on the strength of the earlier check.
public struct TrustedCLI<Output: Sendable>: Sendable {
    public enum Result: Sendable {
        case ran(Output)
        case refused(String)
    }

    let check: @Sendable () async -> InstalledCLITrust
    let execute: @Sendable ([String]) async -> Output

    public init(check: @escaping @Sendable () async -> InstalledCLITrust, execute: @escaping @Sendable ([String]) async -> Output) {
        self.check = check
        self.execute = execute
    }

    /// Checks, then runs; a refusal runs nothing.
    public func run(_ arguments: [String]) async -> Result {
        switch await check() {
        case .trusted:
            return .ran(await execute(arguments))
        case .refused(let why):
            return .refused(why)
        }
    }
}
