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
/// NSWorkspace on k3sm's fixed paths, never a shell; the status view and the
/// bug report are static `.command` files written into a fresh 0700
/// directory and opened in Terminal.
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

    /// Opens `k3sm status` in Terminal, only for a CLI that passes its trust
    /// check just now.
    static func openStatus() {
        Task {
            if case .refused(let why) = await trustNow() {
                AppModel.alert(title: "k3sm will not run the installed k3sm", text: "It failed the app's check: \(why).")
                return
            }
            openCommand(StatusCommand.commandText, named: StatusCommand.commandName)
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
