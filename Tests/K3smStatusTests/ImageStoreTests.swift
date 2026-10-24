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

/// The Images tab's writes: the reference check, the prune dry run's parse,
/// the offer per image on this Mac's node, and the Pods column.
@Suite("image store writes")
struct ImageStoreTests {
    static let hex = String(repeating: "0123456789abcdef", count: 4)
    static let hex2 = String(repeating: "fedcba9876543210", count: 4)
    static let note = "(dry run — pass --force to delete)"
    static let nothing = "  nothing to reclaim: every blob in the cache is referenced."
    static let registryHead = "registry registry-k3sm:6450:"
    static let skippedWhy = "this node runs no registry; prune the cluster registry on the server that runs it"
    static let skipped = [registryHead, "  skipped: " + skippedWhy, "node cache:"]
    static let gcTail = " untagged manifest(s); the registry's garbage collection reclaims their layers on its next sweep"

    // MARK: ImageRef

    @Test("references the grammar accepts", arguments: [
        "nginx", "nginx:1.27", "library/nginx:latest", "docker.io/library/nginx:1.27",
        "ghcr.io/k3sm-io/mlx-serve:v0.3.0", "localhost/app:dev", "localhost:5000/app", "registry.example.com:443/a/b/c:tag_1.2-x",
        "127.0.0.1:5000/team/app:1", "a__b/c-d--e.f:T", "nginx@sha256:" + hex, "docker.io/library/nginx:1.27@sha256:" + hex,
        "localhost:5000",
    ])
    func refAccepted(_ text: String) {
        #expect(ImageRef(text)?.value == text)
        #expect(ImageRef.problem(text) == nil)
    }

    struct Refused: Sendable, CustomTestStringConvertible {
        let text: String
        let problem: ImageRef.Problem
        var testDescription: String { text.debugDescription }
    }

    static let refused: [Refused] = [
        Refused(text: "", problem: .empty),
        Refused(text: "-n", problem: .badName),
        Refused(text: "--force", problem: .badName),
        Refused(text: "two words", problem: .invalidCharacter),
        Refused(text: "nginx;id", problem: .invalidCharacter),
        Refused(text: "$(id)", problem: .invalidCharacter),
        Refused(text: "`id`", problem: .invalidCharacter),
        Refused(text: "a'b", problem: .invalidCharacter),
        Refused(text: "nginx\n:1", problem: .invalidCharacter),
        Refused(text: "nginx\u{200B}:1", problem: .invalidCharacter),
        Refused(text: "ghcr.io/x/evil\u{202E}gnp.exe:1", problem: .invalidCharacter),
        Refused(text: "ngïnx", problem: .invalidCharacter),
        Refused(text: "Nginx", problem: .badName),
        Refused(text: "Library/nginx", problem: .badName),
        Refused(text: "nginx/", problem: .badName),
        Refused(text: "/nginx", problem: .badName),
        Refused(text: "a//b", problem: .badName),
        Refused(text: "a..b", problem: .badName),
        Refused(text: "a___b", problem: .badName),
        Refused(text: "a.-b", problem: .badName),
        Refused(text: ":tag", problem: .badName),
        Refused(text: "nginx:", problem: .badTag),
        Refused(text: "nginx:-x", problem: .badTag),
        Refused(text: "nginx:.x", problem: .badTag),
        Refused(text: "nginx:" + String(repeating: "t", count: 129), problem: .badTag),
        Refused(text: "nginx@sha256:abc", problem: .badDigest),
        Refused(text: "nginx@sha512:" + hex, problem: .badDigest),
        Refused(text: "nginx@sha256:" + hex.uppercased(), problem: .badDigest),
        Refused(text: "nginx@", problem: .badDigest),
        Refused(text: "-bad.io/x", problem: .badDomain),
        Refused(text: "bad-.io/x", problem: .badDomain),
        Refused(text: "a.io:/x", problem: .badDomain),
        Refused(text: "a.io:123456/x", problem: .badDomain),
        Refused(text: "a.io:12ab/x", problem: .badDomain),
        Refused(text: "[fd00::1]:5000/x", problem: .invalidCharacter),
        Refused(text: String(repeating: "a", count: 256), problem: .tooLong),
        Refused(text: String(repeating: "a", count: ImageRef.maxLength + 1), problem: .tooLong),
    ]

