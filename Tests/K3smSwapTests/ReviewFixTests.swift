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

/// Runs hdiutil with arguments and returns its status.
private func hdiutil(_ arguments: [String]) -> Int32 {
    run("/usr/bin/hdiutil", arguments)
}

/// The cases the security and Darwin reviews asked for: the go-back bound
/// to the engine's own record, the journal's names never used outside their
/// grammar, the staged tree private to this account, the volume refused
/// before the app quits, and the identity that survives a renumbered device.
@Suite("swap engine review fixes", .serialized)
struct ReviewFixTests {
    @Test func goBackRestoresOnlyTheRecordedCopy() throws {
        // The genuine previous copy comes back.
        do {
            let s = Scratch()
            s.updateOnce()
            let record = try #require(JournalStore(paths: s.paths).readRecord())
            #expect(record.name == "k3sm-v1.0.0.previous")
            #expect(record.installedTag == "v1.1.0")
            s.requestGoBack(tag: "v1.0.0", app: s.appProcess(exitingAfter: 0.2))
            #expect(s.engine().goBack() == .committed)
            #expect(s.tag(at: s.target) == "v1.0.0")
            // The record now names the bundle the go-back replaced.
            #expect(JournalStore(paths: s.paths).readRecord()?.name == "k3sm-v1.1.0.previous")
        }
        // A planted older signed copy is refused, even with a committed
        // journal forged to name it.
        do {
            let s = Scratch()
            s.updateOnce()
            let installed = identity(s.target)
            s.makeBundle(at: s.paths.previousDirectory + "/k3sm-v0.9.0.previous", tag: "v0.9.0", behaviour: "handshake")
            var forged = try #require(s.journal)
            forged.outgoingTag = "v0.9.0"
            forged.previousName = "k3sm-v0.9.0.previous"
            try JournalStore(paths: s.paths).write(forged)
            s.requestGoBack(tag: "v0.9.0", app: s.appProcess(exitingAfter: 0.2))
            let spy = SpyRenamer()
            #expect(s.engine(renamer: spy).goBack() == .verificationFailed)
            #expect(spy.count == 0)
            #expect(identity(s.target) == installed)
            #expect(s.journal?.reason == .verificationFailed)
        }
        // A different signed bundle put under the recorded name (another
        // cdhash) is refused.
        do {
            let s = Scratch()
            s.updateOnce()
            let installed = identity(s.target)
            let previous = s.paths.previousDirectory + "/k3sm-v1.0.0.previous"
            run("/bin/rm", ["-rf", previous])
            s.makeBundle(at: previous, tag: "v1.0.0", behaviour: "silent")
            s.requestGoBack(tag: "v1.0.0", app: s.appProcess(exitingAfter: 0.2))
            let spy = SpyRenamer()
            #expect(s.engine(renamer: spy).goBack() == .verificationFailed)
            #expect(spy.count == 0)
            #expect(identity(s.target) == installed)
        }
        // No record, no go-back.
        do {
            let s = Scratch()
            s.updateOnce()
            JournalStore(paths: s.paths).writeRecord(nil)
            s.requestGoBack(tag: "v1.0.0", app: s.appProcess(exitingAfter: 0.2))
            #expect(s.engine(renamer: SpyRenamer()).goBack() == .verificationFailed)
        }
    }

    @Test func rollbackRestoresThePriorRecord() throws {
        let s = Scratch()
        s.updateOnce()
        let prior = try #require(JournalStore(paths: s.paths).readRecord())
        let name = s.stage(tag: "v1.2.0", behaviour: "silent")
        s.request(stagedName: name, expectedTag: "v1.2.0", app: s.appProcess(exitingAfter: 0.2))
        #expect(s.engine(timeouts: .silent).swap() == .rolledBack)
        #expect(JournalStore(paths: s.paths).readRecord() == prior)
        #expect(s.journal?.reason == .rolledBack)
    }

