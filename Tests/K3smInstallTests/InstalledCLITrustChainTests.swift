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

/// The app-side check on the installed CLI's versioned chain, over a fake
/// filesystem: the same accept and refuse cases the root preamble's chain
/// suite runs for real, so the app and the root step agree on the layout.
@Suite("installed CLI trust symlink chain")
struct InstalledCLITrustChainTests {
    typealias Facts = InstalledCLITrust.PathFacts

    struct Node {
        var kind: Kind
        var owner: UInt32 = 0
        var mode: UInt16 = 0o755
        var acl = false
        enum Kind { case dir, file, link(String) }
    }

    static let dir = "/Library/k3sm"
    static let cli = dir + "/k3sm"
    static let current = dir + "/current"
    static let versions = dir + "/versions"
    static let version = "v0.3.0"
    static func versionDir(_ v: String = version) -> String { versions + "/" + v }
    static func target(_ v: String = version) -> String { versionDir(v) + "/k3sm" }

    static func layout(chain: Bool, version: String = version) -> [String: Node] {
        var fs: [String: Node] = ["/": Node(kind: .dir), "/Library": Node(kind: .dir), dir: Node(kind: .dir)]
        if chain {
            fs[cli] = Node(kind: .link("current/k3sm"))
            fs[current] = Node(kind: .link("versions/" + version))
            fs[versions] = Node(kind: .dir)
            fs[versionDir(version)] = Node(kind: .dir)
            fs[target(version)] = Node(kind: .file)
        } else {
            fs[cli] = Node(kind: .file)
        }
        return fs
    }

    /// The verdict over `fs`, and the path the signature check was asked about.
    static func evaluate(_ fs: [String: Node], signature: Bool = true) -> (InstalledCLITrust, String?) {
        var signed: String?
        let verdict = InstalledCLITrust.evaluate(
            cliPath: cli,
            facts: { path in
                guard let n = fs[path] else { return nil }
                var isLink = false, isDir = false, isFile = false
                switch n.kind {
                case .dir: isDir = true
                case .file: isFile = true
                case .link: isLink = true
                }
                return Facts(isSymlink: isLink, isDirectory: isDir, isRegularFile: isFile, ownerUID: n.owner, mode: n.mode, hasACL: n.acl)
            },
            linkTarget: { path in
                if case .link(let t) = fs[path]?.kind { return t }
                return nil
            },
            signatureValid: { signed = $0; return signature })
        return (verdict, signed)
    }

    // MARK: accepted

    @Test("the flat regular file is still accepted")
    func flatAccepted() {
        let (verdict, signed) = Self.evaluate(Self.layout(chain: false))
        #expect(verdict == .trusted)
        #expect(signed == Self.cli)
    }

    @Test("the full chain is accepted, and the signature is checked on the resolved target",
          arguments: ["v0.3.0", "v0.3.0-rc.1", "0.3.0+build_1", "unknown-0123456789ab"])
    func chainAccepted(_ version: String) {
        let (verdict, signed) = Self.evaluate(Self.layout(chain: true, version: version))
        #expect(verdict == .trusted)
        #expect(signed == Self.target(version))
    }

