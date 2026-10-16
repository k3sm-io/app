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

@Suite("the console's model actions")
struct ModelActionsTests {
    @Test("unload and load are one merge patch each, built from typed values")
    func modelScaleArgumentsGolden() throws {
        let ns = try #require(ResourceName("mlx"))
        let model = try #require(ResourceName("qwen"))
        #expect(K3smCLI.modelScaleArguments(namespace: ns, model: model, scale: .unload(recording: 2))
            == ["kubectl", "patch", "mlxmodels.mlx.k3sm.io", "qwen", "-n", "mlx", "--type=merge", "-p",
                #"{"metadata":{"annotations":{"k3sm.io/replicas-before-unload":"2"}},"spec":{"replicas":0}}"#])
        #expect(K3smCLI.modelScaleArguments(namespace: ns, model: model, scale: .load(to: 3))
            == ["kubectl", "patch", "mlxmodels.mlx.k3sm.io", "qwen", "-n", "mlx", "--type=merge", "-p",
                #"{"metadata":{"annotations":{"k3sm.io/replicas-before-unload":null}},"spec":{"replicas":3}}"#])
    }

    @Test("the patch decodes to the typed values it was built from")
    func patchRoundTrips() throws {
        let unload = try decodedPatch(.unload(recording: 4))
        #expect(((unload["metadata"] as? [String: Any])?["annotations"] as? [String: Any])?[ModelActions.replicasAnnotation] as? String == "4")
        #expect((unload["spec"] as? [String: Any])?["replicas"] as? Int == 0)
        let load = try decodedPatch(.load(to: 4))
        #expect(((load["metadata"] as? [String: Any])?["annotations"] as? [String: Any])?[ModelActions.replicasAnnotation] is NSNull)
        #expect((load["spec"] as? [String: Any])?["replicas"] as? Int == 4)
    }

    @Test("the UID read and the delete are fixed argument lists")
    func uidAndDeleteArgumentsGolden() throws {
        let ns = try #require(ResourceName("mlx"))
        let model = try #require(ResourceName("qwen"))
        #expect(K3smCLI.modelUIDArguments(namespace: ns, model: model)
            == ["kubectl", "get", "mlxmodels.mlx.k3sm.io", "qwen", "-n", "mlx", "-o", "jsonpath={.metadata.uid}"])
        #expect(K3smCLI.deleteModelArguments(namespace: ns, model: model)
            == ["kubectl", "delete", "mlxmodels.mlx.k3sm.io", "qwen", "-n", "mlx", "--wait=false"])
    }

    struct AvailabilityCase: Sendable, CustomTestStringConvertible {
        let name: String
        let replicas: Int?
        let recorded: String?
        let actions: [ModelAction]
        let scale: ModelScale
        var testDescription: String { name }
    }

    static let availabilityCases: [AvailabilityCase] = [
        AvailabilityCase(name: "a serving model unloads, recording its count", replicas: 2, recorded: nil,
                         actions: [.unload, .delete], scale: .unload(recording: 2)),
        AvailabilityCase(name: "unset replicas mean one", replicas: nil, recorded: nil,
                         actions: [.unload, .delete], scale: .unload(recording: 1)),
        AvailabilityCase(name: "a stale record is replaced by the current count", replicas: 2, recorded: "5",
                         actions: [.unload, .delete], scale: .unload(recording: 2)),
        AvailabilityCase(name: "an unloaded model loads its recorded count", replicas: 0, recorded: "3",
                         actions: [.load, .delete], scale: .load(to: 3)),
        AvailabilityCase(name: "a model scaled to zero by hand loads one", replicas: 0, recorded: nil,
                         actions: [.load, .delete], scale: .load(to: 1)),
        AvailabilityCase(name: "a zero record loads one", replicas: 0, recorded: "0", actions: [.load, .delete], scale: .load(to: 1)),
        AvailabilityCase(name: "a negative record loads one", replicas: 0, recorded: "-2", actions: [.load, .delete], scale: .load(to: 1)),
        AvailabilityCase(name: "a word loads one", replicas: 0, recorded: "two", actions: [.load, .delete], scale: .load(to: 1)),
        AvailabilityCase(name: "a signed record loads one", replicas: 0, recorded: "+3", actions: [.load, .delete], scale: .load(to: 1)),
        AvailabilityCase(name: "a padded record loads one", replicas: 0, recorded: " 3", actions: [.load, .delete], scale: .load(to: 1)),
        AvailabilityCase(name: "a record past int32 loads one", replicas: 0, recorded: "2147483648",
                         actions: [.load, .delete], scale: .load(to: 1)),
        AvailabilityCase(name: "the int32 ceiling is kept", replicas: 0, recorded: "2147483647",
                         actions: [.load, .delete], scale: .load(to: 2147483647)),
        AvailabilityCase(name: "non-ASCII digits load one", replicas: 0, recorded: "\u{0663}", actions: [.load, .delete], scale: .load(to: 1)),
    ]

