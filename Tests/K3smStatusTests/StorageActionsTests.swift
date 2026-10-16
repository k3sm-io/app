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

@Suite("the Storage tab's actions")
struct StorageActionsTests {
    static func rows() throws -> [StorageRow] { try StorageList.decode(try fixture("kubectl_storage.json")) }

    static func row(_ key: String) throws -> StorageRow { try #require(try rows().first { $0.key == key }) }

    /// A pod list mounting shop's claims: web-0 and web-1 mount data-db-0,
    /// a finished job mounted it too, a pod in another namespace mounts a
    /// claim of the same name there, and one mounts logs by an ephemeral
    /// volume's generated name only in name (it is not shop/logs).
    static let podsJSON = #"""
    {"kind": "List", "items": [
      {"kind": "Pod", "metadata": {"name": "web-0", "namespace": "shop", "uid": "u0"},
       "spec": {"containers": [{"image": "app:1"}], "volumes": [{"name": "data", "persistentVolumeClaim": {"claimName": "data-db-0"}}, {"name": "tmp", "emptyDir": {}}]},
       "status": {"phase": "Running"}},
      {"kind": "Pod", "metadata": {"name": "web-1", "namespace": "shop", "uid": "u1"},
       "spec": {"containers": [{"image": "app:1"}], "volumes": [{"name": "data", "persistentVolumeClaim": {"claimName": "data-db-0", "readOnly": true}}]},
       "status": {"phase": "Pending"}},
      {"kind": "Pod", "metadata": {"name": "seed", "namespace": "shop", "uid": "u2"},
       "spec": {"containers": [{"image": "app:1"}], "volumes": [{"name": "data", "persistentVolumeClaim": {"claimName": "data-db-0"}}]},
       "status": {"phase": "Succeeded"}},
      {"kind": "Pod", "metadata": {"name": "web-0", "namespace": "other", "uid": "u3"},
       "spec": {"containers": [{"image": "app:1"}], "volumes": [{"name": "data", "persistentVolumeClaim": {"claimName": "data-db-0"}}]},
       "status": {"phase": "Running"}},
      {"kind": "Pod", "metadata": {"name": "scratch", "namespace": "shop", "uid": "u4"},
       "spec": {"containers": [{"image": "app:1"}], "volumes": [{"name": "work", "ephemeral": {"volumeClaimTemplate": {"spec": {}}}}]},
       "status": {"phase": "Running"}}
    ]}
    """#

    static func pods() throws -> [Pod] { try Workloads.decode(Data(podsJSON.utf8)).pods }

    @Test("a pod's claims are its claim volumes and its ephemeral volumes' generated claims")
    func podClaimsDecode() throws {
        let pods = try Self.pods()
        #expect(pods.first { $0.namespace == "shop" && $0.name == "web-0" }?.claims == ["data-db-0"])
        #expect(pods.first { $0.name == "scratch" }?.claims == ["scratch-work"])
        // A pod list without volumes still decodes, with none.
        let bare = try Workloads.decode(try fixture("kubectl_pods_running.json"))
        #expect(bare.pods.allSatisfy { $0.claims.isEmpty })
    }

    @Test("the claim's Delete names the pods still mounting it, and says its data stays on disk")
    func claimInUseWarningNamesThePods() throws {
        let row = try Self.row("pvc/shop/data-db-0")
        // Only shop's unfinished pods mounting this claim: not the finished
        // job, not the same claim name in another namespace.
        #expect(StorageActions.mountingPods(row, in: try Self.pods()).map(\.name) == ["web-0", "web-1"])
        let request = try #require(StorageActions.deleteRequest(for: row, pods: try Self.pods()))
        #expect(request.mountedBy == ["web-0", "web-1"])
        let c = request.confirmation
        #expect(c.title == "Delete claim shop/data-db-0?")
        #expect(c.verbTitle == "Delete")
        #expect(c.destructive)
        #expect(c.message.contains("It is still mounted by web-0 and web-1."))
        #expect(c.message.contains("Kubernetes keeps the claim, as Terminating, until those pods are gone."))
        #expect(c.message.contains("the data stays on the node's disk in /var/lib/k3sm/storage/shop/data-db-0, because its storage class retains volumes"))
        // The inspector lists the same pods.
        let body = InspectorDetails.claim(row, pods: try Self.pods())
        #expect(body.facts.last == InspectorFact("Mounted by", "web-0, web-1"))
    }

    @Test("a claim no pod mounts, an unread pod list, an unbound claim and a non-Retain volume each say so")
    func claimConfirmationCases() throws {
        let idle = try #require(StorageActions.deleteRequest(for: try Self.row("pvc/shop/data-db-0"), pods: []))
        #expect(idle.confirmation.message.hasPrefix("No listed pod mounts it."))
        #expect(InspectorDetails.claim(try Self.row("pvc/shop/data-db-0"), pods: []).facts.last == InspectorFact("Mounted by", "no listed pod"))
        let unread = try #require(StorageActions.deleteRequest(for: try Self.row("pvc/shop/data-db-0"), pods: nil))
        #expect(unread.mountedBy == nil)
        #expect(unread.confirmation.message.hasPrefix("The pod list has not been read"))
        let pending = try #require(StorageActions.deleteRequest(for: try Self.row("pvc/build/cache"), pods: []))
        #expect(pending.confirmation.message.hasSuffix("It is not bound to a volume, so it holds no data."))
        // pvc-2222 records no reclaim policy: its data's fate is not claimed.
        let logs = try #require(StorageActions.deleteRequest(for: try Self.row("pvc/shop/logs"), pods: []))
        #expect(logs.confirmation.message.contains("what happens to its data is not known here"))
        let one = try #require(StorageActions.deleteRequest(for: try Self.row("pvc/shop/data-db-0"),
                                                             pods: try Self.pods().filter { $0.namespace == "shop" && $0.name == "web-0" }))
        #expect(one.confirmation.message.contains("until that pod is gone."))
    }

    @Test("a claim offers Delete on its menu and the Delete key; a volume alone offers nothing")
    func claimMenu() throws {
        let menu = StorageActions.menu(for: try Self.row("pvc/shop/data-db-0"), pods: [])
        #expect(menu.items.map(\.title) == ["Delete…"])
        #expect(menu.deleteKeyItem?.id == "delete-claim:pvc/shop/data-db-0")
        #expect(StorageActions.menu(for: try Self.row("pv/pvc-9999"), pods: []).isEmpty)
    }

    @Test("the claim delete and its UID read are fixed argument lists")
    func deleteClaimArgumentsGolden() throws {
        let ns = try #require(ResourceName("shop"))
        let claim = try #require(ResourceName("data-db-0"))
        #expect(K3smCLI.deleteClaimArguments(namespace: ns, claim: claim)
            == ["kubectl", "delete", "pvc", "data-db-0", "-n", "shop", "--wait=false"])
        #expect(K3smCLI.claimUIDArguments(namespace: ns, claim: claim)
            == ["kubectl", "get", "pvc", "data-db-0", "-n", "shop", "-o", "jsonpath={.metadata.uid}"])
        let request = try #require(StorageActions.deleteRequest(for: try Self.row("pvc/shop/data-db-0"), pods: []))
        #expect(request.arguments == K3smCLI.deleteClaimArguments(namespace: ns, claim: claim))
        #expect(request.precheckArguments == K3smCLI.claimUIDArguments(namespace: ns, claim: claim))
        #expect(request.section == .storage)
        #expect(request.kind == .delete)
    }

    @Test("the claim's UID check runs the delete only on the claim confirmed")
    func claimUIDCheck() throws {
        let request = try #require(StorageActions.deleteRequest(for: try Self.row("pvc/shop/data-db-0"), pods: []))
        #expect(request.precheck(.exited(status: 0, output: Data("uid-claim-db\n".utf8))) == nil)
        #expect(request.precheck(.exited(status: 0, output: Data("uid-other".utf8)))
            == .refused("Delete refused: the claim changed since you clicked; nothing was deleted."))
        let gone = Data(#"Error from server (NotFound): persistentvolumeclaims "data-db-0" not found"#.utf8)
        #expect(request.precheck(.exited(status: 1, output: gone))?.failed == true)
        #expect(request.precheck(.exited(status: 1, output: gone))?.text.contains("changed since you clicked") == true)
        #expect(request.precheck(.noAnswer)?.text.contains("nothing was deleted") == true)
        #expect(request.report(.exited(status: 0, output: Data()))
            == .succeeded("Delete asked for the claim. Its data stays on the node's disk."))
        let busy = try #require(StorageActions.deleteRequest(for: try Self.row("pvc/shop/data-db-0"), pods: try Self.pods()))
        #expect(busy.report(.exited(status: 0, output: Data())).text.contains("stays Terminating"))
        // kubectl's text is untrusted: one line, no controls.
        let hostile = busy.report(.exited(status: 1, output: Data("bad\n\u{202E}evil".utf8)))
        #expect(hostile == .failed("Delete failed. kubectl said: bad evil"))
    }

    @Test("a claim whose names the guard refuses, or listed without a UID, offers no Delete")
    func refusedClaimsOfferNothing() throws {
        let json = #"""
        {"kind": "List", "items": [
          {"kind": "PersistentVolumeClaim", "metadata": {"name": "--all", "namespace": "shop", "uid": "u"}, "spec": {}},
          {"kind": "PersistentVolumeClaim", "metadata": {"name": "data", "namespace": "-A", "uid": "u"}, "spec": {}},
          {"kind": "PersistentVolumeClaim", "metadata": {"name": "data", "namespace": "shop"}, "spec": {}},
          {"kind": "PersistentVolume", "metadata": {"name": "--force", "uid": "u"}, "spec": {}, "status": {"phase": "Released"}}
        ]}
        """#
        let rows = try StorageList.decode(Data(json.utf8))
        #expect(rows.count == 4)
        for row in rows { #expect(StorageActions.deleteRequest(for: row, pods: []) == nil) }
        #expect(StorageActions.cleanupRequest(rows) == nil)
    }

    @Test("the cleanup takes released volumes and available ones no claim reserves")
    func cleanupSelection() throws {
        let request = try #require(StorageActions.cleanupRequest(try Self.rows()))
        // pvc-6666 is Available but reserved for a claim; Bound volumes are claims' rows.
        #expect(request.volumes.map(\.name.value) == ["pvc-7777", "pvc-8888", "pvc-9999"])
        #expect(request.volumes.map(\.uid) == ["uid-pv-7777", "uid-pv-8888", "uid-pv-9999"])
        #expect(StorageActions.cleanable(phase: "Released", claimed: true))
        #expect(StorageActions.cleanable(phase: "Available", claimed: false))
        #expect(!StorageActions.cleanable(phase: "Available", claimed: true))
        #expect(!StorageActions.cleanable(phase: "Bound", claimed: true))
        #expect(!StorageActions.cleanable(phase: "Failed", claimed: true))
        #expect(StorageActions.cleanupRequest(try Self.rows().filter { $0.claim != nil }) == nil)
    }

    @Test("the volume cleanup is one fixed argument list, with the volume read before it")
    func deleteVolumesArgumentsGolden() throws {
        let names = try ["pvc-7777", "pvc-8888"].map { try #require(ResourceName($0)) }
        #expect(K3smCLI.deleteVolumesArguments(names) == ["kubectl", "delete", "pv", "pvc-7777", "pvc-8888", "--wait=false"])
        #expect(K3smCLI.volumesArguments == ["kubectl", "get", "pv", "-o", "json"])
        let request = try #require(StorageActions.cleanupRequest(try Self.rows()))
        #expect(request.arguments == ["kubectl", "delete", "pv", "pvc-7777", "pvc-8888", "pvc-9999", "--wait=false"])
        #expect(request.precheckArguments == K3smCLI.volumesArguments)
        #expect(request.rowKey == ActionMenu.bulkRowKey)
        #expect(!(try Self.rows()).contains { $0.key == ActionMenu.bulkRowKey })
    }

    @Test("the cleanup's confirmation previews the count, the names and the directories that stay")
    func cleanupConfirmation() throws {
        let request = try #require(StorageActions.cleanupRequest(try Self.rows()))
        let c = request.confirmation
        #expect(c.title == "Delete 3 released or unclaimed volumes?")
        #expect(c.verbTitle == "Delete released and unclaimed volumes")
        #expect(ActionMenuItem(request).title == "Delete released and unclaimed volumes…")
        #expect(c.destructive)
        #expect(c.message == "k3sm deletes these volume objects: pvc-7777, pvc-8888 and pvc-9999. "
            + "Their data directories stay on disk: /var/lib/k3sm/storage/shop/logs and /var/lib/k3sm/storage/gone/old; 1 more records no path. "
            + "Removing a directory takes root on its node and is not done here.")
        let one = VolumeCleanupRequest(volumes: [request.volumes[1]])
        #expect(one.confirmation.title == "Delete 1 released or unclaimed volume?")
        #expect(one.confirmation.message.contains("this volume object: pvc-8888. Its data directory stays on disk; the volume records no path."))
        #expect(one.report(.exited(status: 0, output: Data())) == .succeeded("Delete asked for 1 volume; its data directory stays on disk."))
    }

    @Test("the cleanup runs only when every volume is still listed with its UID and still unused")
    func cleanupCheck() throws {
        let request = try #require(StorageActions.cleanupRequest(try Self.rows()))
        let current = try fixture("kubectl_storage.json")
        // The storage fixture is a List holding claims too; the check reads only volumes.
        let volumesOnly = try JSONSerialization.data(withJSONObject: [
            "kind": "List",
            "items": (try JSONSerialization.jsonObject(with: current) as! [String: Any])["items"].map { items in
                (items as! [[String: Any]]).filter { $0["kind"] as? String == "PersistentVolume" }
            }!,
        ])
        #expect(request.precheck(.exited(status: 0, output: volumesOnly)) == nil)
        // One volume bound since the click: refused, nothing runs.
        let rebound = String(decoding: volumesOnly, as: UTF8.self).replacingOccurrences(of: #""Available""#, with: #""Bound""#)
        #expect(request.precheck(.exited(status: 0, output: Data(rebound.utf8)))
            == .refused("Delete refused: the volumes changed since you clicked; nothing was deleted."))
        // One volume recreated under its name: another UID, refused.
        let recreated = String(decoding: volumesOnly, as: UTF8.self).replacingOccurrences(of: "uid-pv-9999", with: "uid-new")
        #expect(request.precheck(.exited(status: 0, output: Data(recreated.utf8)))?.failed == true)
        // One volume gone: refused.
        let fewer = Data(#"{"kind": "List", "items": []}"#.utf8)
        #expect(request.precheck(.exited(status: 0, output: fewer))?.failed == true)
        #expect(request.precheck(.exited(status: 0, output: Data("not json".utf8)))
            == .failed("Delete failed: the volume list could not be read; nothing was deleted."))
        #expect(request.precheck(.noAnswer)?.text.contains("nothing was deleted") == true)
        #expect(request.precheck(.missing) == .failed("Delete failed: k3sm is not installed on this Mac."))
    }

    @Test("lists in a sentence stop at the limit")
    func listedNames() {
        #expect(StorageActions.listed([]) == "")
        #expect(StorageActions.listed(["a"]) == "a")
        #expect(StorageActions.listed(["a", "b"]) == "a and b")
        #expect(StorageActions.listed(["a", "b", "c"]) == "a, b and c")
        let many = (1...13).map { "v\($0)" }
        #expect(StorageActions.listed(many) == (1...10).map { "v\($0)" }.joined(separator: ", ") + " and 3 more")
    }
}
