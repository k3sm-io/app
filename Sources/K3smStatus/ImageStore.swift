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

// The Images tab's writes: Untag, Prune and Mirror, each through the checked
// root step (`LifecycleScriptBuilder.renderImage` in K3smInstall) on this Mac.
// Untag deletes a tag from the cluster registry with the server's push
// credential, which only root and the control plane read, so it is offered
// only on the server. Prune's cache half talks to the root-owned runtimed
// socket and its registry half reads that same credential; on an agent the
// CLI skips the registry half and says so. Mirror is `k3sm image pull`, which
// fills this node's cache through the daemon and then copies a public image
// into the cluster registry.

extension K3smCLI {
    /// `k3sm image prune` with no flag: the CLI's dry run, which is its
    /// default (it has no `--dry-run` flag; deleting takes `--force`).
    public static let imagePruneDryRunArguments = ["image", "prune"]
    /// `k3sm image prune --force`: deletes the content no pod and no name references.
    public static let imagePruneArguments = ["image", "prune", "--force"]

    /// `k3sm image untag <tag> --digest <digest>`: deletes one tag from the
    /// cluster registry; the CLI refuses it when the tag already names
    /// content other than the digest the list read.
    public static func imageUntagArguments(_ tag: RegistryTag) -> [String] {
        ["image", "untag", tag.reference.value, "--digest", tag.digest]
    }

    /// `k3sm image pull <reference>`: fetches through the daemon's own puller,
    /// then, by the CLI's default, copies a public image into the cluster
    /// registry (no `--no-mirror`).
    public static func imagePullArguments(_ reference: ImageRef) -> [String] {
        ["image", "pull", reference.value]
    }
}

/// ImageStoreScope is which node the Images tab's writes act on: this Mac's
/// own node, as the status report names it, or none when it names none.
public struct ImageStoreScope: Equatable, Sendable {
    /// This Mac's node, a `ResourceName`; nil when the report names none.
    public let node: String?
    /// This Mac's role, nil when the report does not say: Mirror's copy into
    /// the cluster registry runs only on the server.
    public let role: NodeRole?

    public init(node: String?, role: NodeRole? = nil) {
        self.node = node.flatMap(ResourceName.init)?.value
        self.role = role
    }

    /// The scope from this Mac's last status report.
    public static func decide(report: StatusReport?) -> ImageStoreScope {
        ImageStoreScope(node: report.flatMap(ClusterDisplay.ownNodeName), role: report.flatMap(NodeRole.detect))
    }

    /// Why nothing can be changed here, when the report names no node.
    public static let unknownNodeText =
        "k3sm has not said which node is this Mac, so images cannot be changed from here."

    /// The header row's line naming where the writes act.
    public var label: String {
        node.map { "This Mac: node \($0)" } ?? "This Mac: node not known"
    }
}

/// RegistryTag is one tag of the cluster registry that Untag may delete: a
/// reference `ImageRef` passes, in the registry `registry-k3sm:6450`, with a
/// tag and no digest, and the manifest digest the registry's list read for
/// it, "sha256:" and 64 lowercase hex, which the CLI's `--digest` pins.
public struct RegistryTag: Hashable, Sendable {
    /// The cluster registry's name, as `k3sm image ls` writes references.
    public static let registry = "registry-k3sm:6450"

    public let reference: ImageRef
    public let digest: String

    /// The tag, or nil when `reference` is not a tag of the cluster registry
    /// or `digest` is not a sha256 digest.
    public init?(reference: String, digest: String?) {
        guard let ref = ImageRef(reference), !ref.hasDigest, ref.registryHost == Self.registry,
              let last = reference.split(separator: "/").last, last.contains(":"),
              let digest, ImagesList.digest(of: "x@" + digest) == digest else { return nil }
        self.reference = ref
        self.digest = digest
    }
}

/// ImagePrunePreview is what `k3sm image prune` (its dry run) said it would
/// delete on this Mac: the node cache's blob digests, their size and the kept
/// blobs by reason, and the cluster registry's half.
public struct ImagePrunePreview: Equatable, Sendable {
    /// One reason the daemon or the registry kept content, and how many.
    public struct Kept: Equatable, Sendable {
        /// The CLI's words, clipped.
        public let reason: String
        public let count: Int

        public init(reason: String, count: Int) {
            self.reason = reason
            self.count = count
        }
    }