    @Test("unload or load is decided by spec.replicas and the record alone", arguments: availabilityCases)
    func availability(_ c: AvailabilityCase) throws {
        let row = try modelRow(replicas: c.replicas, recorded: c.recorded)
        #expect(ModelActions.available(for: row) == c.actions)
        #expect(ModelActions.scale(replicas: row.replicas, recorded: row.replicasBeforeUnload) == c.scale)
        let scaling = try #require(ModelActions.request(c.actions[0], for: row))
        #expect(scaling.scale == c.scale)
        #expect(scaling.arguments == K3smCLI.modelScaleArguments(
            namespace: try #require(ResourceName("mlx")), model: try #require(ResourceName("qwen")), scale: c.scale))
        #expect(scaling.kind == .change)
    }

    @Test("a model whose names the guard refuses, or listed without a UID, offers nothing")
    func refusedNamesOfferNothing() throws {
        for row in [try modelRow(name: "--all"), try modelRow(namespace: "-A"), try modelRow(name: "Qwen"), try modelRow(uid: nil)] {
            #expect(ModelActions.available(for: row).isEmpty)
            #expect(ModelActions.menu(for: row).deleteKeyItem == nil)
        }
    }

    @Test("every action reads the model's UID first, and only Delete is on the Delete key")
    func precheckAndDeleteKey() throws {
        let row = try modelRow(replicas: 2)
        let menu = ModelActions.menu(for: row)
        #expect(menu.items.map(\.id) == ["unload:mlx/qwen", "delete:mlx/qwen"])
        #expect(menu.deleteKeyItem?.id == "delete:mlx/qwen")
        for action in ModelActions.available(for: row) {
            let request = try #require(ModelActions.request(action, for: row))
            #expect(request.precheckArguments
                == ["kubectl", "get", "mlxmodels.mlx.k3sm.io", "qwen", "-n", "mlx", "-o", "jsonpath={.metadata.uid}"])
            #expect(request.section == .models)
            #expect(request.rowKey == "mlx/qwen")
        }
        let delete = try #require(ModelActions.request(.delete, for: row))
        #expect(delete.kind == .delete)
        #expect(delete.arguments == ["kubectl", "delete", "mlxmodels.mlx.k3sm.io", "qwen", "-n", "mlx", "--wait=false"])
    }

    @Test("the confirmations name the count and what Delete keeps")
    func confirmations() throws {
        let unload = try #require(ModelActions.request(.unload, for: try modelRow(replicas: 2))).confirmation
        #expect(unload.title == "Unload mlx/qwen?")
        #expect(unload.message == "k3sm scales this model to zero: its 2 replicas stop and its endpoint stops answering. "
            + "The model stays, with the count recorded on it, and Load brings back 2 replicas.")
        #expect(unload.destructive)
        let load = try #require(ModelActions.request(.load, for: try modelRow(replicas: 0, recorded: "1"))).confirmation
        #expect(load.title == "Load mlx/qwen?")
        #expect(load.message.hasPrefix("k3sm scales this model back to 1 replica. "))
        #expect(!load.destructive)
        let delete = try #require(ModelActions.request(.delete, for: try modelRow(cache: true))).confirmation
        #expect(delete.title == "Delete mlx/qwen?")
        #expect(delete.message == "k3sm deletes this model, its serving pods, its Services and its cache claim. "
            + "The weights volume is kept: it appears in the Storage tab as Released, and deleting it there frees the disk.")
        #expect(delete.verbTitle == "Delete")
        #expect(delete.destructive)
        let bare = try #require(ModelActions.request(.delete, for: try modelRow(cache: false))).confirmation
        #expect(bare.message == "k3sm deletes this model, its serving pods and its Services. It has no cache volume, so no weights are kept.")
    }

    struct VerifyCase: Sendable, CustomTestStringConvertible {
        let name: String
        let action: ModelAction
        let run: ActionRun
        let want: ActionOutcome?
        var testDescription: String { name }
    }

    static let verifyCases: [VerifyCase] = [
        VerifyCase(name: "the same UID runs", action: .unload, run: .exited(status: 0, output: Data("uid-1\n".utf8)), want: nil),
        VerifyCase(name: "another UID refuses the unload", action: .unload, run: .exited(status: 0, output: Data("uid-2".utf8)),
                   want: .refused("Unload refused: the model changed since you clicked; nothing was changed.")),
        VerifyCase(name: "a gone model refuses the delete", action: .delete,
                   run: .exited(status: 1, output: Data("Error from server (NotFound): mlxmodels.mlx.k3sm.io \"qwen\" not found".utf8)),
                   want: .refused("Delete refused: the model changed since you clicked; nothing was deleted.")),
        VerifyCase(name: "another failure quotes kubectl", action: .delete,
                   run: .exited(status: 1, output: Data("Unable to connect\u{202E} to the server\n".utf8)),
                   want: .failed("Delete failed; nothing was deleted. kubectl said: Unable to connect to the server")),
        VerifyCase(name: "no answer changes nothing", action: .unload, run: .noAnswer,
                   want: .failed("Unload failed: the k3sm CLI did not answer the model check; nothing was changed.")),
        VerifyCase(name: "a missing CLI", action: .delete, run: .missing, want: .failed("Delete failed: k3sm is not installed on this Mac.")),
    ]

    @Test("the UID read before the action", arguments: verifyCases)
    func verify(_ c: VerifyCase) throws {
        let request = try #require(ModelActions.request(c.action, for: try modelRow(replicas: 2)))
        #expect(ModelActions.verify(request, run: c.run) == c.want)
    }

    @Test("a run's report")
    func reports() throws {
        let ok = ActionRun.exited(status: 0, output: Data())
        let unload = try #require(ModelActions.request(.unload, for: try modelRow(replicas: 2)))
        #expect(ModelActions.report(unload, run: ok)
            == .succeeded("Unload asked: the operator scales the model to zero, and Load brings back 2 replicas."))
        let load = try #require(ModelActions.request(.load, for: try modelRow(replicas: 0, recorded: "2")))
        #expect(ModelActions.report(load, run: ok) == .succeeded("Load asked: the operator scales the model to 2 replicas."))
        let delete = try #require(ModelActions.request(.delete, for: try modelRow(cache: true)))
        #expect(ModelActions.report(delete, run: ok) == .succeeded("Delete asked: k3sm removes the model; its weights volume stays in the Storage tab."))
        #expect(ModelActions.report(unload, run: .exited(status: 1, output: Data("forbidden\nby RBAC".utf8)))
            == .failed("Unload failed. kubectl said: forbidden by RBAC"))
        #expect(ModelActions.report(load, run: .noAnswer)
            == .failed("Load failed: the k3sm CLI did not answer. Refresh to see whether the model changed."))
        #expect(ModelActions.report(delete, run: .refused("owned by\nmallory"))
            == .failed("Delete failed: the installed k3sm failed the app's check (owned by mallory), so it was not run."))
    }

    @Test("a serving model copies its endpoint and a curl call through its Service's cluster IP")
    func copies() throws {
        let row = try modelRow(endpoint: "qwen.mlx.svc.cluster.local:8000")
        let local = ModelActions.local(for: row)
        #expect(local.map(\.id) == ["copy-endpoint", "copy-curl"])
        #expect(local[0].action == .copy("qwen.mlx.svc.cluster.local:8000"))
        #expect(local[1].action == .copy(
            #"curl -sS "http://$(/Library/k3sm/k3sm kubectl get svc qwen -n mlx -o jsonpath='{.spec.clusterIP}'):8000/v1/chat/completions" "#
            + #"-H 'Content-Type: application/json' "#
            + #"-d '{"max_tokens":64,"messages":[{"content":"Hello","role":"user"}],"model":"mlx-community/Qwen3-4B-4bit"}'"#))
        #expect(ModelActions.menu(for: row).local == local)
        // An http:// prefix and a short service domain are the same Service.
        #expect(ModelActions.servicePort(for: try modelRow(endpoint: "http://qwen.mlx.svc:8080")) == 8080)
    }

    @Test("no curl call for another host, an odd port or a model that is not a plain repository id")
    func noCurlUnlessSafe() throws {
        for endpoint in ["other.mlx.svc.cluster.local:8000", "qwen.mlx.svc.cluster.local", "qwen.mlx.svc.cluster.local:0",
                         "qwen.mlx.svc.cluster.local:99999", "qwen.mlx.svc.evil$(x):8000", "qwen.mlx.svcx:8000"] {
            #expect(ModelActions.curlExample(for: try modelRow(endpoint: endpoint)) == nil, "\(endpoint)")
        }
        for model in ["x'; rm -rf ~; '", "a b", "", "m\"x", "$(id)", "a`b`"] {
            #expect(ModelActions.curlExample(for: try modelRow(model: model, endpoint: "qwen.mlx.svc.cluster.local:8000")) == nil)
        }
        #expect(ModelActions.local(for: try modelRow(endpoint: nil)).isEmpty)
        #expect(ModelActions.local(for: try modelRow(endpoint: "qwen.mlx.svc:80 $(id)")).isEmpty)
    }
}

