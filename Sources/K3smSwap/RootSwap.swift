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
import os

/// RootSwapMode is the helper's root mode: `--root-swap` is what the root
/// step execs (verify, then hand off), `--root-swap-detached` the half that
/// outlives the root step (wait, swap, relaunch).
public enum RootSwapMode: String, Sendable, CaseIterable {
    case prepare = "--root-swap"
    case detached = "--root-swap-detached"
}

/// RootSwapArguments is the root mode's whole argument list: the mode and
/// three integers, the console user's uid, the app's pid and its start time
/// in microseconds. No path, no name, no tag. Each integer is decimal digits
/// only, with no sign and no leading zero; uid 0 and pid 0 are refused.
public struct RootSwapArguments: Equatable, Sendable {
    public let mode: RootSwapMode
    public let uid: uid_t
    public let app: ProcessIdentity

    public init(mode: RootSwapMode, uid: uid_t, app: ProcessIdentity) {
        self.mode = mode
        self.uid = uid
        self.app = app
    }

    /// Parses the arguments after the executable; nil unless they are
    /// exactly a root mode and its three integers.
    public init?(arguments: [String]) {
        guard arguments.count == 4, let mode = RootSwapMode(rawValue: arguments[0]),
              let uid = Self.integer(arguments[1], max: UInt64(UInt32.max - 1)), uid > 0,
              let pid = Self.integer(arguments[2], max: UInt64(Int32.max)), pid > 0,
              let start = Self.integer(arguments[3], max: UInt64.max)
        else { return nil }
        self.init(mode: mode, uid: uid_t(uid), app: ProcessIdentity(pid: Int32(pid), start: ProcessStart(packedMicroseconds: start)))
    }

    /// The words after the executable, as `init?(arguments:)` reads them;
    /// nil when the start time does not pack.
    public var words: [String]? {
        guard let start = app.start.packedMicroseconds else { return nil }
        return [mode.rawValue, String(uid), String(app.pid), String(start)]
    }

    static func integer(_ text: String, max: UInt64) -> UInt64? {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty, bytes.count <= 20, bytes.allSatisfy({ (48...57).contains($0) }),
              bytes.count == 1 || bytes[0] != 48, let value = UInt64(text), value <= max
        else { return nil }
        return value
    }
}

/// RootOwnership is the owner root gives everything it keeps: `root:wheel`.
/// Only the tests, which do not run as root, pass their own account.
public struct RootOwnership: Equatable, Sendable {
    public let uid: uid_t
    public let gid: gid_t

    public init(uid: uid_t, gid: gid_t) {
        self.uid = uid
        self.gid = gid
    }

    public static let root = RootOwnership(uid: 0, gid: 0)
}

/// RootSwapLayout is every location of the root path: the Applications
/// directory holding the constant target, root's work directory, and the
/// console user's paths (from that account's passwd entry), which give the
/// staged bundle and the user-side helper copy. Tests inject scratch roots;
/// the helper uses `forAccount(uid:)`.
public struct RootSwapLayout: Equatable, Sendable {
    public let applications: String
    public let workDirectory: String
    public let user: SwapPaths

    public init(applications: String, workDirectory: String, user: SwapPaths) {
        self.applications = applications
        self.workDirectory = workDirectory
        self.user = user
    }

    /// The compiled locations for the account `uid`.
    public static func forAccount(uid: uid_t) -> RootSwapLayout? {
        SwapPaths.forAccount(uid: uid).map {
            RootSwapLayout(applications: AppSwapPaths.applications, workDirectory: AppSwapPaths.workDirectory, user: $0)
        }
    }

    public var target: String { applications + "/" + SwapPaths.bundleName }
    public var stagePath: String { workDirectory + "/" + AppSwapPaths.stageName }
    public var stagedBundle: String { stagePath + "/" + SwapPaths.bundleName }
    public var previousDirectory: String { workDirectory + "/" + AppSwapPaths.previousName }
    public var recordPath: String { workDirectory + "/" + AppSwapPaths.recordName }
}

