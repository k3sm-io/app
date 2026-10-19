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

/// HelperMode is the one argument the swap helper takes.
public enum HelperMode: String, Sendable, CaseIterable {
    case swap = "--swap"
    case goBack = "--go-back"
    case relaunch = "--relaunch"
}

/// HelperError is why the helper copy could not be installed or run.
public enum HelperError: Error, Equatable, Sendable {
    /// The private directory is missing, a symlink, not this account's or
    /// not mode 0700.
    case directory
    /// The bundled helper is missing or does not satisfy the requirement.
    case source
    /// The copy could not be made, or is a symlink, has another owner, mode
    /// or link count.
    case copy
    /// The copy does not satisfy the requirement, or its cdhash differs from
    /// the bundled helper's.
    case verification
    /// `posix_spawn` failed.
    case spawn
}

/// HelperSpawner puts the swap helper where it can run while the app's
/// bundle is renamed under it, and starts it:
///
/// - `installHelperCopy(from:)` clones (or, across volumes, copies) the
///   bundle's `Contents/Helpers/k3sm-app-update` without following a symlink
///   into the private 0700 directory under a temporary name, sets mode 0500,
///   renames it into place, and verifies it;
/// - `verifyInstalledCopy(bundled:)` checks the directory (this account's,
///   0700, not a symlink) and the copy (a regular file, this account's, mode
///   0500, one link), then that it satisfies the helper requirement and that
///   its cdhash equals the bundled helper's;
/// - `spawn(mode:bundled:)` verifies again and `posix_spawn`s the copy with
///   `POSIX_SPAWN_SETSID`, so it outlives the app, with a fixed environment
///   and its standard streams on `/dev/null`.
///
/// The copy lives in a directory this account owns, so anything running as
/// this account can replace it between a check and an exec. It runs only as
/// this account. A root mode must never exec it, nor any file a user can
/// write: root runs only a copy it made itself into a root-owned directory
/// and verified there.
public struct HelperSpawner: Sendable {
    public let paths: SwapPaths
    /// The helper requirement (`AppUpdateTrust.helperRequirement(teamID:)`).
    public let requirement: String

    public init(paths: SwapPaths, requirement: String) {
        self.paths = paths
        self.requirement = requirement
    }

