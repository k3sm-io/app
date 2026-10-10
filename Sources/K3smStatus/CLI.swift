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

/// K3smCLI is how the app invokes the k3sm CLI: one absolute path, fixed
/// argument lists, and an environment the app builds itself. Nothing in the
/// user's own environment (PATH, KUBECONFIG, K3SM_WORK_DIR) reaches the CLI.
public enum K3smCLI {
    /// The installed CLI. The app never searches PATH for it.
    public static let path = "/Library/k3sm/k3sm"
    /// The install root. Its absence is the app's first-run state.
    public static let installRoot = "/Library/k3sm"
    /// The cheap visibility probe: launchd state only, no apiserver call.
    public static let probeArguments = ["status", "daemons", "-o", "json"]
    /// The full report, run only when the user looks at it.
    public static let reportArguments = ["status", "-o", "json"]
    /// The installed version, read on launch for the update check.
    public static let versionArguments = ["version"]
    /// The PATH every CLI run gets: system directories only.
    public static let systemPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    /// Builds the CLI's whole environment from the user's passwd entry. A home
    /// that is not an absolute path is replaced by /var/empty, so the CLI never
    /// resolves `~` against the working directory.
    public static func environment(home: String, user: String) -> [String: String] {
        let safeHome = home.hasPrefix("/") ? home : "/var/empty"
        return [
            "HOME": safeHome,
            "USER": user,
            "LOGNAME": user,
            "PATH": systemPath,
        ]
    }
}

/// PollSchedule is the visibility poll's cadence: 5 s while the status item is
/// shown, 15 s while it is hidden, and a 4 s deadline after which a run is
/// killed. The poller starts the next run only after the previous one exits.
public enum PollSchedule {
    public static let visibleInterval: Duration = .seconds(5)
    public static let hiddenInterval: Duration = .seconds(15)
    public static let killDeadline: Duration = .seconds(4)

    /// The wait before the next poll, chosen by whether the item is shown.
    public static func interval(visible: Bool) -> Duration {
        visible ? visibleInterval : hiddenInterval
    }
}

/// StatusDisplay limits how much status text the app renders. Every string
/// from the CLI is data: it is shown verbatim, with control characters
/// replaced, clipped to a fixed length, and capped to a fixed row count.
public enum StatusDisplay {
    public static let maxRows = 24
    public static let maxLength = 160

    /// Returns the text safe to show on one line: control characters become
    /// spaces and anything past `maxLength` characters becomes an ellipsis.
    public static func clip(_ text: String) -> String {
        let flat = String(text.map { $0.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) ? " " : $0 })
        guard flat.count > maxLength else { return flat }
        return String(flat.prefix(maxLength - 1)) + "…"
    }

    /// Returns at most `maxRows` rows with every field clipped.
    public static func rows(of report: StatusReport) -> [StatusRow] {
        report.rows.prefix(maxRows).map {
            StatusRow(name: clip($0.name), state: clip($0.state), detail: clip($0.detail))
        }
    }
}
