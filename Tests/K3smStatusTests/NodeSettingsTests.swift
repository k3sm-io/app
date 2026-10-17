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
import Testing

@testable import K3smStatus

@Suite("the Settings window's Cluster and Storage panes")
struct NodeSettingsTests {
    /// A report with `role` and `rows`, decoded from JSON like the CLI's.
    private static func report(role: String, rows: [[String: Any]], verdict: String = "running") throws -> StatusReport {
        let object: [String: Any] = ["schemaVersion": 1, "verdict": verdict, "role": role, "summary": "", "rows": rows]
        return try StatusReport.decode(JSONSerialization.data(withJSONObject: object))
    }

    private static func settingsRow(state: String = "ok", remedy: String? = nil, _ wide: [String: String]) -> [String: Any] {
        var row: [String: Any] = ["name": "settings", "state": state, "severity": "ok", "detail": "", "wide": wide]
        if let remedy { row["remedy"] = remedy }
        return row
    }

    private static var dataRoot: [String: Any] { [
        "name": "data-root", "state": "ok", "severity": "ok", "detail": "/var/lib/k3sm (apfs volume k3sm-data, mounted)",
        "wide": ["declared": "true", "mounted": "true", "owner": "0", "volume": "k3sm-data", "quota": "100 GiB"],
    ] }

    /// The server wide map from k3sm's network-recorded golden.
    private static let serverWide = [
        "data-volume": "none", "kubeconfig-name": "k3sm", "lan-access": "off", "mesh-ip": "100.64.0.1",
        "nodeport-addresses": "local", "registry-port": "5000", "release-base": "https://releases.example.test/k3sm",
        "tls-sans": "k3sm.example.test,192.0.2.20",
    ]

    private static func value(_ pane: NodeSettingsPane, _ label: String) -> SettingLine? {
        pane.lines.first { $0.label == label }
    }

