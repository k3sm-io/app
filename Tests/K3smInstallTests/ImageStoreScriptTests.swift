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
import Synchronization
import Testing

import K3smStatus
@testable import K3smInstall

/// The Images tab's root verbs: their argv against the k3sm CLI
/// (cmd/k3sm/image.go), the script each renders (the lifecycle script's
/// checks, then one CLI line), and the driver that runs them.
@Suite("image store root script")
struct ImageStoreScriptTests {
    static let team = TeamID("ABCDE12345")!
    static let hex = String(repeating: "0123456789abcdef", count: 4)
    static let nginx = ImageRef("docker.io/library/nginx:1.27")!
    static let appTag = RegistryTag(reference: "registry-k3sm:6450/app:v1", digest: "sha256:" + hex)!

    struct Case: Sendable, CustomTestStringConvertible {
        let verb: LifecycleScriptBuilder.ImageVerb
        let argv: [String]
        let prompt: String
        var testDescription: String { argv.joined(separator: " ") }
    }

    static let cases: [Case] = [
        Case(verb: .pruneDryRun, argv: ["image", "prune"],
             prompt: "k3sm wants to read what a prune would delete from this Mac's image cache and the cluster registry."),
        Case(verb: .prune, argv: ["image", "prune", "--force"],
             prompt: "k3sm wants to delete the image content nothing references from this Mac's image cache and the cluster registry."),
        Case(verb: .untag(appTag), argv: ["image", "untag", "registry-k3sm:6450/app:v1", "--digest", "sha256:" + hex],
             prompt: "k3sm wants to delete the tag registry-k3sm:6450/app:v1 from the cluster registry."),
        Case(verb: .pull(ImageRef("ghcr.io/k3sm-io/app@sha256:" + hex)!), argv: ["image", "pull", "ghcr.io/k3sm-io/app@sha256:" + hex],
             prompt: "k3sm wants to pull ghcr.io/k3sm-io/app@sha256:\(hex) to this Mac and copy it into the cluster registry with the server's credential."),
    ]

    @Test("the argument list", arguments: cases)
    func argumentList(_ c: Case) {
        #expect(LifecycleScriptBuilder.imageArguments(c.verb) == c.argv)
    }

    @Test("the prompt names this Mac", arguments: cases)
    func prompt(_ c: Case) {
        let script = LifecycleScriptBuilder.renderImage(c.verb, teamID: Self.team)
        #expect(script.prompt == c.prompt)
        #expect(!script.readsInput)
        #expect(!script.usesStagingLock)
    }

    static func cliLine(_ verb: LifecycleScriptBuilder.ImageVerb) throws -> String {
        let lines = LifecycleScriptBuilder.renderImage(verb, teamID: team).text.split(separator: "\n").filter { $0.hasPrefix("exec ") }
        try #require(lines.count == 1, "want exactly one exec line")
        return String(lines[0])
    }

    @Test("the argv the shell passes", arguments: cases)
    func shellArgv(_ c: Case) throws {
        let line = try Self.cliLine(c.verb)
        let prefix = "exec \"$k3sm\" "
        try #require(line.hasPrefix(prefix))
        let probe = "set -- " + line.dropFirst(prefix.count) + "\nfor a in \"$@\"; do printf '%s\\n' \"$a\"; done\n"
        let result = try shell(["-c", probe])
        #expect(result.status == 0)
        #expect(result.output.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init) == c.argv)
    }