    /// The registry half: the untagged manifests the prune deletes from the
    /// cluster registry, or why this node skipped it.
    public struct Registry: Equatable, Sendable {
        /// Why this node pruned no registry (it runs none); nil when it did.
        public let skipped: String?
        /// The untagged manifests, each "<repository>@sha256:<64 hex>".
        public let manifests: [String]
        public let kept: [Kept]
        /// Repositories whose index could not be read; nothing in them is touched.
        public let unreadable: [String]
        /// Deletions the registry refused (a forced run only).
        public let failed: Int

        public init(skipped: String? = nil, manifests: [String] = [], kept: [Kept] = [], unreadable: [String] = [], failed: Int = 0) {
            self.skipped = skipped
            self.manifests = manifests
            self.kept = kept
            self.unreadable = unreadable
            self.failed = failed
        }
    }

    /// The blobs it would delete, each "sha256:<64 hex>".
    public let digests: [String]
    /// The size those blobs come to, as the CLI wrote it ("12.3 MiB", "0 B").
    public let size: String
    public let kept: [Kept]
    public let registry: Registry

    public init(digests: [String], size: String, kept: [Kept], registry: Registry) {
        self.digests = digests
        self.size = size
        self.kept = kept
        self.registry = registry
    }

    /// Whether there is nothing to reclaim in the node cache.
    public var isEmpty: Bool { digests.isEmpty }

    /// Whether neither half has anything to delete: no blob in the node
    /// cache and no untagged manifest in the cluster registry.
    public var nothingToReclaim: Bool { digests.isEmpty && registry.manifests.isEmpty }

    /// The most digests the preview sheet lists; the rest are counted.
    public static let shownDigests = 200
}

/// ImagePruneRead is how a prune's output read: what it would delete (a dry
/// run) or deleted (`--force`), or the 1-based line that did not fit the
/// CLI's shape, so nothing is guessed from it.
public enum ImagePruneRead: Equatable, Sendable {
    case read(ImagePrunePreview)
    case malformed(line: Int)
    case tooLong
}

/// ImagePrune reads `k3sm image prune`'s output (cmd/k3sm/imageprune.go
/// `renderPrune`), strictly. Two sections, in order:
///
///   - "registry <name>:", then either "  skipped: <why>", or one
///     "  <verb> <repo>@<digest> (untagged)" line per manifest, a forced run's
///     "  could not delete <repo>@<digest>: <error>" lines, the
///     "  <verb> N untagged manifest(s); …" summary whose N matches, an
///     optional "  kept untagged:" block of "    <reason> <count>" lines, and
///     "  unreadable, left alone: <repo>" lines;
///   - "node cache:", then an optional "  nothing to reclaim: …" line, one
///     "  <verb> <digest>" line per blob, the "  <verb> N blob(s), <size>"
///     summary whose N matches, and an optional "  kept:" block.
///
/// A dry run ends with its "(dry run …)" note; a forced run says "deleted"
/// and carries no note. Any other line refuses the whole read, so a run that
/// did not say it was a dry run is never shown as one.
public enum ImagePrune {
    /// The most lines a read accepts.
    public static let maxLines = 50_000

    static let registrySummaryTail =
        " untagged manifest(s); the registry's garbage collection reclaims their layers on its next sweep"
    static let cacheNothing = "  nothing to reclaim: every blob in the cache is referenced."

    private enum Section { case start, registry, registryKept, cache, cacheKept, done }

