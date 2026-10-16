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

import AppKit
import K3smInstall
import K3smStatus

/// MenuActions are the menu's unprivileged actions. Logs open through
/// NSWorkspace on k3sm's fixed paths, never a shell; the live status and top
/// views and the bug report are static `.command` files, and a pod's shell a
/// `.command` built from checked names, written into a fresh
/// 0700 directory and opened in Terminal.
@MainActor
enum MenuActions {
    static let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")

    /// Opens the logs this account can read, the node daemon's first.
    static func openLogs(role: NodeRole?) {
        let readable = K3smLogs.paths(for: role).filter { FileManager.default.isReadableFile(atPath: $0) }
        guard !readable.isEmpty else {
            AppModel.alert(title: "No k3sm log to open", text: "No k3sm log under \(K3smLogs.directory) is readable by this account.")
            return
        }
        for path in readable {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
        log.notice("menu: opened logs")
    }

    /// The installed CLI's trust, checked now (never a cached verdict).
    private static func trustNow() async -> InstalledCLITrust {
        let team = SelfCheck.teamID()
        return await Task.detached { SelfCheck.installedCLITrust(team: team) }.value
    }

    /// Opens one live view in Terminal, only for a CLI that passes its trust
    /// check just now.
    static func openLive(_ view: LiveView) {
        Task {
            if case .refused(let why) = await trustNow() {
                AppModel.alert(title: "k3sm will not run the installed k3sm", text: "It failed the app's check: \(why).")
                return
            }
            switch view {
            case .status: openCommand(StatusCommand.commandText, named: StatusCommand.commandName)
            case .top: openCommand(TopCommand.commandText, named: TopCommand.commandName)
            }
            log.notice("menu: opened \(view.rawValue, privacy: .public) live view")
        }
    }

    /// The Live Top answer kept for the installed CLI binary.
    private static var topCache = LiveTopProbe.Cache()

    /// Whether the installed CLI offers the top view: the kept answer for this
    /// binary, or one `k3sm status top --help` run through the trust check.
    /// Only the exit status is read; the output is discarded.
    static func liveTopOffered() async -> Bool {
        let identity = cliIdentity()
        if let kept = topCache.offered(for: identity) {
            return kept
        }
        let team = SelfCheck.teamID()
        let environment = SelfCheck.cliEnvironment()
        let cli = TrustedCLI<CLIOutcome>(
            check: { await Task.detached { SelfCheck.installedCLITrust(team: team) }.value },
            execute: { arguments in
                await CLIProcess.run(path: K3smCLI.path, arguments: arguments, environment: environment,
                                     deadline: PollSchedule.killDeadline, limit: OutputLimit.detail)
            })
        let outcome: LiveTopProbe.Outcome
        switch await cli.run(LiveTopProbe.arguments) {
        case .ran(.exited(let status, _)): outcome = .exited(status)
        default: outcome = .noAnswer
        }
        return topCache.record(outcome, for: identity)
    }

    /// The installed CLI binary's identity, or nil when it cannot be read.
    private static func cliIdentity() -> LiveTopProbe.Identity? {
        var st = stat()
        guard lstat(K3smCLI.path, &st) == 0 else { return nil }
        return LiveTopProbe.Identity(
            device: Int64(st.st_dev), inode: UInt64(st.st_ino), size: Int64(st.st_size),
            modified: Int64(st.st_mtimespec.tv_sec), modifiedNanos: Int64(st.st_mtimespec.tv_nsec),
            changed: Int64(st.st_ctimespec.tv_sec), changedNanos: Int64(st.st_ctimespec.tv_nsec))
    }

    /// Opens a shell in one container of a pod in Terminal
    /// (`PodShellCommand`), only for a CLI that passes its trust check just
    /// now. The CLI runs there as the user, under `env -i`.
    static func openShell(_ shell: PodShell) {
        Task {
            if case .refused(let why) = await trustNow() {
                let alert = PodShell.refusedAlert(why: why)
                AppModel.alert(title: alert.title, text: alert.text)
                return
            }
            openCommand(PodShellCommand.commandText(shell), named: PodShellCommand.commandName)
            log.notice("console: open-shell opened")
        }
    }

    /// Writes a bug report: Terminal runs the collector, which writes the
    /// report beside itself and opens it for review. Nothing is uploaded. A
    /// CLI that fails its trust check is left out of the report, not run.
    static func writeBugReport() {
        Task {
            let trusted = await trustNow() == .trusted
            openCommand(BugReport.commandText(cliTrusted: trusted), named: BugReport.commandName)
            log.notice("menu: bug report collector opened")
        }
    }

    private static func openCommand(_ text: String, named name: String) {
        let path: String
        do {
            path = try CommandFile.write(text, named: name, under: NSTemporaryDirectory())
        } catch {
            AppModel.alert(title: "k3sm could not write \(name)", text: "The temporary folder is not writable.")
            return
        }
        NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }
}
