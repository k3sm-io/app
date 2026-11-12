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
import K3smSwap
import Synchronization

/// A fixture that could not be placed or moved aside; it fails the one test
/// that asked, never the process.
struct FixtureError: Error, CustomStringConvertible {
    let description: String
}

/// FixtureStore signs each distinct fixture once per test process and hands
/// every test a copy, so the system's code-signing services see one signature
/// per content instead of one per test. It is the only place in this target
/// that signs.
///
/// Nothing it or a scratch world makes is removed while a test process runs,
/// nor at its exit: a bundle removed while the system still scans it is the
/// suspected fault. Trees are left under the temporary directory, each named
/// for the process that made it, and a later run sweeps a bounded number of
/// them once that process is gone (`FixtureTrees`).
final class FixtureStore: @unchecked Sendable {
    /// Signs the item at a path; returns the signing tool's exit status.
    typealias Signer = @Sendable (String) -> Int32
    /// Says whether an untampered copy at a path still satisfies the fixtures'
    /// requirement.
    typealias Checker = @Sendable (String) -> Bool

    /// The requirement every fixture satisfies: an ad-hoc signature carries
    /// the identifier, so no certificate is needed.
    static let requirement = "identifier \"io.k3sm.test.fixture\""

    /// The store the tests use: real signing, and the product's own
    /// signature check on the first copy of each item.
    static let shared: FixtureStore = {
        FixtureTrees.sweepOnce()
        return FixtureStore(directory: FixtureTrees.directory(named: "store"), signer: codesign,
                            checker: { StaticCodeVerifier.cdhash(path: $0, requirement: FixtureStore.requirement) != nil })
    }()

    let directory: String
    private let signer: Signer
    private let checker: Checker
    private let state = Mutex<(items: [String: String], checked: Set<String>)>(([:], []))

