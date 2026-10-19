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
import K3smSwap
import Testing

/// The swap engine against real fixture bundles, real renames, real
/// processes and real code signatures. Only LaunchServices is replaced (by
/// `FixtureLauncher`), and only where a test says so the renamer.
@Suite("swap engine", .serialized)
struct SwapEngineTests {
    @Test func swapSuccessKeepsPreviousCopy() throws {
        let s = Scratch()
        s.install(tag: "v1.0.0")
        let oldCDHash = try #require(StaticCodeVerifier.cdhash(path: s.target, requirement: fixtureRequirement))
        let name = s.stage(tag: "v1.1.0")
        let staged = try #require(StaticCodeVerifier.cdhash(path: SwapPaths.stagingDirectory(target: s.target, name: name) + "/k3sm.app",
                                                          requirement: fixtureRequirement))
        s.request(stagedName: name, expectedTag: "v1.1.0", app: s.appProcess(exitingAfter: 0.2))

        #expect(s.engine().swap() == .committed)

        #expect(s.tag(at: s.target) == "v1.1.0")
        #expect(StaticCodeVerifier.cdhash(path: s.target, requirement: fixtureRequirement) == staged)
        let previous = s.paths.previousDirectory + "/k3sm-v1.0.0.previous"
        #expect(s.previousEntries() == ["k3sm-v1.0.0.previous"])
        #expect(!previous.hasSuffix(".app"))
        #expect(!previous.hasPrefix(s.applications))
        #expect(StaticCodeVerifier.cdhash(path: previous, requirement: fixtureRequirement) == oldCDHash)
        #expect(s.journal?.state == .committed)
        #expect(s.stagingEntries().isEmpty)
        #expect(s.appBundles(in: s.applications) == ["k3sm.app"])
        #expect(s.launcher.launches == [.init(path: s.target, arguments: ["--updated-from", "v1.0.0", "--handshake"])])
    }

    @Test func missingHandshakeRollsBack() throws {
        let s = Scratch()
        s.install(tag: "v1.0.0")
        let original = try #require(identity(s.target))
        let name = s.stage(tag: "v1.1.0", behaviour: "silent")
        s.request(stagedName: name, expectedTag: "v1.1.0", app: s.appProcess(exitingAfter: 0.2))

        #expect(s.engine(timeouts: .silent).swap() == .rolledBack)

        let launched = try #require(s.journal?.launched)
        #expect(!launched.isRunning)
        #expect(identity(s.target) == original)
        #expect(s.tag(at: s.target) == "v1.0.0")
        #expect(s.journal?.state == .rolledBack)
        #expect(s.journal?.reason == .rolledBack)
        #expect(s.launcher.launches.last == .init(path: s.target, arguments: ["--update-failed", "v1.1.0"]))
        #expect(s.previousEntries().isEmpty)
        #expect(s.stagingEntries().isEmpty)
        #expect(s.appBundles(in: s.applications) == ["k3sm.app"])
    }

    @Test func earlyExitRollsBack() throws {
        let s = Scratch()
        s.install(tag: "v1.0.0")
        let original = try #require(identity(s.target))
        let name = s.stage(tag: "v1.1.0", behaviour: "exit-early")
        s.request(stagedName: name, expectedTag: "v1.1.0", app: s.appProcess(exitingAfter: 0.2))
        // A handshake bound far beyond the run: only NOTE_EXIT can end it early.
        let timeouts = SwapTimeouts(appExit: .seconds(5), handshake: .seconds(60), terminate: .seconds(2), poll: .milliseconds(50))
        let start = ContinuousClock.now

        #expect(s.engine(timeouts: timeouts).swap() == .rolledBack)

        #expect(ContinuousClock.now - start < .seconds(20))
        #expect(identity(s.target) == original)
        #expect(s.journal?.state == .rolledBack)
        #expect(s.launcher.launches.last?.arguments == ["--update-failed", "v1.1.0"])
    }

    @Test func parentNeverExitsAbandonsKeepsStaged() throws {
        let s = Scratch()
        s.install(tag: "v1.0.0")
        let original = try #require(identity(s.target))
        let name = s.stage(tag: "v1.1.0")
        s.request(stagedName: name, expectedTag: "v1.1.0", app: s.appProcess(exitingAfter: 30))
        let spy = SpyRenamer()
        let timeouts = SwapTimeouts(appExit: .milliseconds(500), handshake: .seconds(5), terminate: .seconds(1), poll: .milliseconds(50))

        #expect(s.engine(renamer: spy, timeouts: timeouts).swap() == .abandoned)

        #expect(spy.count == 0)
        #expect(identity(s.target) == original)
        #expect(s.stagingEntries() == [name])
        #expect(s.tag(at: SwapPaths.stagingDirectory(target: s.target, name: name) + "/k3sm.app") == "v1.1.0")
        #expect(s.journal?.state == .verified)
        #expect(s.launcher.launches.isEmpty)
    }

    /// KillPoint is one place a helper can die.
    struct KillPoint: Sendable, CustomTestStringConvertible {
        let state: JournalState
        let phase: SwapFaultPhase
        var testDescription: String { "\(state) \(phase)" }
        /// The rollback points need a new bundle that never answers.
        var silent: Bool { state == .rolledBack }
        /// The release at the target once the reconcile ran: the new one
        /// once the swap act happened and was not being undone.
        var settledTag: String {
            switch (state, phase) {
            case (.verified, _), (.swapped, .written), (.rolledBack, _): return "v1.0.0"
            default: return "v1.1.0"
            }
        }
    }

    static let killPoints: [KillPoint] = [JournalState.verified, .swapped, .launched, .committed, .rolledBack].flatMap { state in
        SwapFaultPhase.allCases.map { KillPoint(state: state, phase: $0) }
    }

    @Test(arguments: killPoints)
    func killAtEveryJournalStepReconciles(_ point: KillPoint) throws {
        let s = Scratch()
        s.install(tag: "v1.0.0")
        let name = s.stage(tag: "v1.1.0", behaviour: point.silent ? "silent" : "handshake")
        s.request(stagedName: name, expectedTag: "v1.1.0", app: s.appProcess(exitingAfter: 0.2))
        let faults = SwapFaults { state, phase in state == point.state && phase == point.phase }
        _ = s.engine(timeouts: point.silent ? .silent : .test, faults: faults).swap()
        let killed = try #require(s.journal)
        #expect(killed.state == point.state)

        // The next app launch: the app at the target is the one running.
        let exited = s.appProcess(exitingAfter: 0)
        while exited.isRunning { usleep(10_000) }
        let goBackEngine = s.engine()
        let reconciler = SwapReconciler(paths: s.paths, verifier: s.verifier, currentApp: exited,
                                        spawnGoBack: { goBackEngine.goBack() == .committed })
        let running = s.tag(at: s.target)
        let selfCheck = (try? s.verifier.verify(bundleAt: s.target, requireTag: true)) != nil
        _ = reconciler.reconcile(runningTag: running, runningSelfCheck: { selfCheck })

        #expect((try? s.verifier.verify(bundleAt: s.target, requireTag: true)) != nil)
        #expect(s.tag(at: s.target) == point.settledTag)
        #expect(s.journal?.state.isTerminal == true)
        #expect(s.appBundles(in: s.applications) == ["k3sm.app"])
        #expect(s.appBundles(in: s.paths.previousDirectory).isEmpty)
        // A swap that stood keeps exactly the old bundle; one that did not
        // keeps no copy of the new one.
        switch s.journal?.state {
        case .committed? where s.tag(at: s.target) == "v1.1.0":
            #expect(s.previousEntries() == ["k3sm-v1.0.0.previous"])
        default:
            #expect(s.tag(at: s.target) == "v1.0.0")
            #expect(!s.previousEntries().contains("k3sm-v1.0.0.previous"))
        }
    }

    @Test func requestNamingAnotherDirectoryRefused() throws {
        let cases: [(String, (Scratch, String) -> Void)] = [
            ("target outside the roots", { s, name in
                let elsewhere = s.root + "/Elsewhere"
                try? FileManager.default.createDirectory(atPath: elsewhere, withIntermediateDirectories: true)
                s.makeBundle(at: elsewhere + "/k3sm.app", tag: "v1.0.0", behaviour: "handshake")
                s.request(stagedName: name, expectedTag: "v1.1.0", app: s.appProcess(exitingAfter: 0.1), target: elsewhere + "/k3sm.app")
            }),
            ("symlinked target", { s, name in
                let real = s.root + "/real.app"
                try? FileManager.default.moveItem(atPath: s.target, toPath: real)
                try? FileManager.default.createSymbolicLink(atPath: s.target, withDestinationPath: real)
                s.request(stagedName: name, expectedTag: "v1.1.0", app: s.appProcess(exitingAfter: 0.1))
            }),
            ("bad staging name", { s, _ in
                s.request(stagedName: "../staging", expectedTag: "v1.1.0", app: s.appProcess(exitingAfter: 0.1))
            }),
            ("staged copy in another directory", { s, name in
                let dir = SwapPaths.stagingDirectory(target: s.target, name: name)
                let other = s.root + "/other-staging"
                try? FileManager.default.moveItem(atPath: dir, toPath: other)
                try? FileManager.default.createSymbolicLink(atPath: dir, withDestinationPath: other)
                s.request(stagedName: name, expectedTag: "v1.1.0", app: s.appProcess(exitingAfter: 0.1))
            }),
            ("staging name naming nothing", { s, _ in
                s.request(stagedName: SwapPaths.newStagingName(), expectedTag: "v1.1.0", app: s.appProcess(exitingAfter: 0.1))
            }),
            ("request not 0600", { s, name in
                s.request(stagedName: name, expectedTag: "v1.1.0", app: s.appProcess(exitingAfter: 0.1))
                chmod(s.paths.requestPath, 0o644)
            }),
            ("request a symlink", { s, name in
                s.request(stagedName: name, expectedTag: "v1.1.0", app: s.appProcess(exitingAfter: 0.1))
                let moved = s.root + "/request.json"
                rename(s.paths.requestPath, moved)
                symlink(moved, s.paths.requestPath)
            }),
            ("private directory not 0700", { s, name in
                s.request(stagedName: name, expectedTag: "v1.1.0", app: s.appProcess(exitingAfter: 0.1))
                chmod(s.paths.privateDirectory, 0o755)
            }),
        ]
        for (label, arrange) in cases {
            let s = Scratch()
            s.install(tag: "v1.0.0")
            let original = identity(s.target)
            let name = s.stage(tag: "v1.1.0")
            arrange(s, name)
            let spy = SpyRenamer()
            let exit = s.engine(renamer: spy).swap()
            #expect(exit == .refusedRequest, "\(label)")
            #expect(spy.count == 0, "\(label)")
            #expect(s.launcher.launches.isEmpty, "\(label)")
            if label != "symlinked target" { #expect(identity(s.target) == original, "\(label)") }
        }
    }

    @Test func oldExecutableInodeUnchanged() throws {
        let s = Scratch()
        s.install(tag: "v1.0.0")
        let exe = "/Contents/MacOS/k3sm-app"
        let before = try #require(identity(s.target + exe))
        let bytes = try Data(contentsOf: URL(fileURLWithPath: s.target + exe))
        let name = s.stage(tag: "v1.1.0")
        s.request(stagedName: name, expectedTag: "v1.1.0", app: s.appProcess(exitingAfter: 0.2))

        #expect(s.engine().swap() == .committed)

        let kept = s.paths.previousDirectory + "/k3sm-v1.0.0.previous" + exe
        #expect(identity(kept) == before)
        #expect(try Data(contentsOf: URL(fileURLWithPath: kept)) == bytes)
        #expect(identity(s.target + exe) != before)
    }

    @Test func renameErrnoOutcomes() throws {
        let cases: [(Int32, SwapExit, RenameOutcome)] = [
            (ENOTSUP, .unsupportedVolume, .unsupportedVolume),
            (EPERM, .needsAdministrator, .needsAdministrator),
            (EACCES, .needsAdministrator, .needsAdministrator),
            (EROFS, .readOnlyVolume, .readOnlyVolume),
            (EIO, .abandoned, .failed(EIO)),
            (ENOENT, .abandoned, .failed(ENOENT)),
        ]
        for (code, exit, outcome) in cases {
            #expect(RenameOutcome(errno: code) == outcome)
            let s = Scratch()
            s.install(tag: "v1.0.0")
            let original = identity(s.target)
            let name = s.stage(tag: "v1.1.0")
            s.request(stagedName: name, expectedTag: "v1.1.0", app: s.appProcess(exitingAfter: 0.2))
            #expect(s.engine(renamer: SpyRenamer(swapErrno: code)).swap() == exit, "errno \(code)")
            #expect(identity(s.target) == original, "errno \(code)")
            #expect(s.journal?.state == .verified, "errno \(code)")
            #expect(s.journal?.reason == exit, "errno \(code)")
            #expect(s.stagingEntries() == [name], "errno \(code)")
            #expect(s.launcher.launches == [.init(path: s.target, arguments: ["--update-failed", "v1.1.0"])], "errno \(code)")
        }
        #expect(RenameOutcome(errno: EXDEV) == .crossDevice)
        #expect(RenameOutcome(errno: ENOTSUP).message == "Move k3sm.app to Applications on the startup disk")
    }

    @Test func exdevCopiesOntoTargetVolume() throws {
        let s = Scratch()
        s.install(tag: "v1.0.0")
        // The staging directory is the mount point of a separate APFS volume,
        // so the swap fails with EXDEV.
        let image = s.root + "/staging.dmg"
        #expect(run("/usr/bin/hdiutil", ["create", "-quiet", "-size", "40m", "-fs", "APFS", "-volname", "k3smswap", image]) == 0)
        let name = SwapPaths.newStagingName()
        let mount = SwapPaths.stagingDirectory(target: s.target, name: name)
        try FileManager.default.createDirectory(atPath: mount, withIntermediateDirectories: true)
        #expect(run("/usr/bin/hdiutil", ["attach", "-quiet", "-nobrowse", "-noautoopen", "-mountpoint", mount, image]) == 0)
        defer { run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mount]) }
        var fs = statfs(), tfs = statfs()
        statfs(mount, &fs)
        statfs(s.applications, &tfs)
        try #require(fs.f_fsid.val.0 != tfs.f_fsid.val.0 || fs.f_fsid.val.1 != tfs.f_fsid.val.1)
        s.makeBundle(at: mount + "/k3sm.app", tag: "v1.1.0", behaviour: "handshake")
        s.request(stagedName: name, expectedTag: "v1.1.0", app: s.appProcess(exitingAfter: 0.2))

        #expect(s.engine().swap() == .committed)

        #expect(s.tag(at: s.target) == "v1.1.0")
        let journal = try #require(s.journal)
        #expect(journal.state == .committed)
        #expect(journal.request.stagedName != name)
        #expect(SwapPaths.isStagingName(journal.request.stagedName))
        #expect(s.previousEntries() == ["k3sm-v1.0.0.previous"])
        var after = statfs()
        statfs(s.target, &after)
        #expect(after.f_fsid.val.0 == tfs.f_fsid.val.0 && after.f_fsid.val.1 == tfs.f_fsid.val.1)
    }

    @Test func exitWatcherTreatsESRCHAsExited() throws {
        let s = Scratch()
        let process = s.appProcess(exitingAfter: 0)
        while process.isRunning { usleep(10_000) }
        // Give the reaper its moment: the pid is then free, and EV_ADD on it
        // fails with ESRCH.
        usleep(100_000)
        let start = ContinuousClock.now
        #expect(KqueueProcessWatcher().waitForExit(process, timeout: .seconds(10)))
        #expect(ContinuousClock.now - start < .seconds(1))
    }

    @Test func startTimeMismatchCountsAsExited() throws {
        let s = Scratch()
        let live = s.appProcess(exitingAfter: 30)
        let reused = ProcessIdentity(pid: live.pid, start: ProcessStart(seconds: live.start.seconds - 1, microseconds: live.start.microseconds))
        let start = ContinuousClock.now
        #expect(KqueueProcessWatcher().waitForExit(reused, timeout: .seconds(10)))
        #expect(ContinuousClock.now - start < .seconds(1))
        #expect(!KqueueProcessWatcher().waitForExit(live, timeout: .milliseconds(200)))
    }

    @Test func floorReadFromInstalledBundle() throws {
        // The request claims a much older installed release; the floor still
        // comes from the installed bundle, so an equal tag is refused.
        do {
            let s = Scratch()
            s.install(tag: "v1.0.0")
            let name = s.stage(tag: "v1.0.0")
            s.request(stagedName: name, expectedTag: "v1.0.0", app: s.appProcess(exitingAfter: 0.1)) { journal in
                journal.outgoingTag = "v0.0.1"
            }
            let spy = SpyRenamer()
            #expect(s.engine(renamer: spy).swap() == .verificationFailed)
            #expect(spy.count == 0)
        }
        // Staged at or below the installed release.
        for staged in ["v1.0.0", "v0.9.0", "v1.0.0-rc.1"] {
            let s = Scratch()
            s.install(tag: "v1.0.0")
            let name = s.stage(tag: staged)
            s.request(stagedName: name, expectedTag: staged, app: s.appProcess(exitingAfter: 0.1))
            let spy = SpyRenamer()
            #expect(s.engine(renamer: spy).swap() == .verificationFailed, "\(staged)")
            #expect(spy.count == 0, "\(staged)")
            #expect(s.launcher.launches.map(\.arguments) == [["--update-failed", staged]], "\(staged)")
        }
        // A staged bundle without K3smPayloadTag, even with a higher short
        // version.
        do {
            let s = Scratch()
            s.install(tag: "v1.0.0")
            let name = SwapPaths.newStagingName()
            let dir = SwapPaths.stagingDirectory(target: s.target, name: name)
            s.makeBundle(at: dir + "/k3sm.app", tag: nil, behaviour: "handshake", shortVersion: "9.0.0")
            s.request(stagedName: name, expectedTag: "v9.0.0", app: s.appProcess(exitingAfter: 0.1))
            let spy = SpyRenamer()
            #expect(s.engine(renamer: spy).swap() == .verificationFailed)
            #expect(spy.count == 0)
        }
        // The rc of the next release is above the installed final.
        do {
            let s = Scratch()
            s.install(tag: "v1.0.0")
            let name = s.stage(tag: "v1.1.0-rc.1")
            s.request(stagedName: name, expectedTag: "v1.1.0-rc.1", app: s.appProcess(exitingAfter: 0.1))
            #expect(s.engine().swap() == .committed)
        }
    }

    @Test func handshakeBoundToLaunchedCdhash() throws {
        // Another process writes the right token with its own pid.
        do {
            let s = Scratch()
            s.install(tag: "v1.0.0")
            let original = identity(s.target)
            let name = s.stage(tag: "v1.1.0", behaviour: "silent")
            let impostor = s.root + "/impostor.app"
            s.makeBundle(at: impostor, tag: "v1.1.0", behaviour: "handshake")
            let launcher = s.launcher
            launcher.afterLaunch.withLock { hook in
                hook = { _ = launcher.start(executable: impostor + "/Contents/MacOS/k3sm-app", arguments: ["--handshake"]) }
            }
            s.request(stagedName: name, expectedTag: "v1.1.0", app: s.appProcess(exitingAfter: 0.2))
            #expect(s.engine(timeouts: .silent).swap() == .rolledBack)
            #expect(identity(s.target) == original)
            let message = try JSONDecoder().decode(HandshakeMessage.self, from: Data(contentsOf: URL(fileURLWithPath: s.paths.handshakePath)))
            #expect(message.pid != s.journal?.launched?.pid)
        }
        // The launched process answers, but runs other code than the target.
        do {
            let s = Scratch()
            s.install(tag: "v1.0.0")
            let original = identity(s.target)
            let name = s.stage(tag: "v1.1.0", behaviour: "silent")
            let impostor = s.root + "/impostor.app"
            s.makeBundle(at: impostor, tag: "v1.1.0", behaviour: "handshake")
            s.launcher.substitute.withLock { $0 = impostor }
            s.request(stagedName: name, expectedTag: "v1.1.0", app: s.appProcess(exitingAfter: 0.2))
            #expect(s.engine(timeouts: .silent).swap() == .rolledBack)
            #expect(identity(s.target) == original)
            let message = try JSONDecoder().decode(HandshakeMessage.self, from: Data(contentsOf: URL(fileURLWithPath: s.paths.handshakePath)))
            #expect(message.pid == s.journal?.launched?.pid)
        }
    }

    @Test func helperCopyMustMatchBundledHelper() throws {
        func signed(_ s: Scratch, _ source: String, _ name: String) -> String {
            let path = s.root + "/" + name
            try? FileManager.default.copyItem(atPath: source, toPath: path)
            #expect(run("/usr/bin/codesign", ["--force", "--sign", "-", "--timestamp=none", "--identifier", "io.k3sm.test.fixture", path]) == 0)
            return path
        }
        let s = Scratch()
        let bundled = signed(s, FixtureBinaries.app, "k3sm-app-update")
        let spawner = HelperSpawner(paths: s.paths, requirement: fixtureRequirement)
        try spawner.installHelperCopy(from: bundled)
        try spawner.verifyInstalledCopy(bundled: bundled)
        var st = stat()
        lstat(s.paths.helperCopyPath, &st)
        #expect(st.st_mode & 0o7777 == 0o500)

        // A different binary in its place.
        let other = signed(s, FixtureBinaries.otherTeam, "other-helper")
        unlink(s.paths.helperCopyPath)
        try FileManager.default.copyItem(atPath: other, toPath: s.paths.helperCopyPath)
        chmod(s.paths.helperCopyPath, 0o500)
        #expect(throws: HelperError.verification) { try spawner.verifyInstalledCopy(bundled: bundled) }
        // A symlink to the right binary.
        unlink(s.paths.helperCopyPath)
        symlink(bundled, s.paths.helperCopyPath)
        #expect(throws: HelperError.copy) { try spawner.verifyInstalledCopy(bundled: bundled) }
        // The right binary with another mode.
        try spawner.installHelperCopy(from: bundled)
        chmod(s.paths.helperCopyPath, 0o755)
        #expect(throws: HelperError.copy) { try spawner.verifyInstalledCopy(bundled: bundled) }
        // A second link to it.
        try spawner.installHelperCopy(from: bundled)
        link(s.paths.helperCopyPath, s.root + "/second-link")
        #expect(throws: HelperError.copy) { try spawner.verifyInstalledCopy(bundled: bundled) }
        unlink(s.root + "/second-link")
        // The private directory with another mode.
        try spawner.installHelperCopy(from: bundled)
        chmod(s.paths.privateDirectory, 0o755)
        #expect(throws: HelperError.directory) { try spawner.verifyInstalledCopy(bundled: bundled) }
        chmod(s.paths.privateDirectory, 0o700)
        // A bundled helper that does not satisfy the requirement.
        let unsigned = s.root + "/unsigned-helper"
        try FileManager.default.copyItem(atPath: FixtureBinaries.app, toPath: unsigned)
        #expect(throws: HelperError.source) { try spawner.installHelperCopy(from: unsigned) }
    }

    @Test func previousCopyVerifiesUnderNonBundleName() throws {
        let s = Scratch()
        s.install(tag: "v1.0.0")
        let name = s.stage(tag: "v1.1.0")
        s.request(stagedName: name, expectedTag: "v1.1.0", app: s.appProcess(exitingAfter: 0.2))
        #expect(s.engine().swap() == .committed)
        let previous = s.paths.previousDirectory + "/k3sm-v1.0.0.previous"
        let verified = try s.verifier.verify(bundleAt: previous, requireTag: true)
        #expect(verified.tag == "v1.0.0")
        #expect(SwapPaths.tag(ofPreviousName: "k3sm-v1.0.0.previous") == "v1.0.0")
        #expect(SwapPaths.tag(ofPreviousName: "k3sm-v1.0.0.app") == nil)
    }

    @Test func goBackRestoresPreviousCopy() throws {
        let s = Scratch()
        s.install(tag: "v1.0.0")
        let original = identity(s.target)
        let name = s.stage(tag: "v1.1.0")
        s.request(stagedName: name, expectedTag: "v1.1.0", app: s.appProcess(exitingAfter: 0.2))
        #expect(s.engine().swap() == .committed)
        let journal = SwapJournal(request: SwapRequest(mode: .goBack, target: s.target, stagedName: "", expectedTag: "v1.0.0",
                                                       token: SwapRequest.newToken(), app: s.appProcess(exitingAfter: 0.2)))
        try JournalStore(paths: s.paths).write(journal)

        #expect(s.engine().goBack() == .committed)

        #expect(identity(s.target) == original)
        #expect(s.previousEntries() == ["k3sm-v1.1.0.previous"])
        #expect(s.appBundles(in: s.applications) == ["k3sm.app"])
        #expect(s.launcher.launches.last?.arguments == ["--updated-from", "v1.1.0", "--handshake"])
    }

    @Test func teamStampMustBeAuthorized() throws {
        let s = Scratch()
        s.install(tag: "v1.0.0")
        let name = s.stage(tag: "v1.1.0", executable: FixtureBinaries.otherTeam)
        let path = SwapPaths.stagingDirectory(target: s.target, name: name) + "/k3sm.app"
        #expect(throws: BundleVerifyError.teamStamp) { try s.verifier.verify(bundleAt: path, requireTag: true) }
        let developer = StaticCodeVerifier(requirement: fixtureRequirement, runningTeam: nil)
        #expect(throws: BundleVerifyError.teamStamp) { try developer.verify(bundleAt: s.target, requireTag: true) }
        #expect(TeamStamp.read(Data("k3sm-team-id-pin:\0k3sm-team-id-pin:ABCDE12345\0".utf8)) == fixtureTeam)
        #expect(TeamStamp.read(Data("k3sm-team-id-pin:ABCDE12345\0k3sm-team-id-pin:ABCDE12345\0".utf8)) == nil)
        #expect(TeamStamp.read(Data("k3sm-team-id-pin:\0k3sm-team-id-pin:\0k3sm-team-id-pin:ABCDE12345\0".utf8)) == nil)
        #expect(TeamStamp.read(Data("k3sm-team-id-pin:ABCDE123456\0".utf8)) == nil)
    }
}
