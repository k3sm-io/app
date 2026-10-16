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

/// Each kind's inspector body as a table of label and value, from the
/// fixtures the tabs' decoders read.
@Suite("the inspector's body for each kind of row")
struct InspectorDetailsTests {
    static let redis = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    static let postgres = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

    static func table(_ body: InspectorBody) -> [[String]] {
        body.facts.map { [$0.label, $0.value] }
    }

    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let key: String
        let header: [String?]
        let facts: [[String]]
        var testDescription: String { name }
    }

    static let imageCases: [Case] = [
        Case(name: "an image on two nodes under two tags, used by a pod by its short name",
             key: redis, header: ["Image", "docker.io/library/redis:7", nil],
             facts: [["Reference", "docker.io/library/redis:7"], ["Digest", redis], ["Size", "40 MB"],
                     ["Nodes", "mac-a, mac-b"],
                     ["Also named", "docker.io/library/redis:7.2, docker.io/library/redis@\(redis)"],
                     ["Used by", "default/redis-cache-0"]]),
        Case(name: "an image without a digest, on one node",
             key: "registry.local/web:1.4", header: ["Image", "registry.local/web:1.4", nil],
             facts: [["Reference", "registry.local/web:1.4"], ["Digest", "not reported"], ["Size", "12 MB"],
                     ["Nodes", "mac-a"], ["Used by", "default/web-7c9d4f6b8-x2lqp"]]),
        Case(name: "an image known only by digest that no listed pod names",
             key: postgres, header: ["Image", "docker.io/library/postgres@\(postgres)", nil],
             facts: [["Reference", "docker.io/library/postgres@\(postgres)"], ["Digest", postgres], ["Size", "150 MB"],
                     ["Nodes", "mac-b"], ["Used by", "no listed pod"]]),
    ]

    @Test("an image's facts", arguments: imageCases)
    func image(_ c: Case) throws {
        let read = try NodeListRead.decode(try fixture("kubectl_nodes_images.json"))
        guard case .listed(let images) = read.images else { Issue.record("not listed"); return }
        let pods = try Workloads.decode(try fixture("kubectl_pods_mixed.json")).pods
        let image = try #require(images.first { $0.key == c.key })
        let body = InspectorDetails.image(image, pods: pods)
        #expect([body.kind, body.title, body.subtitle] == c.header)
        #expect(Self.table(body) == c.facts)
    }

    @Test("an image says nothing about pods until the pod list has been read")
    func imageWithoutPods() throws {
        let read = try NodeListRead.decode(try fixture("kubectl_nodes_images.json"))
        guard case .listed(let images) = read.images else { Issue.record("not listed"); return }
        #expect(InspectorDetails.image(images[0], pods: nil).facts.allSatisfy { $0.label != "Used by" })
        #expect(InspectorDetails.keys(images: read.images) == Set(images.map(\.key)))
        #expect(InspectorDetails.keys(images: .notReported) == [])
        #expect(InspectorDetails.keys(images: nil) == nil)
    }

    @Test("a reference compares in its fully qualified form")
    func normalizedReferences() {
        let cases: [(String, String)] = [
            ("redis:7", "docker.io/library/redis:7"),
            ("alpine", "docker.io/library/alpine:latest"),
            ("user/app", "docker.io/user/app:latest"),
            ("index.docker.io/library/nginx:1", "docker.io/library/nginx:1"),
            ("localhost/x", "localhost/x:latest"),
            ("localhost:5000/x:2", "localhost:5000/x:2"),
            ("ghcr.io/a/b:1", "ghcr.io/a/b:1"),
            ("registry.local:5000/web", "registry.local:5000/web:latest"),
            ("r@\(Self.redis)", "docker.io/library/r@\(Self.redis)"),
        ]
        for (reference, want) in cases {
            #expect(InspectorDetails.normalized(reference) == want, "\(reference)")
        }
    }

    @Test("the build engine's facts")
    func build() throws {
        let ready = InspectorDetails.build(try BuildEngine.decode(try fixture("kubectl_builder_ready.json")))
        #expect([ready.kind, ready.title, ready.subtitle] == ["Build engine", "k3sm-builder", nil])
        #expect(Self.table(ready) == [["State", "Ready"], ["Detail", "Builds run here."], ["Pod", "k3sm-builder"],
                                      ["Node", "mac-a"], ["Cache", "k3sm-builder"], ["Cache phase", "Bound"], ["Cache size", "20 GB"]])
        let absent = InspectorDetails.build(try BuildEngine.decode(Data(#"{"kind":"List","items":[]}"#.utf8)))
        #expect(absent.title == BuildEngine.defaultName)
        #expect(Self.table(absent) == [["State", "Not running"], ["Detail", "Start it with k3sm builder up."],
                                       ["Pod", "none"], ["Cache", "none"]])
    }

    static let serviceCases: [Case] = [
        Case(name: "a node port service with Ingress hosts", key: "shop/web", header: ["Service", "web", "shop"],
             facts: [["Type", "NodePort"], ["Cluster IP", "10.43.0.20"], ["Ports", "80:30080/TCP, 443/TCP"],
                     ["Endpoints", "not reported"], ["Ingress hosts", "*, shop.example.test"]]),
        Case(name: "a headless service with no Ingress", key: "shop/db", header: ["Service", "db", "shop"],
             facts: [["Type", "ClusterIP"], ["Cluster IP", "None"], ["Ports", "5432/TCP"], ["Endpoints", "not reported"], ["Ingress hosts", "none"]]),
    ]

    @Test("a service's facts", arguments: serviceCases)
    func service(_ c: Case) throws {
        let rows = try ServicesList.decode(try fixture("kubectl_services_ingress.json"))
        let body = InspectorDetails.service(try #require(rows.first { $0.key == c.key }))
        #expect([body.kind, body.title, body.subtitle] == c.header)
        #expect(Self.table(body) == c.facts)
    }

    static let claimCases: [Case] = [
        Case(name: "a bound claim with its granted access mode", key: "pvc/shop/data-db-0", header: ["Claim", "data-db-0", "shop"],
             facts: [["Volume", "pvc-1111"], ["Capacity", "2.0 GB"], ["Access", "ReadWriteOnce"], ["Class", "local-path"], ["Phase", "Bound"],
                     ["Path", "/var/lib/k3sm/storage/shop/data-db-0"]]),
        Case(name: "an unbound claim with the mode it asks for", key: "pvc/build/cache", header: ["Claim", "cache", "build"],
             facts: [["Volume", "not bound"], ["Capacity", "512 MB"], ["Access", "ReadWriteOnce"], ["Class", "local-path"], ["Phase", "Pending"]]),
        Case(name: "a claim with no class and no modes", key: "pvc/shop/logs", header: ["Claim", "logs", "shop"],
             facts: [["Volume", "pvc-2222"], ["Capacity", "4.0 GB"], ["Access", "not reported"], ["Class", "none"], ["Phase", "Bound"]]),
        Case(name: "a volume no claim holds", key: "pv/pvc-9999", header: ["Volume", "pvc-9999", nil],
             facts: [["Claim", "none holds it"], ["Capacity", "8.0 GB"], ["Access", "ReadWriteOnce, ReadOnlyMany"], ["Class", "local-path"], ["Phase", "Released"],
                     ["Path", "/var/lib/k3sm/storage/gone/old"]]),
    ]

    @Test("a claim's facts", arguments: claimCases)
    func claim(_ c: Case) throws {
        let rows = try StorageList.decode(try fixture("kubectl_storage.json"))
        let body = InspectorDetails.claim(try #require(rows.first { $0.key == c.key }))
        #expect([body.kind, body.title, body.subtitle] == c.header)
        #expect(Self.table(body) == c.facts)
    }

    static let modelCases: [Case] = [
        Case(name: "a ready model with its endpoint", key: "mlx/qwen", header: ["Model", "qwen", "mlx"],
             facts: [["Model", "mlx-community/Qwen3-4B-4bit"], ["Replicas", "2"], ["Ready", "2"], ["Phase", "Ready"],
                     ["Endpoint", "http://qwen.mlx.svc:8080"]]),
        Case(name: "a downloading model, one replica by default, no endpoint yet", key: "mlx/llama", header: ["Model", "llama", "mlx"],
             facts: [["Model", "mlx-community/Llama-3.2-1B-4bit"], ["Replicas", "1"], ["Ready", "0"], ["Phase", "Downloading"],
                     ["Endpoint", "not set"]]),
    ]

    @Test("a model's facts", arguments: modelCases)
    func model(_ c: Case) throws {
        let rows = try ModelsList.decode(try fixture("kubectl_mlxmodels.json"))
        let body = InspectorDetails.model(try #require(rows.first { $0.key == c.key }))
        #expect([body.kind, body.title, body.subtitle] == c.header)
        #expect(Self.table(body) == c.facts)
    }

    @Test("each tab's empty inspector names its kind")
    func emptyText() {
        let want: [ConsoleSection: String] = [
            .workloads: "Select a pod.", .nodes: "Select a node.", .images: "Select an image.", .builds: "Select a build.",
            .services: "Select a service.", .storage: "Select a claim.", .models: "Select a model.",
            .stats: "The charts cover this session's reads, the last hour at most.",
        ]
        for section in ConsoleSection.allCases {
            #expect(InspectorDetails.emptyText(section) == want[section])
        }
    }
}