/// UserSideRunner runs the console user's own helper copy as that user,
/// for the launch after root's swap. It is the only thing the root path
/// runs as the user, and it never runs as root.
public protocol UserSideRunner: Sendable {
    /// Runs the user-side `mode` (`--relaunch` or `--relaunch-failed`) and
    /// returns its exit status; nil when it could not run or did not finish
    /// within the bound.
    func run(_ mode: HelperMode) -> Int32?
}

/// ConsoleSessionRunner is the real `UserSideRunner`:
/// `launchctl asuser <uid> /usr/bin/sudo -n -u '#<uid>' -- <helper copy>
/// <mode>`, by absolute path, never through a shell, with a fixed
/// environment. `launchctl asuser` only enters the user's GUI bootstrap
/// namespace and keeps root; `sudo -u '#<uid>'` is what drops to the
/// account, so root never executes the user-writable copy as root. The copy
/// refuses to run as root on its own as well.
public struct ConsoleSessionRunner: UserSideRunner {
    public let uid: uid_t
    public let helperPath: String
    /// How long the user side may take: its launch (30 s) and handshake
    /// (60 s) bounds, with room.
    public static let bound: Duration = .seconds(180)
    public static let launchctl = "/bin/launchctl"

    public init(uid: uid_t, helperPath: String) {
        self.uid = uid
        self.helperPath = helperPath
    }

    /// The argv after `/bin/launchctl`.
    public static func arguments(uid: uid_t, helperPath: String, mode: HelperMode) -> [String] {
        ["asuser", String(uid), "/usr/bin/sudo", "-n", "-u", "#" + String(uid), "--", helperPath, mode.rawValue]
    }

    public func run(_ mode: HelperMode) -> Int32? {
        guard uid != 0, mode == .relaunch || mode == .relaunchFailed else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.launchctl)
        process.arguments = Self.arguments(uid: uid, helperPath: helperPath, mode: mode)
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }
        if done.wait(timeout: .now() + Double(Self.bound.components.seconds)) == .timedOut {
            process.terminate()
            if done.wait(timeout: .now() + 5) == .timedOut { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            return nil
        }
        process.waitUntilExit()
        return process.terminationReason == .exit ? process.terminationStatus : nil
    }
}

/// RootSwapHooks is the tests' race seam: `beforeRename` runs right before
/// the target's identity is checked the last time. The helper never sets
/// it.
public struct RootSwapHooks: Sendable {
    public let beforeRename: (@Sendable () -> Void)?

    public init(beforeRename: (@Sendable () -> Void)?) {
        self.beforeRename = beforeRename
    }

    public static let none = RootSwapHooks(beforeRename: nil)
}

/// RootSwapLock is the held `flock` on the work directory's `lock` file. The
/// verifying half passes its descriptor to the detached half, so the lock
/// is held from the first check to the last rename with no gap.
public final class RootSwapLock: @unchecked Sendable {
    public private(set) var fd: Int32

    init(fd: Int32) {
        self.fd = fd
    }

    public func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    /// Closes this descriptor without unlocking, after the detached half was
    /// given a duplicate: an `flock` belongs to the open file, which the
    /// duplicate keeps, so an unlock here would unlock the detached half too.
    public func handOff() {
        guard fd >= 0 else { return }
        close(fd)
        fd = -1
    }

    deinit { release() }
}

/// RootSwapRefusal is why the verifying half stopped; nothing was renamed.
public struct RootSwapRefusal: Error, Equatable, Sendable {
    public let exit: AppSwapExit

    public init(_ exit: AppSwapExit) {
        self.exit = exit
    }
}