    public static func parse(_ output: String, forced: Bool = false) -> ImagePruneRead {
        let verb = forced ? "deleted " : "would delete "
        let lines = output.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > maxLines { return .tooLong }
        var section = Section.start
        // The registry half.
        var skipped: String?
        var manifests: [String] = []
        var failed = 0
        var registryCount: Int?
        var registryKept: [ImagePrunePreview.Kept] = []
        var unreadable: [String] = []
        // The node-cache half.
        var nothing = false
        var digests: [String] = []
        var summary: (count: Int, size: String)?
        var kept: [ImagePrunePreview.Kept] = []
        for (index, raw) in lines.enumerated() {
            let line = String(raw)
            let bad = ImagePruneRead.malformed(line: index + 1)
            if line.isEmpty { continue }
            if section == .registryKept {
                if let entry = keptEntry(line) {
                    registryKept.append(entry)
                    continue
                }
                guard !registryKept.isEmpty else { return bad }
                section = .registry
            }
            if section == .cacheKept {
                if let entry = keptEntry(line) {
                    kept.append(entry)
                    continue
                }
                guard !kept.isEmpty else { return bad }
                section = .cache
            }
            switch section {
            case .start:
                guard line.hasPrefix("registry "), line.hasSuffix(":"),
                      word(line.dropFirst("registry ".count).dropLast()) != nil else { return bad }
                section = .registry
            case .registry:
                if line == "node cache:" {
                    guard skipped != nil || registryCount != nil else { return bad }
                    section = .cache
                } else if line.hasPrefix("  skipped: ") {
                    let why = line.dropFirst("  skipped: ".count).trimmingCharacters(in: .whitespaces)
                    guard skipped == nil, manifests.isEmpty, failed == 0, registryCount == nil, !why.isEmpty else { return bad }
                    skipped = StatusDisplay.clip(why)
                } else if line.hasPrefix("  " + verb), line.hasSuffix(" (untagged)") {
                    let ref = line.dropFirst(2 + verb.count).dropLast(" (untagged)".count)
                    guard skipped == nil, failed == 0, registryCount == nil, let ref = manifestRef(ref) else { return bad }
                    manifests.append(ref)
                } else if forced, line.hasPrefix("  could not delete ") {
                    let rest = line.dropFirst("  could not delete ".count)
                    // The digest's "sha256:" has no space after its colon, so
                    // the first ": " ends the reference and starts the error.
                    guard skipped == nil, registryCount == nil, let sep = rest.range(of: ": "),
                          manifestRef(rest[..<sep.lowerBound]) != nil else { return bad }
                    failed += 1
                } else if line.hasPrefix("  " + verb), line.hasSuffix(registrySummaryTail) {
                    let n = line.dropFirst(2 + verb.count).dropLast(registrySummaryTail.count)
                    guard skipped == nil, registryCount == nil, let count = Int(n), count == manifests.count else { return bad }
                    registryCount = count
                } else if line == "  kept untagged:" {
                    guard registryCount != nil, registryKept.isEmpty, unreadable.isEmpty else { return bad }
                    section = .registryKept
                } else if line.hasPrefix("  unreadable, left alone: ") {
                    guard registryCount != nil, let repo = word(line.dropFirst("  unreadable, left alone: ".count)) else { return bad }
                    unreadable.append(repo)
                } else {
                    return bad
                }
            case .cache:
                if line == cacheNothing {
                    guard !nothing, digests.isEmpty, summary == nil else { return bad }
                    nothing = true
                } else if line.hasPrefix("  " + verb + "sha256:") {
                    let digest = String(line.dropFirst(2 + verb.count))
                    guard !nothing, summary == nil, ImagesList.digest(of: "x@" + digest) == digest else { return bad }
                    digests.append(digest)
                } else if line.hasPrefix("  " + verb) {
                    guard summary == nil, let parsed = summaryLine(line.dropFirst(2 + verb.count)) else { return bad }
                    summary = parsed
                } else if line == "  kept:" {
                    guard summary != nil, kept.isEmpty else { return bad }
                    section = .cacheKept
                } else if !forced, line.hasPrefix("(dry run"), line.hasSuffix(")") {
                    guard summary != nil else { return bad }
                    section = .done
                } else {
                    return bad
                }
            case .done, .registryKept, .cacheKept:
                return bad
            }
        }
        let end = ImagePruneRead.malformed(line: lines.count)
        if section == .cacheKept, kept.isEmpty { return end }
        guard section == (forced ? .cacheKept : .done) || (forced && section == .cache) else { return end }
        guard let summary, summary.count == digests.count, nothing == digests.isEmpty else { return end }
        let registry = ImagePrunePreview.Registry(skipped: skipped, manifests: manifests, kept: registryKept,
                                                  unreadable: unreadable, failed: failed)
        return .read(ImagePrunePreview(digests: digests, size: summary.size, kept: kept, registry: registry))
    }

    /// "<repository>@sha256:<64 hex>", the repository one word.
    static func manifestRef(_ text: Substring) -> String? {
        guard let at = text.lastIndex(of: "@"), word(text[..<at]) != nil,
              ImagesList.digest(of: String(text)) != nil else { return nil }
        return String(text)
    }

    /// One non-empty word: no whitespace, no control character, bounded.
    static func word(_ text: Substring) -> String? {
        guard !text.isEmpty, text.count <= ImageRef.maxLength,
              !text.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return String(text)
    }

