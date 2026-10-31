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

@testable import K3smHost
import K3smInstall

/// `InstalledCLI.trust(policy:)` against a real layout: developer mode swaps
/// the signature check for the marker, and nothing else.
@Suite("developer mode trust table: the installed CLI")
struct DeveloperModeHostTests {
    typealias Facts = InstalledCLITrust.PathFacts
    static let good = Facts(isSymlink: false, isDirectory: false, isRegularFile: true, ownerUID: 0, mode: 0o644)
    static let bad: [(String, Facts?)] = [
        ("absent", nil),
        ("a symlink", Facts(isSymlink: true, isDirectory: false, isRegularFile: false, ownerUID: 0, mode: 0o644)),
        ("a directory", Facts(isSymlink: false, isDirectory: true, isRegularFile: false, ownerUID: 0, mode: 0o755)),
        ("another owner", Facts(isSymlink: false, isDirectory: false, isRegularFile: true, ownerUID: 501, mode: 0o644)),
        ("group-writable", Facts(isSymlink: false, isDirectory: false, isRegularFile: true, ownerUID: 0, mode: 0o664)),
        ("an ACL", Facts(isSymlink: false, isDirectory: false, isRegularFile: true, ownerUID: 0, mode: 0o644, hasACL: true)),
    ]
    /// `/`, `/Library` as root-owned directories and `marker` at the marker path.
    static func rooted(_ marker: Facts?) -> (String) -> Facts? {
        { path in
            if path == DeveloperMode.markerPath { return marker }
            return ["/", "/Library"].contains(path)
                ? Facts(isSymlink: false, isDirectory: true, isRegularFile: false, ownerUID: 0, mode: 0o755) : nil
        }
    }
    static let signatureRefusal = InstalledCLITrust.refused("the installed k3sm is not signed by the k3sm Developer ID")

    static func trust(_ layout: InstalledCLIChainHostTests.Layout, _ policy: TrustPolicy, marker: Facts?) -> InstalledCLITrust {
        InstalledCLI.trust(policy: policy, cliPath: layout.cli, owners: [0, getuid()],
                           markerOn: { DeveloperMode.isOn(owners: [0], facts: Self.rooted(marker)) })
    }

    @Test("developer mode trusts the paths with a valid marker, and refuses on the signature path without one")
    func developerModeTrustTableHostPolicy() throws {
        let layout = try InstalledCLIChainHostTests.makeLayout(chain: true)
        defer { try? FileManager.default.removeItem(atPath: layout.base) }
        #expect(Self.trust(layout, .developer, marker: Self.good) == .trusted)
        for (name, facts) in Self.bad {
            #expect(Self.trust(layout, .developer, marker: facts) == Self.signatureRefusal, "\(name)")
        }
        // The Developer ID policy checks the signature whatever the marker:
        // the layout's shell script carries no Developer ID signature.
        let team = TeamID("ABCDE12345")!
        #expect(Self.trust(layout, .developerID(team), marker: Self.good) == Self.signatureRefusal)
    }

    @Test("developer mode keeps every path check on the CLI")
    func developerModeTrustTableHostPathsStay() throws {
        let layout = try InstalledCLIChainHostTests.makeLayout(chain: false)
        defer { try? FileManager.default.removeItem(atPath: layout.base) }
        try FileManager.default.setAttributes([.posixPermissions: 0o775], ofItemAtPath: layout.cli)
        guard case .refused(let why) = Self.trust(layout, .developer, marker: Self.good) else {
            Issue.record("a group-writable CLI was trusted")
            return
        }
        #expect(why.contains("is not owned by root, or is writable by group or others"))
    }

    /// A marker in a real directory tree, read through `developerModeOn`,
    /// the check the app's badge, its enabled verbs and its trust policy use.
    static func markerTree() throws -> (dir: String, marker: String) {
        // The real path (/private/var/..., not /var/...), so no ancestor is a symlink.
        let tmp = try #require(realpath(NSTemporaryDirectory(), nil))
        defer { free(tmp) }
        let base = String(cString: tmp) + "/k3sm-host-marker-\(UUID().uuidString)"
        let dir = base + "/Library"
        let fm = FileManager.default
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: base)
        let marker = dir + "/k3sm.developer-mode"
        try Data().write(to: URL(fileURLWithPath: marker))
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: marker)
        return (dir, marker)
    }

    @Test("a marker whose parent directory is group-writable reads as off")
    func developerModeMarkerParentGroupWritable() throws {
        let tree = try Self.markerTree()
        let base = (tree.dir as NSString).deletingLastPathComponent
        defer { try? FileManager.default.removeItem(atPath: base) }
        // Every ancestor of the temporary directory belongs to root or to this user.
        let owners: Set<UInt32> = [0, getuid()]
        #expect(InstalledCLI.developerModeOn(markerPath: tree.marker, owners: owners))
        try FileManager.default.setAttributes([.posixPermissions: 0o775], ofItemAtPath: tree.dir)
        #expect(!InstalledCLI.developerModeOn(markerPath: tree.marker, owners: owners))
        // The marker alone still passes the leaf checks: only the chain refuses it.
        let leaf = try #require(InstalledCLI.pathFacts(tree.marker))
        #expect(!leaf.isSymlink && leaf.isRegularFile && leaf.mode & 0o022 == 0)
    }

    @Test("a marker reached through a symlinked directory reads as off")
    func developerModeMarkerSymlinkedParent() throws {
        let tree = try Self.markerTree()
        let base = (tree.dir as NSString).deletingLastPathComponent
        defer { try? FileManager.default.removeItem(atPath: base) }
        let link = base + "/linked"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "Library")
        #expect(!InstalledCLI.developerModeOn(markerPath: link + "/k3sm.developer-mode", owners: [0, getuid()]))
        #expect(!InstalledCLI.developerModeOn(markerPath: base + "/Library/absent", owners: [0, getuid()]))
    }
}
