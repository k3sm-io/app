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

/// NodeSettings is the status report's `settings` row read as the node's
/// install settings: the values `k3sm install` recorded (or the default the
/// daemon takes when none is), the data volume, and LAN access. Its `wide`
/// keys are the CLI's contract. A value only root can read is `restricted`
/// on the wire and `.restricted` here; a key the row does not carry is
/// `.notReported`. Every value is untrusted data and is shown clipped.
public struct NodeSettings: Equatable, Sendable {
    /// The row's name in the report.
    public static let rowName = "settings"
    /// The wire word for a value only root can read.
    public static let restrictedWord = "restricted"

    /// One setting of the row, by its `wide` key.
    public enum Key: String, CaseIterable, Sendable {
        case nodePortAddresses = "nodeport-addresses"
        case registryPort = "registry-port"
        case tlsSANs = "tls-sans"
        case meshIP = "mesh-ip"
        case kubeconfigName = "kubeconfig-name"
        case releaseBase = "release-base"
        case dataVolume = "data-volume"
        case lanAccess = "lan-access"

        /// The label the pane shows.
        public var label: String {
            switch self {
            case .nodePortAddresses: "NodePort addresses"
            case .registryPort: "Registry port"
            case .tlsSANs: "TLS SANs"
            case .meshIP: "Mesh address"
            case .kubeconfigName: "Kubeconfig name"
            case .releaseBase: "Release base"
            case .dataVolume: "Data volume"
            case .lanAccess: "LAN access"
            }
        }

        /// Flags only `k3sm server` takes: a worker's row carries none of them.
        public var serverOnly: Bool {
            switch self {
            case .registryPort, .tlsSANs, .meshIP, .kubeconfigName: true
            default: false
            }
        }

        /// The Settings pane that shows the key.
        public var pane: SettingsPane {
            switch self {
            case .dataVolume, .releaseBase: .storage
            default: .cluster
            }
        }
    }

    /// One value as the row carries it.
    public enum Value: Equatable, Sendable {
        /// A value as printed (not yet clipped).
        case value(String)
        /// Readable only by root.
        case restricted
        /// The row does not carry the key.
        case notReported
    }

    /// Whether the row says it needs an administrator (`needs-admin`).
    public let needsAdmin: Bool
    /// The row's remedy, "" when it names none.
    public let remedy: String
    /// The row's values by key; a key absent here is not reported.
    public let values: [Key: Value]

    /// The value of `key`, `.notReported` when the row does not carry it.
    public func value(_ key: Key) -> Value {
        values[key] ?? .notReported
    }

    /// The settings in `report`, nil when there is no report or it carries
    /// no `settings` row (a k3sm from before the row, or no install).
    public static func decode(_ report: StatusReport?) -> NodeSettings? {
        guard let row = report?.row(named: rowName) else { return nil }
        var values: [Key: Value] = [:]
        for key in Key.allCases {
            guard let raw = row.wide[key.rawValue] else { continue }
            values[key] = raw == restrictedWord ? .restricted : .value(raw)
        }
        return NodeSettings(needsAdmin: row.rowState == .needsAdmin, remedy: row.remedy, values: values)
    }
}

/// SettingLine is one line of the Cluster or Storage pane: a label, the
/// value shown (clipped), whether it is root's alone (drawn with a lock), and
/// the text Copy puts on the clipboard, nil where a copy is no use (a
/// default, an unknown or a restricted value).
public struct SettingLine: Equatable, Sendable, Identifiable {
    public let label: String
    public let value: String
    public let restricted: Bool
    public let copyText: String?

    public var id: String { label }

    public init(label: String, value: String, restricted: Bool = false, copyText: String? = nil) {
        self.label = label
        self.value = value
        self.restricted = restricted
        self.copyText = copyText
    }
}

