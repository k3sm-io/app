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
import Testing

import K3smStatus
@testable import K3smInstall
@testable import K3smSwap

/// The administrator path for the app swap: the root script, byte for byte,
/// and the root half it runs (`AdminSwapEngine`) over ad-hoc signed fixture
/// bundles, with every hostile target the plan names.
@Suite struct AppSwapRootTests {
    static let team = TeamID("ABCDE12345")!

    // MARK: the root script

    static let goldenTargetCheck = #"""
        apps='/Applications'
        target='/Applications/k3sm.app'
        if [ -L "$apps" ] || [ ! -d "$apps" ] || [ -L "$target" ] || [ ! -d "$target" ]; then
        	echo 'app-swap: refused: Applications or k3sm.app in it is a symlink or not a folder'
        	exit 120
        fi

        """#

    static let goldenTail = #"""
        helper="$stage"/'k3sm.app'/'Contents/Helpers/k3sm-app-update'
        if [ -L "$helper" ] || [ ! -f "$helper" ]; then
        	echo 'app-swap: refused: the installed helper is missing or not a regular file'
        	exit 121
        fi
        /bin/chmod 0500 "$helper"
        if ! /usr/bin/codesign --verify --strict '-R=anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = "ABCDE12345" and identifier "io.k3sm.app.update"' "$helper"; then
        	echo 'app-swap: refused: the installed helper is not signed by the k3sm Developer ID'
        	exit 121
        fi
        echo 'app-swap: running the installed helper as root'
        "$helper" '--admin-swap'

