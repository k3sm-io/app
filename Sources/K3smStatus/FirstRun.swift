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

/// FirstRunPath is the first run's one question: start a cluster on this
/// Mac, or join one that runs.
public enum FirstRunPath: String, CaseIterable, Equatable, Sendable {
    case start
    case join

    /// The choice as the first step lists it.
    public var title: String {
        switch self {
        case .start: return "Start a cluster on this Mac"
        case .join: return "Join a cluster"
        }
    }

    /// The line under the choice.
    public var detail: String {
        switch self {
        case .start: return "This Mac runs the control plane and its own pods. Other Macs can join it later."
        case .join: return "This Mac joins a cluster another Mac runs, as a worker. You need that Mac's address and a join token."
        }
    }
}

/// FirstRunStep is one screen of the guided first run.
public enum FirstRunStep: String, CaseIterable, Equatable, Sendable {
    /// Start a cluster, or join one.
    case choose
    /// Join only: paste the server's address and the join token.
    case join
    /// What will happen, and the administrator prompt (or, in a developer
    /// build, the exact Terminal command).
    case review
    /// The install running through the checked root step, each phase named.
    case install
    /// Done (the console opens on the new state), or a plain failure.
    case finished

    /// The step's name in the step list.
    public var title: String {
        switch self {
        case .choose: return "Choose"
        case .join: return "Join Details"
        case .review: return "Review"
        case .install: return "Install"
        case .finished: return "Done"
        }
    }
}

/// FirstRunReview is the review step: a title, what will happen, and either
/// the button that asks for an administrator (the checked root step) or, in a
/// developer build, the exact command to run in Terminal.
public struct FirstRunReview: Equatable, Sendable {
    public let title: String
    /// What will happen, in order.
    public let lines: [String]
    /// The button that runs the install; nil in a developer build.
    public let installButton: String?
    /// The exact Terminal command, shown with Copy Command and Open
    /// Terminal; set only in a developer build. It never carries the token.
    public let terminalCommand: String?
}

/// FirstRunInstallPhase is one named phase of the install as it runs, read
/// from the copy-out log's own progress lines.
public enum FirstRunInstallPhase: Int, CaseIterable, Comparable, Sendable {
    /// macOS asks for an administrator's name and password.
    case authenticate
    /// The root step clears old staging entries.
    case sweep
    /// It copies the app out to a root-owned staging directory.
    case copy
    /// It checks the copy's Developer ID signature.
    case verify
    /// The staged k3sm installs (and, for a join, joins the cluster).
    case install

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// The copy-out log line that begins the phase; nil for the
    /// administrator prompt, which writes no line. The script writes these
    /// (`RootScriptBuilder`), and a test pins the two together.
    public var marker: String? {
        switch self {
        case .authenticate: return nil
        case .sweep: return "copy-out: sweeping stale staging entries"
        case .copy: return "copy-out: copying the app bundle"
        case .verify: return "copy-out: verifying the signature"
        case .install: return "copy-out: running k3sm install"
        }
    }

    /// The phase's name in the progress list.
    public func title(for path: FirstRunPath) -> String {
        switch self {
        case .authenticate: return "Authenticate as an administrator"
        case .sweep: return "Clear old staging files"
        case .copy: return "Copy k3sm out of the app"
        case .verify: return "Check the copy's Developer ID signature"
        case .install: return path == .join ? "Install k3sm and join the cluster" : "Install and start k3sm"
        }
    }
}

/// FirstRunPhaseState is where one phase stands in the progress list.
public enum FirstRunPhaseState: Equatable, Sendable {
    case pending
    case active
    case done
    case failed
}

/// FirstRunPhaseRow is one line of the install step's progress list.
public struct FirstRunPhaseRow: Equatable, Sendable {
    public let phase: FirstRunInstallPhase
    public let title: String
    public let state: FirstRunPhaseState
}

/// FirstRunOutcome is how the install ended.
public enum FirstRunOutcome: Equatable, Sendable {
    case succeeded
    /// The app's sentence for the failure (`OutcomeSummary`).
    case failed(String)
}

/// FirstRunFinish is the finished step: a title, the lines under it, and its
/// one button.
public struct FirstRunFinish: Equatable, Sendable {
    public let succeeded: Bool
    public let title: String
    public let lines: [String]
    /// "Open Console" after a success, "Try Again" after a failure.
    public let button: String
}

