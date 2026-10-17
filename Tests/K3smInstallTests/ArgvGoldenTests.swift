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

/// The golden argv of every root step, pinned against the k3sm CLI's flags
/// (cmd/k3sm/install.go: `install --from-staging --user --agent --server
/// --token-file`, `uninstall [--purge --yes --user]`). Each case is checked twice:
/// as the builder's argument list, and as the argv /bin/sh actually hands the
/// CLI when it runs the rendered line.
@Suite("root step argv goldens")
struct ArgvGoldenTests {
    static let stage = "/Library/k3sm.staging/0.2.0.AbCdEfGh"
    static let studio = try! ServerAddress(parsing: "studio.local")

    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let action: CopyOutAction
        let argv: [String]
        var testDescription: String { name }
    }

    static let install = ["install", "--from-staging", stage, "--user", "alice"]

    static let cases: [Case] = [
        Case(name: "server first run", action: .startServer, argv: install),
        Case(name: "join", action: .join(studio),
             argv: install + ["--agent", "--server", "studio.local", "--token-file", stage + "/join-token"]),
        Case(name: "join over IPv6", action: .join(try! ServerAddress(parsing: "[fd00::1]:9345")),
             argv: install + ["--agent", "--server", "fd00::1", "--token-file", stage + "/join-token"]),
        Case(name: "update a server", action: .update(.server), argv: install),
        Case(name: "update a worker", action: .update(.agent(joinServer: studio)),
             argv: install + ["--agent", "--server", "studio.local"]),
        Case(name: "repair, in place", action: .repair, argv: ["install", "--from-staging", stage]),
        Case(name: "uninstall, keep data", action: .uninstall(purge: false), argv: ["uninstall"]),
        Case(name: "purge", action: .uninstall(purge: true), argv: ["uninstall", "--purge", "--yes", "--user", "alice"]),
    ]

    static func plan(_ action: CopyOutAction) throws -> CopyOutPlan {
        try CopyOutPlan(
            bundlePath: "/Applications/k3sm.app", payloadVersion: SemanticVersion("0.2.0")!,
            teamID: TeamID("ABCDE12345")!, user: ConsoleUser("alice")!, action: action)
    }

    @Test("the argument list", arguments: cases)
    func argumentList(_ c: Case) throws {
        let got = RootScriptBuilder.arguments(for: try Self.plan(c.action)).map { $0.resolved(stage: Self.stage) }
        #expect(got == c.argv)
    }

    @Test("the argv the shell passes", arguments: cases)
    func shellArgv(_ c: Case) throws {
        let text = RootScriptBuilder.render(try Self.plan(c.action)).text
        let lines = text.split(separator: "\n").filter { $0.hasPrefix("\"$k3sm\" ") }
        try #require(lines.count == 1, "want exactly one CLI invocation line")
        // "$k3sm" names a function that prints each argument on its own line.
        let probe = "stage=" + ShellQuote.quote(Self.stage) + "\n"
            + "argv() { for a in \"$@\"; do printf '%s\\n' \"$a\"; done; }\n"
            + "k3sm=argv\n"
            + lines[0] + "\n"
        let result = try shell(["-c", probe])
        #expect(result.status == 0)
        #expect(result.output.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init) == c.argv)
    }

    /// A repair is the CLI's in-place shape, which reads the kubeconfig owner
    /// from the server's record and needs no user (RepairTests.repairArgv).
    @Test("no install other than a repair relies on sudo's environment")
    func everyInstallNamesTheUser() throws {
        for c in Self.cases where c.argv.first == "install" && c.action != .repair {
            let i = try #require(c.argv.firstIndex(of: "--user"), "\(c.name) passes no --user")
            #expect(c.argv[i + 1] == "alice")
        }
    }

    @Test("a plain uninstall passes no flag at all")
    func uninstallFlags() throws {
        let plain = RootScriptBuilder.arguments(for: try Self.plan(.uninstall(purge: false)))
        #expect(plain == [.literal("uninstall")])
    }

    @Test("a purge names the console user, because env -i strips SUDO_USER")
    func purgeNamesTheUser() throws {
        let purge = RootScriptBuilder.arguments(for: try Self.plan(.uninstall(purge: true)))
        let i = try #require(purge.firstIndex(of: .literal("--user")))
        #expect(purge[i + 1] == .literal("alice"))
        #expect(purge.contains(.literal("--yes")))
    }

    /// The k3sm checkout to cross-check against: K3SM_DIR, or a sibling.
    static var cliSource: URL? {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = ProcessInfo.processInfo.environment["K3SM_DIR"].map { URL(fileURLWithPath: $0) }
            ?? root.deletingLastPathComponent().appending(path: "k3sm")
        let file = dir.appending(path: "cmd/k3sm/install.go")
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    @Test("every flag passed is one the CLI declares", .enabled(if: cliSource != nil))
    func flagsDeclared() throws {
        let source = try String(contentsOf: try #require(Self.cliSource), encoding: .utf8)
        func declared(_ set: String) -> Set<String> {
            // Flag declarations inside the named FlagSet's function, e.g.
            // fs.StringVar(&o.targetUser, "user", ...) and fs.Bool("purge", ...).
            let marker = "flag.NewFlagSet(\"\(set)\""
            guard let start = source.range(of: marker) else { return [] }
            var names = Set<String>()
            for line in source[start.upperBound...].split(separator: "\n") {
                if line.contains("fs.Parse(") || line.contains("fs.Visit(") { break }
                let kinds = ["fs.StringVar(", "fs.BoolVar(", "fs.IntVar(", "fs.String(", "fs.Bool(", "fs.Int("]
                guard kinds.contains(where: { line.contains($0) }) else { continue }
                let parts = line.split(separator: "\"", omittingEmptySubsequences: false)
                if parts.count >= 2, !parts[1].isEmpty { names.insert(String(parts[1])) }
            }
            return names
        }
        let installFlags = declared("install")
        let uninstallFlags = declared("uninstall")
        // A scrape that finds nothing means the CLI source changed shape, not
        // that every flag is fine: fail loudly instead of passing vacuously.
        try #require(!installFlags.isEmpty, "found no k3sm install flags in cmd/k3sm/install.go; the scrape is stale")
        try #require(!uninstallFlags.isEmpty, "found no k3sm uninstall flags in cmd/k3sm/install.go; the scrape is stale")
        #expect(installFlags.contains("from-staging"))
        #expect(uninstallFlags.contains("purge"))
        for c in Self.cases {
            let flags = c.argv.filter { $0.hasPrefix("--") }.map { String($0.dropFirst(2)) }
            let known = c.argv.first == "install" ? installFlags : uninstallFlags
            for f in flags {
                #expect(known.contains(f), "\(c.name): --\(f) is not a k3sm \(c.argv[0]) flag")
            }
        }
    }

    /// The published one-liner (install.sh) and the app install the same product.
    /// An explicit allowlist, so a new default flag on either side fails here.
    @Test("the app install keeps the script's argv shape")
    func installMatchesScriptShape() throws {
        let serverFlags = ["--from-staging", "--user"]
        let joinExtra = ["--agent", "--server", "--token-file"]
        func flags(_ argv: [String]) -> [String] { argv.filter { $0.hasPrefix("--") } }
        let server = try #require(Self.cases.first { $0.name == "server first run" })
        #expect(server.argv.first == "install")
        #expect(flags(server.argv) == serverFlags)
        #expect(server.argv.count == 1 + 2 * serverFlags.count)
        let join = try #require(Self.cases.first { $0.name == "join" })
        #expect(join.argv.first == "install")
        #expect(flags(join.argv) == serverFlags + joinExtra)
        #expect(join.argv.count == 1 + 2 * serverFlags.count + 1 + 2 * (joinExtra.count - 1))

        guard let dir = ProcessInfo.processInfo.environment["K3SM_DIR"] else {
            print("skipped the install.sh half: K3SM_DIR is unset")
            return
        }
        let script = try String(contentsOf: URL(fileURLWithPath: dir).appending(path: "install.sh"), encoding: .utf8)
        let marker = "\"$STAGE/k3sm\" install"
        let lines = script.split(separator: "\n").filter { $0.contains(marker) }
        try #require(!lines.isEmpty, "install.sh has no \(marker) line; the scrape is stale")
        for line in lines {
            let rest = line[line.range(of: marker)!.upperBound...]
            #expect(!rest.contains("--"), "install.sh passes a flag to install: \(line)")
            let next = rest.trimmingCharacters(in: .whitespaces).first
            #expect(next == nil || next == ";" || next == ")" || next == "|" || next == "&" || next == "#",
                    "install.sh passes an argument to install: \(line)")
        }
    }
}
