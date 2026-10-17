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

@Suite("decode kubectl pod lists")
struct WorkloadsTests {
    @Test("a live list from a single-node cluster")
    func live() throws {
        let w = try Workloads.decode(try fixture("kubectl_pods_running.json"))
        #expect(w.pods.count == 3)
        #expect(w.namespaces == ["default"])
        let names = w.pods.map(\.name)
        #expect(names == ["bench-vm", "hello-http-6bcddf6f77-sz8n8", "hello-native"])
        let vm = try #require(w.pods.first { $0.name == "bench-vm" })
        #expect(vm.kind == .linuxVM)
        #expect(vm.image == "alpine:3.20")
        #expect(vm.health == .running)
        #expect(vm.owner == nil)
        #expect(vm.memoryRequest == Int64(268_435_456))
        #expect(vm.cpuRequest == nil)
        let owned = try #require(w.pods.first { $0.name.hasPrefix("hello-http") })
        #expect(owned.kind == .nativeProcess)
        #expect(owned.owner == "ReplicaSet hello-http-6bcddf6f77")
        #expect(owned.ports == [8080])
        #expect(owned.created != nil)
    }

    @Test("every health reading the list can show")
    func mixed() throws {
        let w = try Workloads.decode(try fixture("kubectl_pods_mixed.json"))
        #expect(w.namespaces == ["default", "ml", "temporal"])
        func pod(_ name: String) throws -> Pod { try #require(w.pods.first { $0.name == name }) }
        #expect(try pod("web-7c9d4f6b8-x2lqp").health == .running)
        #expect(try pod("web-7c9d4f6b8-x2lqp").cpuRequest == 0.25)
        #expect(try pod("web-7c9d4f6b8-x2lqp").memoryRequest == Int64(67_108_864))
        let crash = try pod("probes-demo")
        #expect(crash.health == .waiting("CrashLoopBackOff"))
        #expect(crash.health.severity == "warn")
        #expect(crash.restarts == 3)
        #expect(!crash.ready)
        let pending = try pod("redis-cache-0")
        #expect(pending.health == .waiting("Unschedulable"))
        #expect(pending.kind == .linuxVM)
        #expect(try pod("mlx-qwen-0").cpuRequest == 2)
        #expect(try pod("mlx-qwen-0").memoryRequest == Int64(21_474_836_480))
        #expect(try pod("backfill-1").health == .completed)
        #expect(try pod("backfill-1").health.severity == "off")
        let failed = try pod("postgres-0")
        #expect(failed.health == .failed("Error"))
        #expect(failed.health.severity == "bad")
        #expect(failed.owner == "StatefulSet postgres")
        #expect(w.pods(in: "ml").map(\.name) == ["backfill-1", "mlx-qwen-0"])
    }

    @Test("an empty list is a list")
    func empty() throws {
        let w = try Workloads.decode(try fixture("kubectl_pods_empty.json"))
        #expect(w.pods.isEmpty)
        #expect(w.namespaces.isEmpty)
    }

    @Test("a single pod is not a list")
    func single() throws {
        #expect(throws: WorkloadsDecodeError.malformed) {
            try Workloads.decode(try fixture("kubectl_pod_single.json"))
        }
    }

    @Test("a list of another kind is refused")
    func services() throws {
        #expect(throws: WorkloadsDecodeError.notAPodList("List")) {
            try Workloads.decode(try fixture("kubectl_services_list.json"))
        }
    }

    @Test("not JSON is malformed")
    func malformed() {
        #expect(throws: WorkloadsDecodeError.malformed) {
            try Workloads.decode(Data("k3sm kubectl: no cluster".utf8))
        }
    }
}

@Suite("quantities")
struct QuantityTests {
    @Test("cores", arguments: [("500m", 0.5), ("2", 2.0), ("1500m", 1.5), ("0", 0.0)])
    func cores(_ c: (String, Double)) {
        #expect(Quantity.cores(c.0) == c.1)
    }

    @Test("bytes", arguments: [("256Mi", Int64(268_435_456)), ("1Gi", Int64(1_073_741_824)), ("500M", Int64(500_000_000)), ("1024", Int64(1024)), ("64Ki", Int64(65536))])
    func bytes(_ c: (String, Int64)) {
        #expect(Quantity.bytes(c.0) == c.1)
    }

    @Test("garbage is nil")
    func garbage() {
        #expect(Quantity.cores("lots") == nil)
        #expect(Quantity.bytes("12Qi") == nil)
    }

