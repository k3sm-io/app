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

/// The Images tab's three actions against the cluster registry: Untag
/// deletes a registry tag pinned to its digest, Prune offers the registry's
/// untagged manifests even when the node cache has nothing to reclaim, and
/// Mirror pulls a public image and copies it into the registry.
@Suite("image actions on the cluster registry")
struct ImageActionsTests {
    static let hex = String(repeating: "0123456789abcdef", count: 4)
    static let digest = "sha256:" + hex

    static func row(_ reference: String, digest: String? = ImageActionsTests.digest) throws -> RegistryImage {
        let digestField = digest.map { ",\"digest\":\"\($0)\"" } ?? ""
        let json = "{\"schemaVersion\":1,\"registry\":{\"name\":\"registry-k3sm:6450\",\"reachable\":true},"
            + "\"images\":[{\"reference\":\"\(reference)\",\"repository\":\"app\",\"tag\":\"v1\"\(digestField)}]}"
        return try #require(RegistryImages.decode(Data(json.utf8)).images.first)
    }

    static let tail = " untagged manifest(s); the registry's garbage collection reclaims their layers on its next sweep"

    static let lowerHex: String = String(repeating: "0123456789abcdef", count: 4)
    static let halfHex: String = String(repeating: "0123456789abcdef", count: 2)
    static let hostileDigests: [String] = [
        "junk@sha256:" + lowerHex,
        "sha256:" + lowerHex + "\n",
        "sha256:" + halfHex + "\n" + halfHex,
        "sha256:" + lowerHex.uppercased(),
        "SHA256:" + lowerHex,
        " sha256:" + lowerHex,
    ]

    @Test("RegistryTag refuses a hostile digest field", arguments: hostileDigests)
    func hostileDigest(_ digest: String) {
        #expect(RegistryTag(reference: "registry-k3sm:6450/app:v1", digest: digest) == nil)
        #expect(RegistryTag(reference: "registry-k3sm:6450/app:v1", digest: Self.digest) != nil)
    }

    @Test("Untag, Prune and Mirror act on the cluster registry")
    func imageActionsTargetTheRegistry() throws {
        // Untag: a registry row's tag, pinned to the digest the list read.
        let image = try Self.row("registry-k3sm:6450/app:v1")
        let tag = try #require(image.untag)
        #expect(K3smCLI.imageUntagArguments(tag) == ["image", "untag", "registry-k3sm:6450/app:v1", "--digest", Self.digest])
        #expect(try Self.row("registry-k3sm:6450/app:v1", digest: nil).untag == nil)
        #expect(RegistryTag(reference: "docker.io/library/nginx:1", digest: Self.digest) == nil)
        #expect(RegistryTag(reference: "registry-k3sm:6450/app@" + Self.digest, digest: Self.digest) == nil)
        #expect(RegistryTag(reference: "registry-k3sm:6450/app:v1@" + Self.digest, digest: Self.digest) == nil)
        #expect(RegistryTag(reference: "registry-k3sm:6450/app", digest: Self.digest) == nil)
        #expect(RegistryTag(reference: "registry-k3sm:6450/app:v1", digest: "sha256:abc") == nil)
        #expect(RegistryTag(reference: "registry-k3sm:6450/app:v1; id", digest: Self.digest) == nil)
        #expect(RegistryTag(reference: "registry-k3sm:6450/app:v1", digest: "--force") == nil)
        #expect(RegistryTag(reference: "registry-k3sm:64500/app:v1", digest: Self.digest) == nil)
        // It runs where the registry's credential is: the server.
        #expect(ImageStoreText.untagUnavailable(image, role: .server) == nil)
        #expect(ImageStoreText.untagUnavailable(image, role: .agent) == ImageStoreText.untagOnServer)
        #expect(ImageStoreText.untagUnavailable(image, role: nil) == ImageStoreText.untagOnServer)
        #expect(ImageStoreText.untagUnavailable(try Self.row("registry-k3sm:6450/app:v1", digest: nil), role: .server)
                == ImageStoreText.untagNoDigest)
        let question = ImageStoreText.untagQuestion(tag)
        #expect(question.title == "Untag registry-k3sm:6450/app:v1?")
        #expect(question.message.contains("from the cluster registry"))
        #expect(question.message.contains(Self.digest))
        #expect(ImageStoreText.prompt(untag: tag) == "k3sm wants to delete the tag registry-k3sm:6450/app:v1 from the cluster registry.")
        #expect(ImageStoreText.untagged(tag) == "Untagged registry-k3sm:6450/app:v1 in the cluster registry.")

