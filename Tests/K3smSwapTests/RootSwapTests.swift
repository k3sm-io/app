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
@testable import K3smSwap
import Synchronization
import Testing

/// UserSide stands in for `ConsoleSessionRunner`: it records each mode and
/// runs the real user-side engine for it in the scratch world, unless a
/// test fixes the answer.
final class UserSide: UserSideRunner, @unchecked Sendable {
    let scratch: Scratch
    let timeouts: SwapTimeouts
    /// A fixed answer per mode; a nil answer is a run that did not happen.
    let fixed: Mutex<[HelperMode: Int32?]>
    private let log = Mutex<[HelperMode]>([])

    init(_ scratch: Scratch, timeouts: SwapTimeouts = .test, fixed: [HelperMode: Int32?] = [:]) {
        self.scratch = scratch
        self.timeouts = timeouts
        self.fixed = Mutex(fixed)
    }

    var calls: [HelperMode] { log.withLock { $0 } }

    func run(_ mode: HelperMode) -> Int32? {
        log.withLock { $0.append(mode) }
        if let answer = fixed.withLock({ $0[mode] }) { return answer }
        let engine = scratch.engine(timeouts: timeouts)
        switch mode {
        case .relaunch: return engine.relaunch().rawValue
        case .relaunchFailed: return engine.relaunchFailed().rawValue
        case .swap, .goBack: return nil
        }
    }
}

extension Scratch {
    /// Root's work folder in this world, made like the root step makes it.
    var work: String { root + "/work" }

    func makeWork(mode: mode_t = 0o700) {
        try? FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        chmod(work, mode)
    }

    var rootLayout: RootSwapLayout { RootSwapLayout(applications: applications, workDirectory: work, user: paths) }

    /// Stages a fixture bundle at the fixed home-relative path root reads.
    func stageForRoot(tag: String?, behaviour: String = "handshake") {
        let dir = paths.userStagedForRootDirectory
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        chmod(dir, 0o700)
        makeBundle(at: paths.userStagedForRoot, tag: tag, behaviour: behaviour)
    }

    /// Writes the user's `rootUpdate` request, as `SwapClient` does.
    @discardableResult
    func requestRoot(expectedTag: String, app: ProcessIdentity, target: String? = nil, outgoing: String? = "v1.0.0") -> SwapJournal {
        var journal = SwapJournal(request: SwapRequest(mode: .rootUpdate, target: target ?? self.target, stagedName: "",
                                                       expectedTag: expectedTag, token: SwapRequest.newToken(), app: app))
        journal.outgoingTag = outgoing
        try! JournalStore(paths: paths).write(journal)
        return journal
    }

    func rootEngine(app: ProcessIdentity, userSide: any UserSideRunner, renamer: any Renamer = SystemRenamer(),
                    timeouts: SwapTimeouts = .test, hooks: RootSwapHooks = .none, expectedTag: String = "v1.1.0") -> RootSwapEngine {
        RootSwapEngine(layout: rootLayout, owner: RootOwnership(uid: getuid(), gid: getgid()), account: getuid(), app: app,
                       expectedTag: expectedTag, verifier: verifier, watcher: KqueueProcessWatcher(), renamer: renamer, userSide: userSide,
                       timeouts: timeouts, hooks: hooks)
    }

    /// Runs both halves in this process, as the helper runs them in two.
    func rootSwap(_ engine: RootSwapEngine) -> AppSwapExit {
        switch engine.prepare() {
        case .failure(let refusal): return refusal.exit
        case .success(let lock): return engine.complete(lock: lock)
        }
    }

    func workEntries() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: work)) ?? []).sorted()
    }

    func rootPrevious() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: rootLayout.previousDirectory)) ?? []).sorted()
    }
}

@Suite("root swap", .serialized)
struct RootSwapTests {
    @Test func rootSwapCommitsAndKeepsARootOwnedRecord() throws {
        let s = Scratch()
        s.makeWork()
        s.install(tag: "v1.0.0")
        s.stageForRoot(tag: "v1.1.0")
        let app = s.appProcess(exitingAfter: 0.2)
        s.requestRoot(expectedTag: "v1.1.0", app: app)
        let user = UserSide(s)
        let engine = s.rootEngine(app: app, userSide: user)

        #expect(s.rootSwap(engine) == .committed)

        #expect(s.tag(at: s.target) == "v1.1.0")
        #expect(user.calls == [.relaunch])
        #expect(s.rootPrevious() == ["k3sm-v1.0.0.previous"])
        #expect(s.appBundles(in: s.rootLayout.previousDirectory).isEmpty)
        // The record is root's (here: the work folder owner's), 0600, in
        // the work folder, and the user's private folder holds none.
        let record = try #require(engine.readRecord())
        #expect(record.tag == "v1.0.0" && record.installedTag == "v1.1.0" && record.floorTag == "v1.0.0")
        var st = stat()
        #expect(lstat(s.rootLayout.recordPath, &st) == 0 && st.st_mode & 0o777 == 0o600)
        #expect(!FileManager.default.fileExists(atPath: s.paths.previousRecordPath))
        // The stage is gone; the user's journal is closed and its staged copy removed.
        #expect(s.workEntries() == ["lock", "previous", "previous.json"])
        #expect(s.journal?.state == .committed)
        #expect(!FileManager.default.fileExists(atPath: s.paths.userStagedForRoot))
        #expect(s.launcher.launches.map(\.arguments) == [["--updated-from", "v1.0.0", "--handshake"]])
    }