    @Test("each renders the stop script's checks and differs only in its CLI line", arguments: cases)
    func onlyTheLineDiffers(_ c: Case) throws {
        let stop = LifecycleScriptBuilder.render(.stop, teamID: Self.team).text
        let text = LifecycleScriptBuilder.renderImage(c.verb, teamID: Self.team).text
        let argv = c.argv.map(ShellQuote.quote).joined(separator: " ")
        #expect(text == stop.replacingOccurrences(
            of: "exec \"$k3sm\" 'stop' '--actor' 'user' '--reason' 'from the k3sm app'", with: "exec \"$k3sm\" " + argv))
        let exec = try #require(text.range(of: "exec \"$k3sm\""))
        #expect(text.range(of: "/usr/bin/codesign --verify --strict")!.lowerBound < exec.lowerBound)
        #expect(text.range(of: "\ncheck \"$k3sm\"\n")!.lowerBound < exec.lowerBound)
        let line = LifecycleScriptBuilder.renderImage(c.verb, teamID: Self.team).command(inputPath: "/dev/null")
        #expect(!line.contains("lockf"))
        #expect(try shell(["-n", "-c", line]).status == 0)
    }

    @Test("the pull script, byte for byte")
    func goldenPull() {
        let text = LifecycleScriptBuilder.renderImage(.pull(Self.nginx), teamID: Self.team).text
        #expect(text.hasSuffix("\nexec \"$k3sm\" 'image' 'pull' 'docker.io/library/nginx:1.27'\n"))
        #expect(text.hasPrefix("set -eu\numask 077\ncd /\nk3sm='/Library/k3sm/k3sm'\n"))
    }

    @Test("the Mirror root step passes the CLI no HOME and no KUBECONFIG, so the copy uses the server's own credential")
    func pullEnvironment() {
        let script = LifecycleScriptBuilder.renderImage(.pull(Self.nginx), teamID: Self.team)
        let line = script.command(inputPath: "/dev/null")
        #expect(line.hasPrefix("/usr/bin/env -i PATH=\(K3smCLI.systemPath) /bin/sh -c "))
        for name in ["HOME", "KUBECONFIG"] {
            #expect(!script.text.contains(name), "the Mirror script names \(name)")
            #expect(!line.contains(name + "="), "the Mirror command line sets \(name)")
        }
        #expect(script.prompt.contains("with the server's credential"))
    }

    @Test("Mirror on an agent says the copy was skipped because it needs the server")
    func pullOnAgent() async {
        let runner = Runner([PrivilegedRun(outcome: .succeeded, errorOutput: "k3sm image pull: warning: the copy was not written\n",
                                           output: "pulled docker.io/library/nginx:1.27\n")])
        let result = await Self.driver(runner).pull("docker.io/library/nginx:1.27", scope: ImageStoreScope(node: "laptop", role: .agent))
        #expect(result == .ran(.succeeded, "Pulled docker.io/library/nginx:1.27 on node laptop. "
                               + "The copy into the cluster registry was skipped: it needs the server, whose own credential writes it."))
    }

    @Test("no flag but prune's --force and untag's --digest is passed, never --no-mirror or an --allow flag")
    func flags() {
        let all = Self.cases.flatMap(\.argv).filter { $0.hasPrefix("-") }
        #expect(all == ["--force", "--digest"])
    }

    /// The k3sm CLI source directory: K3SM_DIR, or a sibling checkout.
    static var cliDirectory: URL? {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = ProcessInfo.processInfo.environment["K3SM_DIR"].map { URL(fileURLWithPath: $0) }
            ?? root.deletingLastPathComponent().appending(path: "k3sm")
        let file = dir.appending(path: "cmd/k3sm/image.go")
        return FileManager.default.fileExists(atPath: file.path) ? dir.appending(path: "cmd/k3sm") : nil
    }

    @Test("every verb and flag passed is one cmd/k3sm/image.go declares", .enabled(if: cliDirectory != nil))
    func cliContract() throws {
        let dir = try #require(Self.cliDirectory)
        let image = try String(contentsOf: dir.appending(path: "image.go"), encoding: .utf8)
        let main = try String(contentsOf: dir.appending(path: "main.go"), encoding: .utf8)
        #expect(main.contains("case \"image\":"), "k3sm has no image command")
        // Prune takes no positional argument; untag and pull take exactly one reference.
        #expect(image.contains(#"case "prune", "ls", "df":"#))
        #expect(image.contains(#"case "pull", "untag", "inspect", "save":"#))
        // --force is the delete; the dry run is the default and has no flag of its own.
        #expect(image.contains(#"fs.BoolVar(&o.force, "force", false"#))
        let prune = try String(contentsOf: dir.appending(path: "imageprune.go"), encoding: .utf8)
        #expect(prune.contains("DryRun: !o.force"))
        #expect(!image.contains(#""dry-run""#), "k3sm image grew a --dry-run flag; pass it explicitly")
        // Untag pins the tag's digest; pull copies a public image into the cluster registry by default.
        #expect(image.contains(#"fs.StringVar(&o.digest, "digest", """#))
        #expect(image.contains(#"fs.BoolVar(&o.noMirror, "no-mirror", false"#))
        #expect(image.contains("if !o.noMirror {"))
        // Untag and prune's registry half act on the cluster registry, named registry-k3sm:6450.
        let flat = try String(contentsOf: dir.appending(path: "flatregistry.go"), encoding: .utf8)
        #expect(flat.contains(#"const flatRegistryHost = "\#(RegistryTag.registry)""#))
        // A refused flag on a verb is an error, never ignored, so the argv is all there is.
        #expect(image.contains(#"case "untag":"#) && image.contains(#"case "pull":"#) && image.contains(#"case "prune":"#))
    }

    // MARK: the driver

    /// A runner that records the scripts it is handed and answers each with the next run.
    final class Runner: PrivilegedRunner {
        private let runs: Mutex<[PrivilegedRun]>
        private let seen = Mutex<[RootScript]>([])

        init(_ runs: [PrivilegedRun]) {
            self.runs = Mutex(runs)
        }

        var scripts: [RootScript] { seen.withLock { $0 } }

        func runAsRoot(_ script: RootScript, input: Data?) async -> PrivilegedOutcome {
            await runAsRootReportingError(script, input: input).outcome
        }

        func runAsRootReportingError(_ script: RootScript, input: Data?) async -> PrivilegedRun {
            seen.withLock { $0.append(script) }
            return runs.withLock { $0.isEmpty ? PrivilegedRun(outcome: .succeeded) : $0.removeFirst() }
        }
    }

    static let here = ImageStoreScope(node: "studio")

    static func image(_ nodes: [String], tags: [String: [String]]) -> NodeImage {
        var items: [String] = []
        for node in nodes {
            let names = (["x@sha256:" + hex] + (tags[node] ?? [])).map { "\"" + $0 + "\"" }.joined(separator: ",")
            items.append("{\"kind\":\"Node\",\"metadata\":{\"name\":\"" + node + "\"},\"status\":{\"images\":[{\"names\":["
                         + names + "],\"sizeBytes\":1}]}}")
        }
        let list = "{\"kind\":\"List\",\"items\":[" + items.joined(separator: ",") + "]}"
        guard let read = try? NodeListRead.decode(Data(list.utf8)), case .listed(let images) = read.images, let first = images.first else {
            fatalError("not listed")
        }
        return first
    }

    /// The questions a fake user was asked, by title.
    final class Asked: Sendable {
        private let seen = Mutex<[String]>([])
        private let said = Mutex<[String]>([])
        func append(_ title: String) { seen.withLock { $0.append(title) } }
        func message(_ text: String) { said.withLock { $0.append(text) } }
        var titles: [String] { seen.withLock { $0 } }
        var messages: [String] { said.withLock { $0 } }
    }

    static func driver(_ runner: Runner, answer: Bool = true, asked: Asked? = nil) -> ImageStoreDriver {
        ImageStoreDriver(teamID: team, runner: runner) { question in
            asked?.append(question.title)
            asked?.message(question.message)
            return answer
        }
    }

    static func registryImage(_ reference: String, digest: String? = "sha256:" + hex) throws -> RegistryImage {
        let field = digest.map { ",\"digest\":\"\($0)\"" } ?? ""
        let json = "{\"schemaVersion\":1,\"registry\":{\"name\":\"registry-k3sm:6450\",\"reachable\":true},"
            + "\"images\":[{\"reference\":\"\(reference)\"\(field)}]}"
        return try #require(RegistryImages.decode(Data(json.utf8)).images.first)
    }

    @Test("Untag asks first, naming the tag, and runs only a registry tag pinned to its digest, on the server")
    func untag() async throws {
        let image = try Self.registryImage("registry-k3sm:6450/app:v1")
        let asked = Asked()
        let runner = Runner([PrivilegedRun(outcome: .succeeded, output: "untagged registry-k3sm:6450/app:v1")])
        let result = await Self.driver(runner, asked: asked).untag(image, role: .server)
        #expect(asked.titles == ["Untag registry-k3sm:6450/app:v1?"])
        #expect(runner.scripts == [LifecycleScriptBuilder.renderImage(.untag(Self.appTag), teamID: Self.team)])
        #expect(result == .ran(.succeeded, "Untagged registry-k3sm:6450/app:v1 in the cluster registry."))

        let declined = Runner([])
        #expect(await Self.driver(declined, answer: false).untag(image, role: .server) == .declined)
        #expect(declined.scripts.isEmpty)

        let other = Runner([])
        #expect(await Self.driver(other).untag(image, role: .agent) == .refused(ImageStoreText.untagOnServer))
        #expect(await Self.driver(other).untag(image, role: nil) == .refused(ImageStoreText.untagOnServer))
        let unpinned = try Self.registryImage("registry-k3sm:6450/app:v1", digest: nil)
        #expect(await Self.driver(other).untag(unpinned, role: .server) == .refused(ImageStoreText.untagNoDigest))
        #expect(other.scripts.isEmpty)

        let off = PrivilegedAvailability.disabled(reason: "no root step")
        #expect(ImageStoreDriver.untagDisabledReason(image, role: .agent, availability: off, busy: true) == "no root step")
        #expect(ImageStoreDriver.untagDisabledReason(image, role: .agent, availability: .enabled, busy: true) == ImageStoreText.untagOnServer)
        #expect(ImageStoreDriver.untagDisabledReason(image, role: .server, availability: .enabled, busy: true) == "Another change is running.")
        #expect(ImageStoreDriver.untagDisabledReason(image, role: .server, availability: .enabled, busy: false) == nil)

        let refused = Runner([PrivilegedRun(outcome: .failed(exitStatus: 1),
                                            errorOutput: "k3sm image: untag registry-k3sm:6450/app:v1: it names sha256:x, not sha256:y; nothing was removed")])
        #expect(await Self.driver(refused).untag(image, role: .server)
                == .ran(.failed(exitStatus: 1), "k3sm image untag failed: k3sm image: untag registry-k3sm:6450/app:v1: it names sha256:x, not sha256:y; nothing was removed"))
    }

    @Test("Mirror asks first, naming the registry and the copy, and runs only a reference that passes ImageRef")
    func pull() async {
        let runner = Runner([PrivilegedRun(outcome: .succeeded, output: "pulled docker.io/library/nginx:1.27\r  digest:   sha256:x"
                                               + "\r  mirror:   registry-k3sm:6450/docker.io/library/nginx:1.27")])
        let asked = Asked()
        let result = await Self.driver(runner, asked: asked).pull("  docker.io/library/nginx:1.27 ", scope: Self.here)
        #expect(asked.titles == ["Mirror docker.io/library/nginx:1.27?"])
        #expect(asked.messages == ["k3sm pulls docker.io/library/nginx:1.27 into the image cache of node studio, this Mac, "
                                   + "then copies it into the cluster registry, which nodes pull from when its own registry cannot be reached. "
                                   + "The copy uses the server's own administrator credential, not your kubeconfig, so on an agent it is skipped. "
                                   + "The image daemon, running as root, contacts docker.io, with no credential."])
        #expect(runner.scripts == [LifecycleScriptBuilder.renderImage(.pull(Self.nginx), teamID: Self.team)])
        let declined = Runner([])
        #expect(await Self.driver(declined, answer: false).pull("nginx:1.27", scope: Self.here) == .declined)
        #expect(declined.scripts.isEmpty)
        #expect(result == .ran(.succeeded, "Pulled docker.io/library/nginx:1.27 on node studio and copied it into the cluster registry "
                               + "as registry-k3sm:6450/docker.io/library/nginx:1.27."))
        for hostile in hostileStrings + ["--force", "nginx:1; id"] where ImageRef(hostile.trimmingCharacters(in: .whitespaces)) == nil {
            let refused = Runner([])
            let got = await Self.driver(refused).pull(hostile, scope: Self.here)
            guard case .refused = got else { Issue.record("\(hostile.debugDescription) was not refused"); continue }
            #expect(refused.scripts.isEmpty)
        }
    }

    @Test("Prune runs its dry run, returns the parsed list, and deletes only on its own call")
    func prune() async {
        let dry = ["registry registry-k3sm:6450:", "  skipped: this node runs no registry", "node cache:",
                   "  would delete sha256:" + Self.hex, "  would delete 1 blob(s), 1.0 KiB", "(dry run — pass --force to delete)"]
            .joined(separator: "\r")
        let runner = Runner([PrivilegedRun(outcome: .succeeded, output: dry)])
        let preview = await Self.driver(runner).previewPrune(scope: Self.here)
        #expect(preview == .preview(ImagePrunePreview(digests: ["sha256:" + Self.hex], size: "1.0 KiB", kept: [],
                                                    registry: .init(skipped: "this node runs no registry"))))
        #expect(runner.scripts == [LifecycleScriptBuilder.renderImage(.pruneDryRun, teamID: Self.team)])

        // A dry run cut at the cap is refused on its own sentence, before any parse.
        let cut = Runner([PrivilegedRun(outcome: .succeeded, output: dry, outputTruncated: true)])
        #expect(await Self.driver(cut).previewPrune(scope: Self.here) == .refused(ImageStoreText.previewTruncated))
        let cutForce = Runner([PrivilegedRun(outcome: .succeeded, output: "deleted sha256:" + Self.hex, outputTruncated: true)])
        #expect(await Self.driver(cutForce).prune(scope: Self.here) == .ran(.succeeded, ImageStoreText.prunedTruncated(node: "studio")))

        let malformed = Runner([PrivilegedRun(outcome: .succeeded, output: "deleted sha256:" + Self.hex)])
        #expect(await Self.driver(malformed).previewPrune(scope: Self.here) == .refused(ImageStoreText.previewUnreadable(.malformed(line: 1))))
        #expect(malformed.scripts.count == 1)

        let failed = Runner([PrivilegedRun(outcome: .failed(exitStatus: 1), errorOutput: "k3sm image: prune images: runtimed unavailable")])
        #expect(await Self.driver(failed).previewPrune(scope: Self.here)
                == .ran(.failed(exitStatus: 1), "k3sm image prune failed: k3sm image: prune images: runtimed unavailable"))

        let forced = Runner([PrivilegedRun(outcome: .succeeded, output: "registry registry-k3sm:6450:\r  skipped: this node runs no registry\rnode cache:\r"
                                                              + "  deleted sha256:\(Self.hex)\r  deleted 1 blob(s), 1.0 KiB")])
        #expect(await Self.driver(forced).prune(scope: Self.here) == .ran(.succeeded, "Deleted 1 blob, 1.0 KiB, on node studio."))
        #expect(forced.scripts == [LifecycleScriptBuilder.renderImage(.prune, teamID: Self.team)])

        let nowhere = Runner([])
        #expect(await Self.driver(nowhere).previewPrune(scope: ImageStoreScope(node: nil)) == .refused(ImageStoreScope.unknownNodeText))
        #expect(await Self.driver(nowhere).prune(scope: ImageStoreScope(node: nil)) == .refused(ImageStoreScope.unknownNodeText))
        #expect(nowhere.scripts.isEmpty)
    }

    @Test("only the image verbs ask for their standard output; install, update and lifecycle scripts never do")
    func outputIsOptIn() throws {
        for c in Self.cases {
            #expect(LifecycleScriptBuilder.renderImage(c.verb, teamID: Self.team).capturesOutput)
        }
        for verb in LifecycleScriptBuilder.FixedVerb.allCases {
            #expect(!LifecycleScriptBuilder.render(verb, teamID: Self.team).capturesOutput, "\(verb.rawValue) captures its output")
        }
        #expect(!LifecycleScriptBuilder.renderUpdateApply(teamID: Self.team, options: .defaults, release: ReleaseTag("v0.1.8")!).capturesOutput)
        let studio = try ServerAddress(parsing: "studio.local")
        for action: CopyOutAction in [.startServer, .join(studio), .update(.server), .update(.agent(joinServer: studio)), .repair,
                                      .uninstall(purge: false), .uninstall(purge: true)] {
            let plan = try CopyOutPlan(bundlePath: "/Applications/k3sm.app", payloadVersion: SemanticVersion("0.2.0")!,
                                       teamID: Self.team, user: ConsoleUser("alice")!, action: action)
            #expect(!RootScriptBuilder.render(plan).capturesOutput)
        }
    }

    @Test("a runner holds at most the cap of standard output, and says when it cut it")
    func outputCap() {
        #expect(PrivilegedRun.maxOutputBytes == 262_144)
        #expect(PrivilegedRun.capped(nil) == (nil, false))
        let fits = String(repeating: "a", count: PrivilegedRun.maxOutputBytes)
        #expect(PrivilegedRun.capped(fits) == (fits, false))
        let over = fits + "b"
        let cut = PrivilegedRun.capped(over)
        #expect(cut.truncated)
        #expect(cut.text == fits)
        let wide = String(repeating: "a", count: PrivilegedRun.maxOutputBytes - 1) + "é"
        let split = PrivilegedRun.capped(wide)
        #expect(split.truncated)
        #expect(split.text?.utf8.count ?? 0 <= PrivilegedRun.maxOutputBytes + 2)
        #expect(split.text?.hasPrefix(String(repeating: "a", count: PrivilegedRun.maxOutputBytes - 1)) == true)
    }

    @Test("the script's own refusals and a cancelled prompt read as such")
    func classify() {
        let verb = LifecycleScriptBuilder.ImageVerb.prune
        func text(_ run: PrivilegedRun) -> String {
            guard case .ran(_, let t) = ImageStoreDriver.classify(run, verb: verb, node: "studio") else { return "" }
            return t
        }
        #expect(text(PrivilegedRun(outcome: .cancelled)) == "Cancelled. Nothing was changed.")
        #expect(text(PrivilegedRun(outcome: .failed(exitStatus: LifecycleExit.refusedBinary))).contains("not owned by root"))
        #expect(text(PrivilegedRun(outcome: .failed(exitStatus: LifecycleExit.signatureRejected))).contains("Developer ID"))
        #expect(text(PrivilegedRun(outcome: .failed(exitStatus: 7))) == "k3sm image prune --force failed with exit status 7.")
    }

    @Test("the writes are disabled for the root step's reason first, then an unknown node, then a running write")
    func disabled() {
        let off = PrivilegedAvailability.disabled(reason: "no root step")
        #expect(ImageStoreDriver.disabledReason(scope: Self.here, availability: off, busy: true) == "no root step")
        #expect(ImageStoreDriver.disabledReason(scope: ImageStoreScope(node: nil), availability: .enabled, busy: true)
                == ImageStoreScope.unknownNodeText)
        #expect(ImageStoreDriver.disabledReason(scope: Self.here, availability: .enabled, busy: true) == "Another change is running.")
        #expect(ImageStoreDriver.disabledReason(scope: Self.here, availability: .enabled, busy: false) == nil)
    }
}