        // Prune: the dry run, then --force; an empty node cache still offers the registry half.
        #expect(K3smCLI.imagePruneDryRunArguments == ["image", "prune"])
        #expect(K3smCLI.imagePruneArguments == ["image", "prune", "--force"])
        let registryOnly = ["registry registry-k3sm:6450:", "  would delete app@\(Self.digest) (untagged)", "  would delete 1" + Self.tail,
                            "node cache:", "  nothing to reclaim: every blob in the cache is referenced.",
                            "  would delete 0 blob(s), 0 B", "(dry run — pass --force to delete)"].joined(separator: "\n")
        guard case .read(let preview) = ImagePrune.parse(registryOnly) else {
            Issue.record("the registry-only dry run did not read")
            return
        }
        #expect(preview.digests.isEmpty)
        #expect(!preview.nothingToReclaim)
        #expect(ImageStoreText.pruneLead(preview, node: "studio")
                == "Nothing to reclaim in the cache of node studio, this Mac: a pod or a name references every blob.")
        #expect(ImageStoreText.pruneRegistry(preview)?.hasPrefix("It would also delete 1 untagged manifest from the cluster registry") == true)
        let nothing = ["registry registry-k3sm:6450:", "  would delete 0" + Self.tail, "node cache:",
                       "  nothing to reclaim: every blob in the cache is referenced.",
                       "  would delete 0 blob(s), 0 B", "(dry run — pass --force to delete)"].joined(separator: "\n")
        guard case .read(let empty) = ImagePrune.parse(nothing) else {
            Issue.record("the empty dry run did not read")
            return
        }
        #expect(empty.nothingToReclaim)
        let forced = ["registry registry-k3sm:6450:", "  deleted app@\(Self.digest) (untagged)", "  deleted 1" + Self.tail,
                      "node cache:", "  nothing to reclaim: every blob in the cache is referenced.",
                      "  deleted 0 blob(s), 0 B"].joined(separator: "\n")
        #expect(ImageStoreText.pruned(output: forced, node: "studio")
                == "Deleted 1 untagged manifest from the cluster registry. Node studio's cache had nothing to delete.")

        // Mirror: the pull copies a public image into the cluster registry, by the CLI's default.
        let nginx = try #require(ImageRef("docker.io/library/nginx:1.27"))
        #expect(K3smCLI.imagePullArguments(nginx) == ["image", "pull", "docker.io/library/nginx:1.27"])
        #expect(nginx.mirrorsToRegistry)
        #expect(ImageRef("nginx:1.27")!.mirrorsToRegistry)
        #expect(!ImageRef("registry-k3sm:6450/app:v1")!.mirrorsToRegistry)
        #expect(!ImageRef("localhost:5000/app:1")!.mirrorsToRegistry)
        #expect(ImageStoreText.pullQuestion(nginx, node: "studio").message.contains("then copies it into the cluster registry"))
        #expect(ImageStoreText.pullQuestion(ImageRef("registry-k3sm:6450/app:v1")!, node: "studio").message
            .contains("No copy is written"))
        let mirrored = "pulled docker.io/library/nginx:1.27\n  digest:   \(Self.digest)\n  mirror:   registry-k3sm:6450/docker.io/library/nginx:1.27\n"
        #expect(ImageStoreText.pulled(nginx, node: "studio", output: mirrored, warning: nil)
                == "Pulled docker.io/library/nginx:1.27 on node studio and copied it into the cluster registry as registry-k3sm:6450/docker.io/library/nginx:1.27.")
        let warned = ImageStoreText.pulled(nginx, node: "studio", output: "pulled docker.io/library/nginx:1.27\n",
                                           warning: "k3sm image pull: warning: the copy was not written: no route\n")
        #expect(warned.hasPrefix("Pulled docker.io/library/nginx:1.27 on node studio, but its copy in the cluster registry was not written:"))
        #expect(warned.contains("no route"))
    }
}
