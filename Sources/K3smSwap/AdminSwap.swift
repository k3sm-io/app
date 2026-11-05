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
import K3smInstall
import K3smStatus

/// AdminSwapLocations is where the administrator path works. The helper
/// uses `standard` only, every value a compiled constant (`AppSwapRoot`);
/// tests build one over a scratch directory with their own uid as `owner`.
public struct AdminSwapLocations: Equatable, Sendable {
    /// The one target.
    public let target: String
    /// The root-owned 0700 directory staged bundles are copied into.
    public let workRoot: String
    /// The root-owned 0700 directory the replaced bundle moves to.
    public let previousRoot: String
    /// Root's record of the highest release it has installed
    /// (`AppSwapRoot.floorRecord`): owned by `owner`, mode 0600.
    public let floorRecord: String
    /// The owner the work and previous directories, and every copy before it
    /// takes the target's owner, must have: root.
    public let owner: uid_t
    public let group: gid_t

    public init(target: String, workRoot: String, previousRoot: String, floorRecord: String, owner: uid_t, group: gid_t) {
        self.target = target
        self.workRoot = workRoot
        self.previousRoot = previousRoot
        self.floorRecord = floorRecord
        self.owner = owner
        self.group = group
    }

    /// The shipped locations.
    public static let standard = AdminSwapLocations(target: AppSwapRoot.target, workRoot: AppSwapRoot.workRoot,
                                                    previousRoot: AppSwapRoot.previousRoot,
                                                    floorRecord: AppSwapRoot.floorRecord, owner: 0, group: 0)
}

/// TreeInspector reads one entry of a tree without following a symlink. The
/// engine checks the target's tree through it; tests inject one that reports
/// another owner, since a test cannot chown a file to root.
public protocol TreeInspector: Sendable {
    /// `fstatat(dirFD, name, AT_SYMLINK_NOFOLLOW)`, or nil when it fails.
    func status(at dirFD: Int32, _ name: String) -> stat?
    /// Whether the regular file or directory `name` in `dirFD` carries an
    /// extended ACL with at least one entry; nil when it cannot be read.
    func hasExtendedACL(at dirFD: Int32, _ name: String) -> Bool?
}

/// SystemTreeInspector is the real `TreeInspector`.
public struct SystemTreeInspector: TreeInspector {
    public init() {}

    public func status(at dirFD: Int32, _ name: String) -> stat? {
        var st = stat()
        return fstatat(dirFD, name, &st, AT_SYMLINK_NOFOLLOW) == 0 ? st : nil
    }

    /// Opens `name` without following a symlink (the caller has already
    /// refused anything but a regular file or a directory) and reads its
    /// `ACL_TYPE_EXTENDED` ACL: none is `ENOENT`.
    public func hasExtendedACL(at dirFD: Int32, _ name: String) -> Bool? {
        let fd = openat(dirFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else { return errno == ENOENT ? false : nil }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        return acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry) == 0
    }
}

/// ConsoleAccount is the user logged in at the console.
public struct ConsoleAccount: Equatable, Sendable {
    public let uid: uid_t
    /// The home folder from the passwd entry, absolute.
    public let home: String

    public init(uid: uid_t, home: String) {
        self.uid = uid
        self.home = home
    }

    /// The staged bundle root copies from: the home plus the compiled
    /// relative path, never a path from the request file.
    public var stagedBundle: String { home + "/" + AppSwapRoot.stagedRelativePath }
}

/// ConsoleSession says who owns the console.
public protocol ConsoleSession: Sendable {
    func account() -> ConsoleAccount?
}

/// SystemConsoleSession reads the owner of `/dev/console` and that uid's
/// passwd entry. Root (the login window) and an account without an
/// absolute, canonical home count as no user.
public struct SystemConsoleSession: ConsoleSession {
    public init() {}

