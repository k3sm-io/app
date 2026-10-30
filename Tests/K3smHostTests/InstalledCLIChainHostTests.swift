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

/// The app-side check against a real layout in a temporary directory, so
/// `lstat` and `readlink` themselves are exercised: the fake filesystem in
/// the K3smInstall tests covers every rule, this covers the system calls.
@Suite("installed CLI trust on a real chain")
struct InstalledCLIChainHostTests {
    struct Layout {
        let base: String
        var dir: String { base + "/k3sm" }
        var cli: String { dir + "/k3sm" }
        var current: String { dir + "/current" }
        var target: String { dir + "/versions/v0.3.0/k3sm" }
    }

    static func makeLayout(chain: Bool) throws -> Layout {
        // The real path (/private/var/..., not /var/...), so no ancestor is a symlink.
        let tmp = try #require(realpath(NSTemporaryDirectory(), nil))
        defer { free(tmp) }
        let layout = Layout(base: String(cString: tmp) + "/k3sm-host-chain-\(UUID().uuidString)")
        let fm = FileManager.default
        let mode: [FileAttributeKey: Any] = [.posixPermissions: 0o755]
        try fm.createDirectory(atPath: layout.dir, withIntermediateDirectories: true, attributes: mode)
        try fm.setAttributes(mode, ofItemAtPath: layout.base)
        let binary = chain ? layout.target : layout.cli
        if chain {
            try fm.createDirectory(atPath: layout.dir + "/versions/v0.3.0", withIntermediateDirectories: true, attributes: mode)
            try fm.createSymbolicLink(atPath: layout.current, withDestinationPath: "versions/v0.3.0")
            try fm.createSymbolicLink(atPath: layout.cli, withDestinationPath: "current/k3sm")
        }
        try Data("#!/bin/sh\n".utf8).write(to: URL(fileURLWithPath: binary))
        try fm.setAttributes(mode, ofItemAtPath: binary)
        return layout
    }

    static func trust(_ layout: Layout, signed: inout String?) -> InstalledCLITrust {
        var seen: String?
        let verdict = InstalledCLI.trust(cliPath: layout.cli, owners: [0, getuid()]) { seen = $0; return true }
        signed = seen
        return verdict
    }

    @Test("the flat regular file is still accepted")
    func flat() throws {
        let layout = try Self.makeLayout(chain: false)
        defer { try? FileManager.default.removeItem(atPath: layout.base) }
        var signed: String?
        #expect(Self.trust(layout, signed: &signed) == .trusted)
        #expect(signed == layout.cli)
    }

    @Test("the full chain is accepted, and the signature is checked on the resolved target")
    func chain() throws {
        let layout = try Self.makeLayout(chain: true)
        defer { try? FileManager.default.removeItem(atPath: layout.base) }
        var signed: String?
        #expect(Self.trust(layout, signed: &signed) == .trusted)
        #expect(signed == layout.target)
    }

    @Test("readlink returns the exact target, a trailing newline included")
    func exactTarget() throws {
        let layout = try Self.makeLayout(chain: true)
        defer { try? FileManager.default.removeItem(atPath: layout.base) }
        #expect(InstalledCLI.linkTarget(layout.cli) == "current/k3sm")
        #expect(InstalledCLI.linkTarget(layout.target) == nil)
        try FileManager.default.removeItem(atPath: layout.cli)
        try FileManager.default.createSymbolicLink(atPath: layout.cli, withDestinationPath: "current/k3sm\n")
        var signed: String?
        #expect(Self.trust(layout, signed: &signed) == .refused("\(layout.cli) is a symlink other than current/k3sm"))
        #expect(signed == nil)
    }

    @Test("a group-writable link is refused")
    func writableLink() throws {
        let layout = try Self.makeLayout(chain: true)
        defer { try? FileManager.default.removeItem(atPath: layout.base) }
        #expect(lchmod(layout.current, 0o775) == 0)
        var signed: String?
        #expect(Self.trust(layout, signed: &signed)
            == .refused("\(layout.current) is not owned by root, or is writable by group or others"))
    }

    @Test("this user's chain is refused when only root is trusted")
    func rootOnly() throws {
        let layout = try Self.makeLayout(chain: true)
        defer { try? FileManager.default.removeItem(atPath: layout.base) }
        let verdict = InstalledCLI.trust(cliPath: layout.cli, owners: [0]) { _ in true }
        guard case .refused(let why) = verdict else { Issue.record("want refused"); return }
        #expect(why.contains("is not owned by root"))
    }
}