    init(directory: String, signer: @escaping Signer, checker: @escaping Checker) {
        self.directory = directory
        self.signer = signer
        self.checker = checker
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    /// The pre-signed item for `key`, built by `build` into the path it is
    /// given and signed the first time `key` is asked for. Every item of the
    /// same key has the same content, so it is signed once. A signing failure
    /// stops the process: every test after it would fail the same way.
    func signedItem(key: String, name: String, build: (String) -> Void) -> String {
        state.withLock { state in
            if let path = state.items[key] { return path }
            let dir = directory + "/" + String(state.items.count)
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let path = dir + "/" + name
            build(path)
            let status = signer(path)
            precondition(status == 0, "fixture signing failed: the test fixture store's codesign exited \(status) for \(path)")
            state.items[key] = path
            return path
        }
    }

    /// Copies the pre-signed item for `key` to `path`, where nothing may be
    /// yet. The copy keeps the signature (a bundle's own directory name is not
    /// sealed); the first copy of each key and every copy on another volume
    /// are checked, so a refusal test can never pass on a signature the copy
    /// lost.
    func place(key: String, name: String, at path: String, build: (String) -> Void) throws(FixtureError) {
        let source = signedItem(key: key, name: name, build: build)
        let fm = FileManager.default
        try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        var st = stat()
        guard lstat(path, &st) != 0 else { throw FixtureError(description: "a fixture is placed only where nothing is: \(path)") }
        do {
            try fm.copyItem(atPath: source, toPath: path)
        } catch {
            // A partial copy this call just made, never verified in place:
            // nothing half-made stays where a test would look.
            try? fm.removeItem(atPath: path)
            throw FixtureError(description: "could not copy the signed fixture to \(path): \(error)")
        }
        // The first copy of each key, and every copy on another volume than
        // the store, is checked in process with the product's own check.
        var here = stat(), there = stat()
        let otherVolume = stat(source, &here) != 0 || stat(path, &there) != 0 || here.st_dev != there.st_dev
        let first = state.withLock { $0.checked.insert(key).inserted }
        if first || otherVolume, !checker(path) {
            if first { state.withLock { _ = $0.checked.remove(key) } }
            throw FixtureError(description: "the untampered copy at \(path) does not satisfy the fixture requirement")
        }
    }

    /// Moves the item at `path` aside, into `root` or, across volumes, to the
    /// top of the item's own volume, instead of removing it while the system
    /// may still be scanning it.
    static func retire(_ path: String, root: String) throws(FixtureError) {
        let name = "retired-" + UUID().uuidString.prefix(8)
        if rename(path, root + "/" + name) == 0 { return }
        var failure = errno
        if failure == EXDEV {
            var fs = statfs()
            if statfs((path as NSString).deletingLastPathComponent, &fs) == 0 {
                let mount = withUnsafeBytes(of: fs.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                if rename(path, (mount == "/" ? "" : mount) + "/" + FixtureTrees.prefix + name) == 0 { return }
                failure = errno
            }
        }
        throw FixtureError(description: "could not move \(path) aside: errno \(failure)")
    }

    /// The one ad-hoc signing call: the identifier is what `requirement`
    /// names.
    private static let codesign: Signer = { path in
        run("/usr/bin/codesign", ["--force", "--sign", "-", "--timestamp=none", "--identifier", "io.k3sm.test.fixture", path])
    }
}

/// FixtureTrees owns where this target's fixture trees live and the one
/// sweep that removes old ones.
enum FixtureTrees {
    /// Every tree this target makes under the temporary directory starts so,
    /// and ends with its maker's `ownerSuffix`.
    static let prefix = "k3sm-swap-"
    /// Trees the sweep never touches: scratch volumes' directories.
    static let exempt = ["k3sm-swap-volumes-"]
    /// A tree is swept only once its maker is gone and it is older than this.
    static let sweepAge: TimeInterval = 3600
    /// At most this many trees go per run, oldest first.
    static let sweepLimit = 20

    /// Names the process that made a tree; a digit run alone never does.
    static var ownerSuffix: String { "-p" + String(getpid()) }

    /// A fresh tree path for this process, `kind` naming what it holds.
    static func directory(named kind: String) -> String {
        realPath(NSTemporaryDirectory()) + "/" + prefix + kind + ownerSuffix
    }

    /// Sweeps once per process, before the first tree is made.
    static func sweepOnce() { _ = swept }

    private static let swept: Bool = {
        sweep(in: realPath(NSTemporaryDirectory()), prefix: prefix, exempt: exempt, age: sweepAge, limit: sweepLimit)
        return true
    }()

    /// Removes up to `limit` trees named `prefix…-p<pid>`, oldest first, each
    /// a real directory this user owns, whose process is gone, older than
    /// `age`. It follows no link and crosses no mount point.
    static func sweep(in tmp: String, prefix: String, exempt: [String], age: TimeInterval, limit: Int) {
        let fm = FileManager.default
        let now = Date()
        var old: [(path: String, modified: Date)] = []
        for name in (try? fm.contentsOfDirectory(atPath: tmp)) ?? [] where name.hasPrefix(prefix) {
            if exempt.contains(where: name.hasPrefix) { continue }
            guard let marker = name.range(of: "-p", options: .backwards),
                  let pid = Int32(name[marker.upperBound...]), pid > 0 else { continue }
            // Alive, or alive as another user: never swept, whatever its age.
            if pid == getpid() || kill(pid, 0) == 0 || errno == EPERM { continue }
            let path = tmp + "/" + name
            var st = stat()
            guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR, st.st_uid == geteuid() else { continue }
            let modified = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
            if now.timeIntervalSince(modified) > age { old.append((path, modified)) }
        }
        for (path, _) in old.sorted(by: { $0.modified < $1.modified }).prefix(limit) {
            run("/usr/bin/find", [path, "-xdev", "(", "-type", "d", "-o", "-type", "f", ")",
                                  "-exec", "/usr/bin/chflags", "-h", "nouchg", "{}", "+"])
            run("/usr/bin/find", [path, "-xdev", "-type", "d", "-exec", "/bin/chmod", "u+rwx", "{}", "+"])
            run("/bin/rm", ["-rfx", path])
        }
    }
}