/// RootSwapEngine is the standard-user root path's swap, run as root by the
/// helper copy the root step verified. It takes no path from anyone: the
/// target is the layout's constant, the staged bundle comes from the console
/// user's passwd entry and a compiled relative path, and the user's request
/// file is never read.
///
/// `prepare` (the root step waits for it, so a refusal reaches the app):
///
/// 1. the work directory owned by root, mode 0700, no symlink; its lock,
///    without waiting; stale stages and helper copies swept;
/// 2. the work directory on the target's volume, which can swap two names
///    in one step;
/// 3. every directory from the home folder down to the staged bundle owned
///    by the account, writable by no group or other user, and no symlink;
/// 4. `ditto` the staged bundle into the root-owned stage, refuse a
///    symlink, a special file, a setuid or setgid file or a group- or
///    other-writable entry in the copy, and chown it all to root;
/// 5. the stage on the target's file system (`statfs` `f_fsid`);
/// 6. verify the installed bundle (its tag, the floor, read through the
///    Applications directory's descriptor) and the copy (the requirement,
///    the bundle id, the team stamp, a `K3smPayloadTag` strictly above the
///    installed one);
/// 7. give the copy's top folder the target's owner and group and its mode
///    without group or other write or special bits.
///
/// `complete` (detached, after the root step returned):
///
/// 1. wait for the app to exit (its pid and start time);
/// 2. verify both bundles again, check the target's identity, then
///    `renameatx_np(RENAME_SWAP | RENAME_NOFOLLOW_ANY)` through the
///    directory descriptors;
/// 3. check the swap moved exactly those two, move the old bundle into the
///    root-owned previous directory as `k3sm-<tag>.previous`, verify the
///    target again;
/// 4. run the user side `--relaunch` as the account; on its success write
///    the root-owned previous record (the floor only rises) and clean up;
///    otherwise verify the kept copy, swap it back as root and run the user
///    side `--relaunch-failed`.
///
/// The stage sits in a directory only root can enter, so nothing changes
/// the verified copy between the check and the rename.
public struct RootSwapEngine: Sendable {
    public let layout: RootSwapLayout
    public let owner: RootOwnership
    public let account: uid_t
    public let app: ProcessIdentity
    public let verifier: any BundleVerifier
    public let watcher: any ProcessWatcher
    public let renamer: any Renamer
    public let userSide: any UserSideRunner
    public let timeouts: SwapTimeouts
    let hooks: RootSwapHooks

    public init(layout: RootSwapLayout, owner: RootOwnership, account: uid_t, app: ProcessIdentity, verifier: any BundleVerifier,
                watcher: any ProcessWatcher, renamer: any Renamer, userSide: any UserSideRunner, timeouts: SwapTimeouts,
                hooks: RootSwapHooks = .none) {
        self.layout = layout
        self.owner = owner
        self.account = account
        self.app = app
        self.verifier = verifier
        self.watcher = watcher
        self.renamer = renamer
        self.userSide = userSide
        self.timeouts = timeouts
        self.hooks = hooks
    }

    // MARK: the verifying half

    /// Checks, copies and verifies; returns the held lock for `complete`.
    /// `keepHelper` is the running helper copy's name, which the sweep
    /// leaves. Every refusal removes the stage and renames nothing.
    public func prepare(keepHelper: String? = nil) -> Result<RootSwapLock, RootSwapRefusal> {
        guard account != 0 else { return refuse(.refusedRequest, "the account is root") }
        guard let workFD = openWork() else { return refuse(.refusedPath, "the work folder is not root's own") }
        defer { close(workFD) }
        guard let lock = takeLock(workFD) else { return refuse(.busy, "another root swap holds the lock") }
        sweep(workFD, keepHelper: keepHelper)
        let result = prepareLocked(workFD)
        if case .failure = result {
            FileOps.removeTree(at: workFD, AppSwapPaths.stageName)
            lock.release()
            return result.map { _ in lock }
        }
        RootSwapLog.logger.notice("root-swap: verified the staged copy; handing off")
        return .success(lock)
    }

