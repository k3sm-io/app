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

import K3smStatus
@testable import K3smInstall

/// The lifecycle root script: its literal verbs, its argv against the k3sm
/// CLI (cmd/k3sm/lifecycle.go), its command line, and its refusals, proven by
/// running the rendered command against real directories that fail each check.
/// Every refusal case stops the script before the CLI line; none runs past it.
@Suite("lifecycle root script")
struct LifecycleScriptTests {
    static let team = TeamID("ABCDE12345")!

    static let goldenArgv: [LifecycleVerb: [String]] = [
        .stop: ["stop", "--actor", "user", "--reason", "from the k3sm app"],
        .start: ["start", "--actor", "user", "--reason", "from the k3sm app"],
        .restart: ["restart", "--actor", "user", "--reason", "from the k3sm app"],
    ]

    @Test("the verb set is closed: stop, start, restart")
    func verbs() {
        #expect(LifecycleVerb.allCases.map(\.rawValue) == ["stop", "start", "restart"])
    }

    @Test("the argument list", arguments: LifecycleVerb.allCases)
    func argumentList(_ verb: LifecycleVerb) {
        #expect(LifecycleScriptBuilder.arguments(for: verb) == Self.goldenArgv[verb])
    }

    /// The single CLI line of a rendered script.
    static func cliLine(_ verb: LifecycleVerb) throws -> String {
        let lines = LifecycleScriptBuilder.render(verb, teamID: team).text.split(separator: "\n").filter { $0.hasPrefix("exec ") }
        try #require(lines.count == 1, "want exactly one exec line")
        return String(lines[0])
    }

    @Test("the argv the shell passes", arguments: LifecycleVerb.allCases)
    func shellArgv(_ verb: LifecycleVerb) throws {
        let line = try Self.cliLine(verb)
        let prefix = "exec \"$k3sm\" "
        try #require(line.hasPrefix(prefix))
        let probe = "set -- " + line.dropFirst(prefix.count) + "\nfor a in \"$@\"; do printf '%s\\n' \"$a\"; done\n"
        let result = try shell(["-c", probe])
        #expect(result.status == 0)
        #expect(result.output.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init) == Self.goldenArgv[verb])
    }

