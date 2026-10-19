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

/// SwapMode is what a request asks the helper to do.
public enum SwapMode: String, Codable, Sendable {
    /// Replace the installed bundle with the staged one.
    case update
    /// Put the kept previous copy back in place of the installed bundle.
    case goBack
}

/// ProcessStart is a process's start time, which, with its pid, names one
/// process: a pid alone may be reused once the process exits.
public struct ProcessStart: Codable, Hashable, Sendable {
    public let seconds: UInt64
    public let microseconds: UInt64

    public init(seconds: UInt64, microseconds: UInt64) {
        self.seconds = seconds
        self.microseconds = microseconds
    }
}

/// ProcessIdentity is a pid and the start time of the process that held it.
public struct ProcessIdentity: Codable, Hashable, Sendable {
    public let pid: Int32
    public let start: ProcessStart

    public init(pid: Int32, start: ProcessStart) {
        self.pid = pid
        self.start = start
    }

    /// The identity of a live process, from `proc_pidinfo`
    /// (`PROC_PIDTBSDINFO`), or nil when no process holds `pid` or it has
    /// exited and waits only to be reaped.
    public static func of(pid: Int32) -> ProcessIdentity? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_status != UInt32(SZOMB)
        else { return nil }
        return ProcessIdentity(pid: pid, start: ProcessStart(seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec))
    }

    /// This process.
    public static func current() -> ProcessIdentity? {
        of(pid: getpid())
    }

    /// Whether the process this identity names is still running: the pid is
    /// held by a process with the same start time.
    public var isRunning: Bool {
        Self.of(pid: pid) == self
    }
}

/// SwapRequest is what the app asks for. It is untrusted input to the
/// helper: every path is checked against `SwapPaths`, the incoming tag is
/// compared with the bundle's own sealed tag, and the floor is read from the
/// installed bundle, never from here.
public struct SwapRequest: Codable, Equatable, Sendable {
    public var mode: SwapMode
    /// The bundle to replace: one of `SwapPaths.allowedTargets`.
    public var target: String
    /// The staging directory's name in the target's directory (update only).
    public var stagedName: String
    /// The tag the incoming bundle carries (`K3smPayloadTag`).
    public var expectedTag: String
    /// The handshake token: 32 random bytes as hex.
    public var token: String
    /// The app that asked; the helper waits for it to exit.
    public var app: ProcessIdentity
    /// For a go-back that undoes a failed update: the failed tag, passed to
    /// the relaunched app as `--update-failed`.
    public var failedTag: String?

    public init(mode: SwapMode, target: String, stagedName: String, expectedTag: String, token: String,
                app: ProcessIdentity, failedTag: String? = nil) {
        self.mode = mode
        self.target = target
        self.stagedName = stagedName
        self.expectedTag = expectedTag
        self.token = token
        self.app = app
        self.failedTag = failedTag
    }

    /// A new handshake token.
    public static func newToken() -> String {
        FileOps.randomHex(bytes: 32)
    }
}

/// JournalState is how far a swap got. Each state is written, with fsync,
/// before the step it names, so a state names an act that may or may not
/// have happened; whoever reads it decides from the identity at the target.
public enum JournalState: String, Codable, Sendable, CaseIterable {
    /// The app wrote the request.
    case staged
    /// The helper verified the incoming bundle and recorded both identities.
    case verified
    /// The helper is about to swap (or has swapped) the bundles.
    case swapped
    /// The helper is about to launch (or has launched) the target.
    case launched
    /// The new bundle answered the handshake; the swap stands.
    case committed
    /// The swap was undone, or never happened.
    case rolledBack

    /// Whether nothing is left to do for this journal.
    public var isTerminal: Bool { self == .committed || self == .rolledBack }
}

/// SwapJournal is the request file: the app's request and the helper's
/// progress through it. Written 0600 into the private 0700 directory.
public struct SwapJournal: Codable, Equatable, Sendable {
    /// The format version this build reads and writes.
    public static let currentSchema = 1