    @Test func rootSwapRefusesATargetReplacedBeforeTheRename() throws {
        let s = Scratch()
        s.makeWork()
        s.install(tag: "v1.0.0")
        s.stageForRoot(tag: "v1.1.0")
        let app = s.appProcess(exitingAfter: 0.2)
        s.requestRoot(expectedTag: "v1.1.0", app: app)
        let user = UserSide(s, fixed: [.relaunchFailed: 0])
        let spy = SpyRenamer()
        let target = s.target
        let hooks = RootSwapHooks {
            // Something else takes the target's place after the checks.
            _ = rename(target, target + ".moved")
            s.makeBundle(at: target, tag: "v1.0.0", behaviour: "handshake")
        }
        let engine = s.rootEngine(app: app, userSide: user, renamer: spy, hooks: hooks)
        #expect(engine.prepare().map { lock in engine.complete(lock: lock) } == .success(.verificationFailed))
        #expect(spy.count == 0)
        // Nothing outside the constant target was touched: the replacement
        // is in place, the moved bundle where it was moved.
        #expect(FileManager.default.fileExists(atPath: target + ".moved"))
        #expect(s.tag(at: target) == "v1.0.0")
        #expect(s.rootPrevious().isEmpty)
        #expect(user.calls == [.relaunchFailed])
        #expect(engine.readRecord() == nil)
    }