    /// "N blob(s), <size>", where the size is the CLI's `humanBytes`: "<n> B"
    /// or "<n>.<d> <K|M|G|T|P|E>iB".
    static func summaryLine(_ text: Substring) -> (count: Int, size: String)? {
        let parts = text.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].hasSuffix(" blob(s)"),
              let count = Int(parts[0].dropLast(" blob(s)".count)), count >= 0 else { return nil }
        guard parts[1].hasPrefix(" ") else { return nil }
        let size = parts[1].dropFirst()
        let words = size.split(separator: " ", omittingEmptySubsequences: false)
        guard words.count == 2 else { return nil }
        let digits = { (s: Substring) in !s.isEmpty && s.unicodeScalars.allSatisfy { ("0"..."9").contains($0) } }
        if words[1] == "B" {
            guard digits(words[0]) else { return nil }
        } else {
            let number = words[0].split(separator: ".", omittingEmptySubsequences: false)
            guard number.count == 2, digits(number[0]), number[1].count == 1, digits(number[1]),
                  words[1].count == 3, words[1].hasSuffix("iB"), "KMGTPE".contains(words[1].first!) else { return nil }
        }
        return (count, String(size))
    }

    /// "    <reason> <count>": four spaces, the reason, its count.
    static func keptEntry(_ line: String) -> ImagePrunePreview.Kept? {
        guard line.hasPrefix("    "), let space = line.lastIndex(of: " ") else { return nil }
        let reason = line[line.index(line.startIndex, offsetBy: 4)..<space].trimmingCharacters(in: .whitespaces)
        guard !reason.isEmpty, let count = Int(line[line.index(after: space)...]), count >= 0 else { return nil }
        return ImagePrunePreview.Kept(reason: StatusDisplay.clip(reason), count: count)
    }
}

/// ImageStoreText is every sentence the Images tab's writes show: their
/// questions, the preview sheet's lines and their outcomes. A reference in
/// them is an `ImageRef` (ASCII, bounded); a node name a `ResourceName`.
public enum ImageStoreText {
    /// Why Untag is disabled for a registry image, or nil when it may run:
    /// the list gave it no tag and digest to pin, or this Mac is not the
    /// server, which holds the registry's push credential.
    public static func untagUnavailable(_ image: RegistryImage, role: NodeRole?) -> String? {
        guard image.untag != nil else { return untagNoDigest }
        guard role == .server else { return untagOnServer }
        return nil
    }

    /// The line under an enabled Untag button.
    public static let untagNote = "Untag deletes this tag from the cluster registry, refused if the tag already names content other than the digest above."

    /// Why Untag is disabled off the server.
    public static let untagOnServer = "Untag runs on the server, which holds the cluster registry's credential."

    /// Why Untag is disabled for a row with no tag and digest to pin.
    public static let untagNoDigest = "The registry's list gave this image no tag and digest that Untag can pin."

    /// The Untag question: the tag, the digest it is pinned to, and what stays.
    public static func untagQuestion(_ tag: RegistryTag) -> (title: String, message: String) {
        (StatusDisplay.clip("Untag \(tag.reference.value)?"),
         "k3sm deletes the tag \(tag.reference.value) from the cluster registry, refused if the tag already names content other than \(tag.digest). "
            + "A manifest another tag names stays, the registry's garbage collection reclaims what no tag names, "
            + "and nodes that cached the image keep their copies, so pods using it keep running.")
    }

    /// The Mirror question: the reference and the node, the registry the root
    /// step contacts (`ImageRef.registryHost`), and whether a copy is written
    /// to the cluster registry (`ImageRef.mirrorsToRegistry`).
    public static func pullQuestion(_ reference: ImageRef, node: String) -> (title: String, message: String) {
        let copy = reference.mirrorsToRegistry
            ? "k3sm pulls \(reference.value) into the image cache of node \(node), this Mac, then copies it into the cluster registry, "
                + "which nodes pull from when its own registry cannot be reached. " + copyCredential
            : "k3sm pulls \(reference.value) into the image cache of node \(node), this Mac. "
                + "No copy is written to the cluster registry for a reference in it or in a registry with a port. "
        return (StatusDisplay.clip("Mirror \(reference.value)?"), copy + registrySentence(reference))
    }

    /// Whose credential the copy into the cluster registry uses: the root
    /// step runs the CLI with no HOME and no KUBECONFIG, so the server's own
    /// administrator credential mints the push token, and an agent, which has
    /// none, skips the copy.
    public static let copyCredential =
        "The copy uses the server's own administrator credential, not your kubeconfig, so on an agent it is skipped. "