    // MARK: refused

    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let message: String
        let mutate: @Sendable (inout [String: Node]) -> Void
        var signature = true
        var testDescription: String { name }
    }

    static func expectRefused(_ c: Case) {
        var fs = layout(chain: true)
        c.mutate(&fs)
        let (verdict, _) = evaluate(fs, signature: c.signature)
        guard case .refused(let why) = verdict else {
            Issue.record("want refused, got \(verdict)"); return
        }
        #expect(why.contains(c.message), "\(why)")
    }

    static let notOwned = "is not owned by root, or is writable by group or others"
    static let components = [cli, current, versions, versionDir(), target()]

    @Test("a component not root-owned is refused", arguments: components)
    func notRootOwned(_ path: String) {
        Self.expectRefused(Case(name: path, message: path + " " + Self.notOwned, mutate: { $0[path]!.owner = 501 }))
    }

    @Test("a component group- or other-writable is refused", arguments: components + [dir])
    func groupOrOtherWritable(_ path: String) {
        Self.expectRefused(Case(name: path + " g+w", message: path + " " + Self.notOwned, mutate: { $0[path]!.mode = 0o775 }))
        Self.expectRefused(Case(name: path + " o+w", message: path + " " + Self.notOwned, mutate: { $0[path]!.mode = 0o757 }))
    }

    @Test("a component with an ACL is refused", arguments: components)
    func acl(_ path: String) {
        Self.expectRefused(Case(name: path, message: path + " carries an ACL", mutate: { $0[path]!.acl = true }))
    }

    static let leaving: [Case] = [
        Case(name: "k3sm is an absolute link to the same chain", message: cli + " is a symlink other than current/k3sm",
             mutate: { $0[cli]!.kind = .link(current + "/k3sm") }),
        Case(name: "k3sm points out of the layout", message: cli + " is a symlink other than current/k3sm",
             mutate: { $0[cli]!.kind = .link("../elsewhere/k3sm") }),
        Case(name: "current is an absolute link", message: current + " does not point into versions",
             mutate: { $0[current]!.kind = .link(versionDir()) }),
        Case(name: "current points out of the layout", message: current + " does not point into versions",
             mutate: { $0[current]!.kind = .link("../k3sm/versions/" + version) }),
        Case(name: "current climbs out of versions", message: current + " names an invalid version",
             mutate: { $0[current]!.kind = .link("versions/../../elsewhere") }),
        Case(name: "current names versions itself", message: current + " names an invalid version",
             mutate: { $0[current]!.kind = .link("versions/..") }),
    ]

    @Test("a chain leaving /Library/k3sm is refused", arguments: leaving)
    func leavingTheLayout(_ c: Case) { Self.expectRefused(c) }

    @Test("a final target that fails the requirement is refused")
    func failsRequirement() {
        Self.expectRefused(Case(name: "unsigned", message: "not signed by the k3sm Developer ID", mutate: { _ in }, signature: false))
    }

    static let extraHop: [Case] = [
        Case(name: "the target is itself a link", message: target() + " is a symlink",
             mutate: { $0[target()]!.kind = .link("k3sm.real"); $0[versionDir() + "/k3sm.real"] = Node(kind: .file) }),
        Case(name: "the version directory is a link", message: versionDir() + " is a symlink",
             mutate: { $0[versionDir()]!.kind = .link("v0.3.1") }),
        Case(name: "versions is a link", message: versions + " is a symlink",
             mutate: { $0[versions]!.kind = .link("real-versions") }),
        Case(name: "k3sm points at another link", message: cli + " is a symlink other than current/k3sm",
             mutate: { $0[cli]!.kind = .link("k3sm-next"); $0[dir + "/k3sm-next"] = Node(kind: .link("current/k3sm")) }),
        Case(name: "current is a directory, not a link", message: current + " is not a symlink into versions",
             mutate: { $0[current]!.kind = .dir; $0[current + "/k3sm"] = Node(kind: .file) }),
        Case(name: "current points at a link to versions", message: current + " does not point into versions",
             mutate: { $0[current]!.kind = .link("current-next"); $0[dir + "/current-next"] = Node(kind: .link("versions/" + version)) }),
        Case(name: "the target is a directory", message: target() + " is not a regular file",
             mutate: { $0[target()]!.kind = .dir }),
        Case(name: "versions is a file", message: versions + " is not a directory",
             mutate: { $0[versions]!.kind = .file }),
    ]

    @Test("an extra link hop is refused", arguments: extraHop)
    func extraLinkHop(_ c: Case) { Self.expectRefused(c) }

    static let malformed: [Case] = [
        Case(name: "current dangles", message: versionDir("v9.9.9") + " does not exist",
             mutate: { $0[current]!.kind = .link("versions/v9.9.9") }),
        Case(name: "current is missing", message: current + " is not a symlink into versions",
             mutate: { $0[current] = nil }),
        Case(name: "the target is missing", message: target() + " does not exist",
             mutate: { $0[target()] = nil }),
        Case(name: "a staging directory", message: current + " names an invalid version",
             mutate: { $0[current]!.kind = .link("versions/v0.3.0.partial") }),
        Case(name: "unknown- without twelve hex digits", message: current + " names an invalid version",
             mutate: { $0[current]!.kind = .link("versions/unknown-0123") }),
        Case(name: "an empty version", message: current + " names an invalid version",
             mutate: { $0[current]!.kind = .link("versions/") }),
        Case(name: "a trailing newline in the link", message: cli + " is a symlink other than current/k3sm",
             mutate: { $0[cli]!.kind = .link("current/k3sm\n") }),
        Case(name: "an unreadable link", message: cli + " is a symlink other than current/k3sm",
             mutate: { $0[cli] = Node(kind: .link("")) }),
    ]

    @Test("a dangling link or an invalid version name is refused", arguments: malformed)
    func malformedChain(_ c: Case) { Self.expectRefused(c) }

    // MARK: one grammar

    static let names: [(String, Bool)] = [
        ("v0.3.0", true), ("0.3.0", true), ("v0.3.0-rc.1", true), ("0.3.0+build_1", true),
        ("unknown-0123456789ab", true), ("unknownx", true), ("a.partial.b", true),
        (String(repeating: "x", count: 128), true),
        ("", false), (".", false), ("..", false), (".v1", false), ("-v1", false), ("+v1", false), ("_v1", false),
        ("v1.partial", false), ("v1/x", false), ("v 1", false), ("v1\n", false), ("v\u{fc}", false), ("v1*", false),
        ("unknown-0123456789AB", false), ("unknown-0123", false), ("unknown-0123456789abc", false), ("unknown-", false),
        (String(repeating: "x", count: 129), false),
    ]

    @Test("the Swift and shell version grammars accept and refuse the same names")
    func oneGrammar() throws {
        for (name, valid) in Self.names {
            #expect(VersionDirectoryName.isValid(name) == valid, "Swift: \(name.debugDescription)")
            let script = "refuse() { echo refused; exit 0; }\np=x\nver=" + ShellQuote.quote(name) + "\n"
                + VersionDirectoryName.shellLines.joined(separator: "\n") + "\necho accepted\n"
            let result = try shell(["-c", script])
            #expect(result.status == 0)
            #expect(result.output == (valid ? "accepted\n" : "refused\n"), "shell: \(name.debugDescription) gave \(result.output)")
        }
    }
}
