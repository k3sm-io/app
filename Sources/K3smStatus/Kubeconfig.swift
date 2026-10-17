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

/// KubeconfigFile is the Cluster pane's kubeconfig line: the admin
/// kubeconfig's path, with Copy (which copies the path, never the file's
/// contents) and Show in Finder. The app never opens the file: it only asks
/// whether it exists and whether this account may read it.
public struct KubeconfigFile: Equatable, Sendable {
    /// The path shown, clipped, or "Unknown".
    public let value: String
    /// What Copy puts on the clipboard, nil when there is no file to point at.
    public let copyText: String?
    /// The file Show in Finder selects, nil when there is none.
    public let revealPath: String?
    /// The line under the buttons, nil when there is nothing to explain.
    public let note: String?

    /// The note when no file is at the path.
    public static let missingNote = "There is no kubeconfig at this path. sudo k3sm install writes one for your account."
    /// The note when the file is there but this account cannot read it.
    public static let unreadableNote = "This account cannot read this file, so kubectl with it "
        + StatusDisplay.needsAdminText + "."

    public init(value: String, copyText: String?, revealPath: String?, note: String?) {
        self.value = value
        self.copyText = copyText
        self.revealPath = revealPath
        self.note = note
    }

    /// The admin kubeconfig's path: the one install recorded when the
    /// report carries it (the `admin-kubeconfig` row's `wide.kubeconfig`,
    /// only in an administrator's read, used only when it is an absolute
    /// path that clipping leaves unchanged), else `~/.kube/config` of this
    /// account, where `k3sm install --user` writes it. Nil without a home.
    public static func path(home: String?, report: StatusReport?) -> String? {
        if let recorded = report?.row(named: "admin-kubeconfig")?.wide["kubeconfig"],
           recorded.hasPrefix("/"), StatusDisplay.clip(recorded) == recorded {
            return recorded
        }
        guard let home, !home.isEmpty else { return nil }
        let base = home.hasSuffix("/") ? String(home.dropLast()) : home
        return base + "/.kube/config"
    }

    /// The line for `path` and what the file system says about it.
    public static func decide(path: String?, exists: Bool, readable: Bool) -> KubeconfigFile {
        guard let path else { return KubeconfigFile(value: "Unknown", copyText: nil, revealPath: nil, note: nil) }
        let shown = StatusDisplay.clip(path)
        guard exists else { return KubeconfigFile(value: shown, copyText: nil, revealPath: nil, note: missingNote) }
        return KubeconfigFile(value: shown, copyText: path, revealPath: path, note: readable ? nil : unreadableNote)
    }
}
