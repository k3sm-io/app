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
    static let signatureRefusal = InstalledCLITrust.refused("the installed k3sm is not signed by the k3sm Developer ID")

    static func trust(_ layout: InstalledCLIChainHostTests.Layout, _ policy: TrustPolicy, marker: Facts?) -> InstalledCLITrust {
        InstalledCLI.trust(policy: policy, cliPath: layout.cli, owners: [0, getuid()], marker: { marker })
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
}
