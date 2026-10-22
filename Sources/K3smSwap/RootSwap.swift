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

/// RootSwapArguments is the root mode's whole argument list, four words
/// after the mode: three integers (the console user's uid, the app's pid and
/// its start time in microseconds) and the release tag the app verified. No
/// path, no name.
/// Each integer is decimal digits only, with no sign and no leading zero;
/// uid 0 and pid 0 are refused. The tag must be a release tag in the strict
/// grammar (`BundledRollSupport.isReleaseTag`), the same rule the root
/// script was rendered under.
public struct RootSwapArguments: Equatable, Sendable {
    public let mode: RootSwapMode
    public let uid: uid_t
    public let app: ProcessIdentity
    /// The `K3smPayloadTag` the staged bundle must carry, exactly.
    public let expectedTag: String

    public init?(mode: RootSwapMode, uid: uid_t, app: ProcessIdentity, expectedTag: String) {
        guard uid != 0, app.pid > 0, BundledRollSupport.isReleaseTag(expectedTag) else { return nil }
        self.mode = mode
        self.uid = uid
        self.app = app
        self.expectedTag = expectedTag
    }

    /// Parses the arguments after the executable; nil unless they are
    /// exactly five words: a root mode, its three integers and a release tag.
    public init?(arguments: [String]) {
        guard arguments.count == 5, let mode = RootSwapMode(rawValue: arguments[0]),
              let uid = Self.integer(arguments[1], max: UInt64(UInt32.max - 1)), uid > 0,
              let pid = Self.integer(arguments[2], max: UInt64(Int32.max)), pid > 0,
              let start = Self.integer(arguments[3], max: UInt64.max)
        else { return nil }
        self.init(mode: mode, uid: uid_t(uid), app: ProcessIdentity(pid: Int32(pid), start: ProcessStart(packedMicroseconds: start)),
                  expectedTag: arguments[4])
    }

    /// The words after the executable, as `init?(arguments:)` reads them;
    /// nil when the start time does not pack.
    public var words: [String]? {
        guard let start = app.start.packedMicroseconds else { return nil }
        return [mode.rawValue, String(uid), String(app.pid), String(start), expectedTag]
    }