    public func account() -> ConsoleAccount? {
        var st = stat()
        guard stat(AppSwapRoot.consoleDevice, &st) == 0, st.st_uid != 0 else { return nil }
        guard let entry = getpwuid(st.st_uid), let dir = entry.pointee.pw_dir else { return nil }
        let home = String(cString: dir)
        guard AdminSwapEngine.isCanonicalAbsolute(home), home != "/" else { return nil }
        return ConsoleAccount(uid: st.st_uid, home: home)
    }
}

/// SessionRelauncher relaunches the app in the console user's session.
public protocol SessionRelauncher: Sendable {
    func relaunch(_ account: ConsoleAccount)
}

/// SystemSessionRelauncher runs `AppSwapRoot.relaunchArguments` by absolute
/// path, never through a shell, with a fixed environment, and does not wait:
/// the user-side helper waits for the handshake on its own.
public struct SystemSessionRelauncher: SessionRelauncher {
    public init() {}

    public func relaunch(_ account: ConsoleAccount) {
        let argv = AppSwapRoot.relaunchArguments(uid: account.uid, home: account.home)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            SwapLog.logger.error("admin swap: the relaunch could not start")
        }
    }
}

/// AdminSwapEngine is the root half of the administrator path, run only by
/// the installed bundle's helper from its verified root-owned copy
/// (`AppSwapRootScriptBuilder`). It reads no request file and takes no path:
///
/// 1. The console user and their home come from `ConsoleSession`; the
///    staged bundle is that home plus `AppSwapRoot.stagedRelativePath`, a
///    real directory with no symlink above it.
/// 2. The target is the constant `locations.target`: its parent resolves to
///    itself, it is a real directory opened by descriptor, and its identity,
///    owner, group and mode are recorded. Its whole tree must pass
///    `isSafeTree`, so a tree with a writable, linked or flagged entry is
///    refused before anything is copied. The installed bundle verifies
///    (without a tag requirement). The floor is the higher of root's own
///    record (`locations.floorRecord`, the highest tag this path has
///    installed) and the installed bundle's `K3smPayloadTag` or short
///    version; with no record, the floor is the installed bundle's, when its
///    tree is root's (`locations.owner`) alone. A tree that is not, which is
///    what a release dragged from the disk image is, needs the record: anyone
///    who can write `/Applications` (the admin group can) can change it, so
///    its own tag cannot be the floor, and with no record the run is refused.
///    The root script seeds the record from its verified copy first. A
///    record that exists but is not a root-owned 0600 regular file holding
///    one release tag refuses the run.
/// 3. The work directory is root's own 0700 directory on the target's volume
///    (`statfs` `f_fsid` equal), on a volume that can swap two names in one
///    step. The staged bundle is copied into a fresh directory in it (`ditto`
///    with no extended attributes), refused if any entry is a symlink, a
///    special file, a hard link, setuid or setgid, group or other writable,
///    or flagged immutable, append-only or undeletable (a system flag is
///    refused on the staged tree before the copy; the user flags are cleared
///    on root's copy before it is removed), chowned to
///    root, checked to be on the target's volume, and verified there: the
///    requirement, the bundle id, the team stamp, and a `K3smPayloadTag`
///    strictly above the installed one.
/// 4. The copy takes the target's owner and group when the target's tree is
///    root's alone, and root's otherwise (`copyOwnership`), and its top
///    directory the target's mode, and is verified again (the same cdhash).
///    This is how a bundle an account dragged to `/Applications` becomes
///    root's: never by a chown in place, but by the verified copy replacing
///    it, so the next run finds a tree that is root's alone.
/// 5. Right before the rename the target's identity is read again; then
///    `renameatx_np(RENAME_SWAP)` relative to the two directory descriptors.
///    `EXDEV` makes one fresh copy, verifies it and retries once; `ENOTSUP`
///    and any other errno leave the old bundle in place.
/// 6. After the rename the bundle that came out must be the one recorded
///    and the one that went in must be the copy; otherwise (the target was
///    replaced between the check and the rename) the same two names are
///    swapped back and the run is refused. The target is verified again, and
///    a failure swaps back too. An undo whose rename fails exits
///    `undoFailed`, logs which bundle is believed live, and keeps the bundle that came
///    out in root's work directory.
/// 7. Root's floor record is replaced with the new tag (a 0600 file written
///    durably), the old bundle moves to `previousRoot` as `k3sm-<tag>.previous`, the
///    work directory is emptied, and the app is relaunched in the console
///    session (`SessionRelauncher`).
///
/// Only two names are ever renamed: the constant target and the entry of a
/// directory this engine made inside root's work directory.
public struct AdminSwapEngine: Sendable {
    public let verifier: any BundleVerifier
    public let renamer: any Renamer
    public let console: any ConsoleSession
    public let relauncher: any SessionRelauncher
    public let locations: AdminSwapLocations
    public let inspector: any TreeInspector