    private func prepareLocked(_ workFD: Int32) -> Result<Void, RootSwapRefusal> {
        guard let appsFD = openApplications() else { return refuse(.refusedPath, "the Applications folder or the target is unsafe") }
        defer { close(appsFD) }
        guard sameVolumeAndSwappable() else { return refuse(.unsupportedVolume, "the work folder is not on the target's volume") }
        guard stagedSourceIsSafe() else { return refuse(.stagedRefused, "the staged bundle's path is unsafe") }
        guard mkdirat(workFD, AppSwapPaths.stageName, 0o700) == 0, let stageFD = FileOps.openDirectory(at: workFD, AppSwapPaths.stageName)
        else { return refuse(.refusedPath, "the stage could not be made") }
        defer { close(stageFD) }
        guard fchown(stageFD, owner.uid, owner.gid) == 0, fchmod(stageFD, 0o700) == 0 else {
            return refuse(.refusedPath, "the stage could not be made root's")
        }
        RootSwapLog.logger.notice("root-swap: copying the staged bundle")
        guard DittoCopier.copy(from: layout.user.userStagedForRoot, to: layout.stagedBundle),
              FileOps.isDirectory(at: stageFD, SwapPaths.bundleName), RootTree.isSafe(at: stageFD, SwapPaths.bundleName),
              RootTree.chown(at: stageFD, SwapPaths.bundleName, owner)
        else { return refuse(.stagedRefused, "the staged bundle's copy is missing or unsafe") }
        guard RootTree.sameFileSystem(stageFD, appsFD) else { return refuse(.unsupportedVolume, "the stage is not on the target's file system") }
        guard check(appsFD: appsFD, stageFD: stageFD) != nil else { return refuse(.verificationFailed, "the staged copy failed verification") }
        guard restoreAttributes(appsFD: appsFD, stageFD: stageFD) else { return refuse(.refusedPath, "the target's owner and mode could not be copied") }
        return .success(())
    }

    /// Takes over the lock the verifying half passed on `fd`: it must be the
    /// work directory's `lock` file and the lock must be held through it.
    public func adoptLock(fd: Int32) -> RootSwapLock? {
        guard let workFD = openWork() else { return nil }
        defer { close(workFD) }
        var held = stat(), named = stat()
        guard fstat(fd, &held) == 0, (held.st_mode & S_IFMT) == S_IFREG,
              fstatat(workFD, AppSwapPaths.lockName, &named, AT_SYMLINK_NOFOLLOW) == 0,
              held.st_dev == named.st_dev, held.st_ino == named.st_ino, flock(fd, LOCK_EX | LOCK_NB) == 0,
              fcntl(fd, F_SETFD, FD_CLOEXEC) == 0
        else { return nil }
        return RootSwapLock(fd: fd)
    }

    /// Removes the stage, for a hand-off that did not start.
    public func discardStage() {
        guard let workFD = openWork() else { return }
        FileOps.removeTree(at: workFD, AppSwapPaths.stageName)
        close(workFD)
    }

    // MARK: the detached half

    /// Waits for the app, swaps, relaunches through the user side, and
    /// swaps back when the new app does not come up. Holds `lock` to the end.
    public func complete(lock: RootSwapLock) -> AppSwapExit {
        defer { lock.release() }
        // The app is waited for first, so every later stop relaunches it.
        RootSwapLog.logger.notice("root-swap: waiting for the app to quit")
        let exited = watcher.waitForExit(app, timeout: timeouts.appExit)
        guard let workFD = openWork() else { return finish(.refusedPath, relaunch: exited) }
        defer { close(workFD) }
        guard exited else {
            // The app still runs from the old bundle: nothing is replaced and
            // nothing relaunched.
            FileOps.removeTree(at: workFD, AppSwapPaths.stageName)
            return finish(.abandoned, relaunch: false)
        }
        let exit = swapLocked(workFD)
        FileOps.removeTree(at: workFD, AppSwapPaths.stageName)
        return exit
    }