    /// The registry sentence: which host the image daemon, running as root,
    /// contacts. It fetches with no credential: the CLI's pull passes none
    /// (runtimed `PullImage` calls `Pull` with a nil credential, anonymous).
    public static func registrySentence(_ reference: ImageRef) -> String {
        guard let host = reference.registryHost else {
            return "The image daemon, running as root, contacts this node's own registry if it has one, "
                + "then Docker Hub (index.docker.io), with no credential."
        }
        if reference.registryIsLoopback {
            return "The image daemon, running as root, contacts \(host), this node's own registry, "
                + "then the other nodes' registries if it is not there, with no credential."
        }
        return "The image daemon, running as root, contacts \(host), with no credential."
    }

    /// The refusal when a dry run printed more than the app holds.
    public static let previewTruncated =
        "The prune's dry run printed more than k3sm reads, so its list cannot be shown whole and nothing was deleted."

    /// A finished prune's line when its output was cut at the cap.
    public static func prunedTruncated(node: String) -> String {
        StatusDisplay.clip("The prune ran on node \(node). Its output was longer than k3sm reads, so the count is not shown.")
    }

    /// The Mirror sheet's title and its line under a valid reference.
    public static let pullTitle = "Mirror an image into the cluster"
    public static let pullNote =
        "k3sm pulls it to this Mac, checking every blob's digest, then copies a public image into the cluster registry "
            + "with the server's own credential; an agent skips the copy."

    /// The refusal when this Mac's node changed while the preview was open.
    public static let pruneNodeChanged = "This Mac's node changed while the preview was open, so nothing was deleted."

    /// The prune preview sheet's title.
    public static let pruneTitle = "Prune images on this Mac"

    /// The preview's lead line: what the prune would delete, on which node.
    public static func pruneLead(_ preview: ImagePrunePreview, node: String) -> String {
        guard !preview.isEmpty else {
            return "Nothing to reclaim in the cache of node \(node), this Mac: a pod or a name references every blob."
        }
        let blobs = preview.digests.count == 1 ? "1 blob" : "\(preview.digests.count) blobs"
        return "On node \(node), this Mac, the prune would delete \(blobs) no pod and no name references, \(preview.size):"
    }

    /// The preview's digest lines: the first `shownDigests`, then a count of the rest.
    public static func pruneDigests(_ preview: ImagePrunePreview) -> [String] {
        let shown = Array(preview.digests.prefix(ImagePrunePreview.shownDigests))
        let rest = preview.digests.count - shown.count
        return rest > 0 ? shown + ["and \(rest) more"] : shown
    }

    /// The preview's kept line, nil when it kept nothing.
    public static func pruneKept(_ preview: ImagePrunePreview) -> String? {
        guard !preview.kept.isEmpty else { return nil }
        return "Kept: " + preview.kept.map { "\($0.count) \($0.reason)" }.joined(separator: ", ") + "."
    }

    /// The preview's registry line: how many untagged manifests the prune
    /// would delete from the cluster registry, or why this node skips the
    /// registry; nil when the registry has nothing untagged to delete.
    public static func pruneRegistry(_ preview: ImagePrunePreview) -> String? {
        let registry = preview.registry
        if let skipped = registry.skipped {
            return StatusDisplay.clip("Cluster registry: skipped, \(skipped).")
        }
        guard !registry.manifests.isEmpty else { return nil }
        let count = registry.manifests.count
        let manifests = count == 1 ? "1 untagged manifest" : "\(count) untagged manifests"
        return StatusDisplay.clip("It would also delete \(manifests) from the cluster registry; "
            + "the registry reclaims their layers on its next garbage collection.")
    }

    /// The preview's caveat: the prune is re-derived when it runs.
    public static let pruneCaveat =
        "The prune deletes what nothing references when it runs, so a pull or a new pod in between keeps its content."

    /// The administrator prompts, one per verb, each naming this Mac.
    public static func prompt(untag tag: RegistryTag) -> String {
        "k3sm wants to delete the tag \(tag.reference.value) from the cluster registry."
    }

    public static func prompt(pull reference: ImageRef) -> String {
        reference.mirrorsToRegistry
            ? "k3sm wants to pull \(reference.value) to this Mac and copy it into the cluster registry with the server's credential."
            : "k3sm wants to pull \(reference.value) into this Mac's image cache."
    }

    public static let promptPruneDryRun = "k3sm wants to read what a prune would delete from this Mac's image cache and the cluster registry."
    public static let promptPrune = "k3sm wants to delete the image content nothing references from this Mac's image cache and the cluster registry."

