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

/// A directory that cannot be listed is never read as an empty one.
///
/// The descriptor limit is process-wide and swift-testing runs other suites in
/// parallel, where `.serialized` does not reach, so lowering it here would make
/// them fail with EMFILE. `atTheDescriptorLimit` therefore starts this test
/// binary again in a child process with only `lowLimitChild` selected: the limit
/// is lowered in that process alone, and the parent's is never changed. The
/// child writes what it saw to a file and the parent asserts on it, so a child
/// that did not run is a failure and not a pass. The other tests here need no
/// limit: they make the listing fail with a descriptor that cannot be read.
@Suite struct AppSwapListingFailureTests {
    typealias Fixture = AppSwapRootTreeTests

    static let resultsVariable = "K3SM_TEST_LISTING_RESULTS"
    static var isChild: Bool { getenv(resultsVariable) != nil }

    /// Levels above the soft limit used, ending in what a walk has to find.
    static let depth = 200
    static let softLimit: rlim_t = 64

    /// What the child must report. `deep.*` walks a chain deeper than the limit
    /// allows, with the entry that matters at the bottom. `shallow.*` is the same
    /// walk at the same limit over a tree it can reach, so the limit alone is
    /// not what fails. `last.*` has one descriptor free over an empty directory,
    /// where only the listing's `dup` can fail: removed as if empty, it would go.
    static let expected: [String: String] = [
        "deep.isSafeTree": "false",
        "deep.isPrivateTree": "false",
        "deep.isFree": "false",
        "deep.handOverTree": "false",
        "deep.chownTree": "false",
        "deep.clearUserLockingFlags": "false",
        "deep.removeOnVolume": "false",
        "deep.removeTree": "false",
        "deep.settleOldBundle": "leftInWorkDirectory",
        "deep.bottomUnchanged": "true",
        "shallow.isSafeTree": "true",
        "shallow.isPrivateTree": "true",
        "shallow.isFree": "true",
        "shallow.handOverTree": "true",
        "shallow.chownTree": "true",
        "shallow.clearUserLockingFlags": "true",
        "shallow.removeOnVolume": "true",
        "shallow.removeTree": "true",
        "last.entries": "nil",
        "last.removeOnVolume": "false",
        "last.removeOnVolumeLeftIt": "true",
        "last.removeTree": "false",
        "last.removeTreeLeftIt": "true",
    ]

    @Test("past the descriptor limit every walk fails closed, and an unlistable directory is not removed")
    func atTheDescriptorLimit() throws {
        let t = Fixture.Tree()
        defer { t.cleanUp() }
        let arguments = ProcessInfo.processInfo.arguments
        let bundleFlag = try #require(arguments.firstIndex(of: "--test-bundle-path"), "not started by swift test")
        let bundle = arguments[bundleFlag + 1]
        var childArguments = ["--test-bundle-path", bundle]
        if arguments.contains("--disable-sandbox") { childArguments.append("--disable-sandbox") }
        childArguments += ["--filter", "AppSwapListingFailureTests/lowLimitChild", bundle, "--testing-library", "swift-testing"]

        let results = t.root + "/results.json"
        let log = t.root + "/child.log"
        #expect(FileManager.default.createFile(atPath: log, contents: nil))
        let output = try #require(FileHandle(forWritingAtPath: log))
        defer { try? output.close() }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: arguments[0])
        child.arguments = childArguments
        child.environment = ProcessInfo.processInfo.environment.merging([Self.resultsVariable: results]) { $1 }
        child.standardOutput = output
        child.standardError = output
        let done = DispatchSemaphore(value: 0)
        child.terminationHandler = { _ in done.signal() }
        try child.run()
        if done.wait(timeout: .now() + 300) == .timedOut {
            child.terminate()
            Issue.record("the child did not finish in 300 s")
            return
        }