/// NodeSettingsPane is what one of the two panes shows: its lines, an
/// optional note under them, and whether the lock shows beside the title.
public struct NodeSettingsPane: Equatable, Sendable {
    public let lines: [SettingLine]
    public let note: String?

    /// Whether any value is root's alone.
    public var showsLock: Bool { lines.contains(where: \.restricted) }
}

/// NodeSettingsPanes decides the Settings window's Cluster and Storage
/// panes from the last full status report. They are read-only: the settings
/// change only through `k3sm install`, and `editingNote` says so.
public enum NodeSettingsPanes {
    /// The value of a setting the row does not carry.
    public static let notReported = "not reported by this k3sm"
    /// The note under a pane whose report has no `settings` row.
    public static let notReportedNote = "This k3sm does not report its install settings; a newer release does."
    /// The note under a worker's Cluster pane.
    public static let workerNote = "The mesh address, TLS SANs, registry port and kubeconfig name are set on the server."
    /// The pane's line on a Mac with no k3sm node.
    public static let noNodeText = "This Mac runs no k3sm node, so it has no install settings."
    /// The pane's line before any full report is read.
    public static let notReadText = "The status of this Mac has not been read yet."
    /// The line at the foot of both panes.
    public static let editingNote = "These are set when k3sm is installed. Changing them from the app comes later."

    /// The Cluster pane: the node's role, then the mesh address, TLS SANs,
    /// NodePort addresses, registry port, kubeconfig name and LAN access, the
    /// server-only ones on a server alone.
    public static func cluster(_ report: StatusReport?) -> NodeSettingsPane {
        guard let report else { return NodeSettingsPane(lines: [], note: notReadText) }
        guard report.verdict != .notInstalled else { return NodeSettingsPane(lines: [], note: noNodeText) }
        let role = NodeRole.detect(in: report)
        let settings = NodeSettings.decode(report)
        var lines = [SettingLine(label: "Role", value: roleText(role, report: report))]
        let keys: [NodeSettings.Key] = [.meshIP, .tlsSANs, .nodePortAddresses, .registryPort, .kubeconfigName, .lanAccess]
        for key in keys where shows(key, role: role, settings: settings) {
            lines.append(line(key, settings))
        }
        return NodeSettingsPane(lines: lines, note: note(settings, worker: role == .agent))
    }

    /// The Storage pane: the data volume (its name, quota and encryption when
    /// it is one), whether the data root is mounted (from the `data-root`
    /// row), and the release base.
    public static func storage(_ report: StatusReport?) -> NodeSettingsPane {
        guard let report else { return NodeSettingsPane(lines: [], note: notReadText) }
        guard report.verdict != .notInstalled else { return NodeSettingsPane(lines: [], note: noNodeText) }
        let settings = NodeSettings.decode(report)
        var lines = volumeLines(settings)
        lines.append(SettingLine(label: "Mounted", value: mounted(report.row(named: "data-root"))))
        lines.append(line(.releaseBase, settings))
        return NodeSettingsPane(lines: lines, note: note(settings, worker: false))
    }

    /// Whether the Cluster pane lists `key`: every key on a server, the
    /// worker's own on a worker, and on a Mac whose role is not known the
    /// keys its row carries (all of them when there is no row).
    static func shows(_ key: NodeSettings.Key, role: NodeRole?, settings: NodeSettings?) -> Bool {
        guard key.serverOnly else { return true }
        switch role {
        case .server: return true
        case .agent: return false
        case nil: return settings.map { $0.values[key] != nil } ?? true
        }
    }

    private static func note(_ settings: NodeSettings?, worker: Bool) -> String? {
        guard let settings else { return notReportedNote }
        if settings.needsAdmin || settings.values.values.contains(.restricted) {
            let remedy = StatusDisplay.clip(settings.remedy)
            return StatusDisplay.clip(remedy.isEmpty ? StatusDisplay.needsAdminText
                                      : StatusDisplay.needsAdminText + "; run " + remedy)
        }
        return worker ? workerNote : nil
    }