    // The API server accepts these on any pod in any namespace; the app must
    // refuse them, never trap, or one pod crashes the status poll for everyone.
    @Test("out-of-range bytes are nil, never a trap", arguments: ["1e19", "10000000Ti", "nan", "inf", "-inf", "-1Gi"])
    func outOfRangeBytes(_ s: String) {
        #expect(Quantity.bytes(s) == nil)
    }

    @Test("non-finite or negative cores are nil", arguments: ["nan", "inf", "-1", "-500m"])
    func outOfRangeCores(_ s: String) {
        #expect(Quantity.cores(s) == nil)
    }

    @Test("the largest representable request still decodes")
    func largestBytes() {
        #expect(Quantity.bytes("4Ei") == nil) // no Ei suffix: refused, not misread
        #expect(Quantity.bytes("8000000Ti") == 8_796_093_022_208_000_000)
    }

    @Test("a sum that overflows Int64 is nil")
    func overflowingSum() {
        #expect(Quantity.sum([Int64.max, 1]) == nil)
        #expect(Quantity.sum([1, 2, 3]) == 6)
        #expect(Quantity.sum([]) == 0)
    }

    @Test("two containers whose requests overflow give a nil memory request")
    func overflowingPod() throws {
        let json = #"""
        {"kind":"PodList","items":[{"metadata":{"name":"big","namespace":"default"},
          "spec":{"containers":[
            {"name":"a","image":"x","resources":{"requests":{"memory":"8000000Ti"}}},
            {"name":"b","image":"x","resources":{"requests":{"memory":"8000000Ti"}}}]},
          "status":{"phase":"Pending"}}]}
        """#
        let w = try Workloads.decode(Data(json.utf8))
        #expect(w.pods.count == 1)
        #expect(w.pods.first?.memoryRequest == nil)
    }

    @Test("a pod's owner is its controller reference, not its first reference")
    func podController() throws {
        let pods = try Workloads.decode(try fixture("kubectl_pods_two_owners.json")).pods
        let web = try #require(pods.first { $0.name == "web-5d8f9c7b6-h4k2p" })
        #expect(web.owner == "ReplicaSet web-5d8f9c7b6")
        #expect(web.controllerRef == OwnerRef(apiVersion: "apps/v1", kind: "ReplicaSet", name: "web-5d8f9c7b6", uid: "b"))
        // Its only reference is unmarked: an adopted pod nothing recreates.
        let adopted = try #require(pods.first { $0.name == "adopted-worker" })
        #expect(adopted.owner == nil)
        #expect(adopted.controllerRef == nil)
    }

    @Test("an oversized request on one pod does not stop the list decoding")
    func oversizedPod() throws {
        let json = #"""
        {"kind":"PodList","items":[{"metadata":{"name":"huge","namespace":"default"},
          "spec":{"containers":[{"name":"a","image":"x","resources":{"requests":{"memory":"1e19","cpu":"nan"}}}]},
          "status":{"phase":"Pending"}}]}
        """#
        let w = try Workloads.decode(Data(json.utf8))
        #expect(w.pods.first?.memoryRequest == nil)
        #expect(w.pods.first?.cpuRequest == nil)
    }
}

@Suite("resource names on a command line")
struct ResourceNameTests {
    @Test("accepted", arguments: ["hello-native", "web-7c9d4f6b8-x2lqp", "a", "ns.sub.domain", "k3sm-system", String(repeating: "a", count: 253)])
    func accepted(_ s: String) {
        #expect(ResourceName(s)?.value == s)
    }

    @Test("refused", arguments: ["", "-leading", "trailing-", "Upper", "with space", "../etc", "a;id", "--all-namespaces", "a_b", String(repeating: "a", count: 254)])
    func refused(_ s: String) {
        #expect(ResourceName(s) == nil)
    }

    @Test("detail argument lists are fixed shapes around the two names")
    func arguments() throws {
        let ns = try #require(ResourceName("default")), pod = try #require(ResourceName("hello-native"))
        #expect(K3smCLI.workloadsArguments == ["kubectl", "get", "pods", "-A", "-o", "json"])
        #expect(K3smCLI.nodesArguments == ["kubectl", "get", "nodes", "-o", "json"])
        #expect(K3smCLI.logsArguments(namespace: ns, pod: pod) == ["kubectl", "logs", "-n", "default", "hello-native", "--tail=200", "--all-containers"])
        #expect(K3smCLI.manifestArguments(namespace: ns, pod: pod) == ["kubectl", "get", "pod", "-n", "default", "hello-native", "-o", "yaml"])
        let events = K3smCLI.eventsArguments(namespace: ns, pod: pod)
        #expect(events.prefix(5) == ["kubectl", "get", "events", "-n", "default"])
        #expect(events.contains("involvedObject.name=hello-native"))
    }
}
