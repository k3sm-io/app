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

/// A well-formed join token no real cluster minted. Every test that follows
/// the token through the app checks that it lands on the pasteboard and
/// nowhere else.
let sentinelToken = "K10" + String(repeating: "5e", count: 32) + "::boot-0123456789ab:" + String(repeating: "deadbeef", count: 8)

/// The join token mint: its fixed TTL and argv against the k3sm CLI
/// (cmd/k3sm/token.go), a byte-for-byte golden, the shared installed-CLI
/// checks, and a failed mint that prints nothing on standard output.
@Suite("join token mint")
struct JoinTokenMintTests {
    static let team = TeamID("ABCDE12345")!

    @Test("the TTL is 15 minutes, one constant")
    func ttl() {
        #expect(JoinTokenMint.ttl == .seconds(900))
        #expect(JoinTokenMint.ttlMinutes == 15)
        #expect(JoinTokenMint.ttlFlag == "15m")
        #expect(JoinTokenMint.allCases == [.workerToken])
    }

    @Test("the argv is token create --ttl 15m, never --server")
    func argv() {
        let argv = JoinTokenMint.arguments(for: .workerToken)
        #expect(argv == ["token", "create", "--ttl", "15m"])
        #expect(!argv.contains("--server"))
    }

    @Test("the mint script, byte for byte")
    func golden() {
        let want = #"""
            set -eu
            umask 077
            cd /
            k3sm='/Library/k3sm/k3sm'
            refuse() {
            	echo "k3sm app: refused: $1" >&2
            	exit 100
            }
            nl='
            '
            acl_check() {
            	listing=$(/bin/ls -led "$1") || refuse "$1 could not be checked"
            	case "${listing%% *}" in *+) refuse "$1 carries an ACL" ;; esac
            	case "$listing" in *"$nl"*) refuse "$1 carries an ACL" ;; esac
            }
            for p in '/' '/Library' '/Library/k3sm' '/Library/k3sm/k3sm'; do
            	if [ -L "$p" ]; then refuse "$p is a symlink"; fi
            	if [ ! -e "$p" ]; then refuse "$p does not exist"; fi
            	bad=$(/usr/bin/find "$p" -maxdepth 0 \( ! -user 0 -o -perm -0020 -o -perm -0002 \) -print) || refuse "$p could not be checked"
            	if [ -n "$bad" ]; then refuse "$p is not owned by root, or is writable by group or others"; fi
            	acl_check "$p"
            done
            if [ ! -f "$k3sm" ]; then refuse "$k3sm is not a regular file"; fi
            if ! /usr/bin/codesign --verify --strict '-R=anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = "ABCDE12345"' "$k3sm"; then
            	echo 'k3sm app: refused: the installed k3sm is not signed by the k3sm Developer ID' >&2
            	exit 101
            fi
            token=$("$k3sm" 'token' 'create' '--ttl' '15m')
            printf '%s\n' "$token"

            """#
        let script = JoinTokenMint.render(.workerToken, teamID: Self.team)
        #expect(script.text == want)
        #expect(!script.readsInput)
        #expect(!script.usesStagingLock)
        #expect(script.prompt == "k3sm wants to create a join token for another Mac. It expires in 15 minutes.")
    }

    @Test("the mint script carries the same checks as the lifecycle script")
    func samePreamble() {
        let preamble = InstalledCLIPreamble.render(teamID: Self.team, cliPath: K3smCLI.path)
        let mint = JoinTokenMint.render(.workerToken, teamID: Self.team).text
        let stop = LifecycleScriptBuilder.render(.stop, teamID: Self.team).text
        #expect(mint.hasPrefix(preamble))
        #expect(stop.hasPrefix(preamble))
        for check in ["set -eu", "umask 077", "cd /", "if [ -L \"$p\" ]", "-perm -0020 -o -perm -0002", "\tacl_check \"$p\"",
                      "if [ ! -f \"$k3sm\" ]", "/usr/bin/codesign --verify --strict '-R=anchor apple generic"] {
            #expect(preamble.contains(check), "the preamble lost \(check)")
        }
        // The CLI runs only after every check, and nothing else follows.
        #expect(String(mint.dropFirst(preamble.count)).split(separator: "\n").count == 2)
        let line = JoinTokenMint.render(.workerToken, teamID: Self.team).command(inputPath: "/dev/null")
        #expect(line.hasPrefix("/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/sh -c "))
        #expect(!line.contains("lockf"))
    }

    @Test("the mint script refuses a user-owned CLI and never runs it")
    func refusesUserOwned() throws {
        let tmp = try #require(realpath(NSTemporaryDirectory(), nil))
        defer { free(tmp) }
        let base = URL(fileURLWithPath: String(cString: tmp)).appending(path: "k3sm-mint-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let marker = base.appending(path: "ran")
        let cli = base.appending(path: "k3sm")
        try Data("#!/bin/sh\n: > \(ShellQuote.quote(marker.path))\necho \(sentinelToken)\n".utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        let line = JoinTokenMint.render(.workerToken, teamID: Self.team, cliPath: cli.path).command(inputPath: "/dev/null")
        let result = try shell(["-c", line])
        #expect(result.status == LifecycleExit.refusedBinary)
        #expect(result.output.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    /// Runs the mint's CLI lines (after the checks) against a stand-in CLI.
    static func runTail(cliBody: String) throws -> (status: Int32, output: String) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "k3sm-mint-tail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cli = dir.appending(path: "k3sm")
        try Data(("#!/bin/sh\n" + cliBody).utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        let script = JoinTokenMint.render(.workerToken, teamID: team).text
        let preamble = InstalledCLIPreamble.render(teamID: team, cliPath: K3smCLI.path)
        let tail = "set -eu\nk3sm=\(ShellQuote.quote(cli.path))\n" + script.dropFirst(preamble.count)
        return try shell(["-c", tail])
    }

    @Test("a failed mint prints nothing on standard output")
    func failedMintPrintsNothing() throws {
        let failed = try Self.runTail(cliBody: "echo \(sentinelToken)\necho 'mint failed' >&2\nexit 1\n")
        #expect(failed.status == 1)
        #expect(failed.output.isEmpty)
        let ok = try Self.runTail(cliBody: "test \"$1 $2 $3 $4\" = 'token create --ttl 15m' || exit 9\necho \(sentinelToken)\n")
        #expect(ok.status == 0)
        #expect(ok.output == sentinelToken + "\n")
    }

    // MARK: the k3sm CLI contract

    static var k3smRoot: URL? {
        LifecycleScriptTests.cliDirectory?.deletingLastPathComponent().deletingLastPathComponent()
    }

    @Test("the mint's verb and flag are ones the CLI declares", .enabled(if: k3smRoot != nil))
    func tokenGoDeclares() throws {
        let root = try #require(Self.k3smRoot)
        let token = try String(contentsOf: root.appending(path: "cmd/k3sm/token.go"), encoding: .utf8)
        let main = try String(contentsOf: root.appending(path: "cmd/k3sm/main.go"), encoding: .utf8)
        #expect(main.contains("case \"token\":"), "k3sm has no token verb")
        #expect(token.contains("case \"create\":"), "k3sm token has no create subcommand")
        #expect(token.contains("fs.Duration(\"ttl\""), "k3sm token create declares no --ttl duration flag")
        for f in JoinTokenMint.arguments(for: .workerToken).filter({ $0.hasPrefix("--") }) {
            #expect(token.contains("(\"\(f.dropFirst(2))\""), "\(f) is not a k3sm token create flag")
        }
        // The token grammar the app checks is the one the CLI prints.
        let bootstrap = try String(contentsOf: root.appending(path: "pkg/bootstrap/token.go"), encoding: .utf8)
        #expect(bootstrap.contains("const tokenPrefix = \"K10\""))
        #expect(bootstrap.contains("\"%s%s::%s:%s\", tokenPrefix, caHash, user, secret"))
    }

    @Test("the join command's flags and file are the documented ones", .enabled(if: k3smRoot != nil))
    func joinFormDocumented() throws {
        let root = try #require(Self.k3smRoot)
        let install = try String(contentsOf: root.appending(path: "cmd/k3sm/install.go"), encoding: .utf8)
        for f in JoinCommandText.installArguments(server: "x").filter({ $0.hasPrefix("--") }) {
            #expect(install.contains("Var(&o.") && install.contains(", \"\(f.dropFirst(2))\","), "\(f) is not a k3sm install flag")
        }
        let doc = try String(contentsOf: root.appending(path: "docs/user/multi-node.md"), encoding: .utf8)
        #expect(doc.contains(JoinCommandText.storeStep), "the docs no longer store the token this way")
        #expect(doc.contains("--token-file \(JoinCommandText.tokenFile)"))
        #expect(doc.contains("sudo k3sm install --agent"))
    }
}

/// The join token grammar and its redaction.
@Suite("join token grammar")
struct JoinTokenGrammarTests {
    @Test("a minted token passes")
    func valid() throws {
        let token = try #require(JoinToken(validating: sentinelToken))
        #expect(token.value == sentinelToken)
        #expect(JoinToken(output: sentinelToken + "\n")?.value == sentinelToken)
        #expect(JoinToken(output: sentinelToken + "\r")?.value == sentinelToken)
        #expect(JoinToken(output: "# k3sm join token (expires x)\n" + sentinelToken)?.value == sentinelToken)
    }

    static let refused: [String] = [
        "",
        "K10",
        sentinelToken + "'",
        "'" + sentinelToken,
        sentinelToken + " x",
        sentinelToken.replacingOccurrences(of: "K10", with: "K11"),
        sentinelToken.replacingOccurrences(of: "::", with: ":"),
        "K10" + String(repeating: "5e", count: 31) + "::boot-0123456789ab:" + String(repeating: "deadbeef", count: 8),
        "K10" + String(repeating: "5E", count: 32) + "::boot-0123456789ab:" + String(repeating: "deadbeef", count: 8),
        "K10" + String(repeating: "5e", count: 32) + "::boot-0123456789ab:" + "deadbeef",
        "K10" + String(repeating: "5e", count: 32) + "::boot_01:" + String(repeating: "deadbeef", count: 8),
        "K10" + String(repeating: "5e", count: 32) + "::-boot:" + String(repeating: "deadbeef", count: 8),
        "K10" + String(repeating: "5e", count: 32) + "::boot-0123456789ab:" + String(repeating: "deadbeef", count: 8) + "$(id)",
        "K10" + String(repeating: "5e", count: 32) + "::boot-0123456789ab:" + String(repeating: "deadbeef", count: 8) + ":x",
    ]

    @Test("anything else is refused", arguments: refused)
    func refusal(_ text: String) {
        #expect(JoinToken(validating: text) == nil)
        #expect(JoinToken(output: text) == nil)
    }

    @Test("two token lines are refused")
    func twoLines() {
        #expect(JoinToken(output: sentinelToken + "\n" + sentinelToken) == nil)
    }

    /// A CLI that also prints a warning on standard output leaves a stray
    /// non-comment line beside the token, so nothing is read and nothing is
    /// copied. `do shell script` turns line ends into carriage returns.
    @Test("a warning line beside the token means no token", arguments: ["\n", "\r"])
    func strayWarningLine(_ eol: String) {
        let warning = "warning: the server certificate expires in 3 days"
        #expect(JoinToken(output: warning + eol + sentinelToken) == nil)
        #expect(JoinToken(output: sentinelToken + eol + warning) == nil)
        #expect(JoinToken(output: "# k3sm join token" + eol + warning + eol + sentinelToken + eol) == nil)
        #expect(JoinToken(output: "#warning" + eol + sentinelToken) == nil)
        #expect(JoinToken(output: "# k3sm join token" + eol + sentinelToken + eol)?.value == sentinelToken)
    }

    @Test("the token never prints through description or reflection")
    func redactedDescription() throws {
        let token = try #require(JoinToken(validating: sentinelToken))
        #expect(!"\(token)".contains(sentinelToken))
        #expect(!String(reflecting: token).contains(sentinelToken))
        var dumped = ""
        dump(token, to: &dumped)
        #expect(!dumped.contains("deadbeef"))
    }

    @Test("redaction removes anything token-shaped")
    func redact() {
        #expect(JoinToken.redact("boom \(sentinelToken) done") == "boom <redacted> done")
        #expect(JoinToken.redact("no token here") == "no token here")
        #expect(!JoinToken.redact("a\(sentinelToken)b\(sentinelToken)").contains("deadbeef"))
    }
}

/// The copied command: the documented two-step join as one line.
@Suite("join command text")
struct JoinCommandTextTests {
    static let server = try! ServerAddress(parsing: "192.168.0.50")

    @Test("the copied text, byte for byte")
    func golden() throws {
        let token = try #require(JoinToken(validating: sentinelToken))
        let want = "printf '%s' '\(sentinelToken)' | sudo sh -c 'umask 077; cat > /var/root/k3sm-join-token'"
            + " && sudo k3sm install --agent --server 192.168.0.50 --token-file /var/root/k3sm-join-token"
        #expect(JoinCommandText.render(token: token, server: Self.server) == want)
    }

    @Test("only an IPv4 server renders")
    func ipv4Only() throws {
        let token = try #require(JoinToken(validating: sentinelToken))
        #expect(JoinCommandText.render(token: token, server: try ServerAddress(parsing: "server.local")) == nil)
        #expect(JoinCommandText.render(token: token, server: try ServerAddress(parsing: "[fd00::1]")) == nil)
    }

    @Test("the shell reads the token from stdin and runs the documented install")
    func shellReading() throws {
        let token = try #require(JoinToken(validating: sentinelToken))
        let text = try #require(JoinCommandText.render(token: token, server: Self.server))
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "k3sm-join-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let tok = ShellQuote.quote(dir.appending(path: "tok").path)
        let args = ShellQuote.quote(dir.appending(path: "args").path)
        let fake = "sudo() { if [ \"$1\" = sh ]; then printf '%s\\n' \"$3\" > \(args).sh; cat > \(tok); else printf '%s\\n' \"$@\" > \(args); fi; }\n"
        let result = try shell(["-c", fake + text])
        #expect(result.status == 0)
        #expect(try String(contentsOf: dir.appending(path: "tok"), encoding: .utf8) == sentinelToken)
        #expect(try String(contentsOf: dir.appending(path: "args.sh"), encoding: .utf8) == "umask 077; cat > /var/root/k3sm-join-token\n")
        #expect(try String(contentsOf: dir.appending(path: "args"), encoding: .utf8)
            == (["k3sm"] + JoinCommandText.installArguments(server: "192.168.0.50")).joined(separator: "\n") + "\n")
    }
}