    @Test func journalNamesOutsideGrammarAreNeverUsed() throws {
        let base = ReconcileTests.journal(.swapped)
        #expect(base.namesAreValid)
        var j = base
        j.previousName = "../../k3sm-v1.0.0.previous"
        #expect(!j.namesAreValid)
        j = base
        j.previousName = "k3sm-v1.0.0/../x.previous"
        #expect(!j.namesAreValid)
        j = base
        j.outgoingTag = "v1.0.0;id"
        #expect(!j.namesAreValid)
        j = base
        j.request.failedTag = "../v1.0.0"
        #expect(!j.namesAreValid)
        j = base
        j.request.stagedName = "../.k3sm.app.update-abcdefgh"
        #expect(!j.namesAreValid)

        // The reconciler leaves a journal with a `../` previous name alone:
        // nothing at the path it names is touched.
        let s = Scratch()
        s.install(tag: "v1.0.0")
        let name = s.stage(tag: "v1.1.0")
        s.request(stagedName: name, expectedTag: "v1.1.0", app: s.appProcess(exitingAfter: 0.2))
        let faults = SwapFaults { state, phase in state == .swapped && phase == .acted }
        _ = s.engine(faults: faults).swap()
        var killed = try #require(s.journal)
        let bait = s.root + "/bait"
        try FileManager.default.createDirectory(atPath: bait, withIntermediateDirectories: true)
        killed.previousName = "../../../bait"
        try JournalStore(paths: s.paths).write(killed)
        let reconciler = SwapReconciler(paths: s.paths, verifier: s.verifier, currentApp: nil, spawnGoBack: { false })
        #expect(reconciler.reconcile(runningTag: "v1.1.0", runningSelfCheck: { true }) == .carryOn)
        #expect(FileManager.default.fileExists(atPath: bait))
        #expect(s.journal?.state == .swapped)
        #expect(reconciler.perform(.commit, journal: killed) == .carryOn)
        #expect(s.journal?.state == .swapped)
        #expect(s.stagingEntries() == [name])

        // relaunch() refuses a journal with a bad outgoing tag.
        killed.previousName = "k3sm-v1.0.0.previous"
        killed.outgoingTag = "v1.0.0 --evil"
        try JournalStore(paths: s.paths).write(killed)
        #expect(s.engine().relaunch() == .refusedRequest)
        #expect(s.launcher.launches.isEmpty)
    }

    @Test func stagedTreeMustBePrivate() throws {
        let cases: [(String, (Scratch, String) -> Void)] = [
            ("a group-writable file in the bundle", { s, name in
                chmod(SwapPaths.stagingDirectory(target: s.target, name: name) + "/k3sm.app/Contents/Info.plist", 0o664)
            }),
            ("a world-writable bundle directory", { s, name in
                chmod(SwapPaths.stagingDirectory(target: s.target, name: name) + "/k3sm.app/Contents/MacOS", 0o777)
            }),
            ("a group-writable staging directory", { s, name in
                chmod(SwapPaths.stagingDirectory(target: s.target, name: name), 0o770)
            }),
        ]
        for (label, arrange) in cases {
            let s = Scratch()
            s.install(tag: "v1.0.0")
            let original = identity(s.target)
            let name = s.stage(tag: "v1.1.0")
            arrange(s, name)
            s.request(stagedName: name, expectedTag: "v1.1.0", app: s.appProcess(exitingAfter: 0.2))
            let spy = SpyRenamer()
            #expect(s.engine(renamer: spy).swap() == .verificationFailed, "\(label)")
            #expect(spy.count == 0, "\(label)")
            #expect(identity(s.target) == original, "\(label)")
        }
    }