    /// A finished untag's line.
    public static func untagged(_ tag: RegistryTag) -> String {
        StatusDisplay.clip("Untagged \(tag.reference.value) in the cluster registry.")
    }

    /// The prefix of the CLI's line naming the cluster registry's copy.
    static let mirrorLine = "  mirror:   "

    /// A finished pull's line, from the CLI's first line ("pulled …" or
    /// "up to date …"), its "  mirror:   <name>" line when it wrote the copy,
    /// and its warning when it did not (only when the runner read standard
    /// error). On an agent the copy needs the server, so the line says it was
    /// skipped. The mirror name is shown only once it passes `ImageRef`.
    public static func pulled(_ reference: ImageRef, node: String, role: NodeRole? = nil,
                              output: String?, warning: String?) -> String {
        let lines = (output ?? "").replacingOccurrences(of: "\r", with: "\n").split(separator: "\n")
        let upToDate = lines.first?.hasPrefix("up to date ") == true
        let base = upToDate ? "\(reference.value) was already up to date on node \(node)" : "Pulled \(reference.value) on node \(node)"
        if let line = lines.first(where: { $0.hasPrefix(mirrorLine) }) {
            let name = line.dropFirst(mirrorLine.count).trimmingCharacters(in: .whitespaces)
            let copied = upToDate ? " and was copied into the cluster registry as " : " and copied it into the cluster registry as "
            if let mirror = ImageRef(name) { return StatusDisplay.clip(base + copied + mirror.value + ".") }
        }
        guard reference.mirrorsToRegistry else { return StatusDisplay.clip(base + ".") }
        if role == .agent {
            return StatusDisplay.clip(base + ". The copy into the cluster registry was skipped: it needs the server, "
                + "whose own credential writes it.")
        }
        if let warning, let at = warning.range(of: "warning: ") {
            let why = StatusDisplay.errorText(String(warning[at.upperBound...]))
            if !why.isEmpty { return StatusDisplay.clip(base + ", but its copy in the cluster registry was not written: " + why) }
        }
        return StatusDisplay.clip(base + ", but k3sm did not report a copy in the cluster registry.")
    }

    /// A finished prune's line, from its `--force` output: the node cache's
    /// blobs and the cluster registry's untagged manifests it deleted.
    public static func pruned(output: String?, node: String) -> String {
        guard let output, case .read(let done) = ImagePrune.parse(output, forced: true) else {
            return StatusDisplay.clip("The prune ran on node \(node). Its output did not say how much it deleted.")
        }
        let count = done.registry.manifests.count
        let manifests = count == 1 ? "1 untagged manifest" : "\(count) untagged manifests"
        let blobs = done.digests.count == 1 ? "1 blob" : "\(done.digests.count) blobs"
        switch (done.isEmpty, count == 0) {
        case (true, true):
            return StatusDisplay.clip("The prune ran on node \(node) and found nothing to delete.")
        case (false, true):
            return StatusDisplay.clip("Deleted \(blobs), \(done.size), on node \(node).")
        case (true, false):
            return StatusDisplay.clip("Deleted \(manifests) from the cluster registry. Node \(node)'s cache had nothing to delete.")
        case (false, false):
            return StatusDisplay.clip("Deleted \(blobs), \(done.size), on node \(node), and \(manifests) from the cluster registry.")
        }
    }

    /// The line when a dry run's output does not read.
    public static func previewUnreadable(_ read: ImagePruneRead) -> String {
        switch read {
        case .tooLong: return "The prune's dry run listed more than k3sm reads, so nothing was deleted."
        case .malformed(let line): return "The prune's dry run printed line \(line) in a shape k3sm does not read, so nothing was deleted."
        case .read: return ""
        }
    }

    /// The refusal for a Pull field that is not a reference.
    public static func pullRefused(_ problem: ImageRef.Problem) -> String {
        "Nothing was pulled: " + problem.text
    }
}

extension ImagesList {
    /// How many listed pods use each image, by row key, as the inspector's
    /// "Used by" counts them (`InspectorDetails.podsUsing`).
    public static func podCounts(_ images: [NodeImage], pods: [Pod]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for image in images {
            counts[image.key] = InspectorDetails.podsUsing(image, in: pods).count
        }
        return counts
    }

    /// The Pods cell: the count, or "" before the pod list is read.
    public static func podsText(_ count: Int?) -> String {
        count.map(String.init) ?? ""
    }
}