    public var schema: Int
    public var request: SwapRequest
    public var state: JournalState
    /// When the state was written.
    public var at: Date
    /// The helper running the request.
    public var helper: ProcessIdentity?
    /// The identity of the bundle at the target before the swap.
    public var original: FileIdentity?
    /// The identity of the incoming bundle.
    public var incoming: FileIdentity?
    /// The tag of the bundle at the target before the swap.
    public var outgoingTag: String?
    /// Where the outgoing bundle is kept: `k3sm-<outgoingTag>.previous` in
    /// the previous root.
    public var previousName: String?
    /// The launched process, once there is one.
    public var launched: ProcessIdentity?

    public init(request: SwapRequest, state: JournalState = .staged, at: Date = Date()) {
        schema = Self.currentSchema
        self.request = request
        self.state = state
        self.at = at
    }
}

/// JournalStore reads and writes the journal in the private directory, and
/// holds its lock. A held lock means a live helper.
public struct JournalStore: Sendable {
    /// The largest request file read.
    public static let sizeLimit = 64 * 1024

    public let paths: SwapPaths

    public init(paths: SwapPaths) {
        self.paths = paths
    }

    /// JournalError is why the private directory or the request file was
    /// refused.
    public enum JournalError: Error, Equatable {
        /// The private directory is missing, a symlink, not owned by this
        /// account or not mode 0700.
        case directory
        /// The request file is missing, a symlink, not a regular file, not
        /// owned by this account, not mode 0600 or too large.
        case file
        /// The request file does not decode, or names another schema.
        case format
        /// The write did not complete.
        case write
    }

    /// Creates the support, private and previous directories when missing
    /// (0700, owned by this account) and checks the private one.
    public func prepare() throws(JournalError) {
        for dir in [paths.supportDirectory, paths.privateDirectory, paths.previousDirectory] {
            if mkdir(dir, 0o700) != 0 && errno != EEXIST { throw .directory }
        }
        guard privateDirectoryIsSafe() else { throw .directory }
        guard Self.ownedPrivateDirectory(paths.previousDirectory) else { throw .directory }
    }

    /// Whether the private directory is a real directory owned by this
    /// account with mode 0700.
    public func privateDirectoryIsSafe() -> Bool {
        Self.ownedPrivateDirectory(paths.privateDirectory)
    }

    static func ownedPrivateDirectory(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR && st.st_uid == getuid()
            && st.st_mode & 0o777 == 0o700
    }

    /// Reads the journal: the directory and the file are checked first
    /// (owner, mode, no symlink, size), then it is decoded.
    public func read() throws(JournalError) -> SwapJournal {
        guard privateDirectoryIsSafe() else { throw .directory }
        guard let data = FileOps.read(paths.requestPath, check: .init(owner: getuid(), mode: 0o600, limit: Self.sizeLimit)) else {
            throw .file
        }
        guard let journal = try? Self.decoder.decode(SwapJournal.self, from: data),
              journal.schema == SwapJournal.currentSchema
        else { throw .format }
        return journal
    }

    /// Whether a request file exists at all.
    public var exists: Bool {
        var st = stat()
        return lstat(paths.requestPath, &st) == 0
    }

    /// Writes the journal durably (temporary file, fsync, rename, fsync of
    /// the directory), stamping `at`.
    public func write(_ journal: SwapJournal) throws(JournalError) {
        guard privateDirectoryIsSafe(), let dirFD = FileOps.openDirectory(paths.privateDirectory) else { throw .directory }
        defer { close(dirFD) }
        var stamped = journal
        stamped.at = Date()
        guard let data = try? Self.encoder.encode(stamped),
              FileOps.replaceDurably(dirFD: dirFD, name: SwapPaths.requestName, data: data, mode: 0o600)
        else { throw .write }
    }

    /// Takes the lock without waiting, or returns nil when another process
    /// holds it.
    public func lock() -> JournalLock? {
        guard privateDirectoryIsSafe() else { return nil }
        let fd = open(paths.lockPath, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        return JournalLock(fd: fd)
    }

    /// Whether another process holds the lock (a live helper).
    public func isLockHeld() -> Bool {
        guard privateDirectoryIsSafe() else { return false }
        let fd = open(paths.lockPath, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

/// JournalLock is the held `flock` on the private directory's lock file;
/// it is released when the process exits or `release()` runs.
public final class JournalLock: @unchecked Sendable {
    private var fd: Int32

    init(fd: Int32) {
        self.fd = fd
    }

    /// Releases the lock.
    public func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    deinit { release() }
}
