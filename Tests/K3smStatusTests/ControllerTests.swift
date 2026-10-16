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

@Suite("a pod's controller")
struct ControllerTests {
    @Test("an owner's kind and name are validated", arguments: [
        ("ReplicaSet", "hello-http-6bcddf6f77", true),
        ("StatefulSet", "postgres", true),
        ("Job", "nightly-backup", true),
        ("replicaSet", "lower-case-kind", false),
        ("ReplicaSet", "../etc", false),
        ("ReplicaSet", "-leading-dash", false),
        ("Replica\u{202E}Set", "x", false),
        ("", "x", false),
    ])
    func validated(kind: String, name: String, valid: Bool) {
        #expect((OwnerRef(apiVersion: "apps/v1", kind: kind, name: name) != nil) == valid)
    }

    @Test("pods from a real list keep their owners")
    func fromPodList() throws {
        let pods = try Workloads.decode(try fixture("kubectl_pods_running.json")).pods
        let owners = Set(pods.compactMap { $0.ownerRef?.text })
        #expect(owners.contains("ReplicaSet hello-http-6bcddf6f77"))
        #expect(pods.contains { $0.owner == nil && $0.ownerRef == nil })
    }

    @Test("an owner's API version is validated", arguments: [
        ("apps/v1", true), ("v1", true), ("example.com/v1beta1", true),
        ("", false), ("Apps/v1", false), ("a/b/v1", false), ("/v1", false), ("apps/", false), ("apps/v1 ", false),
    ])
    func apiVersion(apiVersion: String, valid: Bool) {
        #expect((OwnerRef(apiVersion: apiVersion, kind: "Deployment", name: "web") != nil) == valid)
    }

    @Test("a pod's owner is its controller reference, not its first reference")
    func podController() throws {
        let pods = try Workloads.decode(try fixture("kubectl_pods_two_owners.json")).pods
        let web = try #require(pods.first { $0.name == "web-5d8f9c7b6-h4k2p" })
        #expect(web.owner == "ReplicaSet web-5d8f9c7b6")
        #expect(web.ownerRef == OwnerRef(apiVersion: "apps/v1", kind: "ReplicaSet", name: "web-5d8f9c7b6"))
        let adopted = try #require(pods.first { $0.name == "adopted-worker" })
        #expect(adopted.owner == nil)
        #expect(adopted.ownerRef == nil)
    }

    @Test("a Deployment's ReplicaSet names the Deployment")
    func replicaSetWithDeployment() throws {
        let owner = try Controller.decodeReplicaSetOwner(try fixture("kubectl_replicaset_deployment.json"))
        #expect(owner == OwnerRef(apiVersion: "apps/v1", kind: "Deployment", name: "hello-http"))
    }

    @Test("a ReplicaSet with no owner has no controller above it")
    func bareReplicaSet() throws {
        #expect(try Controller.decodeReplicaSetOwner(try fixture("kubectl_replicaset_bare.json")) == nil)
    }