    @Test("the stop script, byte for byte")
    func goldenStop() {
        let want = #"""
            set -eu
            umask 077
            cd /
            k3sm='/Library/k3sm/k3sm'
            refuse() {
            	echo "k3sm app: refused: $1" >&2
            	exit 100
            }
            for p in '/' '/Library' '/Library/k3sm' '/Library/k3sm/k3sm'; do
            	if [ -L "$p" ]; then refuse "$p is a symlink"; fi
            	if [ ! -e "$p" ]; then refuse "$p does not exist"; fi
            	bad=$(/usr/bin/find "$p" -maxdepth 0 \( ! -user 0 -o -perm +0022 \) -print) || refuse "$p could not be checked"
            	if [ -n "$bad" ]; then refuse "$p is not owned by root, or is writable by group or others"; fi
            done
            if [ ! -f "$k3sm" ]; then refuse "$k3sm is not a regular file"; fi
            if ! /usr/bin/codesign --verify --strict '-R=anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = "ABCDE12345"' "$k3sm"; then
            	echo 'k3sm app: refused: the installed k3sm is not signed by the k3sm Developer ID' >&2
            	exit 101
            fi
            exec "$k3sm" 'stop' '--actor' 'user' '--reason' 'from the k3sm app'

            """#
        #expect(LifecycleScriptBuilder.render(.stop, teamID: Self.team).text == want)
    }

    @Test("every verb renders the same checks and differs only in its verb", arguments: LifecycleVerb.allCases)
    func onlyTheVerbDiffers(_ verb: LifecycleVerb) {
        let stop = LifecycleScriptBuilder.render(.stop, teamID: Self.team).text
        let other = LifecycleScriptBuilder.render(verb, teamID: Self.team).text
        #expect(other == stop.replacingOccurrences(of: "exec \"$k3sm\" 'stop'", with: "exec \"$k3sm\" '\(verb.rawValue)'"))
    }

    @Test("the checked paths are / and every ancestor of the CLI")
    func checkedPaths() {
        #expect(LifecycleScriptBuilder.checkedPaths(cliPath: K3smCLI.path) == ["/", "/Library", "/Library/k3sm", "/Library/k3sm/k3sm"])
    }

    @Test("the prompt names the verb", arguments: LifecycleVerb.allCases)
    func prompt(_ verb: LifecycleVerb) {
        let script = LifecycleScriptBuilder.render(verb, teamID: Self.team)
        #expect(script.prompt == "k3sm wants to \(verb.rawValue) k3sm on this Mac.")
        #expect(!script.readsInput)
    }

    @Test("the command line is a scrubbed environment and the script, with no staging lock", arguments: LifecycleVerb.allCases)
    func commandLine(_ verb: LifecycleVerb) throws {
        let script = LifecycleScriptBuilder.render(verb, teamID: Self.team)
        let line = script.command(inputPath: "/dev/null")
        #expect(line == "/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/sh -c " + ShellQuote.quote(script.text) + " < '/dev/null'")
        #expect(!line.contains("lockf"))
        #expect(try shell(["-n", "-c", line]).status == 0)
    }

    @Test("the lifecycle script never reuses the copy-out", arguments: LifecycleVerb.allCases)
    func notTheCopyOut(_ verb: LifecycleVerb) {
        let text = LifecycleScriptBuilder.render(verb, teamID: Self.team).text
        for word in ["staging", "lockf", "ditto", "copy-out", "mktemp", "$stage", "'install'", "uninstall", "chown", "/bin/rm"] {
            #expect(!text.contains(word), "the lifecycle script mentions \(word)")
        }
        // The CLI runs only after both checks.
        let exec = text.range(of: "exec \"$k3sm\"")!.lowerBound
        #expect(text.range(of: "-perm +0022")!.lowerBound < exec)
        #expect(text.range(of: "/usr/bin/codesign --verify --strict")!.lowerBound < exec)
    }

    @Test("the copy-out still takes its lock")
    func copyOutKeepsLock() throws {
        let plan = try CopyOutPlan(
            bundlePath: "/Applications/k3sm.app", payloadVersion: SemanticVersion("0.2.0")!, teamID: Self.team,
            user: ConsoleUser("alice")!, action: .startServer)
        #expect(RootScriptBuilder.render(plan).command(inputPath: "/dev/null").contains("/usr/bin/lockf -k -t 0 '/Library/k3sm.staging.lock'"))
    }

    // MARK: refusals, run for real against directories that fail each check

    struct Refusal: Sendable, CustomTestStringConvertible {
        let name: String
        let cliPath: String
        let status: Int32
        let message: String
        var testDescription: String { name }
    }

    /// Paths on every Mac that fail one check each, in check order.
    static let refusals: [Refusal] = [
        Refusal(name: "an ancestor is a symlink", cliPath: "/etc/k3sm/k3sm", status: 100, message: "/etc is a symlink"),
        Refusal(name: "an ancestor is missing", cliPath: "/usr/k3sm-not-here/k3sm", status: 100, message: "/usr/k3sm-not-here does not exist"),
        Refusal(name: "an ancestor is writable by others", cliPath: "/private/tmp/k3sm-not-here/k3sm", status: 100,
                message: "/private/tmp is not owned by root, or is writable by group or others"),
        Refusal(name: "the CLI is not a regular file", cliPath: "/usr/bin", status: 100, message: "/usr/bin is not a regular file"),
        Refusal(name: "the CLI is not signed by the pinned team", cliPath: "/bin/ls", status: 101,
                message: "not signed by the k3sm Developer ID"),
    ]

    /// Runs a rendered command line, exactly as the administrator prompt
    /// would but as this user, and returns its status and standard error.
    static func run(_ line: String) throws -> (status: Int32, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", line]
        process.environment = ["PATH": "/usr/bin:/bin"]
        let err = Pipe()
        process.standardError = err
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let data = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    @Test("each refusal stops before the CLI runs", arguments: refusals)
    func refusal(_ r: Refusal) throws {
        let line = LifecycleScriptBuilder.render(.stop, teamID: Self.team, cliPath: r.cliPath).command(inputPath: "/dev/null")
        let result = try Self.run(line)
        #expect(result.status == r.status, "stderr: \(result.stderr)")
        #expect(result.stderr.contains(r.message), "stderr: \(result.stderr)")
        #expect(!result.stderr.contains("unknown option"), "the CLI line ran")
    }

    @Test("a user-owned CLI is refused and never executed")
    func userOwnedNeverRuns() throws {
        // The real path (/private/var/..., not /var/...), so the first
        // refusal is the user-owned directory, not the /var symlink.
        let tmp = try #require(realpath(NSTemporaryDirectory(), nil))
        defer { free(tmp) }
        let base = URL(fileURLWithPath: String(cString: tmp)).appending(path: "k3sm-lifecycle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let marker = base.appending(path: "ran")
        let cli = base.appending(path: "k3sm")
        try Data("#!/bin/sh\n: > \(ShellQuote.quote(marker.path))\n".utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        let line = LifecycleScriptBuilder.render(.stop, teamID: Self.team, cliPath: cli.path).command(inputPath: "/dev/null")
        let result = try Self.run(line)
        #expect(result.status == LifecycleExit.refusedBinary)
        #expect(result.stderr.contains("is not owned by root, or is writable by group or others"))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    // MARK: the k3sm CLI contract

    /// The k3sm CLI source directory: K3SM_DIR, or a sibling checkout.
    static var cliDirectory: URL? {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = ProcessInfo.processInfo.environment["K3SM_DIR"].map { URL(fileURLWithPath: $0) }
            ?? root.deletingLastPathComponent().appending(path: "k3sm")
        let file = dir.appending(path: "cmd/k3sm/lifecycle.go")
        return FileManager.default.fileExists(atPath: file.path) ? dir.appending(path: "cmd/k3sm") : nil
    }

    @Test("every lifecycle verb and flag passed is one the CLI declares", .enabled(if: cliDirectory != nil))
    func flagsDeclared() throws {
        let dir = try #require(Self.cliDirectory)
        let lifecycle = try String(contentsOf: dir.appending(path: "lifecycle.go"), encoding: .utf8)
        let main = try String(contentsOf: dir.appending(path: "main.go"), encoding: .utf8)
        // The flags every verb shares, declared inside lifecycleFlags.
        let marker = "func lifecycleFlags("
        let start = try #require(lifecycle.range(of: marker), "no lifecycleFlags in cmd/k3sm/lifecycle.go; the scrape is stale")
        var flags = Set<String>()
        for line in lifecycle[start.upperBound...].split(separator: "\n") {
            if line.contains("fs.Parse(") { break }
            guard ["fs.StringVar(", "fs.BoolVar("].contains(where: { line.contains($0) }) else { continue }
            let parts = line.split(separator: "\"", omittingEmptySubsequences: false)
            if parts.count >= 2, !parts[1].isEmpty { flags.insert(String(parts[1])) }
        }
        try #require(!flags.isEmpty, "found no lifecycle flags; the scrape is stale")
        // The actor the app passes is one the CLI accepts.
        #expect(lifecycle.contains("install.ActorUser"))
        for verb in LifecycleVerb.allCases {
            #expect(main.contains("case \"\(verb.rawValue)\":"), "k3sm has no \(verb.rawValue) verb")
            #expect(lifecycle.contains("lifecycleFlags(\"\(verb.rawValue)\""), "\(verb.rawValue) does not parse the shared flags")
            for f in LifecycleScriptBuilder.arguments(for: verb).filter({ $0.hasPrefix("--") }) {
                #expect(flags.contains(String(f.dropFirst(2))), "--\(f.dropFirst(2)) is not a k3sm \(verb.rawValue) flag")
            }
        }
        // The exit codes the app names are the CLI's.
        let flat = lifecycle.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(flat.contains("exitLifecycleUsage = 2"))
        #expect(flat.contains("exitNeedsRoot = 3"))
        #expect(lifecycle.contains("32+N"))
    }
}