    public init(verifier: any BundleVerifier, renamer: any Renamer, console: any ConsoleSession,
                relauncher: any SessionRelauncher, locations: AdminSwapLocations,
                inspector: any TreeInspector = SystemTreeInspector()) {
        self.verifier = verifier
        self.renamer = renamer
        self.console = console
        self.relauncher = relauncher
        self.locations = locations
        self.inspector = inspector
    }

    /// Whether `path` is absolute with no empty, `.` or `..` component.
    static func isCanonicalAbsolute(_ path: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        if path == "/" { return true }
        return !path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
            .contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }

    /// The `statfs` `f_fsid` of `path`, without following a symlink in its
    /// last component.
    static func fsid(_ path: String) -> fsid_t? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var fs = statfs()
        guard fstatfs(fd, &fs) == 0 else { return nil }
        return fs.f_fsid
    }

    static func sameVolume(_ a: fsid_t?, _ b: fsid_t?) -> Bool {
        guard let a, let b else { return false }
        return a.val.0 == b.val.0 && a.val.1 == b.val.1
    }

    /// Whether `path` resolves to itself: no symlink anywhere in it.
    static func resolvesToItself(_ path: String) -> Bool {
        guard let resolved = realpath(path, nil) else { return false }
        defer { free(resolved) }
        return String(cString: resolved) == path
    }

    /// Runs the swap and returns the exit status (`AppSwapRootExit`, or 0).
    public func run() -> Int32 {
        let status = swap()
        if status == 0 {
            SwapLog.logger.notice("admin swap: committed, relaunching in the console session")
        } else {
            SwapLog.logger.error("admin swap: refused with status \(status, privacy: .public)")
        }
        return status
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    private func swap() -> Int32 {
        guard let account = console.account() else { return AppSwapRootExit.noConsoleUser }

        // The target, by descriptor.
        let target = locations.target
        let parentPath = (target as NSString).deletingLastPathComponent
        let name = (target as NSString).lastPathComponent
        guard Self.resolvesToItself(parentPath), let parentFD = FileOps.openDirectory(parentPath) else {
            return AppSwapRootExit.targetRefused
        }
        defer { close(parentFD) }
        var targetStat = stat()
        guard fstatat(parentFD, name, &targetStat, AT_SYMLINK_NOFOLLOW) == 0, (targetStat.st_mode & S_IFMT) == S_IFDIR,
              let original = FileIdentity.of(dirFD: parentFD, name: name)
        else { return AppSwapRootExit.targetRefused }
        guard Self.isSafeTree(at: parentFD, name, inspector: inspector) else {
            SwapLog.logger.error("admin swap: the installed bundle's tree holds an unsafe entry")
            return AppSwapRootExit.targetUntrusted
        }
        let rootsAlone = Self.isSafeTree(at: parentFD, name, owner: locations.owner, inspector: inspector)
        let targetVolume = Self.fsid(parentPath)
        guard targetVolume != nil, SwapVolume.supportsRenameSwap(path: parentPath) == true else {
            return AppSwapRootExit.volumeRefused
        }

        // The floor: root's record, and the installed bundle. Only a bundle
        // known root's may be the floor by itself.
        guard let recorded = readFloorRecord() else {
            SwapLog.logger.error("admin swap: root's floor record is not a root-owned 0600 file holding one release tag")
            return AppSwapRootExit.targetUntrusted
        }
        guard rootsAlone || recorded != nil else {
            SwapLog.logger.error("admin swap: the installed bundle's tree is not root's alone and root has no floor record")
            return AppSwapRootExit.targetUntrusted
        }
        guard let installed = InstalledRelease.read(bundleAt: target),
              let installedCode = try? verifier.verify(bundleAt: target, requireTag: false), installedCode.identity == original
        else { return AppSwapRootExit.verificationFailed }
        let floor = recorded.map { max($0, installed.version) } ?? installed.version

        // The staged bundle, derived, never read from a request.
        let staged = account.stagedBundle
        var stagedStat = stat()
        guard Self.resolvesToItself((staged as NSString).deletingLastPathComponent),
              lstat(staged, &stagedStat) == 0, (stagedStat.st_mode & S_IFMT) == S_IFDIR
        else { return AppSwapRootExit.stagedRefused }
        // A system flag on the staged tree would survive into root's copy,
        // and root cannot clear it outside single-user mode, so it is
        // refused before anything is copied. A user can set none of them.
        guard let stagedParentFD = FileOps.openDirectory((staged as NSString).deletingLastPathComponent) else {
            return AppSwapRootExit.stagedRefused
        }
        let systemFlagFree = Self.isFree(of: Self.systemLockingFlags, at: stagedParentFD, AppSwapRoot.bundleName)
        close(stagedParentFD)
        guard systemFlagFree else { return AppSwapRootExit.stagedRefused }

        // Root's work directory, on the target's volume.
        guard let workFD = privateDirectory(locations.workRoot) else { return AppSwapRootExit.volumeRefused }
        defer { close(workFD) }
        guard Self.sameVolume(Self.fsid(locations.workRoot), targetVolume) else { return AppSwapRootExit.volumeRefused }
        var made: [String] = []
        var kept: String?
        defer {
            // `ditto` keeps a staged file's flags, so the copy can hold a
            // `uchg` file that would keep its directory from ever being
            // removed; the user flags are cleared first.
            for dirName in made where dirName != kept {
                Self.clearUserLockingFlags(locations.workRoot + "/" + dirName)
                FileOps.removeTree(at: workFD, dirName)
            }
        }

        // Copies the staged bundle into a fresh directory, gives it its final
        // owner and the target's mode, and verifies it twice.
        let ownership = Self.copyOwnership(target: targetStat, rootsAlone: rootsAlone, locations: locations)
        func copyIn() -> (fd: Int32, bundle: VerifiedBundle, dirName: String)? {
            let dirName = FileOps.randomName(length: 12)
            guard mkdirat(workFD, dirName, 0o700) == 0 else { return nil }
            made.append(dirName)
            guard let fd = FileOps.openDirectory(at: workFD, dirName) else { return nil }
            let copyPath = locations.workRoot + "/" + dirName + "/" + AppSwapRoot.bundleName
            guard DittoCopier.copy(from: staged, to: copyPath), Self.isSafeTree(at: fd, AppSwapRoot.bundleName),
                  Self.chownTree(at: fd, AppSwapRoot.bundleName, owner: locations.owner, group: locations.group),
                  Self.sameVolume(Self.fsid(copyPath), targetVolume)
            else { close(fd); return nil }
            guard let first = verifiedNewer(copyPath, fd: fd, floor: floor),
                  Self.chownTree(at: fd, AppSwapRoot.bundleName, owner: ownership.owner, group: ownership.group),
                  fchmodat(fd, AppSwapRoot.bundleName, targetStat.st_mode & 0o7777, AT_SYMLINK_NOFOLLOW) == 0,
                  let second = verifiedNewer(copyPath, fd: fd, floor: floor),
                  second.cdhash == first.cdhash, second.identity == first.identity
            else { close(fd); return nil }
            return (fd, second, dirName)
        }

        guard var copy = copyIn() else { return AppSwapRootExit.verificationFailed }
        defer { close(copy.fd) }

        // The target again, right before the rename.
        guard FileIdentity.of(dirFD: parentFD, name: name) == original, FileOps.isDirectory(at: parentFD, name) else {
            return AppSwapRootExit.targetRefused
        }
        var result = renamer.swap(fromDir: copy.fd, from: AppSwapRoot.bundleName, toDir: parentFD, to: name)
        if result == EXDEV {
            // One fresh copy onto the target's volume, verified, one retry.
            guard let again = copyIn(), again.bundle.cdhash == copy.bundle.cdhash else { return AppSwapRootExit.volumeRefused }
            close(copy.fd)
            copy = again
            result = renamer.swap(fromDir: copy.fd, from: AppSwapRoot.bundleName, toDir: parentFD, to: name)
            if result == EXDEV { return AppSwapRootExit.volumeRefused }
        }
        switch result {
        case 0: break
        case ENOTSUP: return AppSwapRootExit.volumeRefused
        default: return AppSwapRootExit.swapFailed
        }
        FileOps.fullSync(parentFD)

        // Exactly these two bundles must have changed places.
        guard FileIdentity.of(dirFD: copy.fd, name: AppSwapRoot.bundleName) == original,
              FileIdentity.of(dirFD: parentFD, name: name) == copy.bundle.identity
        else {
            // The target changed between the check and the rename: undo it.
            guard undo(copy: copy, parentFD: parentFD, name: name) else {
                kept = copy.dirName
                return AppSwapRootExit.undoFailed
            }
            return AppSwapRootExit.targetRefused
        }
        guard let post = try? verifier.verify(bundleAt: target, requireTag: true), post.identity == copy.bundle.identity,
              post.cdhash == copy.bundle.cdhash
        else {
            guard undo(copy: copy, parentFD: parentFD, name: name) else {
                kept = copy.dirName
                return AppSwapRootExit.undoFailed
            }
            return AppSwapRootExit.verificationFailed
        }

        // Root records the release it installed; the floor never comes from
        // the target alone again. A failed write is logged and the swap
        // stands: the next run's floor is the new bundle, which is root's.
        if let tag = copy.bundle.tag, !writeFloorRecord(tag) {
            SwapLog.logger.error("admin swap: root's floor record could not be written")
        }

        // The old bundle leaves Applications for root's previous directory.
        let previousName = SwapPaths.previousName(tag: installed.tag)
        if let previousFD = privateDirectory(locations.previousRoot) {
            for entry in FileOps.entries(previousFD) {
                Self.clearUserLockingFlags(locations.previousRoot + "/" + entry)
                FileOps.removeTree(at: previousFD, entry)
            }
            if renamer.move(fromDir: copy.fd, from: AppSwapRoot.bundleName, toDir: previousFD, to: previousName) == 0 {
                FileOps.fullSync(previousFD)
            }
            close(previousFD)
        }
        relauncher.relaunch(account)
        return 0
    }

    /// The owner and group root's copy ends with: the target's when its tree
    /// is root's alone, so a swap keeps what an administrator chose, and root's
    /// otherwise, so the account that dragged a release to `/Applications`
    /// owns nothing of what replaces it.
    static func copyOwnership(target: stat, rootsAlone: Bool, locations: AdminSwapLocations) -> (owner: uid_t, group: gid_t) {
        rootsAlone ? (target.st_uid, target.st_gid) : (locations.owner, locations.group)
    }

    /// Swaps the target and root's copy back after a swap that must not
    /// stand, and returns whether the undo rename succeeded. On a failure it
    /// logs which bundle is believed live: root's copy of the staged bundle at the
    /// target, the bundle that came out in root's work directory.
    private func undo(copy: (fd: Int32, bundle: VerifiedBundle, dirName: String), parentFD: Int32, name: String) -> Bool {
        let result = renamer.swap(fromDir: copy.fd, from: AppSwapRoot.bundleName, toDir: parentFD, to: name)
        FileOps.fullSync(parentFD)
        guard result == 0 else {
            let tag = copy.bundle.tag ?? "untagged"
            let kept = locations.workRoot + "/" + copy.dirName + "/" + AppSwapRoot.bundleName
            let copyID = copy.bundle.identity
            let now = FileIdentity.of(dirFD: parentFD, name: name).map { "\($0.volume) inode \($0.ino)" } ?? "nothing"
            SwapLog.logger.error("""
                admin swap: the undo failed with errno \(result, privacy: .public): root's copy of the staged bundle \
                (\(tag, privacy: .public), \(copyID.volume, privacy: .public) inode \(copyID.ino, privacy: .public)) is \
                believed live at \(locations.target, privacy: .public), which now holds \(now, privacy: .public); the bundle \
                that came out is believed kept at \(kept, privacy: .public)
                """)
            return false
        }
        return true
    }

    /// Verifies the copy at `path` and returns it when it is the bundle in
    /// `fd`, carries a tag, and that tag is strictly above `floor`.
    private func verifiedNewer(_ path: String, fd: Int32, floor: SemanticVersion) -> VerifiedBundle? {
        guard let verified = try? verifier.verify(bundleAt: path, requireTag: true),
              verified.identity == FileIdentity.of(dirFD: fd, name: AppSwapRoot.bundleName),
              let version = verified.version, version > floor
        else { return nil }
        return verified
    }

    /// The largest floor record read. The root script reads the same bound,
    /// `AppSwapRootScriptBuilder.floorRecordLimit`; a test pins them equal.
    static let floorRecordLimit = 128

    /// Root's floor record: `.some(nil)` when there is none, `.some(version)`
    /// for a record that is a regular file owned by `locations.owner`, mode
    /// 0600, one link, in a directory with no symlink above it that is
    /// `locations.owner`'s and writable by no group or other user, holding
    /// one release tag and a newline. Anything else is nil: refused.
    private func readFloorRecord() -> SemanticVersion?? {
        let path = locations.floorRecord
        let parent = (path as NSString).deletingLastPathComponent
        var dir = stat()
        guard Self.resolvesToItself(parent), lstat(parent, &dir) == 0, (dir.st_mode & S_IFMT) == S_IFDIR,
              dir.st_uid == locations.owner, dir.st_mode & 0o022 == 0
        else { return nil }
        var st = stat()
        guard lstat(path, &st) == 0 else { return errno == ENOENT ? .some(nil) : nil }
        guard st.st_nlink == 1,
              let data = FileOps.read(path, check: .init(owner: locations.owner, mode: 0o600, limit: Self.floorRecordLimit)),
              let text = String(data: data, encoding: .utf8), text.hasSuffix("\n"),
              let version = AppVersion.releaseTagVersion(String(text.dropLast()))
        else { return nil }
        return .some(version)
    }

    /// Replaces root's floor record with `tag` and a newline, 0600, durably.
    private func writeFloorRecord(_ tag: String) -> Bool {
        let path = locations.floorRecord
        let parent = (path as NSString).deletingLastPathComponent
        guard SwapTag.isReleaseTag(tag), Self.resolvesToItself(parent), let fd = FileOps.openDirectory(parent) else { return false }
        defer { close(fd) }
        return FileOps.replaceDurably(dirFD: fd, name: (path as NSString).lastPathComponent, data: Data((tag + "\n").utf8),
                                      mode: 0o600)
    }

    /// Opens `path`, creating it 0700 when missing, and returns its
    /// descriptor only when it is a real directory owned by
    /// `locations.owner`, writable and searchable by nobody else, with no
    /// symlink above it.
    private func privateDirectory(_ path: String) -> Int32? {
        let parent = (path as NSString).deletingLastPathComponent
        guard Self.resolvesToItself(parent) else { return nil }
        if mkdir(path, 0o700) != 0, errno != EEXIST { return nil }
        guard let fd = FileOps.openDirectory(path) else { return nil }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_uid == locations.owner, st.st_mode & 0o077 == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    /// UF_NOUNLINK: 0x10 in the BSD header, commented out in Darwin's, so
    /// spelled here; refused all the same.
    static let ufNoUnlink: UInt32 = 0x0000_0010
    /// The flags a file's owner can set that keep it from being changed,
    /// appended to only, or removed: `uchg`, `uappnd` and `uunlnk`.
    static let userLockingFlags = UInt32(UF_IMMUTABLE) | UInt32(UF_APPEND) | ufNoUnlink
    /// The superuser's flags of the same kind: `schg`, `sappnd`, `sunlnk`.
    static let systemLockingFlags = UInt32(SF_IMMUTABLE) | UInt32(SF_APPEND) | UInt32(SF_NOUNLINK)

    /// Whether `name` in `dirFD`, and everything under it, is a regular file
    /// or a directory, not setuid or setgid, not group or other writable,
    /// carrying none of `userLockingFlags` or `systemLockingFlags`, and, for
    /// a regular file, with one link only; with no extended ACL (one that
    /// cannot be read counts as present); and, when `owner` is given, owned
    /// by it. Nothing is followed; `inspector` reads each entry.
    ///
    /// The link count refuses every hard link, inside the tree or to a file
    /// outside it: root's copy is made by `ditto` into a fresh directory, so
    /// a count above one there is a link `ditto` kept between two staged
    /// files, and a release bundle has none.
    static func isSafeTree(at dirFD: Int32, _ name: String, owner: uid_t? = nil,
                           inspector: any TreeInspector = SystemTreeInspector()) -> Bool {
        guard let st = inspector.status(at: dirFD, name), st.st_mode & 0o6022 == 0,
              st.st_flags & (userLockingFlags | systemLockingFlags) == 0, owner.map({ st.st_uid == $0 }) ?? true
        else { return false }
        let type = st.st_mode & S_IFMT
        guard type == S_IFREG || type == S_IFDIR, inspector.hasExtendedACL(at: dirFD, name) == false else { return false }
        switch type {
        case S_IFREG: return st.st_nlink == 1
        case S_IFDIR:
            guard let fd = FileOps.openDirectory(at: dirFD, name) else { return false }
            defer { close(fd) }
            return FileOps.entries(fd).allSatisfy { isSafeTree(at: fd, $0, owner: owner, inspector: inspector) }
        default: return false
        }
    }

    /// Whether `name` in `dirFD`, and everything under it, carries none of
    /// `flags`. Nothing is followed; a directory that cannot be opened counts
    /// as carrying them.
    static func isFree(of flags: UInt32, at dirFD: Int32, _ name: String) -> Bool {
        var st = stat()
        guard fstatat(dirFD, name, &st, AT_SYMLINK_NOFOLLOW) == 0, st.st_flags & flags == 0 else { return false }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { return true }
        guard let fd = FileOps.openDirectory(at: dirFD, name) else { return false }
        defer { close(fd) }
        return FileOps.entries(fd).allSatisfy { isFree(of: flags, at: fd, $0) }
    }

    /// Clears `userLockingFlags` on `path` and everything under it, never
    /// following a symlink (`lchflags`), so the tree can be removed. It runs
    /// only on trees root made inside its own 0700 directories, which no
    /// other user can change, so the paths name what was checked. Root may
    /// clear a user flag; the system flags are refused before the copy.
    static func clearUserLockingFlags(_ path: String) {
        var st = stat()
        guard lstat(path, &st) == 0 else { return }
        if st.st_flags & userLockingFlags != 0 { _ = lchflags(path, st.st_flags & ~userLockingFlags) }
        guard (st.st_mode & S_IFMT) == S_IFDIR, let fd = FileOps.openDirectory(path) else { return }
        defer { close(fd) }
        for entry in FileOps.entries(fd) { clearUserLockingFlags(path + "/" + entry) }
    }

    /// Sets the owner and group of `name` in `dirFD` and everything under
    /// it, never following a symlink.
    static func chownTree(at dirFD: Int32, _ name: String, owner: uid_t, group: gid_t) -> Bool {
        guard fchownat(dirFD, name, owner, group, AT_SYMLINK_NOFOLLOW) == 0 else { return false }
        guard FileOps.isDirectory(at: dirFD, name) else { return true }
        guard let fd = FileOps.openDirectory(at: dirFD, name) else { return false }
        defer { close(fd) }
        return FileOps.entries(fd).allSatisfy { chownTree(at: fd, $0, owner: owner, group: group) }
    }
}