    @Test func rootSwapCopiesAStagedBundleFromAnotherVolume() throws {
        let work = realPath(NSTemporaryDirectory()) + "/k3sm-rootswap-volume-" + UUID().uuidString.prefix(8)
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        defer { run("/bin/rm", ["-rf", work]) }
        let home = work + "/home"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        #expect(run("/usr/bin/hdiutil", ["create", "-quiet", "-size", "40m", "-fs", "APFS", "-volname", "k3smroothome", work + "/home.dmg"]) == 0)
        #expect(run("/usr/bin/hdiutil", ["attach", "-quiet", "-nobrowse", "-noautoopen", "-owners", "on", "-mountpoint", home,
                                         work + "/home.dmg"]) == 0)
        defer { run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", home]) }
        let s = Scratch(home: home)
        s.makeWork()
        s.install(tag: "v1.0.0")
        s.stageForRoot(tag: "v1.1.0")
        var staged = statfs(), target = statfs()
        statfs(s.paths.userStagedForRoot, &staged)
        statfs(s.applications, &target)
        try #require(staged.f_fsid.val.0 != target.f_fsid.val.0 || staged.f_fsid.val.1 != target.f_fsid.val.1)
        let app = s.appProcess(exitingAfter: 0.2)
        s.requestRoot(expectedTag: "v1.1.0", app: app)

        #expect(s.rootSwap(s.rootEngine(app: app, userSide: UserSide(s))) == .committed)

        #expect(s.tag(at: s.target) == "v1.1.0")
        var after = statfs()
        statfs(s.target, &after)
        #expect(after.f_fsid.val.0 == target.f_fsid.val.0 && after.f_fsid.val.1 == target.f_fsid.val.1)
    }

    @Test(arguments: ["v1.0.0", "v0.9.0"])
    func rootSwapRefusesALowerOrEqualTag(_ staged: String) throws {
        let s = Scratch()
        s.makeWork()
        s.install(tag: "v1.0.0")
        let original = identity(s.target)
        s.stageForRoot(tag: staged)
        let app = s.appProcess(exitingAfter: 0.2)
        let user = UserSide(s)
        let spy = SpyRenamer()
        let engine = s.rootEngine(app: app, userSide: user, renamer: spy, expectedTag: staged)
        #expect(engine.prepare().map { _ in AppSwapExit.committed } == .failure(RootSwapRefusal(.verificationFailed)))
        #expect(spy.count == 0)
        #expect(identity(s.target) == original)
        #expect(s.workEntries() == ["lock"])
        #expect(user.calls.isEmpty)
    }

    @Test func rootSwapRestoresOwnerGroupAndMode() throws {
        let s = Scratch()
        s.makeWork()
        s.install(tag: "v1.0.0")
        // Another group this account belongs to, when it has one.
        var groups = [gid_t](repeating: 0, count: 64)
        let n = getgroups(Int32(groups.count), &groups)
        let group = groups.prefix(Int(max(n, 0))).first { $0 != getgid() } ?? getgid()
        #expect(lchown(s.target, getuid(), group) == 0)
        #expect(chmod(s.target, 0o775) == 0)
        s.stageForRoot(tag: "v1.1.0")
        let app = s.appProcess(exitingAfter: 0.2)
        s.requestRoot(expectedTag: "v1.1.0", app: app)

        #expect(s.rootSwap(s.rootEngine(app: app, userSide: UserSide(s))) == .committed)

        var st = stat()
        #expect(lstat(s.target, &st) == 0)
        #expect(st.st_uid == getuid() && st.st_gid == group)
        // The target's mode, without group or other write.
        #expect(st.st_mode & 0o7777 == 0o755)
        // Everything below the top folder is root's (the work folder's owner).
        #expect(lstat(s.target + "/Contents/Info.plist", &st) == 0 && st.st_uid == getuid() && st.st_gid == getgid())
    }

    /// A standard user's rename in a folder it cannot write fails with
    /// `EACCES`, which (like `EPERM`) sends the update to the administrator
    /// path; nothing is renamed.
    @Test func eaccesNeedsAdministrator() throws {
        #expect(RenameOutcome(errno: EACCES) == .needsAdministrator)
        #expect(RenameOutcome(errno: EPERM) == .needsAdministrator)
        let s = Scratch()
        s.install(tag: "v1.0.0")
        let original = identity(s.target)
        let name = s.stage(tag: "v1.1.0")
        s.request(stagedName: name, expectedTag: "v1.1.0", app: s.appProcess(exitingAfter: 0.2))
        #expect(chmod(s.applications, 0o555) == 0)
        defer { chmod(s.applications, 0o755) }
        let client = SwapClient(paths: s.paths, helperRequirement: fixtureRequirement, bundledHelper: "/nonexistent")
        #expect(client.requiresAdministrator(target: s.target))
        #expect(s.engine().swap() == .needsAdministrator)
        #expect(identity(s.target) == original)
        #expect(s.journal?.reason == .needsAdministrator)
        #expect(s.journal?.state == .verified)
        chmod(s.applications, 0o755)
        #expect(!client.requiresAdministrator(target: s.target))
    }

    /// The root path keeps its previous copy and record in its own work
    /// folder, which the copy-out's sweep of its staging root never reaches.
    @Test func rootPreviousCopySurvivesTheCopyOutSweep() throws {
        #expect(SwapPaths.rootWorkDirectory == "/Library/k3sm.app-update")
        #expect(SwapPaths.rootPreviousDirectory.hasPrefix(SwapPaths.rootWorkDirectory + "/"))
        #expect(!SwapPaths.rootWorkDirectory.hasPrefix(CopyOutPlan.stagingRoot))
        #expect(!(SwapPaths.rootWorkDirectory + "/").hasPrefix(CopyOutPlan.stagingRoot + "/"))
        let s = Scratch()
        s.makeWork()
        s.install(tag: "v1.0.0")
        s.stageForRoot(tag: "v1.1.0")
        let app = s.appProcess(exitingAfter: 0.2)
        s.requestRoot(expectedTag: "v1.1.0", app: app)
        let engine = s.rootEngine(app: app, userSide: UserSide(s))
        #expect(s.rootSwap(engine) == .committed)
        // The copy-out's sweep, as its script runs it, over a staging root
        // laid out beside the work folder as /Library lays them out.
        let staging = s.root + "/k3sm.staging"
        try FileManager.default.createDirectory(atPath: staging + "/old", withIntermediateDirectories: true)
        #expect(run("/usr/bin/find", [staging, "-mindepth", "1", "-maxdepth", "1", "-exec", "/bin/rm", "-rf", "{}", "+"]) == 0)
        #expect(!FileManager.default.fileExists(atPath: staging + "/old"))
        #expect(s.rootPrevious() == ["k3sm-v1.0.0.previous"])
        #expect(engine.readRecord() != nil)
    }

    @Test func rootSwapRelaunchFailureSwapsBack() throws {
        let s = Scratch()
        s.makeWork()
        s.install(tag: "v1.0.0")
        let original = identity(s.target)
        s.stageForRoot(tag: "v1.1.0", behaviour: "silent")
        let app = s.appProcess(exitingAfter: 0.2)
        s.requestRoot(expectedTag: "v1.1.0", app: app)
        let user = UserSide(s, timeouts: .silent)
        let engine = s.rootEngine(app: app, userSide: user)

        #expect(s.rootSwap(engine) == .rolledBack)

        #expect(identity(s.target) == original)
        #expect(s.tag(at: s.target) == "v1.0.0")
        #expect(user.calls == [.relaunch, .relaunchFailed])
        #expect(s.rootPrevious().isEmpty)
        #expect(engine.readRecord() == nil)
        #expect(s.workEntries() == ["lock", "previous"])
        #expect(s.journal?.state == .rolledBack)
        #expect(s.journal?.reason == .rolledBack)
        #expect(s.launcher.launches.last?.arguments == ["--update-failed", "v1.1.0"])
    }

    @Test func rootSwapArgumentsTakeOnlyThreeIntegers() {
        let good = RootSwapArguments(arguments: ["--root-swap", "501", "4242", "1700000000123456", "v1.2.3"])
        #expect(good?.mode == .prepare && good?.uid == 501 && good?.app.pid == 4242 && good?.expectedTag == "v1.2.3")
        #expect(good?.app.start == ProcessStart(seconds: 1_700_000_000, microseconds: 123_456))
        #expect(good?.words == ["--root-swap", "501", "4242", "1700000000123456", "v1.2.3"])
        #expect(good?.with(mode: .detached)?.words == ["--root-swap-detached", "501", "4242", "1700000000123456", "v1.2.3"])
        #expect(RootSwapArguments(arguments: ["--root-swap-detached", "501", "4242", "0", "v1.2.3-rc.1"])?.mode == .detached)
        let t = "v1.2.3"
        for bad in [[], ["--root-swap"], ["--root-swap", "501", "4242", "1"], ["--root-swap", "501", "4242", "1", t, "/tmp"],
                    ["--root-swap", "0", "4242", "1", t], ["--root-swap", "501", "0", "1", t], ["--root-swap", "-1", "4242", "1", t],
                    ["--root-swap", "+501", "4242", "1", t], ["--root-swap", "0501", "4242", "1", t], ["--root-swap", "501", "4242", "1e3", t],
                    ["--root-swap", "501 ", "4242", "1", t], ["--root-swap", "501", "2147483648", "1", t],
                    ["--root-swap", "501", "4242", "99999999999999999999999", t], ["--swap", "501", "4242", "1", t],
                    ["--root-swap", "/Users/x", "4242", "1", t], ["--root-swap", "501", "4242", "1", "/tmp"]] {
            #expect(RootSwapArguments(arguments: bad) == nil, "\(bad)")
        }
        // A malformed tag argument is refused.
        for tag in ["", "1.2.3", "v1.2", "v1.2.3;id", "v01.2.3", "v1.2.3-beta.1", "v1.2.3 ", "v1.2.3\n", "../v1.2.3"] {
            #expect(RootSwapArguments(arguments: ["--root-swap", "501", "4242", "1", tag]) == nil, "\(tag)")
        }
        let start = ProcessStart(seconds: 1_700_000_000, microseconds: 999_999)
        #expect(start.packedMicroseconds.map(ProcessStart.init(packedMicroseconds:)) == start)
        #expect(ProcessStart(seconds: UInt64.max, microseconds: 0).packedMicroseconds == nil)
    }

    /// A staged bundle under a symlink, under a folder others can write, or
    /// holding a symlink is refused before anything is renamed.
    @Test(arguments: ["missing", "symlinkedStaged", "symlinkedUpdateFolder", "groupWritableFolder", "symlinkInside",
                      "groupWritableInside"])
    func rootSwapRefusesAnUnsafeStagedBundle(_ shape: String) throws {
        let s = Scratch()
        s.makeWork()
        s.install(tag: "v1.0.0")
        let original = identity(s.target)
        let fm = FileManager.default
        let staged = s.paths.userStagedForRoot
        switch shape {
        case "missing":
            break
        case "symlinkedStaged":
            s.makeBundle(at: s.root + "/elsewhere.app", tag: "v1.1.0", behaviour: "handshake")
            try fm.createDirectory(atPath: s.paths.userStagedForRootDirectory, withIntermediateDirectories: true)
            try fm.createSymbolicLink(atPath: staged, withDestinationPath: s.root + "/elsewhere.app")
        case "symlinkedUpdateFolder":
            s.makeBundle(at: s.root + "/elsewhere/staged/k3sm.app", tag: "v1.1.0", behaviour: "handshake")
            try fm.removeItem(atPath: s.paths.privateDirectory)
            try fm.createSymbolicLink(atPath: s.paths.privateDirectory, withDestinationPath: s.root + "/elsewhere")
        case "groupWritableFolder":
            s.stageForRoot(tag: "v1.1.0")
            chmod(s.paths.userStagedForRootDirectory, 0o770)
        case "symlinkInside":
            s.stageForRoot(tag: "v1.1.0")
            try fm.createSymbolicLink(atPath: staged + "/Contents/Resources/link", withDestinationPath: "/etc/hosts")
        default:
            s.stageForRoot(tag: "v1.1.0")
            chmod(staged + "/Contents/Resources/behaviour", 0o664)
        }
        let spy = SpyRenamer()
        let user = UserSide(s)
        let engine = s.rootEngine(app: s.appProcess(exitingAfter: 0.2), userSide: user, renamer: spy)
        #expect(engine.prepare().map { _ in AppSwapExit.committed } == .failure(RootSwapRefusal(.stagedRefused)), "\(shape)")
        #expect(spy.count == 0)
        #expect(identity(s.target) == original)
        #expect(s.workEntries() == ["lock"])
        #expect(user.calls.isEmpty)
    }

    /// The copy's tree check: a setuid or setgid file is refused too. A
    /// copy made without root drops those bits, so this is checked on the
    /// tree directly.
    @Test func rootTreeRefusesSpecialBits() throws {
        let s = Scratch()
        s.stageForRoot(tag: "v1.1.0")
        let dirFD = try #require(FileOps.openDirectory(s.paths.userStagedForRootDirectory))
        defer { close(dirFD) }
        #expect(RootTree.isSafe(at: dirFD, SwapPaths.bundleName))
        let file = s.paths.userStagedForRoot + "/Contents/Resources/behaviour"
        for mode: mode_t in [0o4644, 0o2644, 0o664, 0o646] {
            #expect(chmod(file, mode) == 0)
            #expect(!RootTree.isSafe(at: dirFD, SwapPaths.bundleName), "mode \(String(mode, radix: 8))")
        }
        #expect(chmod(file, 0o644) == 0)
        #expect(mkfifo(s.paths.userStagedForRoot + "/Contents/fifo", 0o600) == 0)
        #expect(!RootTree.isSafe(at: dirFD, SwapPaths.bundleName))
    }

    @Test func rootSwapWorkFolderMustBeRootsOwn() throws {
        let s = Scratch()
        s.install(tag: "v1.0.0")
        s.stageForRoot(tag: "v1.1.0")
        let app = s.appProcess(exitingAfter: 0.2)
        s.makeWork(mode: 0o755)
        #expect(s.rootEngine(app: app, userSide: UserSide(s)).prepare().map { _ in 0 } == .failure(RootSwapRefusal(.refusedPath)))
        run("/bin/rm", ["-rf", s.work])
        try FileManager.default.createDirectory(atPath: s.root + "/realwork", withIntermediateDirectories: true)
        chmod(s.root + "/realwork", 0o700)
        try FileManager.default.createSymbolicLink(atPath: s.work, withDestinationPath: s.root + "/realwork")
        #expect(s.rootEngine(app: app, userSide: UserSide(s)).prepare().map { _ in 0 } == .failure(RootSwapRefusal(.refusedPath)))
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: s.root + "/realwork")) ?? []).isEmpty)
    }

    /// The floor in the root-owned record only rises: each swap writes the
    /// outgoing release, and a floor above the installed release refuses the
    /// swap (`rootSwapRefusesAnInstalledReleaseBelowTheFloor`).
    @Test func rootRecordFloorOnlyRises() throws {
        let s = Scratch()
        s.makeWork()
        s.install(tag: "v1.0.0")
        for (index, tag) in ["v1.1.0", "v1.2.0"].enumerated() {
            s.stageForRoot(tag: tag)
            let app = s.appProcess(exitingAfter: 0.2)
            s.requestRoot(expectedTag: tag, app: app, outgoing: index == 0 ? "v1.0.0" : "v1.1.0")
            let engine = s.rootEngine(app: app, userSide: UserSide(s), expectedTag: tag)
            #expect(s.rootSwap(engine) == .committed)
            #expect(engine.readRecord()?.floorTag == (index == 0 ? "v1.0.0" : "v1.1.0"))
        }
        let engine = s.rootEngine(app: s.appProcess(exitingAfter: 0), userSide: UserSide(s))
        #expect(engine.readRecord()?.tag == "v1.1.0")
        #expect(s.rootPrevious() == ["k3sm-v1.1.0.previous"])
        // The floor never falls back below a floor already in force.
        let installed = InstalledRelease(tag: "v1.0.0", version: SemanticVersion("v1.0.0")!)
        let prior = try #require(engine.readRecord())
        #expect(SwapEngine.floor(after: prior, keeping: installed) == "v1.1.0")
    }

    /// Root reads nothing from the user's request file: a request naming
    /// another target changes nothing about what root swaps.
    @Test func rootSwapIgnoresTheRequestFile() throws {
        let s = Scratch()
        s.makeWork()
        s.install(tag: "v1.0.0")
        let bait = s.root + "/Applications-bait/k3sm.app"
        s.makeBundle(at: bait, tag: "v1.0.0", behaviour: "handshake")
        let baitIdentity = identity(bait)
        s.stageForRoot(tag: "v1.1.0")
        let app = s.appProcess(exitingAfter: 0.2)
        s.requestRoot(expectedTag: "v9.9.9", app: app, target: bait)
        let user = UserSide(s, fixed: [.relaunch: 0])
        #expect(s.rootSwap(s.rootEngine(app: app, userSide: user)) == .committed)
        #expect(s.tag(at: s.target) == "v1.1.0")
        #expect(identity(bait) == baitIdentity)
        #expect(s.tag(at: bait) == "v1.0.0")
    }

    /// The lock is held from the verifying half to the end of the detached
    /// half, and only the work folder's own lock is adopted.
    @Test func rootSwapLockIsHeldAcrossTheHandOff() throws {
        let s = Scratch()
        s.makeWork()
        s.install(tag: "v1.0.0")
        s.stageForRoot(tag: "v1.1.0")
        let app = s.appProcess(exitingAfter: 30)
        let engine = s.rootEngine(app: app, userSide: UserSide(s))
        let lock = try engine.prepare().get()
        #expect(engine.prepare().map { _ in 0 } == .failure(RootSwapRefusal(.busy)))
        let passed = dup(lock.fd)
        let adopted = try #require(engine.adoptLock(fd: passed))
        // The verifying half hands off without unlocking: the lock stays.
        lock.handOff()
        #expect(engine.prepare().map { _ in 0 } == .failure(RootSwapRefusal(.busy)))
        let other = open(s.paths.requestPath, O_RDONLY)
        #expect(engine.adoptLock(fd: other) == nil)
        close(other)
        adopted.release()
    }

    /// An app that never quits leaves everything as it was, and nothing is
    /// relaunched.
    @Test func rootSwapAbandonsWhenTheAppNeverQuits() throws {
        let s = Scratch()
        s.makeWork()
        s.install(tag: "v1.0.0")
        let original = identity(s.target)
        s.stageForRoot(tag: "v1.1.0")
        let app = s.appProcess(exitingAfter: 30)
        let user = UserSide(s)
        let spy = SpyRenamer()
        let short = SwapTimeouts(appExit: .milliseconds(500), handshake: .seconds(1), terminate: .seconds(1), poll: .milliseconds(50))
        #expect(s.rootSwap(s.rootEngine(app: app, userSide: user, renamer: spy, timeouts: short)) == .abandoned)
        #expect(spy.count == 0)
        #expect(identity(s.target) == original)
        #expect(user.calls.isEmpty)
        #expect(s.workEntries() == ["lock"])
    }

    /// A detached half whose work folder is gone after the app quit, or
    /// which could not take over the lock, still brings the app back and
    /// renames nothing.
    @Test func detachedHalfRelaunchesTheAppOnEveryStop() throws {
        let s = Scratch()
        s.makeWork()
        s.install(tag: "v1.0.0")
        s.stageForRoot(tag: "v1.1.0")
        let app = s.appProcess(exitingAfter: 0.2)
        let user = UserSide(s, fixed: [.relaunchFailed: 0])
        let spy = SpyRenamer()
        let engine = s.rootEngine(app: app, userSide: user, renamer: spy)
        let lock = try engine.prepare().get()
        chmod(s.work, 0o755)
        #expect(engine.complete(lock: lock) == .refusedPath)
        #expect(spy.count == 0)
        #expect(user.calls == [.relaunchFailed])
        #expect(s.tag(at: s.target) == "v1.0.0")

        let other = UserSide(s, fixed: [.relaunchFailed: 0])
        #expect(s.rootEngine(app: s.appProcess(exitingAfter: 0.2), userSide: other).relaunchAfterExit() == .busy)
        #expect(other.calls == [.relaunchFailed])
    }

    /// Root is bound to the tag the app verified: a different, newer bundle
    /// signed by the team in the staged place is refused.
    @Test func rootSwapRefusesAnotherNewerBundle() throws {
        let s = Scratch()
        s.makeWork()
        s.install(tag: "v1.0.0")
        let original = identity(s.target)
        s.stageForRoot(tag: "v1.2.0")
        let spy = SpyRenamer()
        let user = UserSide(s)
        let engine = s.rootEngine(app: s.appProcess(exitingAfter: 0.2), userSide: user, renamer: spy, expectedTag: "v1.1.0")
        #expect(engine.prepare().map { _ in 0 } == .failure(RootSwapRefusal(.verificationFailed)))
        #expect(spy.count == 0)
        #expect(identity(s.target) == original)
        #expect(user.calls.isEmpty)
    }

    /// An installed release below the floor of the root-owned record was not
    /// put there by this path, so root replaces nothing.
    @Test func rootSwapRefusesAnInstalledReleaseBelowTheFloor() throws {
        let s = Scratch()
        s.makeWork()
        s.install(tag: "v1.0.0")
        let original = identity(s.target)
        s.stageForRoot(tag: "v1.6.0")
        let hash = String(repeating: "ab", count: 20)
        let record = PreviousRecord(name: "k3sm-v1.5.0.previous", tag: "v1.5.0", cdhash: Data(repeating: 0xab, count: 20),
                                    installedTag: "v1.5.1", installedCDHash: Data(repeating: 0xab, count: 20), floorTag: "v1.5.0")
        #expect(record.cdhash == hash && record.isValid)
        let dirFD = try #require(FileOps.openDirectory(s.work))
        #expect(FileOps.replaceDurably(dirFD: dirFD, name: AppSwapPaths.recordName, data: try JSONEncoder().encode(record), mode: 0o600))
        close(dirFD)
        let spy = SpyRenamer()
        let engine = s.rootEngine(app: s.appProcess(exitingAfter: 0.2), userSide: UserSide(s), renamer: spy, expectedTag: "v1.6.0")
        #expect(engine.readRecord()?.floorTag == "v1.5.0")
        #expect(engine.prepare().map { _ in 0 } == .failure(RootSwapRefusal(.verificationFailed)))
        #expect(spy.count == 0)
        #expect(identity(s.target) == original)
        let installed = try #require(InstalledRelease.read(bundleAt: s.target))
        #expect(!RootSwapEngine.atOrAboveFloor(installed, record: record))
        #expect(RootSwapEngine.atOrAboveFloor(installed, record: nil))
    }

    /// A record that cannot be written after a swap that stood is in the
    /// status, not only in the log.
    @Test func rootSwapReportsARecordItCouldNotWrite() throws {
        let s = Scratch()
        s.makeWork()
        s.install(tag: "v1.0.0")
        s.stageForRoot(tag: "v1.1.0")
        // A folder where the record goes: the durable rename over it fails.
        try FileManager.default.createDirectory(atPath: s.work + "/" + AppSwapPaths.recordName + "/x", withIntermediateDirectories: true)
        let app = s.appProcess(exitingAfter: 0.2)
        s.requestRoot(expectedTag: "v1.1.0", app: app)
        #expect(s.rootSwap(s.rootEngine(app: app, userSide: UserSide(s))) == .committedWithoutRecord)
        #expect(s.tag(at: s.target) == "v1.1.0")
        #expect(s.rootPrevious() == ["k3sm-v1.0.0.previous"])
    }

    /// A run killed between its swap and its move to the previous folder
    /// leaves the old bundle only in the stage; the next run keeps it as the
    /// previous copy instead of sweeping it away.
    @Test func rootSwapKeepsTheOldBundleAfterAKillBetweenSwapAndMove() throws {
        let s = Scratch()
        s.makeWork()
        s.install(tag: "v1.0.0")
        let original = identity(s.target)
        s.stageForRoot(tag: "v1.1.0")
        let app = s.appProcess(exitingAfter: 0.2)
        let user = UserSide(s)
        let killed = s.rootEngine(app: app, userSide: user, hooks: RootSwapHooks(killAfterSwap: { true }))
        #expect(s.rootSwap(killed) == .abandoned)
        #expect(s.tag(at: s.target) == "v1.1.0")
        #expect(identity(s.rootLayout.stagedBundle) == original)
        #expect(s.rootPrevious().isEmpty)
        #expect(user.calls.isEmpty)

        // The next update's verifying half.
        s.stageForRoot(tag: "v1.2.0")
        let next = s.rootEngine(app: s.appProcess(exitingAfter: 30), userSide: UserSide(s), expectedTag: "v1.2.0")
        let lock = try next.prepare().get()
        defer { lock.release() }
        #expect(s.rootPrevious() == ["k3sm-v1.0.0.previous"])
        #expect(identity(s.rootLayout.previousDirectory + "/k3sm-v1.0.0.previous") == original)
        #expect(s.tag(at: s.rootLayout.stagedBundle) == "v1.2.0")

        // An un-swapped incoming copy, newer than the installed bundle, is
        // what a sweep deletes.
        let workFD = try #require(FileOps.openDirectory(s.work))
        defer { close(workFD) }
        let appsFD = try #require(FileOps.openDirectory(s.applications))
        defer { close(appsFD) }
        #expect(next.sweepStage(workFD, appsFD: appsFD))
        #expect(!FileManager.default.fileExists(atPath: s.rootLayout.stagePath))
        #expect(s.rootPrevious() == ["k3sm-v1.0.0.previous"])
    }

    /// A rename macOS refuses as root is its own status, and the errno is
    /// mapped, not lost; nothing is replaced and the app comes back.
    @Test func rootRenameRefusedBySystemIsItsOwnStatus() throws {
        #expect(RootSwapEngine.renameRefusal(errno: EPERM) == .refusedBySystem)
        #expect(RootSwapEngine.renameRefusal(errno: EACCES) == .refusedBySystem)
        #expect(RootSwapEngine.renameRefusal(errno: EXDEV) == .unsupportedVolume)
        #expect(RootSwapEngine.renameRefusal(errno: ENOTSUP) == .unsupportedVolume)
        #expect(RootSwapEngine.renameRefusal(errno: EIO) == .abandoned)
        let s = Scratch()
        s.makeWork()
        s.install(tag: "v1.0.0")
        let original = identity(s.target)
        s.stageForRoot(tag: "v1.1.0")
        let user = UserSide(s, fixed: [.relaunchFailed: 0])
        let engine = s.rootEngine(app: s.appProcess(exitingAfter: 0.2), userSide: user, renamer: SpyRenamer(swapErrno: EPERM))
        #expect(s.rootSwap(engine) == .refusedBySystem)
        #expect(identity(s.target) == original)
        #expect(user.calls == [.relaunchFailed])
        #expect(s.workEntries() == ["lock", "previous"])
    }

    /// When the user-side launch cannot run at all (launchctl or sudo
    /// failed, or a timeout), it is tried once more, and then the verified
    /// update is left in place with its record rather than rolled back.
    @Test func rootSwapLeavesAVerifiedUpdateWhenTheUserSideCannotRun() throws {
        let s = Scratch()
        s.makeWork()
        s.install(tag: "v1.0.0")
        s.stageForRoot(tag: "v1.1.0")
        let app = s.appProcess(exitingAfter: 0.2)
        let user = UserSide(s, fixed: [.relaunch: Int32?.none])
        let engine = s.rootEngine(app: app, userSide: user)
        #expect(s.rootSwap(engine) == .leftUnconfirmed)
        #expect(user.calls == [.relaunch, .relaunch])
        #expect(s.tag(at: s.target) == "v1.1.0")
        #expect(s.rootPrevious() == ["k3sm-v1.0.0.previous"])
        #expect(engine.readRecord()?.tag == "v1.0.0")
    }

    /// The lock reaches the detached half as descriptor 3 even when it is
    /// descriptor 3 already in the parent.
    @Test func detachedHalfGetsTheLockEvenOnDescriptorThree() throws {
        let s = Scratch()
        let marker = s.root + "/marker"
        let lockFD = open(s.root + "/lockfile", O_RDWR | O_CREAT, 0o600)
        defer { close(lockFD) }
        var lock = stat()
        #expect(fstat(lockFD, &lock) == 0)
        // Put the lock on descriptor 3 for the spawn, and put back whatever
        // this process had there.
        let saved = fcntl(3, F_DUPFD_CLOEXEC, 10)
        #expect(dup2(lockFD, 3) == 3)
        let started = RootSwapSpawner.spawnDetached(
            executable: "/bin/sh",
            arguments: ["-c", "/usr/bin/stat -L -f %i /dev/fd/3 > '\(marker).tmp'; /bin/mv '\(marker).tmp' '\(marker)'"],
            lockFD: 3)
        if saved >= 0 {
            dup2(saved, 3)
            close(saved)
        } else {
            close(3)
        }
        #expect(started)
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: marker), Date() < deadline { usleep(50_000) }
        #expect(try String(contentsOfFile: marker, encoding: .utf8) == "\(lock.st_ino)\n")
    }

    /// The user side runs through `launchctl asuser` and `sudo -u '#uid'`,
    /// so root never executes the user's copy as root, and only its two
    /// user-side modes.
    @Test func consoleSessionRunnerDropsToTheUser() {
        let path = "/Users/a/Library/Application Support/io.k3sm.app/update/k3sm-app-update"
        #expect(ConsoleSessionRunner.launchctl == "/bin/launchctl")
        #expect(ConsoleSessionRunner.arguments(uid: 501, helperPath: path, mode: .relaunch)
            == ["asuser", "501", "/usr/bin/sudo", "-n", "-u", "#501", "--", path, "--relaunch"])
        #expect(ConsoleSessionRunner(uid: 501, helperPath: path).run(.swap) == nil)
        #expect(ConsoleSessionRunner(uid: 501, helperPath: path).run(.goBack) == nil)
        #expect(ConsoleSessionRunner(uid: 0, helperPath: path).run(.relaunch) == nil)
    }

    /// The detached half gets its own session, no standard stream but
    /// /dev/null, and no descriptor but the lock on 3.
    @Test func detachedHalfGetsOnlyTheLock() throws {
        let s = Scratch()
        let marker = s.root + "/marker"
        let probe = s.root + "/probe"
        let other = open(s.root + "/held", O_RDWR | O_CREAT, 0o600)
        defer { close(other) }
        let lockFD = open(s.root + "/lockfile", O_RDWR | O_CREAT, 0o600)
        defer { close(lockFD) }
        var held = stat(), lock = stat()
        #expect(fstat(other, &held) == 0 && fstat(lockFD, &lock) == 0)
        // Every descriptor below 10 the child holds, by inode; then whether
        // it leads its own process group.
        let script = """
            for n in 0 1 2 3 4 5 6 7 8 9; do
            \tif [ -e /dev/fd/$n ]; then echo "$n $(/usr/bin/stat -L -f %i /dev/fd/$n)"; fi
            done > '\(probe)'
            pgid=$(/bin/ps -o pgid= -p $$ | /usr/bin/tr -d ' ')
            if [ "$pgid" = "$$" ]; then echo leader >> '\(probe)'; fi
            /bin/mv '\(probe)' '\(marker)'
            """
        #expect(RootSwapSpawner.spawnDetached(executable: "/bin/sh", arguments: ["-c", script], lockFD: lockFD))
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: marker), Date() < deadline { usleep(50_000) }
        let lines = try String(contentsOfFile: marker, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(lines.contains("3 \(lock.st_ino)"))
        #expect(!lines.contains { $0.hasSuffix(" \(held.st_ino)") })
        #expect(lines.contains("leader"))
        let null = try FileManager.default.attributesOfItem(atPath: "/dev/null")[.systemFileNumber] as? Int
        // Standard output is the probe's own redirect here; the other two
        // streams are /dev/null.
        for fd in [0, 2] { #expect(lines.contains("\(fd) \(null ?? -1)")) }
        #expect(lines.filter { $0 != "leader" }.count == 4)
    }

    /// The root mode runs only from a root-owned 0500 copy directly in the
    /// work folder.
    @Test func rootModeRunsOnlyFromItsOwnCopy() throws {
        let s = Scratch()
        s.makeWork()
        let copy = s.work + "/helper.ABCDEFGH"
        FileManager.default.createFile(atPath: copy, contents: Data("x".utf8))
        chmod(copy, 0o500)
        #expect(RootSwapCopy.isTrusted(path: copy, workDirectory: s.work, owner: getuid()))
        #expect(!RootSwapCopy.isTrusted(path: copy, workDirectory: s.work, owner: 0))
        chmod(copy, 0o700)
        #expect(!RootSwapCopy.isTrusted(path: copy, workDirectory: s.work, owner: getuid()))
        chmod(copy, 0o500)
        #expect(!RootSwapCopy.isTrusted(path: s.work + "/helper.", workDirectory: s.work, owner: getuid()))
        #expect(!RootSwapCopy.isTrusted(path: s.paths.helperCopyPath, workDirectory: s.work, owner: getuid()))
        #expect(link(copy, s.work + "/helper.SECONDLK") == 0)
        #expect(!RootSwapCopy.isTrusted(path: copy, workDirectory: s.work, owner: getuid()))
    }

    /// The app's side of the root path writes a `rootUpdate` request for
    /// the first allowed target with no staging name, installs the user's
    /// helper copy, starts nothing, and hands back only three integers.
    @Test func beginAdministratorUpdateWritesARootRequest() throws {
        let s = Scratch()
        s.install(tag: "v1.0.0")
        let bundled = s.root + "/k3sm-app-update"
        try FileManager.default.copyItem(atPath: FixtureBinaries.app, toPath: bundled)
        #expect(run("/usr/bin/codesign", ["--force", "--sign", "-", "--timestamp=none", "--identifier", "io.k3sm.test.fixture", bundled]) == 0)
        let client = SwapClient(paths: s.paths, helperRequirement: fixtureRequirement, bundledHelper: bundled)
        // Nothing staged at the fixed path: refused before anything is written.
        #expect(throws: SwapClient.StartError.request) { try client.beginAdministratorUpdate(expectedTag: "v1.1.0") }
        #expect(s.journal == nil)
        s.stageForRoot(tag: "v1.1.0")
        #expect(throws: SwapClient.StartError.request) { try client.beginAdministratorUpdate(expectedTag: "v1.1.0;id") }

        let ticket = try client.beginAdministratorUpdate(expectedTag: "v1.1.0")

        #expect(ticket.uid == UInt32(getuid()))
        #expect(ticket.appPid == getpid())
        #expect(ProcessIdentity.current()?.start.packedMicroseconds == ticket.appStart)
        let journal = try #require(s.journal)
        #expect(journal.request.mode == .rootUpdate && journal.state == .staged)
        #expect(journal.request.target == s.target && journal.request.stagedName.isEmpty)
        #expect(journal.request.expectedTag == "v1.1.0" && journal.outgoingTag == "v1.0.0")
        try HelperSpawner(paths: s.paths, requirement: fixtureRequirement).verifyInstalledCopy(bundled: bundled)
        // Nothing was renamed.
        #expect(s.tag(at: s.target) == "v1.0.0")
        #expect(s.paths.userStagedForRoot == s.paths.privateDirectory + "/staged/k3sm.app")
        // A user-mode swap refuses a root request.
        #expect(s.engine().swap() == .refusedRequest)
    }

    /// A `rootUpdate` journal is only ever closed by the reconcile, never
    /// renamed from, and closing it keeps the user's own previous record.
    @Test func reconcileClosesARootJournal() throws {
        var journal = SwapJournal(request: SwapRequest(mode: .rootUpdate, target: "/Applications/k3sm.app", stagedName: "",
                                                       expectedTag: "v1.1.0", token: SwapRequest.newToken(),
                                                       app: ProcessIdentity(pid: 1, start: ProcessStart(seconds: 1, microseconds: 0))))
        #expect(journal.namesAreValid)
        let incoming = ReconcileFacts(lockHeld: false, atTarget: nil, runningTag: "v1.1.0", runningSelfCheck: true, outgoingVerifies: false)
        let other = ReconcileFacts(lockHeld: false, atTarget: nil, runningTag: "v1.0.0", runningSelfCheck: true, outgoingVerifies: true)
        let held = ReconcileFacts(lockHeld: true, atTarget: nil, runningTag: "v1.1.0", runningSelfCheck: true, outgoingVerifies: false)
        for state in [JournalState.staged, .launched] {
            journal.state = state
            #expect(SwapReconciler.decide(journal: journal, facts: incoming) == .commit)
            #expect(SwapReconciler.decide(journal: journal, facts: other) == .discard)
            #expect(SwapReconciler.decide(journal: journal, facts: held) == .nothing)
        }
        for state in [JournalState.committed, .rolledBack] {
            journal.state = state
            #expect(SwapReconciler.decide(journal: journal, facts: incoming) == .nothing)
        }
        journal.request.stagedName = SwapPaths.newStagingName()
        #expect(!journal.namesAreValid)

        let s = Scratch()
        s.updateOnce()
        let record = try #require(JournalStore(paths: s.paths).readRecord())
        var root = s.requestRoot(expectedTag: "v1.2.0", app: s.appProcess(exitingAfter: 0))
        root.state = .launched
        try JournalStore(paths: s.paths).write(root)
        let reconciler = SwapReconciler(paths: s.paths, verifier: s.verifier, currentApp: nil, spawnGoBack: { false })
        #expect(reconciler.reconcile(runningTag: "v1.1.0", runningSelfCheck: { true }) == .carryOn)
        #expect(s.journal?.state == .rolledBack)
        #expect(JournalStore(paths: s.paths).readRecord() == record)
        #expect(s.tag(at: s.target) == "v1.1.0")
    }
}