/// FirstRunFlow is the guided first run, pure: which steps a path takes, how
/// Continue and Back move between them, the review step's text, the install's
/// progress from the copy-out log, and the finished step. The app holds the
/// current step and the fields; this decides.
///
/// | path | steps |
/// |---|---|
/// | start | choose, review, install, finished |
/// | join | choose, join, review, install, finished |
///
/// A developer build (no Team ID pin) cannot run the checked root step, so
/// its review step shows the exact Terminal command and no install button,
/// and the flow stops there.
public enum FirstRunFlow {
    /// The documented install script (the script channel).
    public static let installScriptURL = GuidedSteps.installScriptURL
    /// Where the documented join puts the token: a file only root can read.
    public static let joinTokenFile = "/var/root/k3sm-join-token"
    /// The administrator prompt's own words.
    static let promptLine = "macOS asks for an administrator's name and password once. The install runs as root through the app's checked step."

    /// The steps `path` takes, in order.
    public static func steps(for path: FirstRunPath) -> [FirstRunStep] {
        switch path {
        case .start: return [.choose, .review, .install, .finished]
        case .join: return [.choose, .join, .review, .install, .finished]
        }
    }

    /// The step Continue leads to from `step`, nil where Continue is not
    /// offered: the review step's button is the install itself, and the last
    /// two steps move on their own.
    public static func next(after step: FirstRunStep, path: FirstRunPath) -> FirstRunStep? {
        switch step {
        case .choose: return path == .join ? .join : .review
        case .join: return path == .join ? .review : nil
        case .review, .install, .finished: return nil
        }
    }

    /// The step Back leads to, nil where Back is not offered (the first
    /// step, and while the install runs or after it ended).
    public static func previous(before step: FirstRunStep, path: FirstRunPath) -> FirstRunStep? {
        switch step {
        case .choose, .install, .finished: return nil
        case .join: return .choose
        case .review: return path == .join ? .join : .choose
        }
    }

    /// The step Try Again leads to after a failure: the review for a start,
    /// the join step for a join, since the token was handed to the failed
    /// run and is pasted again (a join token expires in minutes).
    public static func retryStep(for path: FirstRunPath) -> FirstRunStep {
        path == .join ? .join : .review
    }

    /// The review step for `path`. `server` is the validated join address
    /// as shown (`host:port`) and `serverArgument` the host the CLI takes;
    /// both are nil for a start. `developerBuild` is a build with no Team ID
    /// pin; `payload` the release the app carries.
    public static func review(path: FirstRunPath, server: String?, serverArgument: String?,
                              developerBuild: Bool, payload: SemanticVersion?) -> FirstRunReview {
        let release = payload.map { "k3sm \($0)" } ?? "k3sm"
        var lines: [String]
        switch path {
        case .start:
            lines = [
                "This Mac becomes a k3sm server: \(release) is installed in /Library/k3sm and its daemons start now and at every boot.",
                "Your account gets an admin kubeconfig in ~/.kube/config.",
            ]
        case .join:
            let at = server.map { " at \(StatusDisplay.clip($0))" } ?? ""
            lines = [
                "This Mac joins the cluster\(at) as a worker: \(release) is installed in /Library/k3sm and its daemons start now and at every boot.",
                "The join token goes to the administrator step on its input, never on a command line, and is deleted when the step ends.",
            ]
        }
        lines.append("Pods on one Mac share one trust domain. Run untrusted workloads in the vm runtime class.")
        guard developerBuild else {
            lines.append(promptLine)
            return FirstRunReview(title: "Review and install", lines: lines,
                                  installButton: path == .join ? "Join Cluster…" : "Start Cluster…",
                                  terminalCommand: nil)
        }
        lines.append("This build of k3sm is not Developer ID signed, so it cannot run the administrator step. Run the command below in Terminal instead.")
        if path == .join {
            lines.append("When the third line waits, paste the join token, press Return, then Control-D.")
        }
        lines.append("When it ends, reopen this window.")
        return FirstRunReview(title: "Install in Terminal", lines: lines, installButton: nil,
                              terminalCommand: terminalCommand(path: path, serverArgument: serverArgument, payload: payload))
    }