    @Test("references the grammar refuses, and why", arguments: refused)
    func refRefused(_ c: Refused) {
        #expect(ImageRef(c.text) == nil)
        #expect(ImageRef.problem(c.text) == c.problem)
    }

    @Test("every refusal has a line, and no accepted reference holds a shell character")
    func refLines() {
        for problem in [ImageRef.Problem.empty, .tooLong, .invalidCharacter, .badDomain, .badName, .badTag, .badDigest] {
            #expect(!problem.text.isEmpty)
        }
        for c in Self.refused where c.text.unicodeScalars.contains(where: { " ;$`'\"\\|&<>()*?~\n\t".unicodeScalars.contains($0) }) {
            #expect(ImageRef(c.text) == nil)
        }
        let longest = String(repeating: "a", count: 255) + ":" + String(repeating: "t", count: 128) + "@sha256:" + Self.hex
        #expect(longest.count == ImageRef.maxLength)
        #expect(ImageRef(longest) != nil)
    }

    // MARK: the prune dry run

    struct PruneCase: Sendable, CustomTestStringConvertible {
        let name: String
        let output: String
        let want: ImagePruneRead
        var testDescription: String { name }
    }

    static func preview(_ digests: [String], _ size: String, kept: [(String, Int)] = [],
                        registry: ImagePrunePreview.Registry = .init(skipped: skippedWhy)) -> ImagePruneRead {
        .read(ImagePrunePreview(digests: digests, size: size, kept: kept.map { ImagePrunePreview.Kept(reason: $0.0, count: $0.1) },
                                registry: registry))
    }

    /// A cache-only output behind the skipped registry half.
    static func cache(_ lines: [String]) -> String { (skipped + lines).joined(separator: "\n") }

    static let fullRegistry = ImagePrunePreview.Registry(
        manifests: ["apps/web@sha256:" + hex, "apps/api@sha256:" + hex2],
        kept: [.init(reason: "younger than the grace period", count: 1)], unreadable: ["apps/broken"])

    static let full = [
        registryHead,
        "  would delete apps/web@sha256:" + hex + " (untagged)",
        "  would delete apps/api@sha256:" + hex2 + " (untagged)",
        "  would delete 2" + gcTail,
        "  kept untagged:",
        "    younger than the grace period    1",
        "  unreadable, left alone: apps/broken",
        "node cache:",
        "  would delete sha256:" + hex,
        "  would delete sha256:" + hex2,
        "  would delete 2 blob(s), 1.5 MiB",
        "  kept:",
        "    in use by a pod              3",
        "    reachable                    12",
        note,
        "",
    ].joined(separator: "\n")

    static let fullRead = preview(["sha256:" + hex, "sha256:" + hex2], "1.5 MiB", kept: [("in use by a pod", 3), ("reachable", 12)],
                                  registry: fullRegistry)