    public func installHelperCopy(from bundled: String) throws(HelperError) {
        let store = JournalStore(paths: paths)
        guard (try? store.prepare()) != nil, let dirFD = FileOps.openDirectory(paths.privateDirectory) else { throw .directory }
        defer { close(dirFD) }
        guard StaticCodeVerifier.cdhash(path: bundled, requirement: requirement) != nil else { throw .source }
        let source = open(bundled, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard source >= 0 else { throw .source }
        defer { close(source) }
        var st = stat()
        guard fstat(source, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { throw .source }
        // An earlier copy goes first; unlinking never touches its bytes.
        if unlinkat(dirFD, SwapPaths.helperName, 0) != 0 && errno != ENOENT { throw .copy }
        let temp = SwapPaths.helperName + ".tmp-" + FileOps.randomName(length: 12)
        guard fclonefileat(source, dirFD, temp, 0) == 0 || Self.copyBytes(from: source, size: Int(st.st_size), dirFD: dirFD, name: temp)
        else { throw .copy }
        let copyFD = openat(dirFD, temp, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if copyFD >= 0 {
            FileOps.fullSync(copyFD)
            close(copyFD)
        }
        guard fchmodat(dirFD, temp, 0o500, AT_SYMLINK_NOFOLLOW) == 0,
              renameatx_np(dirFD, temp, dirFD, SwapPaths.helperName, UInt32(RENAME_EXCL)) == 0
        else {
            unlinkat(dirFD, temp, 0)
            throw .copy
        }
        FileOps.fullSync(dirFD)
        try verifyInstalledCopy(bundled: bundled)
    }

    /// Copies `size` bytes from `source` into a new file `name` in `dirFD`,
    /// created exclusively: the fallback when a clone is not possible.
    static func copyBytes(from source: Int32, size: Int, dirFD: Int32, name: String) -> Bool {
        let fd = openat(dirFD, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o700)
        guard fd >= 0 else { return false }
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        var offset: off_t = 0
        var ok = true
        while ok, Int(offset) < size {
            let n = pread(source, &buffer, buffer.count, offset)
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { ok = false; break }
            var done = 0
            while done < n {
                let w = buffer.withUnsafeBytes { write(fd, $0.baseAddress! + done, n - done) }
                if w < 0, errno == EINTR { continue }
                guard w > 0 else { ok = false; break }
                done += w
            }
            offset += off_t(n)
        }
        ok = ok && FileOps.fullSync(fd)
        close(fd)
        if !ok { unlinkat(dirFD, name, 0) }
        return ok
    }

    public func verifyInstalledCopy(bundled: String) throws(HelperError) {
        guard JournalStore(paths: paths).privateDirectoryIsSafe() else { throw .directory }
        var st = stat()
        guard lstat(paths.helperCopyPath, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid(),
              st.st_mode & 0o7777 == 0o500, st.st_nlink == 1
        else { throw .copy }
        guard let bundledHash = StaticCodeVerifier.cdhash(path: bundled, requirement: requirement) else { throw .source }
        guard let copyHash = StaticCodeVerifier.cdhash(path: paths.helperCopyPath, requirement: requirement),
              copyHash == bundledHash
        else { throw .verification }
    }

    /// Starts the verified copy with `mode`; returns its pid.
    @discardableResult
    public func spawn(mode: HelperMode, bundled: String) throws(HelperError) -> pid_t {
        try verifyInstalledCopy(bundled: bundled)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for fd: Int32 in [0, 1, 2] {
            posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", fd == 0 ? O_RDONLY : O_WRONLY, 0)
        }
        let path = paths.helperCopyPath
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(path), strdup(mode.rawValue), nil]
        let envp: [UnsafeMutablePointer<CChar>?] = [strdup("PATH=/usr/bin:/bin:/usr/sbin:/sbin"), nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        guard posix_spawn(&pid, path, &actions, &attributes, argv, envp) == 0 else { throw .spawn }
        return pid
    }
}

/// SwapClient is the app's side of starting a swap: it writes the request
/// (state `staged`), installs the helper copy and spawns it. The caller
/// quits right after; the helper waits for that.
public struct SwapClient: Sendable {
    public let paths: SwapPaths
    public let spawner: HelperSpawner
    /// The bundled helper of the running app.
    public let bundledHelper: String

    public init(paths: SwapPaths, helperRequirement: String, bundledHelper: String) {
        self.paths = paths
        spawner = HelperSpawner(paths: paths, requirement: helperRequirement)
        self.bundledHelper = bundledHelper
    }

    /// Why a swap was not started. Each is decided before the app quits.
    public enum StartError: Error, Equatable, Sendable {
        /// A live helper holds the lock.
        case busy
        /// The target cannot be updated in place; the refusal carries the
        /// sentence to show.
        case refused(SwapPaths.TargetRefusal)
        case request
        case helper(HelperError)
    }

    /// Why `target` cannot take a swap, or nil: the path checks and the
    /// volume checks (`RENAME_SWAP` support, the previous root on the same
    /// volume). The app calls this before it offers an update, and
    /// `beginUpdate` calls it again before it writes anything.
    public func refusal(target: String) -> SwapPaths.TargetRefusal? {
        paths.refusal(target: target) ?? paths.volumeRefusal(target: target)
    }

    /// Asks the helper to replace `target` with the bundle staged in
    /// `stagedName`, which carries `expectedTag`.
    public func beginUpdate(target: String, stagedName: String, expectedTag: String) throws(StartError) {
        if let refusal = refusal(target: target) { throw .refused(refusal) }
        guard let app = ProcessIdentity.current() else { throw .request }
        let request = SwapRequest(mode: .update, target: target, stagedName: stagedName, expectedTag: expectedTag,
                                  token: SwapRequest.newToken(), app: app)
        try begin(request, mode: .swap)
    }

    /// Asks the helper to put the kept previous copy back: the one the
    /// engine's previous record names, after the last swap committed.
    public func beginGoBack() throws(StartError) {
        let store = JournalStore(paths: paths)
        guard let journal = try? store.read(), journal.state == .committed, journal.namesAreValid,
              let record = store.readRecord(), let app = ProcessIdentity.current()
        else { throw .request }
        let tag = record.tag
        let request = SwapRequest(mode: .goBack, target: journal.request.target, stagedName: "", expectedTag: tag,
                                  token: SwapRequest.newToken(), app: app)
        try begin(request, mode: .goBack)
    }

    private func begin(_ request: SwapRequest, mode: HelperMode) throws(StartError) {
        let store = JournalStore(paths: paths)
        guard (try? store.prepare()) != nil else { throw .request }
        guard !store.isLockHeld() else { throw .busy }
        guard (try? store.write(SwapJournal(request: request))) != nil else { throw .request }
        do {
            try spawner.installHelperCopy(from: bundledHelper)
            try spawner.spawn(mode: mode, bundled: bundledHelper)
        } catch {
            throw .helper(error)
        }
    }
}