    /// The same arguments for `mode`.
    public func with(mode: RootSwapMode) -> RootSwapArguments? {
        RootSwapArguments(mode: mode, uid: uid, app: app, expectedTag: expectedTag)
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

/// RootSwapHooks is the tests' seam: `beforeRename` runs right before the
/// target's identity is checked the last time (a race), and `killAfterSwap`,
/// when it returns true, stops the detached half right after the swap with
/// no cleanup at all, as a kill or a power loss would. The helper never sets
/// either.
public struct RootSwapHooks: Sendable {
    public let beforeRename: (@Sendable () -> Void)?
    public let killAfterSwap: (@Sendable () -> Bool)?

    public init(beforeRename: (@Sendable () -> Void)? = nil, killAfterSwap: (@Sendable () -> Bool)? = nil) {
        self.beforeRename = beforeRename
        self.killAfterSwap = killAfterSwap
    }

    public static let none = RootSwapHooks()
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
///    without waiting; stale helper copies swept; a stale stage swept, but a
///    bundle in it older than the installed one (the old bundle a killed
///    run left after its swap) is kept as the previous copy, never deleted;
/// 2. the work directory on the target's volume, which can swap two names
///    in one step;
/// 3. every directory from the home folder down to the staged bundle owned
///    by the account, writable by no group or other user, and no symlink;
/// 4. `ditto` the staged bundle into the root-owned stage, refuse a
///    symlink, a special file, a setuid or setgid file or a group- or
///    other-writable entry in the copy, and chown it all to root;
/// 5. the stage on the target's file system (`statfs` `f_fsid`);
/// 6. verify the installed bundle (its tag and version taken from that
///    verification's sealed Info.plist, not below the root-owned record's
///    floor) and
///    the copy (the requirement, the bundle id, the team stamp, a
///    `K3smPayloadTag` exactly the tag the app verified and strictly above
///    the installed one);
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
    /// The tag the app verified; the staged bundle must carry exactly it.
    public let expectedTag: String
    public let verifier: any BundleVerifier
    public let watcher: any ProcessWatcher
    public let renamer: any Renamer
    public let userSide: any UserSideRunner
    public let timeouts: SwapTimeouts
    let hooks: RootSwapHooks

    public init(layout: RootSwapLayout, owner: RootOwnership, account: uid_t, app: ProcessIdentity, expectedTag: String,
                verifier: any BundleVerifier, watcher: any ProcessWatcher, renamer: any Renamer, userSide: any UserSideRunner,
                timeouts: SwapTimeouts, hooks: RootSwapHooks = .none) {
        self.layout = layout
        self.owner = owner
        self.account = account
        self.app = app
        self.expectedTag = expectedTag
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
        sweepHelpers(workFD, keepHelper: keepHelper)
        var madeStage = false
        let result = prepareLocked(workFD, madeStage: &madeStage)
        if case .failure = result {
            // Only a stage this run made, which holds only its own copy, is
            // removed; a stale one it could not clear is left as it is.
            if madeStage { FileOps.removeTree(at: workFD, AppSwapPaths.stageName) }
            lock.release()
            return result.map { _ in lock }
        }
        RootSwapLog.logger.notice("root-swap: verified the staged copy; handing off")
        return .success(lock)
    }

    private func prepareLocked(_ workFD: Int32, madeStage: inout Bool) -> Result<Void, RootSwapRefusal> {
        guard let appsFD = openApplications() else { return refuse(.refusedPath, "the Applications folder or the target is unsafe") }
        defer { close(appsFD) }
        guard sweepStage(workFD, appsFD: appsFD) else { return refuse(.refusedPath, "a stale stage could not be cleared") }
        guard sameVolumeAndSwappable() else { return refuse(.unsupportedVolume, "the work folder is not on the target's volume") }
        guard stagedSourceIsSafe() else { return refuse(.stagedRefused, "the staged bundle's path is unsafe") }
        guard mkdirat(workFD, AppSwapPaths.stageName, 0o700) == 0 else { return refuse(.refusedPath, "the stage could not be made") }
        madeStage = true
        guard let stageFD = FileOps.openDirectory(at: workFD, AppSwapPaths.stageName) else {
            return refuse(.refusedPath, "the stage could not be made")
        }
        defer { close(stageFD) }
        guard fchown(stageFD, owner.uid, owner.gid) == 0, fchmod(stageFD, 0o700) == 0 else {
            return refuse(.refusedPath, "the stage could not be made root's")
        }
        RootSwapLog.logger.notice("root-swap: copying the staged bundle")
        guard DittoCopier.copy(from: layout.user.userStagedForRoot, to: layout.stagedBundle, bound: Self.copyBound),
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

    /// How long root's copy of the staged bundle may take. The root step
    /// holds the administrator prompt's script, and the app, until the copy
    /// ends, and the bundle is a local copy of a few hundred megabytes that
    /// takes seconds; a source that stalls (a network home folder, a dying
    /// disk) is stopped well before that, rather than at the user path's
    /// 600 s, which waits in the background.
    public static let copyBound: Duration = .seconds(120)

    /// Removes the stage, for a hand-off that did not start. The lock is
    /// held and the stage holds only the copy this run made.
    public func discardStage() {
        guard let workFD = openWork() else { return }
        FileOps.removeTree(at: workFD, AppSwapPaths.stageName)
        close(workFD)
    }

    /// Clears the stage at the end of a detached run, keeping an older bundle
    /// in it (see `sweepStage`): a swap back that failed leaves the old
    /// bundle there. Without the Applications folder it keeps the stage.
    private func clearStage(_ workFD: Int32) {
        guard let appsFD = openApplications() else { return }
        _ = sweepStage(workFD, appsFD: appsFD)
        close(appsFD)
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
        guard let exit = swapLocked(workFD) else {
            // Killed by the test seam: nothing after the swap ran.
            return .abandoned
        }
        clearStage(workFD)
        return exit
    }

    /// For a detached half that could not take over the lock: touches no
    /// file (another run may hold the lock), and once the app has quit,
    /// brings it back through the user side.
    public func relaunchAfterExit() -> AppSwapExit {
        if watcher.waitForExit(app, timeout: timeouts.appExit) { _ = userSide.run(.relaunchFailed) }
        return .busy
    }

    /// One swap under the lock; nil only when the test seam killed it.
    // swiftlint:disable:next function_body_length cyclomatic_complexity
    private func swapLocked(_ workFD: Int32) -> AppSwapExit? {
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
            RootSwapLog.logger.error("root-swap: the rename failed with errno \(rc, privacy: .public); nothing replaced")
            return finish(Self.renameRefusal(errno: rc), relaunch: true)
        }
        FileOps.fullSync(appsFD)
        RootSwapLog.logger.notice("root-swap: swapped")
        if hooks.killAfterSwap?() == true { return nil }

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
        var status = userSide.run(.relaunch)
        if status == nil {
            // launchctl or sudo did not run, or the run timed out: no answer
            // either way about the new app, so it is tried once more.
            RootSwapLog.logger.error("root-swap: the user-side launch did not run; trying once more")
            status = userSide.run(.relaunch)
        }
        guard let status else {
            // Still no run: the new bundle is in place and verified, and
            // rolling it back would rest on a failure that says nothing about
            // it. It is kept, with its record, and the app's next launch closes
            // the journal.
            RootSwapLog.logger.error("root-swap: the user-side launch did not run; the verified update is left in place")
            return keep(workFD: workFD, previousFD: previousFD, previousName: previousName, checked: checked, confirmed: false)
        }
        guard status == 0 else {
            RootSwapLog.logger.error("root-swap: the new app did not answer (status \(status, privacy: .public))")
            return rollBack(appsFD: appsFD, workFD: workFD, kept: kept)
        }
        return keep(workFD: workFD, previousFD: previousFD, previousName: previousName, checked: checked, confirmed: true)
    }

    /// Ends a swap that stands: the root-owned previous record (the floor only
    /// rises), then the older previous copies pruned. A record that cannot be
    /// written is reported in the status, not only logged.
    private func keep(workFD: Int32, previousFD: Int32, previousName: String, checked: Checked, confirmed: Bool) -> AppSwapExit {
        let prior = readRecord()
        let record = PreviousRecord(name: previousName, tag: checked.installed.tag, cdhash: checked.installedCode.cdhash,
                                    installedTag: checked.incoming.tag ?? "", installedCDHash: checked.incoming.cdhash,
                                    floorTag: SwapEngine.floor(after: prior, keeping: checked.installed))
        let recorded = writeRecord(workFD, record)
        if recorded {
            SwapEngine.prunePrevious(previousFD: previousFD, keep: previousName)
        } else {
            RootSwapLog.logger.error("root-swap: the previous record could not be written")
        }
        guard confirmed else { return .leftUnconfirmed }
        RootSwapLog.logger.notice("root-swap: committed")
        return recorded ? .committed : .committedWithoutRecord
    }

    /// What a failed root rename means: `EPERM` or `EACCES` is macOS
    /// refusing it (App Management, System Integrity Protection), `EXDEV` or
    /// `ENOTSUP` the volume, anything else a stop with nothing replaced.
    static func renameRefusal(errno code: Int32) -> AppSwapExit {
        switch code {
        case EPERM, EACCES: return .refusedBySystem
        case EXDEV, ENOTSUP: return .unsupportedVolume
        default: return .abandoned
        }
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

    /// Verifies the installed bundle and the staged copy: the outgoing tag
    /// and version from the installed bundle's verification (its sealed
    /// Info.plist, which must carry a `K3smPayloadTag`), never from a
    /// separate read of the file, which the target's owner could change
    /// between that read and the signature check; the copy's tag exactly the
    /// one the app verified and strictly above the installed one; and the
    /// installed release not below the floor of the root-owned record.
    func check(appsFD: Int32, stageFD: Int32) -> Checked? {
        let bundle = SwapPaths.bundleName
        guard FileOps.isDirectory(at: appsFD, bundle), let original = FileIdentity.of(dirFD: appsFD, name: bundle),
              let installedCode = try? verifier.verify(bundleAt: layout.target, requireTag: true), installedCode.identity == original,
              let installed = Self.installedRelease(installedCode),
              FileOps.isDirectory(at: stageFD, bundle), let staged = FileIdentity.of(dirFD: stageFD, name: bundle),
              let incoming = try? verifier.verify(bundleAt: layout.stagedBundle, requireTag: true), incoming.identity == staged,
              incoming.tag == expectedTag, let version = incoming.version, version > installed.version,
              Self.atOrAboveFloor(installed, record: readRecord())
        else { return nil }
        return Checked(original: original, installed: installed, installedCode: installedCode, incoming: incoming)
    }

    /// The installed release as its verification established it: the tag
    /// and version the signature covered, or nil when it carries none.
    static func installedRelease(_ verified: VerifiedBundle) -> InstalledRelease? {
        guard let tag = verified.tag, let version = verified.version, SwapTag.isReleaseTag(tag) else { return nil }
        return InstalledRelease(tag: tag, version: version)
    }

    /// Whether `installed` is at or above the floor of the root-owned
    /// previous record (or there is no record). An installed release below
    /// the floor was put in place by something other than this path, which
    /// keeps the floor rising, so root replaces nothing.
    ///
    /// This does not stop a whole older app being planted: anyone who can
    /// write `/Applications/k3sm.app` can put an older team-signed release
    /// there and run it without asking root. It stops the root path from
    /// treating such a bundle as its starting point, and the record's floor,
    /// which only root writes, from being lowered through it.
    static func atOrAboveFloor(_ installed: InstalledRelease, record: PreviousRecord?) -> Bool {
        guard let record else { return true }
        guard let floor = SemanticVersion(record.floorTag) else { return false }
        return !(installed.version < floor)
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

    /// Removes every helper copy but the running one.
    private func sweepHelpers(_ workFD: Int32, keepHelper: String?) {
        for name in FileOps.entries(workFD) where name.hasPrefix(AppSwapPaths.helperPrefix) && name != keepHelper {
            FileOps.removeTree(at: workFD, name)
        }
    }

    /// Clears a stage, without ever deleting the only copy of the old
    /// bundle. A run killed between its swap and its move to `previous/`
    /// leaves the old bundle in `stage/k3sm.app`, and nothing else records
    /// it. The stage's bundle is therefore kept, as the previous copy named
    /// by its tag, whenever it is not strictly newer than the installed
    /// bundle; an incoming copy always is (the verification requires it), so
    /// only an un-swapped copy is deleted. A bundle whose tag cannot be read
    /// is not a release and is deleted. Returns false when the stage is
    /// still there.
    func sweepStage(_ workFD: Int32, appsFD: Int32) -> Bool {
        let stage = AppSwapPaths.stageName, bundle = SwapPaths.bundleName
        guard FileIdentity.of(dirFD: workFD, name: stage) != nil else { return true }
        if let stageFD = FileOps.openDirectory(at: workFD, stage) {
            defer { close(stageFD) }
            if FileOps.isDirectory(at: stageFD, bundle), let left = InstalledRelease.read(dirFD: stageFD, name: bundle),
               let installed = InstalledRelease.read(dirFD: appsFD, name: bundle), !(installed.version < left.version) {
                guard let previousFD = openPrevious(workFD) else { return false }
                defer { close(previousFD) }
                let name = SwapPaths.previousName(tag: left.tag)
                if FileIdentity.of(dirFD: previousFD, name: name) != nil { FileOps.removeTree(at: previousFD, name) }
                guard renamer.move(fromDir: stageFD, from: bundle, toDir: previousFD, to: name) == 0 else { return false }
                FileOps.fullSync(previousFD)
                RootSwapLog.logger.notice("root-swap: kept the old bundle a stopped run left in the stage")
            }
        }
        return FileOps.removeTree(at: workFD, stage)
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
    /// and writable by no group and no other user. This is check-then-copy,
    /// not a copy without following: `ditto` then copies by path, and the
    /// account could change the path between this check and the copy. The
    /// check keeps other accounts out of the path; the real control is the
    /// one on root's own copy after it is made, in a folder only root can
    /// enter: the tree check, then the requirement, the team stamp and the
    /// exact tag.
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
        // The lock is moved to a descriptor of 10 or more first, so the
        // hand-off never depends on it being 0 to 2 (which the opens above
        // would replace) or already 3 (a dup2 onto itself, whose clearing of
        // close-on-exec under POSIX_SPAWN_CLOEXEC_DEFAULT is not documented).
        let source = fcntl(lockFD, F_DUPFD_CLOEXEC, 10)
        guard source >= 0 else { return false }
        defer { close(source) }
        posix_spawn_file_actions_adddup2(&actions, source, lockDescriptor)
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