        """#

    @Test("the script, byte for byte: the target check, the copy-out's staged copy of the installed bundle, its helper as root")
    func goldenScript() throws {
        let script = AppSwapRootScriptBuilder.render(teamID: Self.team)
        #expect(AppSwapRootScriptBuilder.targetCheck == Self.goldenTargetCheck)
        let staged = RootScriptBuilder.stagedCopy(
            bundlePath: "/Applications/k3sm.app", stagingTemplate: "/Library/k3sm.staging/app-swap-helper.XXXXXXXX",
            designatedRequirement: #"anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = "ABCDE12345" and identifier "io.k3sm.app" and notarized"#,
            beforeCopy: Self.goldenTargetCheck)
        #expect(script.text == staged + Self.goldenTail)
        #expect(script.prompt == "k3sm wants to replace k3sm.app in Applications with the update it downloaded and verified.")
        #expect(!script.readsInput && script.usesStagingLock && script.result == .discarded)
        let line = script.command(inputPath: "/dev/null")
        #expect(line.hasPrefix("/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin /usr/bin/lockf -k -t 0 '/Library/k3sm.staging.lock' /bin/sh -c "))
        #expect(try shell(["-n", "-c", script.text]).status == 0)
    }

    @Test("the verb takes no path: the target is the constant, checked before the copy, and only the copy's helper runs")
    func closedVerb() throws {
        let text = AppSwapRootScriptBuilder.render(teamID: Self.team).text
        func at(_ s: String) throws -> String.Index { try #require(text.range(of: s), "missing \(s)").lowerBound }
        #expect(try at("exit 120") < at("/usr/bin/ditto"))
        #expect(try at("/usr/bin/ditto") < at("codesign --verify --strict --deep"))
        #expect(try at("codesign --verify --strict --deep") < at("helper=\"$stage\""))
        #expect(try at("helper=\"$stage\"") < at("\"$helper\" '--admin-swap'"))
        // Only the constant target and the stage name anything to run or copy.
        let named = text.split(separator: "\n").filter { $0.contains("/Applications/k3sm.app") }
        #expect(named.count == 2, "\(named)")
        #expect(named.contains { $0.hasPrefix("target=") } && named.contains { $0.hasPrefix("/usr/bin/ditto ") })
        #expect(!text.contains("io.k3sm.app/update") && !text.contains("request.json") && !text.contains("$1"))
        #expect(text.split(separator: "\n").filter { $0.hasPrefix("\"$helper\"") } == ["\"$helper\" '--admin-swap'"])
    }

    @Test("the relaunch runs the user's helper as the user, in the console session, by absolute path")
    func relaunchArguments() {
        #expect(AppSwapRoot.relaunchArguments(uid: 501, home: "/Users/kit") == [
            "/bin/launchctl", "asuser", "501", "/usr/bin/sudo", "-n", "-u", "#501", "--",
            "/Users/kit/Library/Application Support/io.k3sm.app/update/k3sm-app-update", "--relaunch",
        ])
        #expect(ConsoleAccount(uid: 501, home: "/Users/kit").stagedBundle
            == "/Users/kit/Library/Application Support/io.k3sm.app/admin-staging/k3sm.app")
    }

    // MARK: the root half, over fixtures

    enum Hostile: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case symlinkedTarget
        case targetSwappedBeforeRename
        case requestNamesAnotherPath
        case stagedOnAnotherVolume
        case workOnAnotherVolume
        case lowerTag
        case equalTag

        var testDescription: String { rawValue }
    }

    @Test("every hostile target is refused or ignored, and no path but the constant target is renamed",
          arguments: Hostile.allCases)
    func appSwapRootScriptRefusesHostileTarget(_ hostile: Hostile) throws {
        let s = AdminScratch()
        defer { s.cleanUp() }
        switch hostile {
        case .symlinkedTarget:
            // The target is a symlink to a real, older bundle elsewhere.
            let elsewhere = s.root + "/Elsewhere/k3sm.app"
            s.makeBundle(at: elsewhere, tag: "v1.0.0")
            try FileManager.default.createSymbolicLink(atPath: s.target, withDestinationPath: elsewhere)
            s.stage(tag: "v1.1.0")
            let before = (identity(elsewhere), identity(s.target), identity(s.staged))
            #expect(s.engine().run() == AppSwapRootExit.targetRefused)
            #expect((identity(elsewhere), identity(s.target), identity(s.staged)) == before)
            #expect(s.tag(at: elsewhere) == "v1.0.0")
            s.expectNothingLeft()

        case .targetSwappedBeforeRename:
            // Between the last check and the rename, the target is moved
            // away and another directory put in its place.
            s.install(tag: "v1.0.0")
            s.stage(tag: "v1.1.0")
            let moved = s.root + "/Moved"
            try FileManager.default.createDirectory(atPath: moved, withIntermediateDirectories: true)
            let decoy = s.root + "/Decoy/k3sm.app"
            s.makeBundle(at: decoy, tag: "v0.5.0")
            let original = identity(s.target)
            let decoyID = identity(decoy)
            let renamer = ReplacingRenamer(target: s.target, movedTo: moved + "/k3sm.app", replacement: decoy)
            #expect(s.engine(renamer: renamer).run() == AppSwapRootExit.targetRefused)
            // The swap was undone: the replacement is back at the target, the
            // original is where the attacker put it, the staged copy untouched.
            #expect(identity(s.target) == decoyID)
            #expect(identity(moved + "/k3sm.app") == original)
            #expect(s.tag(at: s.target) == "v0.5.0" && s.tag(at: s.staged) == "v1.1.0")
            #expect(renamer.swaps == 2)
            s.expectNothingLeft()

        case .requestNamesAnotherPath:
            // The user's request file names another Applications folder and a
            // valid staged bundle in it; root never reads it, and the
            // compiled staging location is empty.
            s.install(tag: "v1.0.0")
            let other = s.root + "/OtherApps"
            let paths = SwapPaths(home: s.home, applicationsRoots: [other])
            let name = SwapPaths.newStagingName()
            s.makeBundle(at: other + "/" + name + "/k3sm.app", tag: "v1.1.0")
            s.makeBundle(at: other + "/k3sm.app", tag: "v1.0.0")
            let store = JournalStore(paths: paths)
            try store.prepare()
            try store.write(SwapJournal(request: SwapRequest(
                mode: .update, target: other + "/k3sm.app", stagedName: name, expectedTag: "v1.1.0",
                token: SwapRequest.newToken(), app: try #require(ProcessIdentity.current()))))
            let before = (identity(s.target), identity(other + "/k3sm.app"), identity(other + "/" + name + "/k3sm.app"))
            #expect(s.engine().run() == AppSwapRootExit.stagedRefused)
            #expect((identity(s.target), identity(other + "/k3sm.app"), identity(other + "/" + name + "/k3sm.app")) == before)
            #expect(s.tag(at: s.target) == "v1.0.0")
            s.expectNothingLeft()

        case .stagedOnAnotherVolume:
            // The home folder is another volume. The staged bundle is never
            // renamed: root copies it onto the target's volume and swaps the
            // copy.
            let volume = try MountedVolume(name: "k3smhome")
            defer { volume.detach() }
            let t = AdminScratch(home: volume.mount + "/home")
            defer { t.cleanUp() }
            t.install(tag: "v1.0.0")
            t.stage(tag: "v1.1.0")
            let staged = identity(t.staged)
            #expect(t.engine().run() == 0)
            #expect(identity(t.staged) == staged, "the staged bundle moved")
            #expect(t.tag(at: t.staged) == "v1.1.0" && t.tag(at: t.target) == "v1.1.0")
            #expect(identity(t.target) != staged)
            #expect(AdminSwapEngine.sameVolume(AdminSwapEngine.fsid(t.target), AdminSwapEngine.fsid(t.applications)))
            #expect(t.relaunched == [t.account])
            t.expectNothingLeft()

        case .workOnAnotherVolume:
            // Root's own copy would land on another volume than the target:
            // refused before anything is copied or renamed.
            let volume = try MountedVolume(name: "k3smwork")
            defer { volume.detach() }
            let t = AdminScratch(workRoot: volume.mount + "/work")
            defer { t.cleanUp() }
            t.install(tag: "v1.0.0")
            t.stage(tag: "v1.1.0")
            let before = (identity(t.target), identity(t.staged))
            #expect(t.engine().run() == AppSwapRootExit.volumeRefused)
            #expect((identity(t.target), identity(t.staged)) == before)
            #expect(t.relaunched.isEmpty)

        case .lowerTag, .equalTag:
            s.install(tag: "v1.0.0")
            s.stage(tag: hostile == .lowerTag ? "v0.9.0" : "v1.0.0")
            let before = (identity(s.target), identity(s.staged))
            #expect(s.engine().run() == AppSwapRootExit.verificationFailed)
            #expect((identity(s.target), identity(s.staged)) == before)
            #expect(s.tag(at: s.target) == "v1.0.0")
            s.expectNothingLeft()
        }
    }

    @Test("a newer staged bundle is copied, verified, given the target's owner and mode, swapped, and relaunched")
    func swapsAndRelaunches() throws {
        let s = AdminScratch()
        defer { s.cleanUp() }
        s.install(tag: "v1.0.0")
        chmod(s.target, 0o755)
        s.stage(tag: "v1.1.0")
        chmod(s.staged, 0o700)
        let original = identity(s.target)
        #expect(s.engine().run() == 0)
        #expect(s.tag(at: s.target) == "v1.1.0")
        var st = stat()
        #expect(lstat(s.target, &st) == 0 && st.st_mode & 0o7777 == 0o755 && st.st_uid == getuid())
        #expect(identity(s.previousRoot + "/k3sm-v1.0.0.previous") == original)
        #expect(s.tag(at: s.staged) == "v1.1.0", "the staged bundle is left for the app to remove")
        #expect(s.relaunched == [s.account])
        s.expectNothingLeft()
    }

    @Test("EXDEV makes one fresh copy, verifies it and retries once; a second EXDEV refuses with the old bundle in place")
    func crossDevice() throws {
        let s = AdminScratch()
        defer { s.cleanUp() }
        s.install(tag: "v1.0.0")
        s.stage(tag: "v1.1.0")
        #expect(s.engine(renamer: FailingRenamer(errnos: [EXDEV])).run() == 0)
        #expect(s.tag(at: s.target) == "v1.1.0")
        s.expectNothingLeft()

        let t = AdminScratch()
        defer { t.cleanUp() }
        t.install(tag: "v1.0.0")
        t.stage(tag: "v1.1.0")
        let original = identity(t.target)
        #expect(t.engine(renamer: FailingRenamer(errnos: [EXDEV, EXDEV])).run() == AppSwapRootExit.volumeRefused)
        #expect(identity(t.target) == original)
        t.expectNothingLeft()

        let u = AdminScratch()
        defer { u.cleanUp() }
        u.install(tag: "v1.0.0")
        u.stage(tag: "v1.1.0")
        #expect(u.engine(renamer: FailingRenamer(errnos: [ENOTSUP])).run() == AppSwapRootExit.volumeRefused)
        #expect(u.engine(renamer: FailingRenamer(errnos: [EPERM])).run() == AppSwapRootExit.swapFailed)
        #expect(u.tag(at: u.target) == "v1.0.0" && u.relaunched.isEmpty)
    }

    @Test("no console user, a symlinked staged bundle, an unsafe staged tree and an unsigned copy are refused")
    func otherRefusals() throws {
        let s = AdminScratch()
        defer { s.cleanUp() }
        s.install(tag: "v1.0.0")
        #expect(s.engine(console: FixedConsole(owner: nil)).run() == AppSwapRootExit.noConsoleUser)
        #expect(s.engine().run() == AppSwapRootExit.stagedRefused, "nothing staged")
        // A symlink at the staged location, to a valid newer bundle.
        let real = s.root + "/Real/k3sm.app"
        s.makeBundle(at: real, tag: "v1.1.0")
        try FileManager.default.createDirectory(atPath: (s.staged as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: s.staged, withDestinationPath: real)
        #expect(s.engine().run() == AppSwapRootExit.stagedRefused)
        try FileManager.default.removeItem(atPath: s.staged)
        // A symlink inside the staged tree.
        s.stage(tag: "v1.1.0")
        try FileManager.default.createSymbolicLink(atPath: s.staged + "/Contents/Resources/link", withDestinationPath: "/etc/passwd")
        #expect(s.engine().run() == AppSwapRootExit.verificationFailed)
        try FileManager.default.removeItem(atPath: s.staged)
        // Another team's stamp.
        s.makeBundle(at: s.staged, tag: "v1.1.0", executable: AdminFixtures.otherTeam)
        #expect(s.engine().run() == AppSwapRootExit.verificationFailed)
        #expect(s.tag(at: s.target) == "v1.0.0" && s.relaunched.isEmpty)
        s.expectNothingLeft()
    }
}

// MARK: fixtures

/// The requirement the ad-hoc signed fixtures satisfy.
private let fixtureRequirement = "identifier \"io.k3sm.test.fixture\""

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

private func identity(_ path: String) -> FileIdentity? { FileIdentity.of(path: path) }

/// AdminFixtures compiles the swap engine's fixture app once, for the
/// fixtures' team and another team.
private enum AdminFixtures {
    static let directory: String = {
        // One directory per test process; those of processes that are gone
        // are swept first.
        let tmp = realPath(NSTemporaryDirectory())
        let prefix = "k3sm-adminswap-fixtures-"
        for name in (try? FileManager.default.contentsOfDirectory(atPath: tmp)) ?? [] where name.hasPrefix(prefix) {
            if let pid = Int32(name.dropFirst(prefix.count)), kill(pid, 0) != 0 {
                try? FileManager.default.removeItem(atPath: tmp + "/" + name)
            }
        }
        let dir = tmp + "/" + prefix + String(getpid())
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "K3smSwapTests/Fixtures/fixture-app.c").path
        for (name, team) in [("fixture-app", "ABCDE12345"), ("fixture-app-other-team", "ZZZZZ99999")] {
            precondition(run("/usr/bin/cc", ["-O0", "-DFIXTURE_TEAM=\"\(team)\"", "-o", dir + "/" + name, source]) == 0,
                         "cc could not compile the fixture app")
        }
        return dir
    }()

    static var app: String { directory + "/fixture-app" }
    static var otherTeam: String { directory + "/fixture-app-other-team" }
}

/// FixedConsole is a console owned by a given account, or by nobody.
private struct FixedConsole: ConsoleSession {
    let owner: ConsoleAccount?
    func account() -> ConsoleAccount? { owner }
}

/// RecordingRelauncher records every relaunch.
private final class RecordingRelauncher: SessionRelauncher, @unchecked Sendable {
    let calls = Mutex<[ConsoleAccount]>([])
    func relaunch(_ account: ConsoleAccount) { calls.withLock { $0.append(account) } }
}

/// ReplacingRenamer, on its first swap, moves the target away and puts
/// `replacement` in its place, then swaps: the race between the engine's last
/// check and its rename.
private final class ReplacingRenamer: Renamer, @unchecked Sendable {
    let target: String
    let movedTo: String
    let replacement: String
    private let count = Mutex<Int>(0)

    init(target: String, movedTo: String, replacement: String) {
        self.target = target
        self.movedTo = movedTo
        self.replacement = replacement
    }

    var swaps: Int { count.withLock { $0 } }

    func swap(fromDir: Int32, from: String, toDir: Int32, to: String) -> Int32 {
        let first = count.withLock { n -> Bool in n += 1; return n == 1 }
        if first {
            precondition(rename(target, movedTo) == 0 && rename(replacement, target) == 0)
        }
        return SystemRenamer().swap(fromDir: fromDir, from: from, toDir: toDir, to: to)
    }

    func move(fromDir: Int32, from: String, toDir: Int32, to: String) -> Int32 {
        SystemRenamer().move(fromDir: fromDir, from: from, toDir: toDir, to: to)
    }
}

/// FailingRenamer fails its first swaps with the given errnos, then swaps.
private final class FailingRenamer: Renamer, @unchecked Sendable {
    private let errnos: Mutex<[Int32]>

    init(errnos: [Int32]) {
        self.errnos = Mutex(errnos)
    }

    func swap(fromDir: Int32, from: String, toDir: Int32, to: String) -> Int32 {
        if let e = errnos.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) { return e }
        return SystemRenamer().swap(fromDir: fromDir, from: from, toDir: toDir, to: to)
    }

    func move(fromDir: Int32, from: String, toDir: Int32, to: String) -> Int32 {
        SystemRenamer().move(fromDir: fromDir, from: from, toDir: toDir, to: to)
    }
}

/// MountedVolume is a scratch APFS disk image, attached without browsing.
private struct MountedVolume {
    let image: String
    let mount: String

    init(name: String) throws {
        let dir = realPath(NSTemporaryDirectory()) + "/k3sm-adminswap-vol-" + UUID().uuidString.prefix(8)
        try FileManager.default.createDirectory(atPath: dir + "/mnt", withIntermediateDirectories: true)
        image = dir + "/volume.dmg"
        mount = dir + "/mnt"
        try #require(run("/usr/bin/hdiutil", ["create", "-quiet", "-size", "40m", "-fs", "APFS", "-volname", name, image]) == 0)
        try #require(run("/usr/bin/hdiutil", ["attach", "-quiet", "-nobrowse", "-noautoopen", "-mountpoint", mount, image]) == 0)
    }

    func detach() {
        run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mount])
        try? FileManager.default.removeItem(atPath: (image as NSString).deletingLastPathComponent)
    }
}

/// AdminScratch is one test's world: an Applications folder holding the
/// target, a home folder holding the compiled staging location, and root's
/// work and previous directories, owned by this account in place of root.
private final class AdminScratch: @unchecked Sendable {
    let root: String
    let home: String
    let workRoot: String
    let previousRoot: String
    let relauncher = RecordingRelauncher()
    var applications: String { root + "/Applications" }
    var target: String { applications + "/k3sm.app" }
    var account: ConsoleAccount { ConsoleAccount(uid: getuid(), home: home) }
    var staged: String { account.stagedBundle }
    var relaunched: [ConsoleAccount] { relauncher.calls.withLock { $0 } }

    init(home: String? = nil, workRoot: String? = nil) {
        root = realPath(NSTemporaryDirectory()) + "/k3sm-adminswap-" + UUID().uuidString.prefix(8)
        self.home = home ?? root + "/home"
        self.workRoot = workRoot ?? root + "/work"
        previousRoot = root + "/previous"
        let fm = FileManager.default
        try? fm.createDirectory(atPath: self.home + "/Library/Application Support/io.k3sm.app", withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: root + "/Applications", withIntermediateDirectories: true)
    }

    func cleanUp() {
        run("/bin/chmod", ["-R", "u+rwx", root])
        try? FileManager.default.removeItem(atPath: root)
    }

    var locations: AdminSwapLocations {
        AdminSwapLocations(target: target, workRoot: workRoot, previousRoot: previousRoot, owner: getuid(), group: getgid())
    }

    func engine(renamer: any Renamer = SystemRenamer(), console: (any ConsoleSession)? = nil) -> AdminSwapEngine {
        AdminSwapEngine(verifier: StaticCodeVerifier(requirement: fixtureRequirement, runningTeam: AppSwapRootTests.team),
                        renamer: renamer, console: console ?? FixedConsole(owner: account), relauncher: relauncher,
                        locations: locations)
    }

    func makeBundle(at path: String, tag: String, executable: String = AdminFixtures.app) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: path + "/Contents/MacOS", withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: path + "/Contents/Resources", withIntermediateDirectories: true)
        try? fm.copyItem(atPath: executable, toPath: path + "/Contents/MacOS/k3sm-app")
        let info: [String: Any] = [
            "CFBundleExecutable": "k3sm-app", "CFBundleIdentifier": "io.k3sm.app", "CFBundlePackageType": "APPL",
            "K3smPayloadTag": tag, "CFBundleShortVersionString": String(tag.dropFirst().prefix { $0 != "-" }),
        ]
        let data = try! PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try! data.write(to: URL(fileURLWithPath: path + "/Contents/Info.plist"), options: [])
        precondition(run("/usr/bin/codesign", ["--force", "--sign", "-", "--timestamp=none", "--identifier", "io.k3sm.test.fixture", path]) == 0,
                     "codesign could not sign the fixture bundle")
    }

    func install(tag: String) { makeBundle(at: target, tag: tag) }

    func stage(tag: String) { makeBundle(at: staged, tag: tag) }

    func tag(at path: String) -> String? { InstalledRelease.read(bundleAt: path)?.tag }

    /// Root's work directory holds nothing after a run, and the target
    /// directory holds only the target.
    func expectNothingLeft(sourceLocation: SourceLocation = #_sourceLocation) {
        let work = (try? FileManager.default.contentsOfDirectory(atPath: workRoot)) ?? []
        #expect(work.isEmpty, "work directory: \(work)", sourceLocation: sourceLocation)
        let apps = (try? FileManager.default.contentsOfDirectory(atPath: applications)) ?? []
        #expect(apps == ["k3sm.app"], "Applications: \(apps)", sourceLocation: sourceLocation)
    }
}
