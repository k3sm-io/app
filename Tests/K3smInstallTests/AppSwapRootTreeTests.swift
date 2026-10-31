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

import Darwin
import Foundation
import Testing

@testable import K3smInstall
@testable import K3smSwap

/// The helper's root-mode location check (`HelperChain`), over an injected
/// `lstat` seam so it runs as a user.
@Suite struct AppSwapRootHelperChainTests {
    static let stage = "/Library/k3sm.staging/app-swap-helper.ABCD1234"
    static let helper = stage + "/k3sm.app/Contents/Helpers/k3sm-app-update"
    static let directory = HelperChain.Entry(isSymlink: false, owner: 0, mode: S_IFDIR | 0o700)

    /// The good chain: every directory from the staging root down to the
    /// helper, and the helper, root-owned and writable by root alone.
    static let good: [String: HelperChain.Entry] = {
        var chain: [String: HelperChain.Entry] = [helper: HelperChain.Entry(isSymlink: false, owner: 0, mode: S_IFREG | 0o500)]
        var dir = (helper as NSString).deletingLastPathComponent
        while dir.count >= CopyOutPlan.stagingRoot.count {
            chain[dir] = directory
            dir = (dir as NSString).deletingLastPathComponent
        }
        return chain
    }()

    struct Case: CustomTestStringConvertible, Sendable {
        let name: String
        let path: String
        let change: [String: HelperChain.Entry]
        let accept: Bool
        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(name: "the good chain", path: helper, change: [:], accept: true),
        Case(name: "a user-owned directory in the chain", path: helper,
             change: [stage + "/k3sm.app/Contents": HelperChain.Entry(isSymlink: false, owner: 501, mode: S_IFDIR | 0o700)], accept: false),
        Case(name: "a user-owned helper", path: helper,
             change: [helper: HelperChain.Entry(isSymlink: false, owner: 501, mode: S_IFREG | 0o500)], accept: false),
        Case(name: "a symlink in the chain", path: helper,
             change: [stage + "/k3sm.app": HelperChain.Entry(isSymlink: true, owner: 0, mode: S_IFLNK | 0o755)], accept: false),
        Case(name: "a group-writable directory", path: helper,
             change: [stage: HelperChain.Entry(isSymlink: false, owner: 0, mode: S_IFDIR | 0o770)], accept: false),
        Case(name: "an other-writable directory", path: helper,
             change: [CopyOutPlan.stagingRoot: HelperChain.Entry(isSymlink: false, owner: 0, mode: S_IFDIR | 0o702)], accept: false),
        Case(name: "a /../ component", path: stage + "/k3sm.app/../k3sm.app/Contents/Helpers/k3sm-app-update", change: [:], accept: false),
        Case(name: "a trailing .. component", path: stage + "/k3sm.app/Contents/Helpers/..", change: [:], accept: false),
        Case(name: "a /./ component", path: stage + "/./k3sm.app/Contents/Helpers/k3sm-app-update", change: [:], accept: false),
        Case(name: "an empty component", path: stage + "//k3sm.app/Contents/Helpers/k3sm-app-update", change: [:], accept: false),
        Case(name: "the staging root but not the helper stage", path: CopyOutPlan.stagingRoot + "/0.2.0.ABCD/k3sm.app/Contents/Helpers/k3sm-app-update",
             change: [:], accept: false),
        Case(name: "outside the staging root", path: "/Applications/k3sm.app/Contents/Helpers/k3sm-app-update", change: [:], accept: false),
        Case(name: "a sibling of the staging root", path: "/Library/k3sm.staging2/app-swap-helper.ABCD1234/k3sm-app-update",
             change: [:], accept: false),
    ]

    @Test("the chain is accepted only when every entry is root's, real and writable by root alone", arguments: cases)
    func chain(_ c: Case) {
        let table = Self.good.merging(c.change) { $1 }
        // The cases that change no entry are refused by the path alone.
        let got = HelperChain.isRootOwned(c.path) { table[$0] }
        #expect(got == c.accept)
    }