    /// The exact Terminal command a developer build shows: the install script
    /// for a start; for a join, the script's download-only mode, the token
    /// written to a root-only file, and the documented agent install from the
    /// downloaded release. Nil for a join whose host is missing or holds a
    /// character outside the address grammar. The token is never in it.
    public static func terminalCommand(path: FirstRunPath, serverArgument: String?, payload: SemanticVersion?) -> String? {
        switch path {
        case .start:
            return GuidedSteps.installScriptCommand(version: payload)
        case .join:
            guard let host = serverArgument, !host.isEmpty, host.utf8.count <= 253,
                  host.utf8.allSatisfy(JoinCommandParser.isAddressByte) else { return nil }
            let pin = payload.map { "K3SM_INSTALL_VERSION=v\($0) " } ?? ""
            let archive = payload.map { "k3sm_\($0)_darwin_arm64.tar.gz" } ?? "k3sm_*_darwin_arm64.tar.gz"
            return [
                "curl -fsSL \(installScriptURL) | \(pin)K3SM_INSTALL_DOWNLOAD_ONLY=1 sh",
                "tar -xzf \(archive)",
                "sudo sh -c 'umask 077; cat > \(joinTokenFile)'",
                "sudo ./k3sm install --agent --server \(host) --token-file \(joinTokenFile)",
            ].joined(separator: "\n")
        }
    }

    /// The phase the copy-out log has reached. While the install runs, a log
    /// that already ends on `copy-out: exit` is the last run's (the new run
    /// clears it only once an administrator has authenticated), so it counts
    /// as the administrator prompt.
    public static func phase(log: String) -> FirstRunInstallPhase {
        let last = log.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
        if let last, last.hasPrefix(exitPrefix) { return .authenticate }
        return finishedPhase(log: log)
    }

    /// The copy-out log's last line prefix (`CopyOutOutcome`).
    public static let exitPrefix = "copy-out: exit "

    /// The progress list: every phase before the reached one done, the
    /// reached one active (failed after a failure), the rest pending; all
    /// done after a success. `outcome` is nil while the install runs.
    public static func progress(path: FirstRunPath, log: String, outcome: FirstRunOutcome?) -> [FirstRunPhaseRow] {
        let reached: FirstRunInstallPhase
        if outcome == nil {
            reached = phase(log: log)
        } else {
            reached = finishedPhase(log: log)
        }
        return FirstRunInstallPhase.allCases.map { phase in
            let state: FirstRunPhaseState
            switch outcome {
            case .succeeded?:
                state = .done
            case .failed?:
                state = phase < reached ? .done : (phase == reached ? .failed : .pending)
            case nil:
                state = phase < reached ? .done : (phase == reached ? .active : .pending)
            }
            return FirstRunPhaseRow(phase: phase, title: phase.title(for: path), state: state)
        }
    }

    /// The furthest phase whose marker the log holds.
    static func finishedPhase(log: String) -> FirstRunInstallPhase {
        var reached = FirstRunInstallPhase.authenticate
        for line in log.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            for phase in FirstRunInstallPhase.allCases where phase > reached {
                if let marker = phase.marker, text.hasPrefix(marker) { reached = phase }
            }
        }
        return reached
    }

    /// The failing command's own last words in a finished copy-out log: the
    /// last line before `copy-out: exit` that is not one of the step's own
    /// progress lines, through `StatusDisplay.errorText`; nil when none.
    public static func commandMessage(log: String) -> String? {
        let lines = log.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        for line in lines.reversed() where !line.isEmpty && !line.hasPrefix(exitPrefix) {
            if line.hasPrefix("copy-out: ") && !line.hasPrefix("copy-out: refused") && line != "copy-out: no join token arrived" {
                return nil
            }
            let text = StatusDisplay.errorText(String(line))
            return text.isEmpty ? nil : StatusDisplay.clip(text)
        }
        return nil
    }

    /// The finished step. A success says the console opens on the new
    /// install; a failure carries the app's sentence (`OutcomeSummary`), the
    /// command's own message from the log, and for a join the fresh-token hint.
    public static func finish(path: FirstRunPath, outcome: FirstRunOutcome, log: String) -> FirstRunFinish {
        switch outcome {
        case .succeeded:
            return FirstRunFinish(
                succeeded: true,
                title: path == .join ? "This Mac joined the cluster" : "k3sm is running",
                lines: ["The console opens on the new install."],
                button: "Open Console")
        case .failed(let sentence):
            var lines = [StatusDisplay.errorText(sentence)]
            if let message = commandMessage(log: log) {
                lines.append("k3sm said: " + message)
            }
            if path == .join {
                lines.append("A join token expires in minutes. Mint a fresh one on the server with `sudo k3sm token create`, then paste the token again.")
            }
            return FirstRunFinish(succeeded: false, title: "k3sm was not installed", lines: lines, button: "Try Again")
        }
    }
}
