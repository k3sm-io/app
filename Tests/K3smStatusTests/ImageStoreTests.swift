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
    static let note = "(dry run — pass --force to unlink)"
    static let nothing = "nothing to reclaim: every blob in the store is referenced."

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

    static func preview(_ digests: [String], _ size: String, kept: [(String, Int)] = []) -> ImagePruneRead {
        .read(ImagePrunePreview(digests: digests, size: size, kept: kept.map { ImagePrunePreview.Kept(reason: $0.0, count: $0.1) }))
    }

    static let full = [
        "would delete sha256:" + hex,
        "would delete sha256:" + hex2,
        "would delete 2 blob(s), 1.5 MiB",
        note,
        "kept:",
        "  in use by a pod           3",
        "  reachable                 12",
        "",
    ].joined(separator: "\n")

    static let pruneCases: [PruneCase] = [
        PruneCase(name: "nothing to reclaim", output: [nothing, "would delete 0 blob(s), 0 B", note, ""].joined(separator: "\n"),
                  want: preview([], "0 B")),
        PruneCase(name: "nothing to reclaim, with what it kept",
                  output: [nothing, "would delete 0 blob(s), 0 B", note, "kept:", "  in use by a pod           7"].joined(separator: "\n"),
                  want: preview([], "0 B", kept: [("in use by a pod", 7)])),
        PruneCase(name: "two blobs, and what it kept", output: full,
                  want: preview(["sha256:" + hex, "sha256:" + hex2], "1.5 MiB", kept: [("in use by a pod", 3), ("reachable", 12)])),
        PruneCase(name: "the administrator prompt's carriage returns, no last newline",
                  output: full.replacingOccurrences(of: "\n", with: "\r").trimmingCharacters(in: .newlines),
                  want: preview(["sha256:" + hex, "sha256:" + hex2], "1.5 MiB", kept: [("in use by a pod", 3), ("reachable", 12)])),
        PruneCase(name: "CRLF line endings", output: full.replacingOccurrences(of: "\n", with: "\r\n"),
                  want: preview(["sha256:" + hex, "sha256:" + hex2], "1.5 MiB", kept: [("in use by a pod", 3), ("reachable", 12)])),
        PruneCase(name: "one blob, bytes", output: ["would delete sha256:" + hex, "would delete 1 blob(s), 512 B", note].joined(separator: "\n"),
                  want: preview(["sha256:" + hex], "512 B")),
        PruneCase(name: "an unknown skip reason renders as its enum name",
                  output: [nothing, "would delete 0 blob(s), 0 B", note, "kept:", "  PRUNE_SKIP_REASON_NEW    2"].joined(separator: "\n"),
                  want: preview([], "0 B", kept: [("PRUNE_SKIP_REASON_NEW", 2)])),
        PruneCase(name: "empty output", output: "", want: .malformed(line: 1)),
        PruneCase(name: "a malformed line is refused", output: ["would delete /etc/passwd", "would delete 0 blob(s), 0 B", note].joined(separator: "\n"),
                  want: .malformed(line: 1)),
        PruneCase(name: "a stray line is refused", output: [nothing, "would delete 0 blob(s), 0 B", "$(id)", note].joined(separator: "\n"),
                  want: .malformed(line: 3)),
        PruneCase(name: "a short digest", output: ["would delete sha256:abc", "would delete 1 blob(s), 1 B", note].joined(separator: "\n"),
                  want: .malformed(line: 1)),
        PruneCase(name: "the count does not match the digests",
                  output: ["would delete sha256:" + hex, "would delete 2 blob(s), 1.0 KiB", note].joined(separator: "\n"),
                  want: .malformed(line: 3)),
        PruneCase(name: "no dry-run note: not shown as a dry run",
                  output: ["would delete sha256:" + hex, "would delete 1 blob(s), 1.0 KiB"].joined(separator: "\n"),
                  want: .malformed(line: 2)),
        PruneCase(name: "a forced run's output is not a dry run",
                  output: ["deleted sha256:" + hex, "deleted 1 blob(s), 1.0 KiB"].joined(separator: "\n"),
                  want: .malformed(line: 1)),
        PruneCase(name: "a size not in the CLI's units",
                  output: ["would delete sha256:" + hex, "would delete 1 blob(s), 12 MB", note].joined(separator: "\n"),
                  want: .malformed(line: 2)),
        PruneCase(name: "a digest after the summary",
                  output: ["would delete 0 blob(s), 0 B", "would delete sha256:" + hex, note].joined(separator: "\n"),
                  want: .malformed(line: 2)),
        PruneCase(name: "nothing to reclaim beside a digest",
                  output: [nothing, "would delete sha256:" + hex, "would delete 1 blob(s), 1 B", note].joined(separator: "\n"),
                  want: .malformed(line: 2)),
        PruneCase(name: "zero blobs without the nothing line",
                  output: ["would delete 0 blob(s), 0 B", note].joined(separator: "\n"), want: .malformed(line: 2)),
        PruneCase(name: "a kept block with no entry",
                  output: [nothing, "would delete 0 blob(s), 0 B", note, "kept:"].joined(separator: "\n"), want: .malformed(line: 4)),
        PruneCase(name: "a kept entry with no count",
                  output: [nothing, "would delete 0 blob(s), 0 B", note, "kept:", "  in use by a pod"].joined(separator: "\n"),
                  want: .malformed(line: 5)),
        PruneCase(name: "two summaries",
                  output: [nothing, "would delete 0 blob(s), 0 B", "would delete 0 blob(s), 0 B", note].joined(separator: "\n"),
                  want: .malformed(line: 3)),
    ]

    @Test("the prune dry run parses its output shapes and refuses any other", arguments: pruneCases)
    func imagePruneDryRunParses(_ c: PruneCase) {
        #expect(ImagePrune.parse(c.output) == c.want)
    }

    @Test("a forced prune reads its own lines, never a dry run's")
    func forcedPruneParses() {
        let done = ["deleted sha256:" + Self.hex, "deleted 1 blob(s), 2.0 GiB", "kept:", "  reachable                 4"].joined(separator: "\n")
        #expect(ImagePrune.parse(done, forced: true) == Self.preview(["sha256:" + Self.hex], "2.0 GiB", kept: [("reachable", 4)]))
        #expect(ImagePrune.parse(Self.full, forced: true) == .malformed(line: 1))
        let withNote = ["deleted 0 blob(s), 0 B", Self.note].joined(separator: "\n")
        #expect(ImagePrune.parse(withNote, forced: true) == .malformed(line: 2))
        #expect(ImageStoreText.pruned(output: done, node: "studio") == "Deleted 1 blob, 2.0 GiB, on node studio.")
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
        let preview = ImagePrunePreview(digests: many, size: "3.0 GiB", kept: [.init(reason: "reachable", count: 2)])
        #expect(ImageStoreText.pruneLead(preview, node: "studio")
                == "On node studio, this Mac, the prune would delete 205 blobs no pod and no name references, 3.0 GiB:")
        let lines = ImageStoreText.pruneDigests(preview)
        #expect(lines.count == ImagePrunePreview.shownDigests + 1)
        #expect(lines.last == "and 5 more")
        #expect(ImageStoreText.pruneKept(preview) == "Kept: 2 reachable.")
        let empty = ImagePrunePreview(digests: [], size: "0 B", kept: [])
        #expect(ImageStoreText.pruneLead(empty, node: "studio").hasPrefix("Nothing to reclaim on node studio"))
        #expect(ImageStoreText.pruneKept(empty) == nil)
    }

    /// The k3sm checkout the prune's output shape is checked against.
    static var imageSource: URL? {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = ProcessInfo.processInfo.environment["K3SM_DIR"].map { URL(fileURLWithPath: $0) }
            ?? root.deletingLastPathComponent().appending(path: "k3sm")
        let file = dir.appending(path: "cmd/k3sm/image.go")
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    @Test("the lines read are the ones cmd/k3sm/image.go prints", .enabled(if: imageSource != nil))
    func pruneShapeMatchesTheCLI() throws {
        let source = try String(contentsOf: try #require(Self.imageSource), encoding: .utf8)
        let start = try #require(source.range(of: "func imagePrune("), "no imagePrune in cmd/k3sm/image.go; the scrape is stale")
        let body = source[start.upperBound...].prefix(2500)
        for line in [
            #"verb := "would delete""#, #"verb = "deleted""#,
            #""nothing to reclaim: every blob in the store is referenced.""#,
            #""%s %s\n", verb, d"#, #""%s %d blob(s), %s\n""#,
            #""(dry run"#, #""kept:""#, #""  %-24s %d\n""#, "DryRun: !o.force",
        ] {
            #expect(body.contains(line), "imagePrune no longer prints \(line)")
        }
        #expect(source.contains(#"return fmt.Sprintf("%d B", n)"#))
        #expect(source.contains(#"return fmt.Sprintf("%.1f %ciB", float64(n)/float64(div), "KMGTPE"[exp])"#))
    }

    // MARK: this Mac's node

    static let here = ImageStoreScope(node: "studio")

    static func image(nodes: [String], tags: [String: [String]]) -> NodeImage {
        var image = NodeImage(key: "sha256:" + hex, digest: "sha256:" + hex, names: ["nginx:1"], sizeBytes: 1, nodes: nodes)
        image.tags = tags.mapValues { $0.compactMap(ImageRef.init) }
        return image
    }

    @Test("with no node named as this Mac's, nothing is offered")
    func offerUnknownNode() {
        let offer = ImageStoreOffer.decide(Self.image(nodes: ["studio"], tags: ["studio": ["nginx:1"]]), scope: ImageStoreScope(node: nil))
        #expect(offer.untag.isEmpty)
        #expect(offer.note == ImageStoreScope.unknownNodeText)
        #expect(ImageStoreScope.decide(report: nil).node == nil)
        #expect(ImageStoreScope(node: "$(id)").node == nil)
        #expect(ImageStoreScope(node: nil).label == "This Mac: node not known")
        #expect(Self.here.label == "This Mac: node studio")
    }

    @Test("an image only on another Mac is managed on that Mac")
    func offerOtherMac() {
        let one = ImageStoreOffer.decide(Self.image(nodes: ["laptop"], tags: ["laptop": ["nginx:1"]]), scope: Self.here)
        #expect(one.untag.isEmpty)
        #expect(one.note == "This image is on node laptop, another Mac: images are managed on that Mac.")
        let two = ImageStoreOffer.decide(Self.image(nodes: ["edge", "laptop"], tags: [:]), scope: Self.here)
        #expect(two.untag.isEmpty)
        #expect(two.note?.contains("images are managed on each of those Macs") == true)
    }

    @Test("an image on this Mac offers its tags on this Mac's node, and names the node")
    func offerThisMac() {
        let image = Self.image(nodes: ["laptop", "studio"], tags: ["studio": ["nginx:1", "nginx:latest"], "laptop": ["nginx:old"]])
        let offer = ImageStoreOffer.decide(image, scope: Self.here)
        #expect(offer.untag.map(\.value) == ["nginx:1", "nginx:latest"])
        #expect(offer.note == "Untag acts on node studio, this Mac. The copies on laptop stay.")
        let none = ImageStoreOffer.decide(Self.image(nodes: ["studio"], tags: [:]), scope: Self.here)
        #expect(none.untag.isEmpty)
        #expect(none.note?.contains("no tag on node studio") == true)
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
        #expect(ImageStoreOffer.decide(lookalike, scope: Self.here).untag.isEmpty)
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
        (K3smCLI.imageUntagArguments(ImageRef("nginx:1.27")!), ["image", "untag", "nginx:1.27"]),
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
        #expect(hub.title == "Pull nginx:1.27 to this Mac?")
        #expect(hub.message == "k3sm pulls nginx:1.27 into the image store of node studio, this Mac. "
                + "The image daemon, running as root, contacts this node's own registry if it has one, "
                + "then Docker Hub (index.docker.io), with no credential.")
        let local = ImageStoreText.registrySentence(ImageRef("localhost:5000/app:1")!)
        #expect(local.contains("contacts localhost:5000, this node's own registry, then the other nodes' registries"))
        #expect(ImageRef("127.0.0.1:5000/a")!.registryIsLoopback)
        #expect(!ImageRef("ghcr.io/a")!.registryIsLoopback)
        #expect(ImageStoreText.registrySentence(ImageRef("ghcr.io/a/b:1")!) == "The image daemon, running as root, contacts ghcr.io, with no credential.")
    }

    @Test("Untag asks naming the image and the node, and the prompts name this Mac")
    func questions() {
        let ref = ImageRef("nginx:1.27")!
        let q = ImageStoreText.untagQuestion(ref, node: "studio")
        #expect(q.title == "Untag nginx:1.27 on this Mac?")
        #expect(q.message.contains("nginx:1.27") && q.message.contains("node studio, this Mac"))
        #expect(q.message.hasSuffix("If a pull moves the name to other content before the administrator step runs, that content loses the name instead."))
        #expect(ImageStoreText.prompt(untag: ref).contains("this Mac's image store"))
        #expect(ImageStoreText.prompt(pull: ref) == "k3sm wants to pull nginx:1.27 into this Mac's image store.")
        #expect(ImageStoreText.promptPruneDryRun.contains("this Mac"))
        #expect(ImageStoreText.promptPrune.contains("this Mac"))
        #expect(ImageStoreText.pulled(ref, node: "studio", output: "up to date nginx:1.27\r  digest:   sha256:x")
                == "nginx:1.27 was already up to date on node studio.")
        #expect(ImageStoreText.pulled(ref, node: "studio", output: "pulled nginx:1.27").hasPrefix("Pulled nginx:1.27 on node studio."))
        #expect(ImageStoreText.untagged(ref, node: "studio") == "Untagged nginx:1.27 on node studio. Prune reclaims its content.")
    }
}
