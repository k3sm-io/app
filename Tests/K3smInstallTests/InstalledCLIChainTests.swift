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

/// The installed CLI's two accepted shapes, run for real as this user against
/// a layout in a temporary directory: the flat root-owned binary, and the
/// versioned chain `k3sm -> current/k3sm`, `current -> versions/<version>`.
/// The preamble's seam trusts this user beside root and takes the code
/// signing requirement, so the layout here can pass; production renders only
/// root and the Developer ID requirement. A copy of /bin/ls stands in for the
/// CLI: it satisfies `anchor apple`, and fails the Developer ID requirement.
@Suite("installed CLI symlink chain")
struct InstalledCLIChainTests {
    static let team = TeamID("ABCDE12345")!
    static let version = "v0.3.0"
    static let accepted = "accepted: "

    /// A layout under a fresh temporary directory. `dir` stands for
    /// /Library/k3sm; `cli` for /Library/k3sm/k3sm.
    struct Layout {
        let base: String
        var dir: String { base + "/k3sm" }
        var cli: String { dir + "/k3sm" }
        var current: String { dir + "/current" }
        var versions: String { dir + "/versions" }
        func versionDir(_ v: String = InstalledCLIChainTests.version) -> String { versions + "/" + v }
        func target(_ v: String = InstalledCLIChainTests.version) -> String { versionDir(v) + "/k3sm" }
    }

    /// Builds the flat layout, or the chain to `version`, every directory
    /// 0755 and the binary 0755.
    static func makeLayout(chain: Bool, version: String = version) throws -> Layout {
        // The real path (/private/var/..., not /var/...), so no ancestor is a symlink.
        let tmp = try #require(realpath(NSTemporaryDirectory(), nil))
        defer { free(tmp) }
        let layout = Layout(base: String(cString: tmp) + "/k3sm-chain-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(atPath: layout.dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: layout.base)
        if chain {
            try fm.createDirectory(atPath: layout.versionDir(version), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
            try fm.copyItem(atPath: "/bin/ls", toPath: layout.target(version))
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: layout.target(version))
            try fm.createSymbolicLink(atPath: layout.current, withDestinationPath: "versions/" + version)
            try fm.createSymbolicLink(atPath: layout.cli, withDestinationPath: "current/k3sm")
        } else {
            try fm.copyItem(atPath: "/bin/ls", toPath: layout.cli)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: layout.cli)
        }
        return layout
    }

    /// The preamble for `layout`, trusting root and this user, then a line
    /// that reports the checked CLI path in place of running it.
    static func script(_ layout: Layout, requirement: String = "anchor apple") -> String {
        InstalledCLIPreamble.render(cliPath: layout.cli, requirement: requirement, owners: [0, getuid()])
            + "echo \"\(accepted)$k3sm\" >&2\n"
    }

    static func run(_ script: String) throws -> (status: Int32, stderr: String) {
        try LifecycleScriptTests.run("/bin/sh -c " + ShellQuote.quote(script))
    }