    /// For a detached half that could not take over the lock: touches no
    /// file (another run may hold the lock), and once the app has quit,
    /// brings it back through the user side.
    public func relaunchAfterExit() -> AppSwapExit {
        if watcher.waitForExit(app, timeout: timeouts.appExit) { _ = userSide.run(.relaunchFailed) }
        return .busy
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    private func swapLocked(_ workFD: Int32) -> AppSwapExit {
        guard let appsFD = openApplications() else { return finish(.refusedPath, relaunch: true) }
        defer { close(appsFD) }
        guard let stageFD = FileOps.openDirectory(at: workFD, AppSwapPaths.stageName), RootTree.isPrivate(stageFD, owner) else {
            return finish(.refusedPath, relaunch: true)
        }
        defer { close(stageFD) }
        guard let previousFD = openPrevious(workFD) else { return finish(.refusedPath, relaunch: true) }
        defer { close(previousFD) }
        guard let checked = check(appsFD: appsFD, stageFD: stageFD) else { return finish(.verificationFailed, relaunch: true) }

        hooks.beforeRename?()
        let bundle = SwapPaths.bundleName
        guard FileIdentity.of(dirFD: appsFD, name: bundle) == checked.original,
              FileIdentity.of(dirFD: stageFD, name: bundle) == checked.incoming.identity
        else {
            RootSwapLog.logger.error("root-swap: the target changed before the rename; nothing renamed")
            return finish(.verificationFailed, relaunch: true)
        }
        let rc = renamer.swap(fromDir: stageFD, from: bundle, toDir: appsFD, to: bundle)
        guard rc == 0 else {
            RootSwapLog.logger.error("root-swap: the rename failed; nothing replaced")
            return finish(rc == EXDEV || rc == ENOTSUP ? .unsupportedVolume : .abandoned, relaunch: true)
        }
        FileOps.fullSync(appsFD)
        RootSwapLog.logger.notice("root-swap: swapped")

        // The swap must have exchanged exactly these two; otherwise undo it.
        guard FileIdentity.of(dirFD: appsFD, name: bundle) == checked.incoming.identity,
              FileIdentity.of(dirFD: stageFD, name: bundle) == checked.original
        else {
            _ = renamer.swap(fromDir: stageFD, from: bundle, toDir: appsFD, to: bundle)
            FileOps.fullSync(appsFD)
            return finish(.verificationFailed, relaunch: true)
        }
        // The old bundle leaves Applications at once, into root's previous
        // directory on the same volume.
        let previousName = SwapPaths.previousName(tag: checked.installed.tag)
        if let existing = FileIdentity.of(dirFD: previousFD, name: previousName), existing != checked.original {
            FileOps.removeTree(at: previousFD, previousName)
        }
        guard renamer.move(fromDir: stageFD, from: bundle, toDir: previousFD, to: previousName) == 0 else {
            _ = renamer.swap(fromDir: stageFD, from: bundle, toDir: appsFD, to: bundle)
            FileOps.fullSync(appsFD)
            return finish(.abandoned, relaunch: true)
        }
        FileOps.fullSync(previousFD)
        let kept = Kept(previousFD: previousFD, name: previousName, original: checked.original, incoming: checked.incoming.identity)

        // The post-swap verification of the constant target.
        guard let post = try? verifier.verify(bundleAt: layout.target, requireTag: true),
              post.identity == checked.incoming.identity, post.tag == checked.incoming.tag, post.cdhash == checked.incoming.cdhash
        else { return rollBack(appsFD: appsFD, workFD: workFD, kept: kept) }

        RootSwapLog.logger.notice("root-swap: relaunching as the user")
        guard userSide.run(.relaunch) == 0 else {
            RootSwapLog.logger.error("root-swap: the new app did not answer")
            return rollBack(appsFD: appsFD, workFD: workFD, kept: kept)
        }
        let prior = readRecord()
        let record = PreviousRecord(name: previousName, tag: checked.installed.tag, cdhash: checked.installedCode.cdhash,
                                    installedTag: checked.incoming.tag ?? "", installedCDHash: checked.incoming.cdhash,
                                    floorTag: SwapEngine.floor(after: prior, keeping: checked.installed))
        if !writeRecord(workFD, record) { RootSwapLog.logger.error("root-swap: the previous record could not be written") }
        SwapEngine.prunePrevious(previousFD: previousFD, keep: previousName)
        RootSwapLog.logger.notice("root-swap: committed")
        return .committed
    }

    /// Kept is where the old bundle went, and the two identities a swap back
    /// checks.
    struct Kept {
        let previousFD: Int32
        let name: String
        let original: FileIdentity
        let incoming: FileIdentity
    }

    /// Puts the kept old bundle back at the target, after verifying it is
    /// exactly the bundle that left, and relaunches it through the user
    /// side. The previous record is left as it was.
    private func rollBack(appsFD: Int32, workFD: Int32, kept: Kept) -> AppSwapExit {
        let path = layout.previousDirectory + "/" + kept.name
        guard FileIdentity.of(dirFD: kept.previousFD, name: kept.name) == kept.original,
              let verified = try? verifier.verify(bundleAt: path, requireTag: false), verified.identity == kept.original,
              renamer.swap(fromDir: kept.previousFD, from: kept.name, toDir: appsFD, to: SwapPaths.bundleName) == 0
        else {
            RootSwapLog.logger.fault("root-swap: could not put the previous bundle back")
            return .abandoned
        }
        FileOps.fullSync(appsFD)
        if FileIdentity.of(dirFD: kept.previousFD, name: kept.name) == kept.incoming {
            FileOps.removeTree(at: kept.previousFD, kept.name)
        }
        RootSwapLog.logger.notice("root-swap: rolled back")
        _ = userSide.run(.relaunchFailed)
        return .rolledBack
    }

    /// Ends a detached run short of a swap; the old app, which quit, comes
    /// back through the user side when `relaunch`.
    private func finish(_ exit: AppSwapExit, relaunch: Bool) -> AppSwapExit {
        RootSwapLog.logger.error("root-swap: stopped without a swap")
        if relaunch { _ = userSide.run(.relaunchFailed) }
        return exit
    }

    private func refuse<T>(_ exit: AppSwapExit, _ why: StaticString) -> Result<T, RootSwapRefusal> {
        RootSwapLog.logger.error("root-swap: refused: \(String(describing: why), privacy: .public)")
        return .failure(RootSwapRefusal(exit))
    }

    // MARK: checks

    /// Checked is what one verification of both bundles established.
    struct Checked {
        let original: FileIdentity
        let installed: InstalledRelease
        let installedCode: VerifiedBundle
        let incoming: VerifiedBundle
    }

    /// Verifies the installed bundle and the staged copy: the floor and the
    /// outgoing tag from the installed bundle's Info.plist, read through the
    /// Applications directory's descriptor; the copy's tag strictly above.
    func check(appsFD: Int32, stageFD: Int32) -> Checked? {
        let bundle = SwapPaths.bundleName
        guard FileOps.isDirectory(at: appsFD, bundle), let original = FileIdentity.of(dirFD: appsFD, name: bundle),
              let installed = InstalledRelease.read(dirFD: appsFD, name: bundle),
              let installedCode = try? verifier.verify(bundleAt: layout.target, requireTag: false), installedCode.identity == original,
              FileOps.isDirectory(at: stageFD, bundle), let staged = FileIdentity.of(dirFD: stageFD, name: bundle),
              let incoming = try? verifier.verify(bundleAt: layout.stagedBundle, requireTag: true), incoming.identity == staged,
              incoming.tag != nil, let version = incoming.version, version > installed.version
        else { return nil }
        return Checked(original: original, installed: installed, installedCode: installedCode, incoming: incoming)
    }

    /// The work directory, opened without following a symlink, after
    /// checking it is a real directory with no symlink above it, owned by
    /// root and mode 0700.
    func openWork() -> Int32? {
        guard let resolved = realpath(layout.workDirectory, nil) else { return nil }
        let real = String(cString: resolved)
        free(resolved)
        guard real == layout.workDirectory, let fd = FileOps.openDirectory(layout.workDirectory) else { return nil }
        guard RootTree.isPrivate(fd, owner) else {
            close(fd)
            return nil
        }
        return fd
    }

    private func takeLock(_ workFD: Int32) -> RootSwapLock? {
        let fd = openat(workFD, AppSwapPaths.lockName, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == owner.uid, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        return RootSwapLock(fd: fd)
    }

    /// Removes a stale stage and every helper copy but the running one.
    private func sweep(_ workFD: Int32, keepHelper: String?) {
        for name in FileOps.entries(workFD) {
            if name == AppSwapPaths.stageName || (name.hasPrefix(AppSwapPaths.helperPrefix) && name != keepHelper) {
                FileOps.removeTree(at: workFD, name)
            }
        }
    }

    /// The Applications directory, opened without following a symlink,
    /// with no symlink above it and the target a real directory in it.
    private func openApplications() -> Int32? {
        guard let resolved = realpath(layout.applications, nil) else { return nil }
        let real = String(cString: resolved)
        free(resolved)
        guard real == layout.applications, let fd = FileOps.openDirectory(layout.applications) else { return nil }
        guard FileOps.isDirectory(at: fd, SwapPaths.bundleName) else {
            close(fd)
            return nil
        }
        return fd
    }

    /// The previous directory in the work directory, made root's 0700 when
    /// missing.
    private func openPrevious(_ workFD: Int32) -> Int32? {
        if mkdirat(workFD, AppSwapPaths.previousName, 0o700) != 0 && errno != EEXIST { return nil }
        guard let fd = FileOps.openDirectory(at: workFD, AppSwapPaths.previousName) else { return nil }
        guard fchown(fd, owner.uid, owner.gid) == 0, fchmod(fd, 0o700) == 0, RootTree.isPrivate(fd, owner) else {
            close(fd)
            return nil
        }
        return fd
    }

    /// Whether the work directory sits on the target's volume (by UUID),
    /// which can exchange two names in one step.
    private func sameVolumeAndSwappable() -> Bool {
        guard let target = SwapVolume.uuid(path: layout.applications), let work = SwapVolume.uuid(path: layout.workDirectory),
              target == work
        else { return false }
        return SwapVolume.supportsRenameSwap(path: layout.applications) == true
    }

    /// Whether every directory from the account's home folder down to the
    /// staged bundle is a real directory (no symlink), owned by the account
    /// and writable by no group and no other user. This keeps other
    /// accounts out of the path; the account itself could still change it
    /// before the copy, so the binding checks are the ones on root's copy.
    func stagedSourceIsSafe() -> Bool {
        guard var fd = FileOps.openDirectory(layout.user.home) else { return false }
        defer { close(fd) }
        guard RootTree.ownedBy(fd, account) else { return false }
        for component in AppSwapPaths.userStagedRelative.split(separator: "/").map(String.init) {
            guard component != "..", component != ".", let next = FileOps.openDirectory(at: fd, component) else { return false }
            close(fd)
            fd = next
            guard RootTree.ownedBy(fd, account) else { return false }
        }
        return true
    }

    /// Gives the copy's top folder the target's owner and group, and the
    /// target's mode with no group or other write and no special bits.
    private func restoreAttributes(appsFD: Int32, stageFD: Int32) -> Bool {
        var st = stat()
        guard fstatat(appsFD, SwapPaths.bundleName, &st, AT_SYMLINK_NOFOLLOW) == 0 else { return false }
        return fchownat(stageFD, SwapPaths.bundleName, st.st_uid, st.st_gid, AT_SYMLINK_NOFOLLOW) == 0
            && fchmodat(stageFD, SwapPaths.bundleName, st.st_mode & 0o755, AT_SYMLINK_NOFOLLOW) == 0
    }

    // MARK: the root-owned previous record

    /// The root-owned previous record, or nil when there is none or it fails
    /// its checks (owned by root, mode 0600, at most 4 KiB) or its grammar.
    public func readRecord() -> PreviousRecord? {
        guard let data = FileOps.read(layout.recordPath, check: .init(owner: owner.uid, mode: 0o600, limit: 4096)),
              let record = try? JournalStore.decoder.decode(PreviousRecord.self, from: data), record.isValid
        else { return nil }
        return record
    }

    private func writeRecord(_ workFD: Int32, _ record: PreviousRecord) -> Bool {
        guard let data = try? JournalStore.encoder.encode(record) else { return false }
        return FileOps.replaceDurably(dirFD: workFD, name: AppSwapPaths.recordName, data: data, mode: 0o600)
    }
}

/// RootTree holds the root path's checks on directories and trees, each by
/// descriptor and never following a symlink.
enum RootTree {
    /// Whether the open directory `fd` is owned by `owner` with mode 0700.
    static func isPrivate(_ fd: Int32, _ owner: RootOwnership) -> Bool {
        var st = stat()
        return fstat(fd, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR && st.st_uid == owner.uid && st.st_mode & 0o777 == 0o700
    }

    /// Whether the open directory `fd` is owned by `uid` and writable by no
    /// group and no other user.
    static func ownedBy(_ fd: Int32, _ uid: uid_t) -> Bool {
        var st = stat()
        return fstat(fd, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR && st.st_uid == uid && st.st_mode & 0o022 == 0
    }

    /// Whether `name` in `dirFD` and everything under it is a regular file
    /// or a directory, with no setuid or setgid bit, writable by no group
    /// and no other user.
    static func isSafe(at dirFD: Int32, _ name: String) -> Bool {
        var st = stat()
        guard fstatat(dirFD, name, &st, AT_SYMLINK_NOFOLLOW) == 0, st.st_mode & 0o6022 == 0 else { return false }
        switch st.st_mode & S_IFMT {
        case S_IFREG:
            return true
        case S_IFDIR:
            guard let fd = FileOps.openDirectory(at: dirFD, name) else { return false }
            defer { close(fd) }
            return FileOps.entries(fd).allSatisfy { isSafe(at: fd, $0) }
        default:
            return false
        }
    }

    /// Gives `name` in `dirFD` and everything under it `owner`.
    static func chown(at dirFD: Int32, _ name: String, _ owner: RootOwnership) -> Bool {
        guard fchownat(dirFD, name, owner.uid, owner.gid, AT_SYMLINK_NOFOLLOW) == 0 else { return false }
        guard FileOps.isDirectory(at: dirFD, name) else { return true }
        guard let fd = FileOps.openDirectory(at: dirFD, name) else { return false }
        defer { close(fd) }
        return FileOps.entries(fd).allSatisfy { chown(at: fd, $0, owner) }
    }

    /// Whether two open descriptors are on one file system (`f_fsid`).
    static func sameFileSystem(_ a: Int32, _ b: Int32) -> Bool {
        var x = statfs(), y = statfs()
        guard fstatfs(a, &x) == 0, fstatfs(b, &y) == 0 else { return false }
        return x.f_fsid.val.0 == y.f_fsid.val.0 && x.f_fsid.val.1 == y.f_fsid.val.1
    }
}

/// RootSwapSpawner starts the detached half: the same verified root copy,
/// in its own session (`POSIX_SPAWN_SETSID`), with a fixed environment, its
/// standard streams on `/dev/null` (so the root step's caller is not held
/// open by them) and no descriptor but the lock, as descriptor 3.
public enum RootSwapSpawner {
    /// The descriptor the detached half finds the lock on.
    public static let lockDescriptor: Int32 = 3

    /// Spawns `executable` with `arguments`; returns whether it started.
    public static func spawnDetached(executable: String, arguments: [String], lockFD: Int32) -> Bool {
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
        posix_spawn_file_actions_adddup2(&actions, lockFD, lockDescriptor)
        let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = [strdup("PATH=/usr/bin:/bin:/usr/sbin:/sbin"), nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        return posix_spawn(&pid, executable, &actions, &attributes, argv, envp) == 0
    }
}

/// RootSwapCopy is the check the helper makes on itself before its root
/// mode does anything: it runs from a copy named `helper.<random>` directly
/// in root's work directory, a regular file owned by root, mode 0500, with
/// one link.
public enum RootSwapCopy {
    public static func isTrusted(path: String, workDirectory: String = AppSwapPaths.workDirectory, owner: uid_t = 0) -> Bool {
        let directory = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        guard let resolved = realpath(workDirectory, nil) else { return false }
        let work = String(cString: resolved)
        free(resolved)
        guard directory == work, name.hasPrefix(AppSwapPaths.helperPrefix), name.count > AppSwapPaths.helperPrefix.count else {
            return false
        }
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG && st.st_uid == owner && st.st_mode & 0o7777 == 0o500
            && st.st_nlink == 1
    }
}

/// RootSwapLog is the root path's os_log, under `io.k3sm.app.update`,
/// category `root-swap`: one static event per step.
enum RootSwapLog {
    static let logger = Logger(subsystem: "io.k3sm.app.update", category: "root-swap")
}

extension InstalledRelease {
    /// Reads `<name>/Contents/Info.plist` in `dirFD`, each directory opened
    /// without following a symlink.
    public static func read(dirFD: Int32, name: String) -> InstalledRelease? {
        guard let data = FileOps.read(at: dirFD, components: [name, "Contents", "Info.plist"], check: .init(limit: 1024 * 1024)),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = AppVersion.payloadRelease(info: info)
        else { return nil }
        let tag = AppVersion.payloadTag(info: info) ?? "v" + version.description
        guard SwapTag.isReleaseTag(tag) else { return nil }
        return InstalledRelease(tag: tag, version: version)
    }
}
