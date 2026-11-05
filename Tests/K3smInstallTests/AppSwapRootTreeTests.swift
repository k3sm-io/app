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
            if let fd = FileOps.openDirectory((root as NSString).deletingLastPathComponent) {
                AdminSwapEngine.clearUserLockingFlags(at: fd, (root as NSString).lastPathComponent)
                close(fd)
            }
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
        AdminSwapEngine.clearUserLockingFlags(at: fd, "tree")
        #expect(FileOps.removeTree(at: fd, "tree"))
    }

    /// Whether `path`, not followed, carries `uchg`.
    static func isImmutable(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && st.st_flags & UInt32(UF_IMMUTABLE) != 0
    }

    @Test("clearing the flags does not follow a symlink planted in the tree, at its top or inside it")
    func clearFlagsLeavesAPlantedSymlinksTarget() throws {
        let t = Tree()
        defer {
            _ = chflags(t.root + "/outside", 0)
            t.cleanUp()
        }
        try #require(chflags(t.root + "/outside", UInt32(UF_IMMUTABLE)) == 0)
        try FileManager.default.createSymbolicLink(atPath: t.tree + "/Contents/planted", withDestinationPath: t.root + "/outside")
        try FileManager.default.createSymbolicLink(atPath: t.root + "/top", withDestinationPath: t.root + "/outside")
        let fd = try #require(FileOps.openDirectory(t.root))
        defer { close(fd) }
        AdminSwapEngine.clearUserLockingFlags(at: fd, "tree")
        AdminSwapEngine.clearUserLockingFlags(at: fd, "top")
        #expect(Self.isImmutable(t.root + "/outside"))
    }

    @Test("a directory swapped for a symlink while the flags are cleared does not lead outside the tree")
    func clearFlagsHoldsTheDirectoryItOpened() throws {
        let t = Tree()
        let decoy = t.root + "/decoy"
        defer {
            _ = chflags(decoy + "/k3sm-app", 0)
            t.cleanUp()
        }
        try FileManager.default.createDirectory(atPath: decoy, withIntermediateDirectories: false)
        try Data("decoy".utf8).write(to: URL(fileURLWithPath: decoy + "/k3sm-app"))
        try #require(chflags(decoy + "/k3sm-app", UInt32(UF_IMMUTABLE)) == 0)
        try #require(chflags(t.tree + "/Contents/MacOS/k3sm-app", UInt32(UF_IMMUTABLE)) == 0)
        let fd = try #require(FileOps.openDirectory(t.root))
        defer { close(fd) }
        // What the owner of a dragged tree can do while root walks it.
        var swapped = false
        AdminSwapEngine.clearUserLockingFlags(at: fd, "tree") { name in
            guard name == "MacOS", !swapped else { return }
            swapped = true
            try? FileManager.default.moveItem(atPath: t.tree + "/Contents/MacOS", toPath: t.tree + "/Contents/moved")
            try? FileManager.default.createSymbolicLink(atPath: t.tree + "/Contents/MacOS", withDestinationPath: decoy)
        }
        #expect(swapped)
        #expect(Self.isImmutable(decoy + "/k3sm-app"), "the walk followed the swapped-in symlink")
        #expect(!Self.isImmutable(t.tree + "/Contents/moved/k3sm-app"), "the walk lost the directory it opened")
    }

    /// A group this account belongs to other than the one a new file gets:
    /// it stands in for root's, since a test cannot chown to root.
    static func handOverGroup(_ path: String) throws -> gid_t {
        var st = stat()
        try #require(lstat(path, &st) == 0)
        var groups = [gid_t](repeating: 0, count: Int(NGROUPS_MAX))
        let count = getgroups(Int32(groups.count), &groups)
        return try #require(groups.prefix(Int(max(count, 0))).first { $0 != st.st_gid })
    }

    static func status(_ path: String) throws -> stat {
        var st = stat()
        try #require(lstat(path, &st) == 0, "\(path)")
        return st
    }

    @Test("handing a tree over changes every entry top-down: flags, group, group and other write, setuid, ACL")
    func handOverChangesEveryEntry() throws {
        let t = Tree()
        defer { t.cleanUp() }
        let file = t.tree + "/Contents/MacOS/k3sm-app"
        let group = try Self.handOverGroup(t.tree)
        try #require(chmod(t.tree + "/Contents", 0o775) == 0 && chmod(file, 0o4775) == 0)
        #expect(try shell(["-c", "/bin/chmod +a 'everyone allow write' " + ShellQuote.quote(t.tree + "/Contents/MacOS")]).status == 0)
        try #require(chflags(file, UInt32(UF_IMMUTABLE)) == 0)
        let fd = try #require(FileOps.openDirectory(t.root))
        defer { close(fd) }
        #expect(AdminSwapEngine.handOverTree(at: fd, "tree", owner: getuid(), group: group))
        for path in [t.tree, t.tree + "/Contents", t.tree + "/Contents/MacOS", file] {
            let st = try Self.status(path)
            #expect(st.st_gid == group && st.st_mode & 0o6022 == 0 && st.st_flags & UInt32(UF_IMMUTABLE) == 0, "\(path)")
        }
        let contents = try #require(FileOps.openDirectory(t.tree + "/Contents"))
        defer { close(contents) }
        #expect(SystemTreeInspector().hasExtendedACL(at: contents, "MacOS") == false)
    }

    @Test("a planted symlink is not followed: its target keeps its owner, group, mode and flags")
    func handOverLeavesASymlinksTarget() throws {
        let t = Tree()
        let outside = t.root + "/outside"
        defer {
            _ = chflags(outside, 0)
            t.cleanUp()
        }
        let group = try Self.handOverGroup(outside)
        try #require(chmod(outside, 0o664) == 0 && chflags(outside, UInt32(UF_IMMUTABLE)) == 0)
        let before = try Self.status(outside)
        try FileManager.default.createSymbolicLink(atPath: t.tree + "/Contents/planted", withDestinationPath: outside)
        let fd = try #require(FileOps.openDirectory(t.root))
        defer { close(fd) }
        #expect(AdminSwapEngine.handOverTree(at: fd, "tree", owner: getuid(), group: group))
        let after = try Self.status(outside)
        #expect(after.st_uid == before.st_uid && after.st_gid == before.st_gid && after.st_mode == before.st_mode && after.st_flags == before.st_flags)
        #expect(try Self.status(t.tree + "/Contents/planted").st_gid == group, "the link itself is handed over")
        #expect(try Self.status(t.tree + "/Contents/MacOS/k3sm-app").st_gid == group)
    }

    @Test("a hard link in the tree is unlinked: the inode, which may be someone else's, keeps its group, mode and flags")
    func handOverUnlinksAHardLink() throws {
        let t = Tree()
        let outside = t.root + "/outside"
        defer {
            _ = chflags(outside, 0)
            t.cleanUp()
        }
        let group = try Self.handOverGroup(outside)
        try #require(link(outside, t.tree + "/Contents/linked") == 0)
        try #require(chmod(outside, 0o664) == 0 && chflags(outside, UInt32(UF_IMMUTABLE)) == 0)
        let before = try Self.status(outside)
        let fd = try #require(FileOps.openDirectory(t.root))
        defer { close(fd) }
        #expect(AdminSwapEngine.handOverTree(at: fd, "tree", owner: getuid(), group: group))
        var gone = stat()
        #expect(lstat(t.tree + "/Contents/linked", &gone) != 0)
        let after = try Self.status(outside)
        #expect(after.st_gid == before.st_gid && after.st_mode == before.st_mode && after.st_flags == before.st_flags && after.st_nlink == 1)
    }

    @Test("a directory is handed over before it is listed, so an entry added up to that moment is walked too")
    func handOverHandsADirectoryOverBeforeListing() throws {
        let t = Tree()
        defer { t.cleanUp() }
        let group = try Self.handOverGroup(t.tree)
        let fd = try #require(FileOps.openDirectory(t.root))
        defer { close(fd) }
        var seen: [String] = []
        let whole = AdminSwapEngine.handOverTree(at: fd, "tree", owner: getuid(), group: group) { name in
            seen.append(name)
            guard name == "MacOS" else { return }
            let dir = t.tree + "/Contents/MacOS"
            #expect((try? Self.status(dir).st_gid) == group, "the directory was listed before it was handed over")
            FileManager.default.createFile(atPath: dir + "/late", contents: Data("late".utf8))
        }
        #expect(whole && seen == ["tree", "Contents", "MacOS"])
        #expect(try Self.status(t.tree + "/Contents/MacOS/late").st_gid == group)
    }

    @Test("an entry that cannot be handed over fails the walk, which still reaches the rest")
    func handOverGoesOnAfterAFailure() throws {
        let t = Tree()
        defer { t.cleanUp() }
        let group = try Self.handOverGroup(t.tree)
        FileManager.default.createFile(atPath: t.tree + "/Contents/MacOS/unreadable", contents: Data("x".utf8))
        FileManager.default.createFile(atPath: t.tree + "/Contents/MacOS/other", contents: Data("x".utf8))
        try #require(chmod(t.tree + "/Contents/MacOS/unreadable", 0o000) == 0)
        let fd = try #require(FileOps.openDirectory(t.root))
        defer { close(fd) }
        #expect(!AdminSwapEngine.handOverTree(at: fd, "tree", owner: getuid(), group: group))
        #expect(try Self.status(t.tree + "/Contents/MacOS/other").st_gid == group)
        #expect(try Self.status(t.tree + "/Contents/MacOS/k3sm-app").st_gid == group)
    }

    @Test("hand-over order: setuid and setgid go before the chown, the ACL before the mode")
    func handOverOrder() throws {
        let t = Tree()
        defer { t.cleanUp() }
        let group = try Self.handOverGroup(t.tree)
        let fd = try #require(FileOps.openDirectory(t.root))
        defer { close(fd) }
        var steps: [String] = []
        #expect(AdminSwapEngine.handOverTree(at: fd, "tree", owner: getuid(), group: group, trace: { steps.append($0) }))
        let first = Array(steps.prefix(6))
        #expect(first == ["flags", "setid", "chown", "flags", "acl", "mode"], "\(steps)")
    }

    @Test("a flagged special file is unlinked unopened: nothing blocks on it and its flag does not stop the walk")
    func handOverUnlinksAFlaggedSpecialFile() throws {
        let t = Tree()
        let fifo = t.tree + "/Contents/pipe"
        defer {
            _ = chflags(fifo, 0)
            t.cleanUp()
        }
        let group = try Self.handOverGroup(t.tree)
        try #require(mkfifo(fifo, 0o600) == 0 && chflags(fifo, UInt32(UF_IMMUTABLE)) == 0)
        let fd = try #require(FileOps.openDirectory(t.root))
        defer { close(fd) }
        #expect(AdminSwapEngine.handOverTree(at: fd, "tree", owner: getuid(), group: group))
        var gone = stat()
        #expect(lstat(fifo, &gone) != 0)
    }

    @Test("a hard-linked symlink is unlinked: the shared inode keeps its group and flags, and its other name stays")
    func handOverUnlinksAHardLinkedSymlink() throws {
        let t = Tree()
        let other = t.root + "/other-link"
        defer {
            _ = lchflags(other, 0)
            t.cleanUp()
        }
        let group = try Self.handOverGroup(t.tree)
        try FileManager.default.createSymbolicLink(atPath: other, withDestinationPath: t.root + "/outside")
        try #require(linkat(AT_FDCWD, other, AT_FDCWD, t.tree + "/Contents/shared", 0) == 0)
        let before = try Self.status(other)
        try #require(before.st_nlink == 2 && before.st_mode & S_IFMT == S_IFLNK)
        let fd = try #require(FileOps.openDirectory(t.root))
        defer { close(fd) }
        #expect(AdminSwapEngine.handOverTree(at: fd, "tree", owner: getuid(), group: group))
        var gone = stat()
        #expect(lstat(t.tree + "/Contents/shared", &gone) != 0)
        let after = try Self.status(other)
        #expect(after.st_gid == before.st_gid && after.st_nlink == 1)
    }

    @Test("the helper's descriptor limit is exactly the wanted one, rising to it or falling to it, within the hard limit")
    func descriptorLimit() {
        let wanted = AdminSwapEngine.wantedDescriptorLimit
        #expect(wanted == 2048)
        #expect(AdminSwapEngine.descriptorLimit(rlimit(rlim_cur: 256, rlim_max: rlim_t.max)) == wanted)
        #expect(AdminSwapEngine.descriptorLimit(rlimit(rlim_cur: 256, rlim_max: 1024)) == 1024)
        #expect(AdminSwapEngine.descriptorLimit(rlimit(rlim_cur: 10240, rlim_max: rlim_t.max)) == wanted)
        #expect(AdminSwapEngine.descriptorLimit(rlimit(rlim_cur: 10240, rlim_max: 20480)) == wanted)
    }

    /// A chain of `depth` directories below `top`, made with one descriptor
    /// at a time: too long a path for anything else.
    static func makeChain(top: Int32, name: String, depth: Int) -> Bool {
        guard mkdirat(top, name, 0o755) == 0, var fd = FileOps.openDirectory(at: top, name) else { return false }
        for _ in 0..<depth {
            guard mkdirat(fd, "d", 0o755) == 0, let next = FileOps.openDirectory(at: fd, "d") else {
                close(fd)
                return false
            }
            close(fd)
            fd = next
        }
        close(fd)
        return true
    }

    @Test("a tree as deep as the helper's descriptor limit is walked and removed within the main thread's 8 MiB stack")
    func deepTreeFitsTheStack() throws {
        // Raising only, and past the helper's limit, so the other tests in this
        // process keep what they had.
        var limit = rlimit()
        try #require(getrlimit(RLIMIT_NOFILE, &limit) == 0)
        limit.rlim_cur = max(limit.rlim_cur, min(limit.rlim_max, 8192))
        try #require(setrlimit(RLIMIT_NOFILE, &limit) == 0 && limit.rlim_cur >= 8192)
        let t = Tree()
        defer { t.cleanUp() }
        let group = try Self.handOverGroup(t.tree)
        let fd = try #require(FileOps.openDirectory(t.root))
        defer { close(fd) }
        let depth = Int(AdminSwapEngine.wantedDescriptorLimit)
        try #require(Self.makeChain(top: fd, name: "deep", depth: depth))
        let results = Results()
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            results.handed = AdminSwapEngine.handOverTree(at: fd, "deep", owner: getuid(), group: group)
            results.safe = AdminSwapEngine.isSafeTree(at: fd, "deep")
            AdminSwapEngine.clearUserLockingFlags(at: fd, "deep")
            results.removed = AdminSwapEngine.removeOnVolume(at: fd, "deep")
            done.signal()
        }
        thread.stackSize = 8 * 1024 * 1024
        thread.start()
        done.wait()
        #expect(results.handed && results.safe && results.removed)
    }

    final class Results: @unchecked Sendable {
        var handed = false
        var safe = false
        var removed = false
    }

    @Test("the refused flags are uchg, uappnd, uunlnk, schg, sappnd and sunlnk, and no other")
    func flagSet() {
        #expect(AdminSwapEngine.userLockingFlags == 0x0000_0016)
        #expect(AdminSwapEngine.systemLockingFlags == 0x0016_0000)
        #expect(AdminSwapEngine.userLockingFlags & UInt32(UF_COMPRESSED | UF_HIDDEN | UF_NODUMP) == 0)
    }
}
