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
import Synchronization

/// Runs an executable by absolute path and returns its exit status.
@discardableResult
private func run(_ path: String, _ arguments: [String]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return -1 }
    process.waitUntilExit()
    return process.terminationStatus
}

private func realPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}

/// AdminFixtureStore signs each distinct fixture once per test process and hands
/// every test a copy, so the system's code-signing services see one signature
/// per shape instead of one per test. It is the only place in this target
/// that signs.
///
/// Nothing it or a scratch world makes is removed while a test process runs,
/// nor at its exit: a bundle removed while the system still scans it is the
/// suspected fault. Trees are left under the temporary directory and a later
/// run sweeps the ones older than `sweepAge` (`AdminFixtureTrees.sweepOnce`).
///
/// A copy of the swap tests' `FixtureStore`: sharing one would need a
/// test-support target in `Package.swift`.
enum AdminFixtureStore {
    /// One directory per test process, under the swept prefix.
    static let directory: String = {
        AdminFixtureTrees.sweepOnce()
        let dir = realPath(NSTemporaryDirectory()) + "/" + AdminFixtureTrees.prefix + "store-" + String(getpid())
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static let signed = Mutex<[String: String]>([:])

    /// The pre-signed item for `key`, built by `build` into the path it is
    /// given and signed the first time `key` is asked for. Every item of the
    /// same key has the same content, so it is signed once.
    static func signedItem(key: String, name: String, build: (String) -> Void) -> String {
        signed.withLock { cache in
            if let path = cache[key] { return path }
            let dir = directory + "/" + String(cache.count)
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let path = dir + "/" + name
            build(path)
            sign(path)
            cache[key] = path
            return path
        }
    }

    /// Copies the pre-signed item for `key` to `path`. The copy keeps the
    /// signature (the bundle's own directory name is not sealed); a bundle
    /// edited after this no longer satisfies it.
    static func place(key: String, name: String, at path: String, build: (String) -> Void) {
        let source = signedItem(key: key, name: name, build: build)
        let fm = FileManager.default
        try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        precondition(!fm.fileExists(atPath: path), "a fixture is placed only where nothing is: \(path)")
        do {
            try fm.copyItem(atPath: source, toPath: path)
        } catch {
            preconditionFailure("could not copy the signed fixture to \(path): \(error)")
        }
    }

    /// The one ad-hoc signing call: the identifier is what `fixtureRequirement`
    /// names, so no certificate is needed.
    private static func sign(_ path: String) {
        let status = run("/usr/bin/codesign", ["--force", "--sign", "-", "--timestamp=none", "--identifier", "io.k3sm.test.fixture", path])
        precondition(status == 0, "codesign could not sign the fixture at \(path)")
    }
}

/// AdminFixtureTrees owns where this target's fixture trees live and the one
/// sweep that removes old ones.
enum AdminFixtureTrees {
    /// Every tree this target makes under the temporary directory starts so.
    static let prefix = "k3sm-adminswap-"
    /// A tree is swept only once it is older than this, long after any scan
    /// of it has finished and any process that made it has gone.
    static let sweepAge: TimeInterval = 3600

    /// Sweeps once per process, before the first tree is made.
    static func sweepOnce() { _ = swept }

    private static let swept: Bool = {
        let tmp = realPath(NSTemporaryDirectory())
        let fm = FileManager.default
        let now = Date()
        for name in (try? fm.contentsOfDirectory(atPath: tmp)) ?? [] where name.hasPrefix(prefix) {
            let path = tmp + "/" + name
            // A scratch volume's directory is its own to remove, after detach.
            if name.hasPrefix(prefix + "vol-") { continue }
            if let suffix = name.split(separator: "-").last, let pid = Int32(suffix), pid == getpid() || kill(pid, 0) == 0 {
                continue
            }
            guard let modified = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
                  now.timeIntervalSince(modified) > sweepAge else { continue }
            // Never across a mount point: a volume a killed run left attached
            // is not this sweep's to empty.
            run("/usr/bin/find", [path, "-xdev", "-exec", "/usr/bin/chflags", "nouchg", "{}", "+"])
            run("/usr/bin/find", [path, "-xdev", "-type", "d", "-exec", "/bin/chmod", "u+rwx", "{}", "+"])
            run("/bin/rm", ["-rfx", path])
        }
        return true
    }()
}