    @Test("anything but a ReplicaSet is refused")
    func notAReplicaSet() throws {
        #expect(throws: ControllerDecodeError.notAReplicaSet("Pod")) {
            try Controller.decodeReplicaSetOwner(try fixture("kubectl_pod_single.json"))
        }
    }

    @Test("the reference marked as the controller wins, and a hostile one is dropped")
    func controllerFlag() throws {
        let marked = #"{"kind":"ReplicaSet","metadata":{"ownerReferences":[{"apiVersion":"v1","kind":"Other","name":"first","controller":false},{"apiVersion":"apps/v1","kind":"Deployment","name":"web","controller":true}]}}"#
        #expect(try Controller.decodeReplicaSetOwner(Data(marked.utf8)) == OwnerRef(apiVersion: "apps/v1", kind: "Deployment", name: "web"))
        let hostile = #"{"kind":"ReplicaSet","metadata":{"ownerReferences":[{"apiVersion":"apps/v1","kind":"Deployment","name":"--all","controller":true}]}}"#
        #expect(try Controller.decodeReplicaSetOwner(Data(hostile.utf8)) == nil)
    }

    @Test("a ReplicaSet whose only owner is not marked as its controller has none", arguments: [
        #"{"kind":"ReplicaSet","metadata":{"ownerReferences":[{"apiVersion":"apps/v1","kind":"Deployment","name":"web","controller":false}]}}"#,
        #"{"kind":"ReplicaSet","metadata":{"ownerReferences":[{"apiVersion":"apps/v1","kind":"Deployment","name":"web"}]}}"#,
    ])
    func unmarkedOwner(json: String) throws {
        #expect(try Controller.decodeReplicaSetOwner(Data(json.utf8)) == nil)
    }

    @Test("the controller is the ReplicaSet's owner when there is one, else the pod's owner")
    func resolve() {
        let rs = OwnerRef(apiVersion: "apps/v1", kind: "ReplicaSet", name: "web-5d8f")
        let deploy = OwnerRef(apiVersion: "apps/v1", kind: "Deployment", name: "web")
        let sts = OwnerRef(apiVersion: "apps/v1", kind: "StatefulSet", name: "db")
        #expect(Controller.needsLookup(rs))
        #expect(!Controller.needsLookup(sts))
        #expect(!Controller.needsLookup(nil))
        #expect(Controller.controller(of: rs, replicaSet: .read(deploy)) == .controller(deploy!))
        #expect(Controller.controller(of: rs, replicaSet: .read(nil)) == .controller(rs!))
        #expect(Controller.controller(of: sts, replicaSet: .read(deploy)) == .controller(sts!))
        #expect(Controller.controller(of: nil, replicaSet: nil) == .noController)
    }

    @Test("a failed ReplicaSet read is told apart from a ReplicaSet with no owner")
    func unread() {
        let rs = OwnerRef(apiVersion: "apps/v1", kind: "ReplicaSet", name: "web-5d8f")!
        #expect(Controller.controller(of: rs, replicaSet: .failed) == .unread(replicaSet: rs))
        #expect(Controller.controller(of: rs, replicaSet: nil) == .unread(replicaSet: rs))
        #expect(Controller.controller(of: rs, replicaSet: .read(nil)) == .controller(rs))
    }

    /// A pod list holding one pod whose controller is `kind` in `apiVersion`.
    static func podList(apiVersion: String, kind: String) -> Data {
        Data(#"{"kind":"PodList","items":[{"metadata":{"name":"p","ownerReferences":[{"apiVersion":"\#(apiVersion)","kind":"\#(kind)","name":"web","controller":true}]},"spec":{"containers":[{"name":"c"}]}}]}"#.utf8)
    }

    @Test("a ReplicaSet kind outside apps/v1 is not read as the built-in one")
    func customReplicaSet() throws {
        let custom = try Workloads.decode(Self.podList(apiVersion: "example.com/v1", kind: "ReplicaSet")).pods[0].ownerRef
        #expect(custom != nil)
        #expect(!Controller.needsLookup(custom))
        #expect(Controller.controller(of: custom, replicaSet: nil) == .noController)
        let builtIn = try Workloads.decode(Self.podList(apiVersion: "apps/v1", kind: "ReplicaSet")).pods[0].ownerRef
        #expect(Controller.needsLookup(builtIn))
    }

    @Test("a ReplicaSet controlled by a kind outside apps/v1 has no controller the app acts on")
    func customDeployment() throws {
        let rs = try Workloads.decode(Self.podList(apiVersion: "apps/v1", kind: "ReplicaSet")).pods[0].ownerRef
        let json = #"{"kind":"ReplicaSet","metadata":{"ownerReferences":[{"apiVersion":"example.com/v1","kind":"Deployment","name":"web","controller":true}]}}"#
        let above = try Controller.decodeReplicaSetOwner(Data(json.utf8))
        #expect(above != nil)
        #expect(Controller.controller(of: rs, replicaSet: .read(above)) == .noController)
    }

    @Test("the ReplicaSet read is a fixed argument list")
    func arguments() {
        let ns = ResourceName("default")!, name = ResourceName("hello-http-6bcddf6f77")!
        #expect(K3smCLI.replicaSetArguments(namespace: ns, name: name)
            == ["kubectl", "get", "replicaset", "hello-http-6bcddf6f77", "-n", "default", "-o", "json"])
    }
}
