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

/// The lifecycle root script's refusals, run for real as this user: every
/// case stops the script before its CLI line, so nothing runs past a check.
extension LifecycleScriptTests {
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

    /// The script's definitions (everything before the check loop): no
    /// command in them acts, so running them and then one `acl_check` runs
    /// exactly the ACL check and nothing past it.
    static func definitions() throws -> String {
        let text = LifecycleScriptBuilder.render(.stop, teamID: team).text
        let loop = try #require(text.range(of: "for p in "))
        return String(text[..<loop.lowerBound])
    }

    @Test("an ACL refuses, with or without the mode's + marker")
    func aclRefusal() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "k3sm-acl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let plain = dir.appending(path: "plain")
        let withACL = dir.appending(path: "with-acl")
        try Data().write(to: plain)
        try Data().write(to: withACL)
        // An owner may add an ACL entry to its own file without root.
        let chmod = try shell(["-c", "/bin/chmod +a 'everyone deny delete' " + ShellQuote.quote(withACL.path)])
        try #require(chmod.status == 0)
        let defs = try Self.definitions()

        let clean = try Self.run("/bin/sh -c " + ShellQuote.quote(defs + "acl_check " + ShellQuote.quote(plain.path) + "\necho passed >&2\n"))
        #expect(clean.status == 0)
        #expect(clean.stderr.contains("passed"))

        let refused = try Self.run("/bin/sh -c " + ShellQuote.quote(defs + "acl_check " + ShellQuote.quote(withACL.path) + "\necho passed >&2\n"))
        #expect(refused.status == LifecycleExit.refusedBinary)
        #expect(refused.stderr.contains("carries an ACL"))
        #expect(!refused.stderr.contains("passed"))

        // An ACL entry line alone (a listing whose mode has no +) refuses too.
        let lines = try Self.run("/bin/sh -c " + ShellQuote.quote(defs.replacingOccurrences(of: "/bin/ls -led \"$1\"", with: "printf '%s\\n%s' '-rw-r--r--  1 root  wheel  0 x' ' 0: group:everyone allow write'") + "acl_check /x\n"))
        #expect(lines.status == LifecycleExit.refusedBinary)
        #expect(lines.stderr.contains("carries an ACL"))
    }
}