        let childLog = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
        let data = try #require(FileManager.default.contents(atPath: results), "the child wrote no results: \(childLog.suffix(2000))")
        let seen = try JSONDecoder().decode([String: String].self, from: data)
        #expect(Set(seen.keys) == Set(Self.expected.keys))
        for (key, value) in Self.expected.sorted(by: { $0.key < $1.key }) {
            #expect(seen[key] == value, "\(key)")
        }
    }

    /// Runs only in the process `atTheDescriptorLimit` starts.
    @Test("the child of the descriptor limit test", .enabled(if: isChild))
    func lowLimitChild() throws {
        let path = try #require(getenv(Self.resultsVariable).map { String(cString: $0) })
        let t = Fixture.Tree()
        defer { t.cleanUp() }
        let group = try Fixture.handOverGroup(t.tree)
        let top = try #require(FileOps.openDirectory(t.root))
        defer { close(top) }
        let uid = getuid()
        var seen: [String: String] = [:]

        // Each walk gets its own chain; the walks change what they reach.
        var count = 0
        func deep(_ key: String, _ bottom: (Int32) -> Bool, _ walk: (String) -> String) throws {
            count += 1
            let name = "deep\(count)"
            try #require(Fixture.makeChain(top: top, name: name, depth: Self.depth))
            let prepared = Self.atBottom(of: name, in: top, depth: Self.depth, bottom)
            try #require(prepared)
            seen["deep." + key] = try Self.withSoftLimit(Self.softLimit) { walk(name) }
        }
        func shallow(_ key: String, _ walk: (String) -> String) throws {
            count += 1
            let name = "shallow\(count)"
            try #require(Fixture.makeChain(top: top, name: name, depth: 3))
            seen["shallow." + key] = try Self.withSoftLimit(Self.softLimit) { walk(name) }
        }
        let writable: (Int32) -> Bool = { fchmod($0, 0o777) == 0 }
        let noDump: (Int32) -> Bool = { fchflags($0, UInt32(UF_NODUMP)) == 0 }
        let locked: (Int32) -> Bool = { fchflags($0, UInt32(UF_IMMUTABLE)) == 0 }
        let untouched: (Int32) -> Bool = { _ in true }

        try deep("isSafeTree", writable) { "\(AdminSwapEngine.isSafeTree(at: top, $0))" }
        try deep("isPrivateTree", writable) { "\(FileOps.isPrivateTree(at: top, $0))" }
        try deep("isFree", noDump) { "\(AdminSwapEngine.isFree(of: UInt32(UF_NODUMP), at: top, $0))" }
        try deep("chownTree", untouched) { "\(AdminSwapEngine.chownTree(at: top, $0, owner: uid, group: group))" }
        try deep("clearUserLockingFlags", locked) { "\(AdminSwapEngine.clearUserLockingFlags(at: top, $0))" }
        try deep("removeOnVolume", untouched) { "\(AdminSwapEngine.removeOnVolume(at: top, $0))" }
        try deep("removeTree", untouched) { "\(FileOps.removeTree(at: top, $0))" }
        try deep("settleOldBundle", untouched) {
            "\(AdminSwapEngine.settleOldBundle(at: top, $0, owner: uid, group: group))"
        }
        try deep("handOverTree", writable) { "\(AdminSwapEngine.handOverTree(at: top, $0, owner: uid, group: group))" }
        // The hand-over's chain, read back at the normal limit: the bottom is out
        // of the walk's reach, so it is still as the test left it.
        var bottomMode: mode_t = 0
        let readBack = Self.atBottom(of: "deep\(count)", in: top, depth: Self.depth) { fd in
            var st = stat()
            bottomMode = fstat(fd, &st) == 0 ? st.st_mode & 0o777 : 0
            return true
        }
        try #require(readBack)
        seen["deep.bottomUnchanged"] = "\(bottomMode == 0o777)"

        try shallow("isSafeTree") { "\(AdminSwapEngine.isSafeTree(at: top, $0))" }
        try shallow("isPrivateTree") { "\(FileOps.isPrivateTree(at: top, $0))" }
        try shallow("isFree") { "\(AdminSwapEngine.isFree(of: UInt32(UF_NODUMP), at: top, $0))" }
        try shallow("handOverTree") { "\(AdminSwapEngine.handOverTree(at: top, $0, owner: uid, group: group))" }
        try shallow("chownTree") { "\(AdminSwapEngine.chownTree(at: top, $0, owner: uid, group: group))" }
        try shallow("clearUserLockingFlags") { "\(AdminSwapEngine.clearUserLockingFlags(at: top, $0))" }
        try shallow("removeOnVolume") { "\(AdminSwapEngine.removeOnVolume(at: top, $0))" }
        try shallow("removeTree") { "\(FileOps.removeTree(at: top, $0))" }

        for name in ["last-a", "last-b", "last-c"] { try #require(mkdirat(top, name, 0o755) == 0) }
        func exists(_ name: String) -> Bool {
            var st = stat()
            return fstatat(top, name, &st, AT_SYMLINK_NOFOLLOW) == 0
        }
        let probe = open("/dev/null", O_RDONLY | O_CLOEXEC)
        try #require(probe >= 0)
        close(probe)
        // The lowest free number is the last one below this limit.
        let oneFree = rlim_t(probe) + 1
        seen["last.entries"] = try Self.withSoftLimit(oneFree) {
            guard let fd = FileOps.openDirectory(at: top, "last-a") else { return "open failed" }
            defer { close(fd) }
            return FileOps.entries(fd).map { "\($0)" } ?? "nil"
        }
        seen["last.removeOnVolume"] = try Self.withSoftLimit(oneFree) { "\(AdminSwapEngine.removeOnVolume(at: top, "last-b"))" }
        seen["last.removeOnVolumeLeftIt"] = "\(exists("last-b"))"
        seen["last.removeTree"] = try Self.withSoftLimit(oneFree) { "\(FileOps.removeTree(at: top, "last-c"))" }
        seen["last.removeTreeLeftIt"] = "\(exists("last-c"))"

        try JSONEncoder().encode(seen).write(to: URL(fileURLWithPath: path))
    }

    /// Runs `body` with this process's soft descriptor limit at `soft`, and
    /// restores it. Only ever called in the child.
    static func withSoftLimit<T>(_ soft: rlim_t, _ body: () -> T) throws -> T {
        var saved = rlimit()
        try #require(getrlimit(RLIMIT_NOFILE, &saved) == 0)
        var low = saved
        low.rlim_cur = soft
        try #require(setrlimit(RLIMIT_NOFILE, &low) == 0)
        defer { setrlimit(RLIMIT_NOFILE, &saved) }
        return body()
    }

    /// Runs `body` on the deepest directory of a `makeChain` chain.
    static func atBottom(of name: String, in top: Int32, depth: Int, _ body: (Int32) -> Bool) -> Bool {
        guard var fd = FileOps.openDirectory(at: top, name) else { return false }
        defer { close(fd) }
        for _ in 0..<depth {
            guard let next = FileOps.openDirectory(at: fd, "d") else { return false }
            close(fd)
            fd = next
        }
        return body(fd)
    }

    /// A descriptor on `path` that lists nothing: `fdopendir` refuses a directory
    /// opened only for searching.
    static func unlistable(_ path: String) throws -> Int32 {
        let fd = open(path, O_SEARCH | O_DIRECTORY | O_CLOEXEC)
        try #require(fd >= 0)
        return fd
    }

    @Test("an empty directory lists as empty, and a failed dup or fdopendir as nothing at all")
    func entriesTellFailureFromEmpty() throws {
        let t = Fixture.Tree()
        defer { t.cleanUp() }
        try FileManager.default.createDirectory(atPath: t.root + "/empty", withIntermediateDirectories: false)
        let empty = try #require(FileOps.openDirectory(t.root + "/empty"))
        defer { close(empty) }
        #expect(FileOps.entries(empty) == [])
        let contents = try #require(FileOps.openDirectory(t.tree))
        defer { close(contents) }
        #expect(FileOps.entries(contents) == ["Contents"])

        #expect(FileOps.entries(-1) == nil, "dup fails")
        let search = try Self.unlistable(t.tree)
        defer { close(search) }
        #expect(FileOps.entries(search) == nil, "fdopendir refuses a search descriptor")
        let file = open(t.root + "/outside", O_RDONLY | O_CLOEXEC)
        try #require(file >= 0)
        defer { close(file) }
        #expect(FileOps.entries(file) == nil, "fdopendir refuses a file")
    }

    @Test("a readdir that ends in an error is a failed listing, even after some names")
    func readdirError() throws {
        let t = Fixture.Tree()
        defer { t.cleanUp() }
        let dir = try #require(opendir(t.tree))
        defer { closedir(dir) }
        #expect(FileOps.names(of: dir, next: { _ in
            errno = 0
            return nil
        }) == [], "the end of the directory")
        #expect(FileOps.names(of: dir, next: { _ in
            errno = EIO
            return nil
        }) == nil, "an error at once")
        var left = 3
        #expect(FileOps.names(of: dir, next: { dir in
            left -= 1
            if left >= 0, let entry = readdir(dir) { return entry }
            errno = EIO
            return nil
        }) == nil, "an error after names")
    }

    @Test("the previous directory is pruned only when it can be listed")
    func prunePrevious() throws {
        let t = Fixture.Tree()
        defer { t.cleanUp() }
        let name = SwapPaths.previousName(tag: "v0.2.0")
        try #require(SwapPaths.tag(ofPreviousName: name) != nil)
        try FileManager.default.createDirectory(atPath: t.tree + "/" + name, withIntermediateDirectories: false)
        let search = try Self.unlistable(t.tree)
        defer { close(search) }
        #expect(!SwapEngine.prunePrevious(previousFD: search, keep: "other"))
        #expect(FileManager.default.fileExists(atPath: t.tree + "/" + name))
        let fd = try #require(FileOps.openDirectory(t.tree))
        defer { close(fd) }
        #expect(SwapEngine.prunePrevious(previousFD: fd, keep: "other"))
        #expect(!FileManager.default.fileExists(atPath: t.tree + "/" + name))
    }

    @Test("root's previous directory is swept only when it can be listed")
    func sweepPrevious() throws {
        let t = Fixture.Tree()
        defer { t.cleanUp() }
        let search = try Self.unlistable(t.tree)
        defer { close(search) }
        #expect(!AdminSwapEngine.sweepPrevious(search))
        #expect(FileManager.default.fileExists(atPath: t.tree + "/Contents"))
        let fd = try #require(FileOps.openDirectory(t.tree))
        defer { close(fd) }
        #expect(AdminSwapEngine.sweepPrevious(fd))
        #expect(!FileManager.default.fileExists(atPath: t.tree + "/Contents"))
    }

    @Test("what an earlier run left is finished only when the work directory can be listed")
    func settleLeftovers() throws {
        let t = Fixture.Tree()
        defer { t.cleanUp() }
        let group = try Fixture.handOverGroup(t.tree)
        let search = try Self.unlistable(t.tree)
        defer { close(search) }
        #expect(!AdminSwapEngine.settleLeftovers(in: search, owner: getuid(), group: group))
        #expect(FileManager.default.fileExists(atPath: t.tree + "/Contents"))
        let fd = try #require(FileOps.openDirectory(t.tree))
        defer { close(fd) }
        #expect(AdminSwapEngine.settleLeftovers(in: fd, owner: getuid(), group: group))
        #expect(!FileManager.default.fileExists(atPath: t.tree + "/Contents"))
    }
}