    @Test func volumeRefusedBeforeTheAppQuits() throws {
        let work = realPath(NSTemporaryDirectory()) + "/k3sm-swap-volumes-" + UUID().uuidString.prefix(8)
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        defer { run("/bin/rm", ["-rf", work]) }
        // A FAT volume cannot exchange two names in one step.
        let fat = work + "/fat"
        try FileManager.default.createDirectory(atPath: fat, withIntermediateDirectories: true)
        #expect(hdiutil(["create", "-quiet", "-size", "8m", "-fs", "MS-DOS", "-volname", "K3SMFAT", work + "/fat.dmg"]) == 0)
        #expect(hdiutil(["attach", "-quiet", "-nobrowse", "-noautoopen", "-mountpoint", fat, work + "/fat.dmg"]) == 0)
        defer { hdiutil(["detach", "-quiet", "-force", fat]) }
        #expect(SwapVolume.supportsRenameSwap(path: fat) == false)
        #expect(SwapVolume.supportsRenameSwap(path: NSTemporaryDirectory()) == true)
        let fatPaths = SwapPaths(home: work, applicationsRoots: [fat])
        #expect(fatPaths.volumeRefusal(target: fat + "/k3sm.app") == .unsupportedVolume)
        #expect(SwapPaths.TargetRefusal.unsupportedVolume.message == "Move k3sm.app to Applications on the startup disk")

        // A home folder on another volume than the target: the previous copy
        // could not leave the Applications folder by a rename, so the swap is
        // refused before the wait, with no rename.
        let home = work + "/home"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        #expect(hdiutil(["create", "-quiet", "-size", "40m", "-fs", "APFS", "-volname", "k3smhome", work + "/home.dmg"]) == 0)
        #expect(hdiutil(["attach", "-quiet", "-nobrowse", "-noautoopen", "-mountpoint", home, work + "/home.dmg"]) == 0)
        defer { hdiutil(["detach", "-quiet", "-force", home]) }
        let s = Scratch(home: home)
        try? JournalStore(paths: s.paths).prepare()
        s.install(tag: "v1.0.0")
        #expect(s.paths.volumeRefusal(target: s.target) == .previousOnOtherVolume)
        // Its own sentence: the volume is capable, so the message must not
        // suggest fixing the volume's file system.
        let sentence = SwapPaths.TargetRefusal.previousOnOtherVolume.message
        #expect(sentence != SwapPaths.TargetRefusal.unsupportedVolume.message)
        #expect(sentence.contains("different disks"))
        #expect(!sentence.contains("startup disk"))
        let client = SwapClient(paths: s.paths, helperRequirement: fixtureRequirement, bundledHelper: "/nonexistent")
        #expect(throws: SwapClient.StartError.refused(.previousOnOtherVolume)) {
            try client.beginUpdate(target: s.target, stagedName: SwapPaths.newStagingName(), expectedTag: "v1.1.0")
        }
        let original = identity(s.target)
        let name = s.stage(tag: "v1.1.0")
        let app = s.appProcess(exitingAfter: 0.2)
        s.request(stagedName: name, expectedTag: "v1.1.0", app: app)
        let spy = SpyRenamer()
        #expect(s.engine(renamer: spy).swap() == .unsupportedVolume)
        #expect(spy.count == 0)
        #expect(identity(s.target) == original)
        #expect(s.journal?.reason == .unsupportedVolume)
        #expect(s.journal?.state == .staged)
    }

    @Test func reconcileSurvivesDevRenumbering() throws {
        #expect(FileIdentity(volume: "V", ino: 7, dev: 1) == FileIdentity(volume: "V", ino: 7, dev: 2))
        #expect(FileIdentity(volume: "V", ino: 7, dev: 1) != FileIdentity(volume: "W", ino: 7, dev: 1))
        let s = Scratch()
        s.install(tag: "v1.0.0")
        let originalExe = try #require(identity(s.target + "/Contents/MacOS/k3sm-app"))
        let name = s.stage(tag: "v1.1.0")
        s.request(stagedName: name, expectedTag: "v1.1.0", app: s.appProcess(exitingAfter: 0.2))
        // Killed after the swap, before the old bundle moved out: the only
        // copy of it is in the staging directory.
        let faults = SwapFaults { state, phase in state == .swapped && phase == .acted }
        _ = s.engine(faults: faults).swap()
        var journal = try #require(s.journal)
        let original = try #require(journal.original)
        let incoming = try #require(journal.incoming)
        // A reboot renumbered the device; the volume UUID and inodes stand.
        journal.original = FileIdentity(volume: original.volume, ino: original.ino, dev: original.dev + 1000)
        journal.incoming = FileIdentity(volume: incoming.volume, ino: incoming.ino, dev: incoming.dev + 1000)
        try JournalStore(paths: s.paths).write(journal)
        let reconciler = SwapReconciler(paths: s.paths, verifier: s.verifier, currentApp: nil, spawnGoBack: { false })
        _ = reconciler.reconcile(runningTag: "v1.1.0", runningSelfCheck: { true })
        #expect(s.journal?.state == .committed)
        #expect(identity(s.paths.previousDirectory + "/k3sm-v1.0.0.previous/Contents/MacOS/k3sm-app") == originalExe)
        #expect(s.tag(at: s.target) == "v1.1.0")
    }

    @Test func floorOnlyRises() throws {
        let s = Scratch()
        s.updateOnce()
        let first = try #require(JournalStore(paths: s.paths).readRecord())
        #expect(first.floorTag == "v1.0.0")
        // A second update keeps the floor at the highest tag kept so far.
        let name = s.stage(tag: "v1.2.0")
        s.request(stagedName: name, expectedTag: "v1.2.0", app: s.appProcess(exitingAfter: 0.2))
        #expect(s.engine().swap() == .committed)
        let second = try #require(JournalStore(paths: s.paths).readRecord())
        #expect(second.floorTag == "v1.1.0")
        // A go-back never lowers it, and an undone swap puts the old one back.
        s.requestGoBack(tag: "v1.1.0", app: s.appProcess(exitingAfter: 0.2))
        #expect(s.engine().goBack() == .committed)
        let third = try #require(JournalStore(paths: s.paths).readRecord())
        #expect(third.floorTag == "v1.2.0")
        #expect(third.floorTag > second.floorTag)
    }

    @Test func goBackBelowTheFloorIsRefused() throws {
        let s = Scratch()
        s.updateOnce()
        let installed = identity(s.target)
        let store = JournalStore(paths: s.paths)
        var record = try #require(store.readRecord())
        record.floorTag = "v1.0.5"
        #expect(store.writeRecord(record))
        s.requestGoBack(tag: "v1.0.0", app: s.appProcess(exitingAfter: 0.2))
        let spy = SpyRenamer()
        #expect(s.engine(renamer: spy).goBack() == .verificationFailed)
        #expect(spy.count == 0)
        #expect(identity(s.target) == installed)
    }

    @Test func aFloorLoweredAfterTheFactIsRefused() throws {
        let s = Scratch()
        s.updateOnce()
        let installed = identity(s.target)
        let store = JournalStore(paths: s.paths)
        var record = try #require(store.readRecord())
        // The floor sits below the tag the record names, and below the
        // installed bundle's tag: a lowered floor.
        record.floorTag = "v0.9.0"
        #expect(store.writeRecord(record))
        s.requestGoBack(tag: "v1.0.0", app: s.appProcess(exitingAfter: 0.2))
        let spy = SpyRenamer()
        #expect(s.engine(renamer: spy).goBack() == .verificationFailed)
        #expect(spy.count == 0)
        #expect(identity(s.target) == installed)
    }

    @Test func crashBeforeTheSwapClearsTheStaleRecord() throws {
        // First update: no record before it. A crash after the record was
        // written and before the swap leaves a record naming a copy that
        // was never kept; the reconciler clears it.
        let s = Scratch()
        s.install(tag: "v1.0.0")
        let name = s.stage(tag: "v1.1.0")
        s.request(stagedName: name, expectedTag: "v1.1.0", app: s.appProcess(exitingAfter: 0.2))
        let faults = SwapFaults { state, phase in state == .swapped && phase == .written }
        _ = s.engine(faults: faults).swap()
        let store = JournalStore(paths: s.paths)
        #expect(store.readRecord() != nil)
        #expect(s.tag(at: s.target) == "v1.0.0")
        let reconciler = SwapReconciler(paths: s.paths, verifier: s.verifier, currentApp: nil, spawnGoBack: { false })
        _ = reconciler.reconcile(runningTag: "v1.0.0", runningSelfCheck: { true })
        #expect(store.readRecord() == nil)

        // With an earlier record, that one comes back.
        let t = Scratch()
        t.updateOnce()
        let prior = try #require(JournalStore(paths: t.paths).readRecord())
        let next = t.stage(tag: "v1.2.0")
        t.request(stagedName: next, expectedTag: "v1.2.0", app: t.appProcess(exitingAfter: 0.2))
        _ = t.engine(faults: faults).swap()
        #expect(JournalStore(paths: t.paths).readRecord() != prior)
        let again = SwapReconciler(paths: t.paths, verifier: t.verifier, currentApp: nil, spawnGoBack: { false })
        _ = again.reconcile(runningTag: "v1.1.0", runningSelfCheck: { true })
        #expect(JournalStore(paths: t.paths).readRecord() == prior)
    }
}