    private static func roleText(_ role: NodeRole?, report: StatusReport) -> String {
        switch role {
        case .server: return "Server"
        case .agent: return "Worker"
        case nil:
            let word = StatusDisplay.clip(report.role)
            return word.isEmpty ? "Unknown" : word
        }
    }

    /// The line for `key`: restricted, not reported, or the value in words.
    static func line(_ key: NodeSettings.Key, _ settings: NodeSettings?) -> SettingLine {
        switch settings?.value(key) ?? .notReported {
        case .restricted:
            return SettingLine(label: key.label, value: StatusDisplay.needsAdminText, restricted: true)
        case .notReported:
            return SettingLine(label: key.label, value: notReported)
        case .value(let raw):
            let clipped = StatusDisplay.clip(raw)
            let (shown, copies) = words(key, clipped)
            return SettingLine(label: key.label, value: shown, copyText: copies ? clipped : nil)
        }
    }

    /// The value shown for a clipped value, and whether Copy is offered:
    /// the CLI's words for a default read in plain words and copy nothing.
    static func words(_ key: NodeSettings.Key, _ value: String) -> (String, Bool) {
        if value.isEmpty || value == "unknown" { return ("Unknown", false) }
        switch (key, value) {
        case (.nodePortAddresses, "every interface"): return ("Every interface", false)
        case (.registryPort, "off"): return ("Off, no node registry", false)
        case (.tlsSANs, "none"), (.meshIP, "none"): return ("None", false)
        case (.releaseBase, "default"): return ("The k3sm releases (default)", false)
        case (.lanAccess, "on"): return ("On", false)
        case (.lanAccess, "off"): return ("Off", false)
        case (.lanAccess, _): return (value, false)
        case (.tlsSANs, _):
            return (StatusDisplay.clip(value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: ", ")), true)
        default: return (value, true)
        }
    }

    /// The data volume's lines. The CLI prints `none` for a plain directory,
    /// else `<name> (quota <size or none>, encrypted|not encrypted)`; a value
    /// in another shape is shown as printed.
    static func volumeLines(_ settings: NodeSettings?) -> [SettingLine] {
        let label = NodeSettings.Key.dataVolume.label
        guard case .value(let raw) = settings?.value(.dataVolume) ?? .notReported else {
            return [line(.dataVolume, settings)]
        }
        let value = StatusDisplay.clip(raw)
        if value == "none" { return [SettingLine(label: label, value: "None, the data root is a plain directory")] }
        if value == "unknown" || value.isEmpty { return [SettingLine(label: label, value: "Unknown")] }
        guard value.hasSuffix(")"), let open = value.range(of: " (quota ", options: .backwards) else {
            return [SettingLine(label: label, value: value, copyText: value)]
        }
        let name = String(value[..<open.lowerBound])
        let inner = value[open.upperBound..<value.index(before: value.endIndex)]
        guard let comma = inner.range(of: ", ", options: .backwards), !name.isEmpty else {
            return [SettingLine(label: label, value: value, copyText: value)]
        }
        let quota = String(inner[..<comma.lowerBound])
        let encryption = String(inner[comma.upperBound...])
        let encryptionText: String
        switch encryption {
        case "encrypted": encryptionText = "Encrypted"
        case "not encrypted": encryptionText = "Not encrypted"
        default: encryptionText = encryption
        }
        return [
            SettingLine(label: label, value: name, copyText: name),
            SettingLine(label: "Quota", value: quota == "none" ? "No quota" : quota),
            SettingLine(label: "Encryption", value: encryptionText),
        ]
    }

    /// Whether the data root is mounted, from the `data-root` row's
    /// `mounted` word; unknown without the row or the word.
    static func mounted(_ row: StatusRow?) -> String {
        switch row?.wide["mounted"] {
        case "true": "Yes"
        case "false": "No"
        default: "Unknown"
        }
    }
}