    @Test("the Cluster and Storage panes map every key, mask restricted values and handle a missing row")
    func nodeSettingsPanes() throws {
        // Every wide key of the contract decodes to a key, and every key has
        // a pane and a label.
        #expect(Set(NodeSettings.Key.allCases.map(\.rawValue)) == [
            "nodeport-addresses", "registry-port", "tls-sans", "mesh-ip", "kubeconfig-name", "release-base",
            "data-volume", "lan-access",
        ])
        for key in NodeSettings.Key.allCases {
            #expect(!key.label.isEmpty)
        }
        #expect(Set(NodeSettings.Key.allCases.filter(\.serverOnly)) == [.registryPort, .tlsSANs, .meshIP, .kubeconfigName])
        let clusterKeys = Set(NodeSettings.Key.allCases.filter { $0.pane == .cluster })
        let storageKeys = Set(NodeSettings.Key.allCases.filter { $0.pane == .storage })
        #expect(clusterKeys == [.meshIP, .tlsSANs, .nodePortAddresses, .registryPort, .kubeconfigName, .lanAccess])
        #expect(storageKeys == [.dataVolume, .releaseBase])

        // A server: every value as k3sm reports it.
        let server = try Self.report(role: "server", rows: [Self.dataRoot, Self.settingsRow(Self.serverWide)])
        let settings = try #require(NodeSettings.decode(server))
        #expect(settings.values[.tlsSANs] == .value("k3sm.example.test,192.0.2.20"))
        #expect(!settings.needsAdmin)
        let cluster = NodeSettingsPanes.cluster(server)
        #expect(cluster.lines.map(\.label) == [
            "Role", "Mesh address", "TLS SANs", "NodePort addresses", "Registry port", "Kubeconfig name", "LAN access",
        ])
        #expect(Self.value(cluster, "Role")?.value == "Server")
        #expect(Self.value(cluster, "Mesh address")?.value == "100.64.0.1")
        #expect(Self.value(cluster, "TLS SANs")?.value == "k3sm.example.test, 192.0.2.20")
        #expect(Self.value(cluster, "TLS SANs")?.copyText == "k3sm.example.test,192.0.2.20")
        #expect(Self.value(cluster, "NodePort addresses")?.value == "local")
        #expect(Self.value(cluster, "Registry port")?.value == "5000")
        #expect(Self.value(cluster, "LAN access")?.value == "Off")
        #expect(Self.value(cluster, "Role")?.copyText == nil)
        #expect(cluster.lines.allSatisfy { !$0.restricted })
        #expect(cluster.note == nil)
        #expect(!cluster.showsLock)

        let storage = NodeSettingsPanes.storage(server)
        #expect(storage.lines.map(\.label) == ["Data volume", "Mounted", "Release base"])
        #expect(Self.value(storage, "Data volume")?.value == "None, the data root is a plain directory")
        #expect(Self.value(storage, "Mounted")?.value == "Yes")
        #expect(Self.value(storage, "Release base")?.value == "https://releases.example.test/k3sm")
        #expect(Self.value(storage, "Release base")?.copyText == "https://releases.example.test/k3sm")

        // A data volume: its name, its quota and its encryption, each a line.
        var volumeWide = Self.serverWide
        volumeWide["data-volume"] = "k3sm-data (quota 100 GiB, encrypted)"
        volumeWide["release-base"] = "default"
        let volume = NodeSettingsPanes.storage(try Self.report(role: "server", rows: [Self.dataRoot, Self.settingsRow(volumeWide)]))
        #expect(volume.lines.map(\.label) == ["Data volume", "Quota", "Encryption", "Mounted", "Release base"])
        #expect(Self.value(volume, "Data volume")?.value == "k3sm-data")
        #expect(Self.value(volume, "Quota")?.value == "100 GiB")
        #expect(Self.value(volume, "Encryption")?.value == "Encrypted")
        #expect(Self.value(volume, "Release base")?.value == "The k3sm releases (default)")
        #expect(Self.value(volume, "Release base")?.copyText == nil)
        // A quota of none, not encrypted.
        volumeWide["data-volume"] = "pods (quota none, not encrypted)"
        let open = NodeSettingsPanes.storage(try Self.report(role: "server", rows: [Self.settingsRow(volumeWide)]))
        #expect(Self.value(open, "Quota")?.value == "No quota")
        #expect(Self.value(open, "Encryption")?.value == "Not encrypted")
        // No data-root row: the mount is not known.
        #expect(Self.value(open, "Mounted")?.value == "Unknown")
        // A data-volume value in a shape this build does not know is shown as printed.
        volumeWide["data-volume"] = "something new"
        let odd = NodeSettingsPanes.storage(try Self.report(role: "server", rows: [Self.settingsRow(volumeWide)]))
        #expect(Self.value(odd, "Data volume")?.value == "something new")
        #expect(Self.value(odd, "Quota") == nil)

        // A worker: the row carries no server-only key, and the pane shows
        // none of them, with a note that they are the server's.
        let worker = try Self.report(role: "agent", rows: [Self.settingsRow([
            "data-volume": "none", "lan-access": "unknown", "nodeport-addresses": "192.0.2.0/24", "release-base": "default",
        ])])
        let workerCluster = NodeSettingsPanes.cluster(worker)
        #expect(workerCluster.lines.map(\.label) == ["Role", "NodePort addresses", "LAN access"])
        #expect(Self.value(workerCluster, "Role")?.value == "Worker")
        #expect(Self.value(workerCluster, "LAN access")?.value == "Unknown")
        #expect(Self.value(workerCluster, "LAN access")?.copyText == nil)
        #expect(workerCluster.note == NodeSettingsPanes.workerNote)
        #expect(NodeSettingsPanes.storage(worker).lines.map(\.label) == ["Data volume", "Mounted", "Release base"])

        // Restricted: the arguments are root's. Each such value shows the
        // lock and the needs-administrator sentence; the note names the remedy.
        let restrictedWide = [
            "data-volume": "none", "kubeconfig-name": "restricted", "lan-access": "unknown", "mesh-ip": "restricted",
            "nodeport-addresses": "restricted", "registry-port": "restricted", "release-base": "restricted",
            "tls-sans": "restricted",
        ]
        let restricted = try Self.report(role: "server", rows: [
            Self.settingsRow(state: "needs-admin", remedy: "sudo k3sm status", restrictedWide),
        ])
        let masked = try #require(NodeSettings.decode(restricted))
        #expect(masked.needsAdmin)
        #expect(masked.values[.meshIP] == .restricted)
        let lockedCluster = NodeSettingsPanes.cluster(restricted)
        #expect(lockedCluster.showsLock)
        #expect(lockedCluster.note == "needs an administrator; run sudo k3sm status")
        for label in ["Mesh address", "TLS SANs", "NodePort addresses", "Registry port", "Kubeconfig name"] {
            let line = try #require(Self.value(lockedCluster, label))
            #expect(line.restricted)
            #expect(line.value == StatusDisplay.needsAdminText)
            #expect(line.copyText == nil)
            #expect(!line.value.contains("restricted"))
        }
        #expect(Self.value(lockedCluster, "LAN access")?.restricted == false)
        let lockedStorage = NodeSettingsPanes.storage(restricted)
        #expect(Self.value(lockedStorage, "Release base")?.restricted == true)
        #expect(Self.value(lockedStorage, "Data volume")?.restricted == false)
        #expect(lockedStorage.showsLock)

        // A missing row (an older k3sm): every setting reads "not reported
        // by this k3sm", and the role is still shown.
        let older = try Self.report(role: "server", rows: [Self.dataRoot])
        #expect(NodeSettings.decode(older) == nil)
        let olderCluster = NodeSettingsPanes.cluster(older)
        #expect(Self.value(olderCluster, "Role")?.value == "Server")
        #expect(olderCluster.lines.dropFirst().allSatisfy { $0.value == NodeSettingsPanes.notReported && $0.copyText == nil })
        #expect(olderCluster.lines.count == 7)
        #expect(olderCluster.note == NodeSettingsPanes.notReportedNote)
        let olderStorage = NodeSettingsPanes.storage(older)
        #expect(Self.value(olderStorage, "Data volume")?.value == NodeSettingsPanes.notReported)
        #expect(Self.value(olderStorage, "Mounted")?.value == "Yes")
        // A key missing from a present row is not reported, too.
        var partial = Self.serverWide
        partial.removeValue(forKey: "tls-sans")
        let partialCluster = NodeSettingsPanes.cluster(try Self.report(role: "server", rows: [Self.settingsRow(partial)]))
        #expect(Self.value(partialCluster, "TLS SANs")?.value == NodeSettingsPanes.notReported)

        // No node, and no report read yet.
        let none = try Self.report(role: "", rows: [], verdict: "not-installed")
        #expect(NodeSettingsPanes.cluster(none).lines.isEmpty)
        #expect(NodeSettingsPanes.cluster(none).note == NodeSettingsPanes.noNodeText)
        #expect(NodeSettingsPanes.storage(none).note == NodeSettingsPanes.noNodeText)
        #expect(NodeSettingsPanes.cluster(nil).lines.isEmpty)
        #expect(NodeSettingsPanes.cluster(nil).note == NodeSettingsPanes.notReadText)
    }

    @Test("a settings value from the CLI is clipped to one line")
    func valuesClipped() throws {
        var wide = Self.serverWide
        wide["kubeconfig-name"] = "k3sm\nforged line"
        wide["tls-sans"] = "a.test,\u{202E}b.test"
        let cluster = NodeSettingsPanes.cluster(try Self.report(role: "server", rows: [Self.settingsRow(wide)]))
        for line in cluster.lines {
            #expect(!line.value.contains("\n"))
            #expect(line.copyText?.contains("\n") != true)
            #expect(!line.value.unicodeScalars.contains("\u{202E}"))
        }
    }

    @Test("the Cluster and Storage panes are listed in toolbar order")
    func panesListed() {
        #expect(SettingsPane.shown == [.general, .cluster, .network, .storage, .updates, .advanced])
        #expect(SettingsPane.cluster.title == "Cluster")
        #expect(SettingsPane.cluster.symbol == "server.rack")
        #expect(SettingsPane.storage.title == "Storage")
        #expect(SettingsPane.storage.symbol == "externaldrive")
        #expect(SettingsPane.restore(from: "cluster") == .cluster)
        #expect(SettingsPane.restore(from: "storage") == .storage)
    }
}
