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

/// The Images tab's read of `k3sm image ls -o json`. The goldens under
/// Fixtures are k3sm's `cmd/k3sm/testdata/image_ls.golden.json` and
/// `image_df.golden.json`, vendored before they reach k3sm's main.
@Suite("registry images")
struct RegistryImagesTests {
    static func json(_ text: String) -> Data { Data(text.utf8) }

    @Test("the image ls golden decodes into the registry, its images, the incomplete nodes and no migration")
    func imageListDecodesRegistryJSONGolden() throws {
        let list = try RegistryImages.decode(fixture("image_ls.golden.json"))
        #expect(list.registryName == "registry-k3sm:6450")
        #expect(list.reachable)
        #expect(list.error == nil)
        #expect(list.cachedOnIncomplete == ["node-full"])
        #expect(list.migration == nil)
        #expect(list.images.map(\.reference) == [
            "registry-k3sm:6450/app:v1", "registry-k3sm:6450/app:v2", "registry-k3sm:6450/tools/multi:v1",
        ])
        let first = try #require(list.images.first)
        #expect(first.key == "registry-k3sm:6450/app:v1")
        #expect(first.repository == "app")
        #expect(first.tag == "v1")
        #expect(first.digest == "sha256:bd0ec198d046597d3fd73c47830f84c597812c1cf4bd91b9fe82e0ae52cac276")
        #expect(first.shortDigest == "sha256:bd0ec198d046")
        #expect(first.platforms == ["darwin/arm64"])
        #expect(first.sizeBytes == 94)
        #expect(first.pods == 2)
        #expect(first.cachedOn == ["node-a", "node-b"])
        #expect(first.cachedOnText == "node-a, node-b")
        #expect(list.images[1].cachedOnText == "none")
        #expect(list.images[1].pods == 0)
        #expect(list.images[2].platforms == ["linux/arm64", "linux/amd64"])
        #expect(RegistryImages.unreachableText(list) == nil)
        #expect(RegistryImages.migrationText(list) == nil)
        #expect(RegistryImages.incompleteText(list)
            == "Node node-full listed only part of its images, so a Cached on cell may leave it out.")
        #expect(RegistryImages.tabResult(exitCode: 0, stdout: try fixture("image_ls.golden.json")) == .value(list))
        #expect(RegistryImages.keys(list) == Set(list.images.map(\.key)))
    }

    @Test("the image df golden is vendored and carries the same schema version and registry")
    func imageDiskGoldenIsVendored() throws {
        let object = try #require(try JSONSerialization.jsonObject(with: fixture("image_df.golden.json")) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == RegistryImages.schemaVersion)
        #expect((object["registry"] as? [String: Any])?["name"] as? String == "registry-k3sm:6450")
    }

    @Test("a schema version other than 1 is a typed error and a named failure")
    func otherSchemaVersionIsATypedError() {
        #expect(throws: RegistryImagesDecodeError.unsupportedSchema(2)) {
            try RegistryImages.decode(Self.json(#"{"schemaVersion":2,"registry":{"name":"r","reachable":true},"images":[]}"#))
        }
        #expect(throws: RegistryImagesDecodeError.unsupportedSchema(nil)) {
            try RegistryImages.decode(Self.json(#"{"registry":{"name":"r","reachable":true},"images":[]}"#))
        }
        #expect(throws: RegistryImagesDecodeError.unsupportedSchema(nil)) {
            try RegistryImages.decode(Self.json(#"{"schemaVersion":true,"registry":{"name":"r","reachable":true}}"#))
        }
        #expect(throws: RegistryImagesDecodeError.malformed) { try RegistryImages.decode(Self.json("[]")) }
        #expect(throws: RegistryImagesDecodeError.malformed) {
            try RegistryImages.decode(Self.json(#"{"schemaVersion":1}"#))
        }
        let result = RegistryImages.tabResult(exitCode: 0, stdout: Self.json(#"{"schemaVersion":3,"registry":{}}"#))
        #expect(result == .failed("k3sm image ls printed schema version 3; this app reads version 1."))
        #expect(RegistryImages.tabResult(exitCode: 1, stdout: Data()) == .failed("k3sm image ls exited 1"))
    }

    @Test("an unreachable registry is one line with its error, made safe to show")
    func unreachableRegistryIsOneLine() throws {
        let list = try RegistryImages.decode(Self.json(#"""
            {"schemaVersion":1,"registry":{"name":"registry-k3sm:6450","reachable":false,"error":"dial tcp:\nconnection refused‮"},"images":[],"cachedOnIncomplete":[],"migration":null}
            """#))
        #expect(!list.reachable)
        #expect(list.error == "dial tcp: connection refused")
        #expect(RegistryImages.unreachableText(list)
            == "The registry registry-k3sm:6450 could not be reached: dial tcp: connection refused.")
    }

    @Test("strings are clipped, bad digests and node names dropped, repeats and reference-less rows skipped, unknown keys ignored")
    func untrustedFieldsAreClipped() throws {
        let long = String(repeating: "a", count: 400)
        let list = try RegistryImages.decode(Self.json(#"""
            {"schemaVersion":1,"future":{"x":1},"registry":{"name":"evil‮name","reachable":true,"extra":1},
             "images":[
              {"reference":"r/\#(long):v1","digest":"sha256:XYZ","platforms":["darwin/arm64\n"],"sizeBytes":-1,"pods":true,"cachedOn":["node-a","Bad Node","node-a"],"new":"k"},
              {"reference":"r/\#(long):v1","digest":"sha256:aa"},
              {"repository":"no-reference"}
             ],
             "cachedOnIncomplete":["n1","n2","n3","n4"],"migration":null}
            """#))
        #expect(list.registryName == "evilname")
        #expect(list.images.count == 1)
        let image = try #require(list.images.first)
        #expect(image.reference.count <= StatusDisplay.maxLength)
        #expect(image.key == ImagesList.rowKey("r/\(long):v1"))
        #expect(image.digest == nil && image.shortDigest == nil)
        #expect(image.platforms == [StatusDisplay.clip("darwin/arm64\n")] && !image.platforms[0].contains("\n"))
        #expect(image.sizeBytes == nil)
        #expect(image.pods == nil)
        #expect(image.cachedOn == ["node-a"])
        #expect(RegistryImages.incompleteText(list)
            == "4 nodes listed only part of their images, so a Cached on cell may leave them out.")
    }

    @Test("a migration object's held count raises the banner; null, zero or no count does not")
    func migrationBannerFollowsHeldEntries() throws {
        func list(_ migration: String) throws -> RegistryImageList {
            try RegistryImages.decode(Self.json(#"{"schemaVersion":1,"registry":{"name":"r","reachable":true},"images":[],"migration":\#(migration)}"#))
        }
        #expect(try list(#"{"held":3,"moved":10,"other":"x"}"#).migration == RegistryMigration(held: 3))
        #expect(RegistryImages.migrationText(try list(#"{"held":3}"#))
            == "3 images stayed in a node's own store when images moved into the registry; load them again to move them.")
        #expect(RegistryImages.migrationText(try list(#"{"held":[{"ref":"a"}]}"#))
            == "1 image stayed in a node's own store when images moved into the registry; load them again to move them.")
        #expect(RegistryImages.migrationText(try list(#"{"held":0}"#)) == nil)
        #expect(try list(#"{"moved":2}"#).migration == RegistryMigration(held: nil))
        #expect(RegistryImages.migrationText(try list(#"{"moved":2}"#)) == nil)
        #expect(try list("null").migration == nil)
        #expect(RegistryImages.emptyText == "The cluster's registry holds no images.")
    }

    @Test("the search matches the reference, and the read runs image ls as JSON without root")
    func searchAndArguments() throws {
        let list = try RegistryImages.decode(fixture("image_ls.golden.json"))
        #expect(RegistryImages.visible(list.images, query: "MULTI").map(\.tag) == ["v1"])
        #expect(RegistryImages.visible(list.images, query: "").count == 3)
        #expect(K3smCLI.imageListArguments == ["image", "ls", "-o", "json"])
    }

    @Test("the inspector shows the reference, digest, platforms, size, pods and cached-on nodes")
    func inspectorShowsRegistryFacts() throws {
        let image = try #require(try RegistryImages.decode(fixture("image_ls.golden.json")).images.last)
        let body = InspectorDetails.registryImage(image)
        #expect(body.title == "registry-k3sm:6450/tools/multi:v1")
        #expect(body.facts.map { [$0.label, $0.value] } == [
            ["Reference", "registry-k3sm:6450/tools/multi:v1"],
            ["Digest", "sha256:65c0531fc64e75566854e90b1e9d5bdbc1620fdad674bd1f8579c4911909af28"],
            ["Platforms", "linux/arm64, linux/amd64"],
            ["Size", WorkloadsDisplay.bytes(178)],
            ["Pods", "2"],
            ["Cached on", "node-a"],
        ])
    }
}