    @Test("an entry that cannot be read refuses")
    func unreadable() {
        var table = Self.good
        table[Self.stage + "/k3sm.app/Contents/Helpers"] = nil
        #expect(!HelperChain.isRootOwned(Self.helper) { table[$0] })
    }

    @Test("the real lstat seam refuses this account's own files")
    func realSeam() {
        #expect(!HelperChain.isRootOwned(Self.helper))
    }
}

/// `AdminSwapEngine.isSafeTree` and the flag helpers over real trees made by
/// this account.
@Suite struct AppSwapRootTreeTests {
    final class Tree: @unchecked Sendable {
        let root: String
        var tree: String { root + "/tree" }
        init() {
            let tmp = (realpath(NSTemporaryDirectory(), nil)).map { p -> String in defer { free(p) }; return String(cString: p) }
            root = (tmp ?? NSTemporaryDirectory()) + "/k3sm-adminswap-tree-" + UUID().uuidString.prefix(8)
            try? FileManager.default.createDirectory(atPath: root + "/tree/Contents/MacOS", withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: root + "/tree/Contents/MacOS/k3sm-app", contents: Data("app".utf8),
                                           attributes: [.posixPermissions: 0o755])
            FileManager.default.createFile(atPath: root + "/outside", contents: Data("outside".utf8))
        }

        func safe() -> Bool {
            guard let fd = FileOps.openDirectory(root) else { return false }
            defer { close(fd) }
            return AdminSwapEngine.isSafeTree(at: fd, "tree")
        }

        func cleanUp() {
            AdminSwapEngine.clearUserLockingFlags(root)
            try? FileManager.default.removeItem(atPath: root)
        }
    }

    @Test("a tree of regular files and directories is safe")
    func plainTree() {
        let t = Tree()
        defer { t.cleanUp() }
        #expect(t.safe())
    }

    @Test("a hard link to a file outside the tree is refused, as is any hard link")
    func hardLink() {
        let t = Tree()
        defer { t.cleanUp() }
        #expect(link(t.root + "/outside", t.tree + "/Contents/link") == 0)
        #expect(!t.safe())
        #expect(unlink(t.root + "/outside") == 0)
        #expect(t.safe(), "one link left: the same file with no second name")
    }

    @Test("a FIFO is refused")
    func fifo() {
        let t = Tree()
        defer { t.cleanUp() }
        #expect(mkfifo(t.tree + "/Contents/pipe", 0o600) == 0)
        #expect(!t.safe())
    }

    @Test("a setuid file is refused")
    func setuid() {
        let t = Tree()
        defer { t.cleanUp() }
        #expect(chmod(t.tree + "/Contents/MacOS/k3sm-app", 0o4755) == 0)
        #expect(!t.safe())
    }

    @Test("a file or a directory flagged uchg or uappnd is refused, and clearing the user flags lets it be removed",
          arguments: [("Contents/MacOS/k3sm-app", UF_IMMUTABLE), ("Contents/MacOS/k3sm-app", UF_APPEND), ("Contents", UF_IMMUTABLE)])
    func userFlags(_ entry: String, _ flag: Int32) {
        let t = Tree()
        defer { t.cleanUp() }
        let path = t.tree + "/" + entry
        #expect(chflags(path, UInt32(flag)) == 0)
        #expect(!t.safe())
        guard let fd = FileOps.openDirectory(t.root) else { Issue.record("no root"); return }
        defer { close(fd) }
        #expect(!AdminSwapEngine.isFree(of: AdminSwapEngine.userLockingFlags, at: fd, "tree"))
        #expect(!FileOps.removeTree(at: fd, "tree"), "the flag keeps the tree")
        AdminSwapEngine.clearUserLockingFlags(t.tree)
        #expect(FileOps.removeTree(at: fd, "tree"))
    }

    @Test("the refused flags are uchg, uappnd, uunlnk, schg, sappnd and sunlnk, and no other")
    func flagSet() {
        #expect(AdminSwapEngine.userLockingFlags == 0x0000_0016)
        #expect(AdminSwapEngine.systemLockingFlags == 0x0016_0000)
        #expect(AdminSwapEngine.userLockingFlags & UInt32(UF_COMPRESSED | UF_HIDDEN | UF_NODUMP) == 0)
    }
}
