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

/// A Builds row's Show in Images: the build record's registry reference
/// (`build ls`, `reference`) mapped to a row of `k3sm image ls -o json`, or
/// to the line saying the image is gone.
@Suite("build image link")
struct BuildImageLinkTests {
    static let reference = "registry-k3sm:6450/myapp:dev"
    static let digest = "sha256:9f2c4e1b7a3d5f60812e4b9c0d7a6e5f4c3b2a1908f7e6d5c4b3a29180716253"

    static func list(_ images: String, reachable: Bool = true) throws -> RegistryImageList {
        try RegistryImages.decode(Data("""
            {"schemaVersion": 1, "registry": {"name": "registry-k3sm:6450", "reachable": \(reachable)}, "images": [\(images)]}
            """.utf8))
    }

    static func image(_ reference: String, digest: String) -> String {
        #"{"repository": "myapp", "tag": "dev", "reference": "\#(reference)", "digest": "\#(digest)"}"#
    }

    @Test("a succeeded build's reference selects its registry row, and an image no longer listed is gone")
    func buildRecordLinksRegistryImage() throws {
        let records = try BuildHistory.decode(fixture("build_ls_json.json"))
        let built = try #require(records.first { $0.status == .succeeded })
        #expect(built.reference == Self.reference)
        #expect(built.imageKey == Self.reference)

        // Listed under its reference with the digest the build recorded.
        let listed = try Self.list(Self.image(Self.reference, digest: Self.digest))
        let link = BuildHistory.imageLink(built, in: listed)
        #expect(link == .listed(Self.reference))
        #expect(link?.note == nil)
        #expect(listed.images.map(\.key).contains(Self.reference))

        // The golden registry does not hold it: gone, and the line says so.
        let golden = try RegistryImages.decode(fixture("image_ls.golden.json"))
        #expect(BuildHistory.imageLink(built, in: golden) == .gone)
        #expect(BuildImageLink.gone.note == BuildHistory.imageGoneText)

        // The tag now names another image: the build's own image is gone.
        let other = "sha256:" + String(repeating: "a", count: 64)
        #expect(BuildHistory.imageLink(built, in: try Self.list(Self.image(Self.reference, digest: other))) == .gone)

        // No read yet, or an unreachable registry, claims nothing.
        #expect(BuildHistory.imageLink(built, in: nil) == .unread)
        #expect(BuildHistory.imageLink(built, in: try Self.list("", reachable: false)) == .unread)
        #expect(BuildImageLink.unread.note == BuildHistory.imageUnreadText)

        // A record without a reference offers no link at all.
        for record in records where record.status != .succeeded {
            #expect(record.reference == nil)
            #expect(BuildHistory.imageLink(record, in: listed) == nil)
        }
    }

    @Test("a reference too long to show maps to the same row key the registry list uses")
    func longReferenceKeysMatch() throws {
        let long = "registry-k3sm:6450/" + String(repeating: "r", count: 300) + ":v1"
        let records = try BuildHistory.decode(Data("""
            [{"id": "aaaaaaaaaaaa", "tag": "x", "status": "succeeded", "reference": "\(long)"}]
            """.utf8))
        let record = try #require(records.first)
        let listed = try Self.list(Self.image(long, digest: Self.digest))
        let key = try #require(listed.images.first?.key)
        #expect(record.imageKey == key)
        #expect(BuildHistory.imageLink(record, in: listed) == .listed(key))
    }
}