    static let pruneCases: [PruneCase] = [
        PruneCase(name: "nothing to reclaim", output: cache([nothing, "  would delete 0 blob(s), 0 B", note, ""]),
                  want: preview([], "0 B")),
        PruneCase(name: "nothing to reclaim, with what it kept",
                  output: cache([nothing, "  would delete 0 blob(s), 0 B", "  kept:", "    in use by a pod           7", note]),
                  want: preview([], "0 B", kept: [("in use by a pod", 7)])),
        PruneCase(name: "both halves, and what each kept", output: full, want: fullRead),
        PruneCase(name: "an empty registry plan",
                  output: [registryHead, "  would delete 0" + gcTail, "node cache:", nothing, "  would delete 0 blob(s), 0 B", note]
                    .joined(separator: "\n"),
                  want: preview([], "0 B", registry: .init())),
        PruneCase(name: "the administrator prompt's carriage returns, no last newline",
                  output: full.replacingOccurrences(of: "\n", with: "\r").trimmingCharacters(in: .newlines), want: fullRead),
        PruneCase(name: "CRLF line endings", output: full.replacingOccurrences(of: "\n", with: "\r\n"), want: fullRead),
        PruneCase(name: "one blob, bytes", output: cache(["  would delete sha256:" + hex, "  would delete 1 blob(s), 512 B", note]),
                  want: preview(["sha256:" + hex], "512 B")),
        PruneCase(name: "an unknown skip reason renders as its enum name",
                  output: cache([nothing, "  would delete 0 blob(s), 0 B", "  kept:", "    PRUNE_SKIP_REASON_NEW    2", note]),
                  want: preview([], "0 B", kept: [("PRUNE_SKIP_REASON_NEW", 2)])),
        PruneCase(name: "empty output", output: "", want: .malformed(line: 1)),
        PruneCase(name: "the old one-section shape is refused",
                  output: ["would delete sha256:" + hex, "would delete 1 blob(s), 1.0 KiB", "(dry run — pass --force to unlink)"]
                    .joined(separator: "\n"),
                  want: .malformed(line: 1)),
        PruneCase(name: "no registry section", output: ["node cache:", nothing, "  would delete 0 blob(s), 0 B", note].joined(separator: "\n"),
                  want: .malformed(line: 1)),
        PruneCase(name: "a malformed line is refused", output: cache(["  would delete /etc/passwd", "  would delete 0 blob(s), 0 B", note]),
                  want: .malformed(line: 4)),
        PruneCase(name: "a stray line is refused", output: cache([nothing, "  would delete 0 blob(s), 0 B", "$(id)", note]),
                  want: .malformed(line: 6)),
        PruneCase(name: "a short digest", output: cache(["  would delete sha256:abc", "  would delete 1 blob(s), 1 B", note]),
                  want: .malformed(line: 4)),
        PruneCase(name: "the count does not match the digests",
                  output: cache(["  would delete sha256:" + hex, "  would delete 2 blob(s), 1.0 KiB", note]),
                  want: .malformed(line: 6)),
        PruneCase(name: "the registry count does not match its manifests",
                  output: [registryHead, "  would delete apps/web@sha256:" + hex + " (untagged)", "  would delete 2" + gcTail]
                    .joined(separator: "\n"),
                  want: .malformed(line: 3)),
        PruneCase(name: "a registry with no summary",
                  output: [registryHead, "  would delete apps/web@sha256:" + hex + " (untagged)", "node cache:"].joined(separator: "\n"),
                  want: .malformed(line: 3)),
        PruneCase(name: "a skipped registry beside a manifest",
                  output: [registryHead, "  would delete apps/web@sha256:" + hex + " (untagged)", "  skipped: " + skippedWhy]
                    .joined(separator: "\n"),
                  want: .malformed(line: 3)),
        PruneCase(name: "a manifest whose repository is not one word",
                  output: [registryHead, "  would delete a b@sha256:" + hex + " (untagged)"].joined(separator: "\n"),
                  want: .malformed(line: 2)),
        PruneCase(name: "a failed deletion in a dry run",
                  output: [registryHead, "  could not delete apps/web@sha256:" + hex + ": denied"].joined(separator: "\n"),
                  want: .malformed(line: 2)),
        PruneCase(name: "no dry-run note: not shown as a dry run",
                  output: cache(["  would delete sha256:" + hex, "  would delete 1 blob(s), 1.0 KiB"]),
                  want: .malformed(line: 5)),
        PruneCase(name: "a forced run's output is not a dry run",
                  output: cache(["  deleted sha256:" + hex, "  deleted 1 blob(s), 1.0 KiB"]),
                  want: .malformed(line: 4)),
        PruneCase(name: "a size not in the CLI's units",
                  output: cache(["  would delete sha256:" + hex, "  would delete 1 blob(s), 12 MB", note]),
                  want: .malformed(line: 5)),
        PruneCase(name: "a digest after the summary",
                  output: cache(["  would delete 0 blob(s), 0 B", "  would delete sha256:" + hex, note]),
                  want: .malformed(line: 5)),
        PruneCase(name: "nothing to reclaim beside a digest",
                  output: cache([nothing, "  would delete sha256:" + hex, "  would delete 1 blob(s), 1 B", note]),
                  want: .malformed(line: 5)),
        PruneCase(name: "zero blobs without the nothing line",
                  output: cache(["  would delete 0 blob(s), 0 B", note]), want: .malformed(line: 5)),
        PruneCase(name: "a kept block with no entry",
                  output: cache([nothing, "  would delete 0 blob(s), 0 B", "  kept:", note]), want: .malformed(line: 7)),
        PruneCase(name: "a kept entry with no count",
                  output: cache([nothing, "  would delete 0 blob(s), 0 B", "  kept:", "    in use by a pod", note]),
                  want: .malformed(line: 7)),
        PruneCase(name: "two summaries",
                  output: cache([nothing, "  would delete 0 blob(s), 0 B", "  would delete 0 blob(s), 0 B", note]),
                  want: .malformed(line: 6)),
        PruneCase(name: "a line after the note",
                  output: cache([nothing, "  would delete 0 blob(s), 0 B", note, "  would delete 0 blob(s), 0 B"]),
                  want: .malformed(line: 7)),
    ]