/// The patch's JSON as an object.
private func decodedPatch(_ scale: ModelScale) throws -> [String: Any] {
    let text = try #require(ModelActions.patch(scale))
    return try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
}

/// One MLXModel decoded through `ModelsList`, in mlx/qwen by default.
private func modelRow(
    name: String = "qwen", namespace: String = "mlx", uid: String? = "uid-1", model: String = "mlx-community/Qwen3-4B-4bit",
    replicas: Int? = 1, recorded: String? = nil, cache: Bool = true, endpoint: String? = nil
) throws -> ModelRow {
    var metadata: [String: Any] = ["name": name, "namespace": namespace]
    if let uid { metadata["uid"] = uid }
    if let recorded { metadata["annotations"] = [ModelActions.replicasAnnotation: recorded] }
    var spec: [String: Any] = ["model": model, "memory": "8Gi"]
    if let replicas { spec["replicas"] = replicas }
    if cache { spec["cache"] = ["storageClassName": "local-path"] }
    var status: [String: Any] = ["phase": "Ready"]
    if let endpoint { status["endpoint"] = endpoint }
    let list: [String: Any] = ["apiVersion": "v1", "kind": "List", "items": [
        ["apiVersion": "mlx.k3sm.io/v1alpha1", "kind": "MLXModel", "metadata": metadata, "spec": spec, "status": status],
    ]]
    let rows = try ModelsList.decode(try JSONSerialization.data(withJSONObject: list))
    return try #require(rows.first)
}
