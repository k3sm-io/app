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
    /// Why the swap ended where it did, written with the state when the
    /// helper stops short of a commit: the relaunched app reads this (the
    /// helper's exit status reaches nobody), and the administrator path
    /// takes over a `verified` journal whose reason is `needsAdministrator`.
    public var reason: SwapExit?
    /// The previous-copy record in force before this swap wrote its own, so
    /// an undone swap (the helper's rollback, or the reconciler after a
    /// crash between the record and the swap) puts it back.
    public var priorRecord: PreviousRecord?

    public init(request: SwapRequest, state: JournalState = .staged, at: Date = Date()) {
        schema = Self.currentSchema
        self.request = request
        self.state = state
        self.at = at
    }

    /// Whether every name and tag the journal carries has its grammar: the
    /// tags are release tags, the previous name is `k3sm-<tag>.previous`,
    /// the staging name is a staging name (or empty for a go-back). The
    /// journal is written by this account and so by anything running as it;
    /// nothing in it is used before this holds.
    public var namesAreValid: Bool {
        guard SwapTag.isReleaseTag(request.expectedTag),
              request.failedTag.map(SwapTag.isReleaseTag) ?? true,
              outgoingTag.map(SwapTag.isReleaseTag) ?? true,
              previousName.map({ SwapPaths.tag(ofPreviousName: $0) != nil }) ?? true
        else { return false }
        switch request.mode {
        case .update: return SwapPaths.isStagingName(request.stagedName)
        case .goBack: return request.stagedName.isEmpty
        }
    }
}

/// PreviousRecord is the engine's own record of the previous copy it keeps:
/// its name, its tag and its main executable's cdhash, and the tag and
/// cdhash of the bundle that replaced it. The engine writes it right before
/// a swap and removes it when the swap is undone. A go-back restores only
/// the copy this record names, only while the installed bundle is the one
/// it names, and only with both cdhashes and tags checked again on the
/// bundles themselves.
///
/// `floorTag` is the monotonic floor: the highest tag this engine has kept
/// as a previous copy. Each swap writes max(the old floor, the outgoing
/// tag) and nothing lowers it (an undone swap puts back the older record,
/// whose floor is the one in force before it). A go-back refuses a target
/// below the floor, and refuses a record whose floor sits below the tag the
/// record itself names, which is what a floor lowered after the fact looks
/// like.
///
/// The record lives in the private directory, and it stays writable by a
/// process running as this account. The floor therefore stops a stray or
/// partial rewrite, and a rewrite that changes only the target or only the
/// floor; it does not stop a process that rewrites both consistently to an
/// older Developer ID signed release of this team, which an administrator
/// account's process can also copy into /Applications directly. Two
/// follow-ups close that: a root-owned record on the standard-user root
/// path, and a minimum-supported tag carried in the signed release
/// index, so a forged record cannot lower the floor.
public struct PreviousRecord: Codable, Equatable, Sendable {
    public var name: String
    public var tag: String
    /// The previous copy's cdhash, lowercase hex.
    public var cdhash: String
    public var installedTag: String
    public var installedCDHash: String
    /// The monotonic floor tag (see above).
    public var floorTag: String

    public init(name: String, tag: String, cdhash: Data, installedTag: String, installedCDHash: Data, floorTag: String) {
        self.floorTag = floorTag
        self.name = name
        self.tag = tag
        self.cdhash = FileOps.hex(cdhash)
        self.installedTag = installedTag
        self.installedCDHash = FileOps.hex(installedCDHash)
    }

    /// Whether the names, tags and hashes have their grammar.
    public var isValid: Bool {
        SwapPaths.tag(ofPreviousName: name) == tag && SwapTag.isReleaseTag(installedTag) && SwapTag.isReleaseTag(floorTag)
            && Self.isHash(cdhash) && Self.isHash(installedCDHash)
    }

    static func isHash(_ s: String) -> Bool {
        (40...64).contains(s.utf8.count) && s.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
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

    /// Reads the previous record, checked like the journal; nil when there
    /// is none or it fails a check or its grammar.
    public func readRecord() -> PreviousRecord? {
        guard privateDirectoryIsSafe(),
              let data = FileOps.read(paths.previousRecordPath, check: .init(owner: getuid(), mode: 0o600, limit: 4096)),
              let record = try? Self.decoder.decode(PreviousRecord.self, from: data), record.isValid
        else { return nil }
        return record
    }

    /// Writes the previous record durably, or removes it for nil.
    @discardableResult
    public func writeRecord(_ record: PreviousRecord?) -> Bool {
        guard privateDirectoryIsSafe(), let dirFD = FileOps.openDirectory(paths.privateDirectory) else { return false }
        defer { close(dirFD) }
        guard let record else {
            let ok = unlinkat(dirFD, SwapPaths.previousRecordName, 0) == 0 || errno == ENOENT
            FileOps.fullSync(dirFD)
            return ok
        }
        guard let data = try? Self.encoder.encode(record) else { return false }
        return FileOps.replaceDurably(dirFD: dirFD, name: SwapPaths.previousRecordName, data: data, mode: 0o600)
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