    @Test("the prune dry run parses its output shapes and refuses any other", arguments: pruneCases)
    func imagePruneDryRunParses(_ c: PruneCase) {
        #expect(ImagePrune.parse(c.output) == c.want)
    }

    @Test("a forced prune reads its own lines, never a dry run's")
    func forcedPruneParses() {
        let done = [
            Self.registryHead,
            "  deleted apps/web@sha256:" + Self.hex + " (untagged)",
            "  could not delete apps/api@sha256:" + Self.hex2 + ": DELETE: unexpected status code 500",
            "  deleted 1" + Self.gcTail,
            "node cache:",
            "  deleted sha256:" + Self.hex,
            "  deleted 1 blob(s), 2.0 GiB",
            "  kept:",
            "    reachable                    4",
        ].joined(separator: "\n")
        #expect(ImagePrune.parse(done, forced: true)
                == Self.preview(["sha256:" + Self.hex], "2.0 GiB", kept: [("reachable", 4)],
                                registry: .init(manifests: ["apps/web@sha256:" + Self.hex], failed: 1)))
        #expect(ImagePrune.parse(Self.full, forced: true) == .malformed(line: 2))
        let withNote = Self.cache(["  deleted 0 blob(s), 0 B", Self.note])
        #expect(ImagePrune.parse(withNote, forced: true) == .malformed(line: 5))
        #expect(ImageStoreText.pruned(output: done, node: "studio")
                == "Deleted 1 blob, 2.0 GiB, on node studio, and 1 untagged manifest from the cluster registry.")
        #expect(ImageStoreText.pruned(output: Self.cache(["  deleted sha256:" + Self.hex, "  deleted 1 blob(s), 2.0 GiB"]), node: "studio")
                == "Deleted 1 blob, 2.0 GiB, on node studio.")
        #expect(ImageStoreText.pruned(output: "garbage", node: "studio").contains("did not say"))
    }

    @Test("an output past the line bound is refused, not read")
    func pruneTooLong() {
        let lines = Array(repeating: "would delete sha256:" + Self.hex, count: ImagePrune.maxLines + 1)
        #expect(ImagePrune.parse(lines.joined(separator: "\n")) == .tooLong)
        #expect(ImageStoreText.previewUnreadable(.tooLong).contains("nothing was deleted"))
        #expect(ImageStoreText.previewUnreadable(.malformed(line: 3)).contains("line 3"))
    }

    @Test("the preview sheet names the node, lists a bounded number of digests and says what it kept")
    func previewText() {
        let many = (0..<(ImagePrunePreview.shownDigests + 5)).map { _ in "sha256:" + Self.hex }
        let preview = ImagePrunePreview(digests: many, size: "3.0 GiB", kept: [.init(reason: "reachable", count: 2)], registry: .init())
        #expect(ImageStoreText.pruneLead(preview, node: "studio")
                == "On node studio, this Mac, the prune would delete 205 blobs no pod and no name references, 3.0 GiB:")
        let lines = ImageStoreText.pruneDigests(preview)
        #expect(lines.count == ImagePrunePreview.shownDigests + 1)
        #expect(lines.last == "and 5 more")
        #expect(ImageStoreText.pruneKept(preview) == "Kept: 2 reachable.")
        let empty = ImagePrunePreview(digests: [], size: "0 B", kept: [], registry: .init())
        #expect(ImageStoreText.pruneLead(empty, node: "studio").hasPrefix("Nothing to reclaim in the cache of node studio"))
        #expect(empty.nothingToReclaim)
        #expect(ImageStoreText.pruneKept(empty) == nil)
    }

    @Test("the preview's registry line counts the untagged manifests the prune would delete")
    func previewRegistryManifests() {
        let one = ImagePrunePreview(digests: [], size: "0 B", kept: [],
                                    registry: .init(manifests: ["apps/web@sha256:" + Self.hex]))
        #expect(ImageStoreText.pruneRegistry(one)
                == "It would also delete 1 untagged manifest from the cluster registry; "
                + "the registry reclaims their layers on its next garbage collection.")
        let two = ImagePrunePreview(digests: [], size: "0 B", kept: [],
                                    registry: .init(manifests: ["apps/web@sha256:" + Self.hex, "apps/api@sha256:" + Self.hex]))
        #expect(ImageStoreText.pruneRegistry(two)?.hasPrefix("It would also delete 2 untagged manifests from the cluster registry") == true)
    }

    @Test("the preview's registry line gives the reason when this node skips the registry")
    func previewRegistrySkipped() {
        let skipped = ImagePrunePreview(digests: [], size: "0 B", kept: [],
                                        registry: .init(skipped: Self.skippedWhy))
        #expect(ImageStoreText.pruneRegistry(skipped) == "Cluster registry: skipped, " + Self.skippedWhy + ".")
    }

    @Test("the preview has no registry line when the registry has nothing untagged")
    func previewRegistryNone() {
        let none = ImagePrunePreview(digests: ["sha256:" + Self.hex], size: "1 MiB", kept: [], registry: .init())
        #expect(ImageStoreText.pruneRegistry(none) == nil)
    }

    /// The k3sm checkout the prune's output shape is checked against.
    static func k3smSource(_ path: String) -> URL? {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = ProcessInfo.processInfo.environment["K3SM_DIR"].map { URL(fileURLWithPath: $0) }
            ?? root.deletingLastPathComponent().appending(path: "k3sm")
        let file = dir.appending(path: path)
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    static var pruneSource: URL? { k3smSource("cmd/k3sm/imageprune.go") }
    static var imageSource: URL? { k3smSource("cmd/k3sm/image.go") }

    @Test("the lines read are the ones cmd/k3sm/imageprune.go prints", .enabled(if: pruneSource != nil && imageSource != nil))
    func pruneShapeMatchesTheCLI() throws {
        let prune = try String(contentsOf: try #require(Self.pruneSource), encoding: .utf8)
        let render = try #require(prune.range(of: "func renderPrune("), "no renderPrune in cmd/k3sm/imageprune.go; the scrape is stale")
        let body = prune[render.upperBound...].prefix(3000)
        for line in [
            #"verb := "would delete""#, #"verb = "deleted""#,
            #""registry %s:\n""#, #""  skipped: %s\n""#, #""  %s %s@%s (untagged)\n""#,
            #""  could not delete %s@%s: %s\n""#,
            #""  %s %d untagged manifest(s); the registry's garbage collection reclaims their layers on its next sweep\n""#,
            #""  kept untagged:""#, #""  unreadable, left alone: %s\n""#, #""node cache:""#,
            #""  nothing to reclaim: every blob in the cache is referenced.""#,
            #""  %s %s\n", verb, d"#, #""  %s %d blob(s), %s\n""#,
            #""  kept:""#, #""(dry run — pass --force to delete)""#, #"renderCounts(out, r.Cache.Kept, "    ")"#,
            #""%s%-28s %d\n""#,
        ] {
            #expect(body.contains(line), "renderPrune no longer prints \(line)")
        }
        #expect(prune.contains("DryRun: !o.force"))
        let image = try String(contentsOf: try #require(Self.imageSource), encoding: .utf8)
        #expect(image.contains(#"return fmt.Sprintf("%d B", n)"#))
        #expect(image.contains(#"return fmt.Sprintf("%.1f %ciB", float64(n)/float64(div), "KMGTPE"[exp])"#))
    }

    // MARK: this Mac's node

    static let here = ImageStoreScope(node: "studio")

    static func image(nodes: [String], tags: [String: [String]]) -> NodeImage {
        var image = NodeImage(key: "sha256:" + hex, digest: "sha256:" + hex, names: ["nginx:1"], sizeBytes: 1, nodes: nodes)
        image.tags = tags.mapValues { $0.compactMap(ImageRef.init) }
        return image
    }

    @Test("the scope names this Mac's node only as a ResourceName")
    func scopeNamesTheNode() {
        #expect(ImageStoreScope.decide(report: nil).node == nil)
        #expect(ImageStoreScope(node: "$(id)").node == nil)
        #expect(ImageStoreScope(node: nil).label == "This Mac: node not known")
        #expect(Self.here.label == "This Mac: node studio")
    }

    @Test("the tags come from each node's own names, unclipped, and only those ImageRef passes")
    func tagsPerNode() throws {
        let long = "registry.example.com/" + String(repeating: "a", count: 170) + ":1"
        let a = ImagesListTests.node("studio", images: #"""
            [{"names":["docker.io/library/nginx@sha256:\#(Self.hex)","docker.io/library/nginx:1.27","\#(long)"],"sizeBytes":7},
             {"names":["docker.io/library/nginx:1.2\u200B7"],"sizeBytes":7}]
            """#)
        let b = ImagesListTests.node("laptop", images: #"""
            [{"names":["docker.io/library/nginx@sha256:\#(Self.hex)","docker.io/library/nginx:latest"],"sizeBytes":7}]
            """#)
        let read = try NodeListRead.decode(ImagesListTests.list([a, b]))
        guard case .listed(let images) = read.images else { Issue.record("not listed"); return }
        let nginx = try #require(images.first { $0.digest == "sha256:" + Self.hex })
        #expect(nginx.tags["studio"]?.map(\.value) == ["docker.io/library/nginx:1.27", long])
        #expect(nginx.tags["laptop"]?.map(\.value) == ["docker.io/library/nginx:latest"])
        #expect(nginx.names.contains(StatusDisplay.clip(long)))
        #expect(StatusDisplay.clip(long) != long)
        // The zero-width space clips to a real-looking name, which is never offered.
        let lookalike = try #require(images.first { $0.digest == nil })
        #expect(lookalike.names == ["docker.io/library/nginx:1.27"])
        #expect(lookalike.tags.isEmpty)
    }

    // MARK: the Pods column

    static func pod(_ name: String, image: String, node: String? = "studio") -> Pod {
        Pod(name: name, namespace: "default", uid: name, image: image, kind: .nativeProcess, phase: "Running", health: .running,
            ready: true, restarts: 0, ports: [], owner: nil, created: nil, cpuRequest: nil, memoryRequest: nil, nodeName: node)
    }

    @Test("the Pods column counts the listed pods using each image")
    func podCounts() {
        let nginx = NodeImage(key: "sha256:" + Self.hex, digest: "sha256:" + Self.hex,
                              names: ["docker.io/library/nginx:1.27", "docker.io/library/nginx@sha256:" + Self.hex],
                              sizeBytes: 1, nodes: ["studio"])
        let other = NodeImage(key: "ghcr.io/x/y:1", digest: nil, names: ["ghcr.io/x/y:1"], sizeBytes: 1, nodes: ["studio"])
        let pods = [
            Self.pod("a", image: "nginx:1.27"), Self.pod("b", image: "docker.io/library/nginx:1.27"),
            Self.pod("c", image: "quay.io/x/nginx@sha256:" + Self.hex), Self.pod("d", image: "nginx:1.26"), Self.pod("e", image: ""),
        ]
        let counts = ImagesList.podCounts([nginx, other], pods: pods)
        #expect(counts[nginx.key] == 3)
        #expect(counts[other.key] == 0)
        #expect(ImagesList.podsText(3) == "3")
        #expect(ImagesList.podsText(0) == "0")
        #expect(ImagesList.podsText(nil) == "")
        #expect(TableColumns.images.column(.pods)?.title == "Pods")
    }

    // MARK: the argv and the questions

    @Test("the image verbs' argv", arguments: [
        (K3smCLI.imagePruneDryRunArguments, ["image", "prune"]),
        (K3smCLI.imagePruneArguments, ["image", "prune", "--force"]),
        (K3smCLI.imageUntagArguments(RegistryTag(reference: "registry-k3sm:6450/nginx:1.27", digest: "sha256:" + hex)!),
         ["image", "untag", "registry-k3sm:6450/nginx:1.27", "--digest", "sha256:" + hex]),
        (K3smCLI.imagePullArguments(ImageRef("ghcr.io/a/b@sha256:" + hex)!), ["image", "pull", "ghcr.io/a/b@sha256:" + hex]),
    ])
    func argv(_ pair: ([String], [String])) {
        #expect(pair.0 == pair.1)
    }

    @Test("the registry the daemon contacts, by go-containerregistry's rule", arguments: [
        ("nginx:1.27", nil), ("library/nginx", nil), ("localhost/app:dev", nil), ("a__b/c", nil),
        ("docker.io/library/nginx:1.27", "docker.io"), ("ghcr.io/k3sm-io/app", "ghcr.io"),
        ("localhost:5000/app", "localhost:5000"), ("127.0.0.1:5000/a/b", "127.0.0.1:5000"), ("registry.example.com:443/a", "registry.example.com:443"),
    ] as [(String, String?)])
    func registryHost(_ pair: (String, String?)) {
        #expect(ImageRef(pair.0)?.registryHost == pair.1)
    }

    @Test("Pull's question names the registry in its own sentence")
    func pullQuestion() {
        let hub = ImageStoreText.pullQuestion(ImageRef("nginx:1.27")!, node: "studio")
        #expect(hub.title == "Mirror nginx:1.27?")
        #expect(hub.message == "k3sm pulls nginx:1.27 into the image cache of node studio, this Mac, then copies it into the cluster registry, "
                + "which nodes pull from when its own registry cannot be reached. "
                + "The copy uses the server's own administrator credential, not your kubeconfig, so on an agent it is skipped. "
                + "The image daemon, running as root, contacts this node's own registry if it has one, "
                + "then Docker Hub (index.docker.io), with no credential.")
        let local = ImageStoreText.registrySentence(ImageRef("localhost:5000/app:1")!)
        #expect(local.contains("contacts localhost:5000, this node's own registry, then the other nodes' registries"))
        #expect(ImageRef("127.0.0.1:5000/a")!.registryIsLoopback)
        #expect(!ImageRef("ghcr.io/a")!.registryIsLoopback)
        #expect(ImageStoreText.registrySentence(ImageRef("ghcr.io/a/b:1")!) == "The image daemon, running as root, contacts ghcr.io, with no credential.")
    }

    @Test("Untag asks naming the tag and its digest, and the prompts name where they act")
    func questions() throws {
        let tag = try #require(RegistryTag(reference: "registry-k3sm:6450/nginx:1.27", digest: "sha256:" + Self.hex))
        let q = ImageStoreText.untagQuestion(tag)
        #expect(q.title == "Untag registry-k3sm:6450/nginx:1.27?")
        #expect(q.message.contains("from the cluster registry, refused if the tag already names content other than sha256:" + Self.hex))
        #expect(!q.message.contains("only while"))
        #expect(!ImageStoreText.untagNote.contains("only while"))
        #expect(ImageStoreText.untagNote.contains("refused if the tag already names content other than the digest above"))
        #expect(ImageStoreText.prompt(untag: tag).contains("the cluster registry"))
        let ref = ImageRef("nginx:1.27")!
        #expect(ImageStoreText.prompt(pull: ref)
                == "k3sm wants to pull nginx:1.27 to this Mac and copy it into the cluster registry with the server's credential.")
        #expect(ImageStoreText.pullNote.contains("with the server's own credential; an agent skips the copy"))
        #expect(ImageStoreText.prompt(pull: ImageRef("localhost:5000/a:1")!) == "k3sm wants to pull localhost:5000/a:1 into this Mac's image cache.")
        #expect(ImageStoreText.promptPruneDryRun.contains("this Mac"))
        #expect(ImageStoreText.promptPrune.contains("this Mac"))
        #expect(ImageStoreText.pulled(ref, node: "studio", output: "up to date nginx:1.27\r  digest:   sha256:x\r  mirror:   registry-k3sm:6450/docker.io/library/nginx:1.27",
                                      warning: nil)
                == "nginx:1.27 was already up to date on node studio and was copied into the cluster registry as registry-k3sm:6450/docker.io/library/nginx:1.27.")
        #expect(ImageStoreText.pulled(ref, node: "studio", output: "pulled nginx:1.27", warning: nil)
                == "Pulled nginx:1.27 on node studio, but k3sm did not report a copy in the cluster registry.")
        // On an agent the copy needs the server: the line says it was skipped, over the CLI's warning.
        let skipped = "Pulled nginx:1.27 on node laptop. The copy into the cluster registry was skipped: it needs the server, "
            + "whose own credential writes it."
        #expect(ImageStoreText.pulled(ref, node: "laptop", role: .agent, output: "pulled nginx:1.27", warning: nil) == skipped)
        #expect(ImageStoreText.pulled(ref, node: "laptop", role: .agent, output: "pulled nginx:1.27",
                                      warning: "k3sm image pull: warning: no admin credential\n") == skipped)
        // A mirror name that does not pass ImageRef is not shown.
        #expect(ImageStoreText.pulled(ref, node: "studio", output: "pulled nginx:1.27\n  mirror:   evil\u{202E}name; id", warning: nil)
                == "Pulled nginx:1.27 on node studio, but k3sm did not report a copy in the cluster registry.")
        let local = ImageRef("registry-k3sm:6450/app:v1")!
        #expect(ImageStoreText.pulled(local, node: "studio", output: "pulled registry-k3sm:6450/app:v1", warning: nil)
                == "Pulled registry-k3sm:6450/app:v1 on node studio.")
        #expect(ImageStoreText.untagged(tag) == "Untagged registry-k3sm:6450/nginx:1.27 in the cluster registry.")
    }
}