    static func link(_ path: String, to destination: String) throws {
        try? FileManager.default.removeItem(atPath: path)
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: destination)
    }

    static func chmod(_ mode: String, _ path: String, link: Bool = false) throws {
        let flag = link ? "-h " : ""
        let result = try shell(["-c", "/bin/chmod " + flag + mode + " " + ShellQuote.quote(path)])
        try #require(result.status == 0)
    }

    // MARK: accepted

    @Test("the flat regular file is still accepted")
    func flatAccepted() throws {
        let layout = try Self.makeLayout(chain: false)
        defer { try? FileManager.default.removeItem(atPath: layout.base) }
        let result = try Self.run(Self.script(layout))
        #expect(result.status == 0, "stderr: \(result.stderr)")
        #expect(result.stderr.contains(Self.accepted + layout.cli))
    }

    @Test("the full chain is accepted, and the CLI path is the resolved target", arguments: ["v0.3.0", "v0.3.0-rc.1", "0.3.0+build_1", "unknown-0123456789ab"])
    func chainAccepted(_ version: String) throws {
        let layout = try Self.makeLayout(chain: true, version: version)
        defer { try? FileManager.default.removeItem(atPath: layout.base) }
        let result = try Self.run(Self.script(layout))
        #expect(result.status == 0, "stderr: \(result.stderr)")
        #expect(result.stderr.contains(Self.accepted + layout.target(version) + "\n"), "stderr: \(result.stderr)")
    }

    @Test("production renders root alone and the Developer ID requirement")
    func productionSeam() {
        let text = InstalledCLIPreamble.render(teamID: Self.team, cliPath: K3smCLI.path)
        #expect(text == InstalledCLIPreamble.render(
            cliPath: K3smCLI.path, requirement: DesignatedRequirement.developerID(teamID: Self.team), owners: [0]))
        #expect(text.contains(#"\( ! -user 0 -o -perm -0020 -o -perm -0002 \)"#))
        #expect(!text.contains("-user \(getuid())") || getuid() == 0)
    }

    // MARK: refused

    /// One way the chain fails, applied to a freshly built chain.
    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let status: Int32
        /// The refusal text, built from the layout.
        let message: @Sendable (Layout) -> String
        let mutate: @Sendable (Layout) throws -> Void
        var requirement = "anchor apple"
        var testDescription: String { name }
    }

    static func expectRefused(_ c: Case) throws {
        let layout = try makeLayout(chain: true)
        defer { try? FileManager.default.removeItem(atPath: layout.base) }
        try c.mutate(layout)
        let result = try run(script(layout, requirement: c.requirement))
        #expect(result.status == c.status, "stderr: \(result.stderr)")
        #expect(result.stderr.contains(c.message(layout)), "stderr: \(result.stderr)")
        #expect(!result.stderr.contains(accepted), "the CLI line was reached")
    }

    static let notOwned = "is not owned by root, or is writable by group or others"

    /// A component owned by neither root nor this user. No file here can
    /// have another owner without root, so the case narrows the trusted
    /// owner for exactly one path: the find test treats it as foreign, and
    /// the refusal must name it. `userOwnedNeverRuns` proves the real
    /// owner test against a real user-owned file.
    @Test("a component not root-owned is refused", arguments: ["k3sm link", "current", "versions", "version directory", "target"])
    func notRootOwned(_ which: String) throws {
        let layout = try Self.makeLayout(chain: true)
        defer { try? FileManager.default.removeItem(atPath: layout.base) }
        let path: String
        switch which {
        case "k3sm link": path = layout.cli
        case "current": path = layout.current
        case "versions": path = layout.versions
        case "version directory": path = layout.versionDir()
        default: path = layout.target()
        }
        let uid = getuid()
        let script = Self.script(layout).replacingOccurrences(
            of: "! -user \(uid)", with: "\\( ! -user \(uid) -o -path \(ShellQuote.quote(path)) \\)")
        try #require(script.contains("-path"))
        let result = try Self.run(script)
        #expect(result.status == LifecycleExit.refusedBinary, "stderr: \(result.stderr)")
        #expect(result.stderr.contains(path + " " + Self.notOwned), "stderr: \(result.stderr)")
        #expect(!result.stderr.contains(Self.accepted))
    }

    static let writable: [Case] = [
        Case(name: "the k3sm link is writable by others", status: 100, message: { $0.cli + " " + notOwned },
             mutate: { try chmod("o+w", $0.cli, link: true) }),
        Case(name: "the current link is writable by group", status: 100, message: { $0.current + " " + notOwned },
             mutate: { try chmod("g+w", $0.current, link: true) }),
        Case(name: "versions is writable by group", status: 100, message: { $0.versions + " " + notOwned },
             mutate: { try chmod("g+w", $0.versions) }),
        Case(name: "the version directory is writable by others", status: 100, message: { $0.versionDir() + " " + notOwned },
             mutate: { try chmod("o+w", $0.versionDir()) }),
        Case(name: "the target is writable by group", status: 100, message: { $0.target() + " " + notOwned },
             mutate: { try chmod("g+w", $0.target()) }),
        Case(name: "the layout directory is writable by others", status: 100, message: { $0.dir + " " + notOwned },
             mutate: { try chmod("o+w", $0.dir) }),
    ]

    @Test("a component group- or other-writable is refused", arguments: writable)
    func groupOrOtherWritable(_ c: Case) throws { try Self.expectRefused(c) }

    static let leaving: [Case] = [
        Case(name: "k3sm is an absolute link to the same chain", status: 100,
             message: { $0.cli + " is a symlink other than current/k3sm" },
             mutate: { try link($0.cli, to: $0.current + "/k3sm") }),
        Case(name: "k3sm points out of the layout", status: 100,
             message: { $0.cli + " is a symlink other than current/k3sm" },
             mutate: { try link($0.cli, to: "../elsewhere/k3sm") }),
        Case(name: "current is an absolute link", status: 100,
             message: { $0.current + " does not point into versions" },
             mutate: { try link($0.current, to: $0.versionDir()) }),
        Case(name: "current points out of the layout", status: 100,
             message: { $0.current + " does not point into versions" },
             mutate: { try link($0.current, to: "../k3sm/versions/" + version) }),
        Case(name: "current climbs out of versions", status: 100,
             message: { $0.current + " names an invalid version" },
             mutate: { try link($0.current, to: "versions/../../elsewhere") }),
        Case(name: "current names versions itself", status: 100,
             message: { $0.current + " names an invalid version" },
             mutate: { try link($0.current, to: "versions/..") }),
    ]

    @Test("a chain leaving /Library/k3sm is refused", arguments: leaving)
    func leavingTheLayout(_ c: Case) throws { try Self.expectRefused(c) }

    static let unsigned: [Case] = [
        Case(name: "the target is not signed by the pinned team", status: 101,
             message: { _ in "not signed by the k3sm Developer ID" },
             mutate: { _ in }, requirement: DesignatedRequirement.developerID(teamID: team)),
        Case(name: "the target is unsigned", status: 101,
             message: { _ in "not signed by the k3sm Developer ID" },
             mutate: { layout in
                 try FileManager.default.removeItem(atPath: layout.target())
                 try Data("#!/bin/sh\n".utf8).write(to: URL(fileURLWithPath: layout.target()))
                 try chmod("0755", layout.target())
             }),
    ]

    @Test("a final target that fails the requirement is refused", arguments: unsigned)
    func failsRequirement(_ c: Case) throws { try Self.expectRefused(c) }

    static let extraHop: [Case] = [
        Case(name: "the target is itself a link", status: 100,
             message: { $0.target() + " is a symlink" },
             mutate: { layout in
                 try FileManager.default.moveItem(atPath: layout.target(), toPath: layout.versionDir() + "/k3sm.real")
                 try link(layout.target(), to: "k3sm.real")
             }),
        Case(name: "the version directory is a link", status: 100,
             message: { $0.versionDir() + " is a symlink" },
             mutate: { layout in
                 try FileManager.default.moveItem(atPath: layout.versionDir(), toPath: layout.versions + "/v0.3.1")
                 try link(layout.versionDir(), to: "v0.3.1")
             }),
        Case(name: "versions is a link", status: 100,
             message: { $0.versions + " is a symlink" },
             mutate: { layout in
                 try FileManager.default.moveItem(atPath: layout.versions, toPath: layout.dir + "/real-versions")
                 try link(layout.versions, to: "real-versions")
             }),
        Case(name: "k3sm points at another link", status: 100,
             message: { $0.cli + " is a symlink other than current/k3sm" },
             mutate: { layout in
                 try link(layout.dir + "/k3sm-next", to: "current/k3sm")
                 try link(layout.cli, to: "k3sm-next")
             }),
        Case(name: "current is a directory, not a link", status: 100,
             message: { $0.current + " is not a symlink into versions" },
             mutate: { layout in
                 try FileManager.default.removeItem(atPath: layout.current)
                 try FileManager.default.createDirectory(atPath: layout.current, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
                 try FileManager.default.copyItem(atPath: "/bin/ls", toPath: layout.current + "/k3sm")
             }),
        Case(name: "current points at a link to versions", status: 100,
             message: { $0.current + " does not point into versions" },
             mutate: { layout in
                 try link(layout.dir + "/current-next", to: "versions/" + version)
                 try link(layout.current, to: "current-next")
             }),
    ]

    @Test("an extra link hop is refused", arguments: extraHop)
    func extraLinkHop(_ c: Case) throws { try Self.expectRefused(c) }

    static let malformed: [Case] = [
        Case(name: "current dangles", status: 100,
             message: { $0.versionDir("v9.9.9") + " does not exist" },
             mutate: { try link($0.current, to: "versions/v9.9.9") }),
        Case(name: "a staging directory", status: 100,
             message: { $0.current + " names an invalid version" },
             mutate: { layout in
                 try FileManager.default.moveItem(atPath: layout.versionDir(), toPath: layout.versionDir("v0.3.0.partial"))
                 try link(layout.current, to: "versions/v0.3.0.partial")
             }),
        Case(name: "a hidden name", status: 100,
             message: { $0.current + " names an invalid version" },
             mutate: { layout in
                 try FileManager.default.moveItem(atPath: layout.versionDir(), toPath: layout.versionDir(".v0.3.0"))
                 try link(layout.current, to: "versions/.v0.3.0")
             }),
        Case(name: "unknown- without twelve hex digits", status: 100,
             message: { $0.current + " names an invalid version" },
             mutate: { layout in
                 try FileManager.default.moveItem(atPath: layout.versionDir(), toPath: layout.versionDir("unknown-0123"))
                 try link(layout.current, to: "versions/unknown-0123")
             }),
        Case(name: "an empty version", status: 100,
             message: { $0.current + " names an invalid version" },
             mutate: { try link($0.current, to: "versions/") }),
        Case(name: "a trailing newline in the link", status: 100,
             message: { $0.cli + " is a symlink other than current/k3sm" },
             mutate: { try link($0.cli, to: "current/k3sm\n") }),
    ]

    @Test("a dangling link or an invalid version name is refused", arguments: malformed)
    func malformedChain(_ c: Case) throws { try Self.expectRefused(c) }
}
