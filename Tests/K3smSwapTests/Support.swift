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
import Synchronization
import Testing

/// The requirement every fixture satisfies: an ad-hoc signature carries the
/// identifier, so no certificate is needed.
let fixtureRequirement = "identifier \"io.k3sm.test.fixture\""
/// The team the fixtures' stamps name, and the one the test verifier runs
/// as.
let fixtureTeam = TeamID("ABCDE12345")!

/// Runs an executable by absolute path and returns its exit status.
@discardableResult
func run(_ path: String, _ arguments: [String]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return -1 }
    process.waitUntilExit()
    return process.terminationStatus
}

/// FixtureBinaries compiles fixture-app.c once per test run, for the
/// fixtures' team and for another team.
enum FixtureBinaries {
    static let directory: String = {
        // One directory per test process; those of test processes that are
        // gone are swept first, so runs leave nothing behind for long.
        let tmp = realPath(NSTemporaryDirectory())
        let prefix = "k3sm-swap-fixtures-"
        for name in (try? FileManager.default.contentsOfDirectory(atPath: tmp)) ?? [] where name.hasPrefix(prefix) {
            if let pid = Int32(name.dropFirst(prefix.count)), kill(pid, 0) != 0 {
                try? FileManager.default.removeItem(atPath: tmp + "/" + name)
            }
        }
        let dir = tmp + "/" + prefix + String(getpid())
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/fixture-app.c").path
        for (name, team) in [("fixture-app", "ABCDE12345"), ("fixture-app-other-team", "ZZZZZ99999")] {
            let status = run("/usr/bin/cc", ["-O0", "-DFIXTURE_TEAM=\"\(team)\"", "-o", dir + "/" + name, source])
            precondition(status == 0, "cc could not compile the fixture app")
        }
        return dir
    }()

    static var app: String { directory + "/fixture-app" }
    static var otherTeam: String { directory + "/fixture-app-other-team" }
}

func realPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}

/// Scratch is one test's private world: a home, an Applications root and
/// the `SwapPaths` over them. It removes itself and stops every process it
/// started.
final class Scratch: @unchecked Sendable {
    let root: String
    let paths: SwapPaths
    let launcher: FixtureLauncher
    var target: String { paths.allowedTargets[0] }
    var applications: String { paths.applicationsRoots[0] }
    private var helpers: [ProcessIdentity] = []

    /// A scratch world; `home` puts the home folder elsewhere (another
    /// volume, in a test).
    init(home: String? = nil) {
        root = realPath(NSTemporaryDirectory()) + "/k3sm-swap-" + UUID().uuidString.prefix(8)
        let fm = FileManager.default
        let homePath = home ?? root + "/home"
        try? fm.createDirectory(atPath: homePath + "/Library/Application Support", withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: root + "/Applications", withIntermediateDirectories: true)
        paths = SwapPaths(home: homePath, applicationsRoots: [root + "/Applications"])
        launcher = FixtureLauncher(privateDirectory: paths.privateDirectory)
        try? JournalStore(paths: paths).prepare()
    }

    deinit {
        launcher.stopAll()
        for process in helpers where process.isRunning { kill(process.pid, SIGKILL) }
        run("/bin/chmod", ["-R", "u+rwx", root])
        try? FileManager.default.removeItem(atPath: root)
    }

    /// Builds a signed fixture bundle at `path`.
    func makeBundle(at path: String, tag: String?, behaviour: String, executable: String = FixtureBinaries.app,
                    shortVersion: String? = nil) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: path + "/Contents/MacOS", withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: path + "/Contents/Resources", withIntermediateDirectories: true)
        try? fm.copyItem(atPath: executable, toPath: path + "/Contents/MacOS/k3sm-app")
        var info: [String: Any] = [
            "CFBundleExecutable": "k3sm-app",
            "CFBundleIdentifier": "io.k3sm.app",
            "CFBundlePackageType": "APPL",
        ]
        if let tag {
            info["K3smPayloadTag"] = tag
            info["CFBundleShortVersionString"] = shortVersion ?? String(tag.dropFirst().prefix { $0 != "-" })
        } else {
            info["CFBundleShortVersionString"] = shortVersion ?? "1.0.0"
        }
        let data = try! PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        // Written in place, never atomically: under a sandbox an atomic write
        // on another volume leaves an unreadable `.TemporaryItems` directory
        // at that volume's root, which is a staging directory in the EXDEV case.
        try! data.write(to: URL(fileURLWithPath: path + "/Contents/Info.plist"), options: [])
        try! Data((behaviour + "\n").utf8).write(to: URL(fileURLWithPath: path + "/Contents/Resources/behaviour"),
                                                  options: [])
        let status = run("/usr/bin/codesign", ["--force", "--sign", "-", "--timestamp=none", "--identifier", "io.k3sm.test.fixture", path])
        precondition(status == 0, "codesign could not sign the fixture bundle")
    }

    /// Installs a fixture bundle at the target.
    func install(tag: String?, behaviour: String = "handshake", shortVersion: String? = nil) {
        makeBundle(at: target, tag: tag, behaviour: behaviour, shortVersion: shortVersion)
    }

    /// Stages a fixture bundle and returns the staging directory's name.
    @discardableResult
    func stage(tag: String?, behaviour: String = "handshake", name: String = SwapPaths.newStagingName(),
               executable: String = FixtureBinaries.app) -> String {
        let dir = SwapPaths.stagingDirectory(target: target, name: name)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        makeBundle(at: dir + "/" + SwapPaths.bundleName, tag: tag, behaviour: behaviour, executable: executable)
        return name
    }

    /// A process standing in for the app that asked for the swap: it exits
    /// after `seconds`. Its identity is read while it is held suspended, so
    /// a short (or zero) sleep cannot exit, and be reaped, before the read.
    func appProcess(exitingAfter seconds: Double) -> ProcessIdentity {
        let (pid, identity) = spawnIdentified("/bin/sleep", [String(seconds)])
        guard let identity else {
            Issue.record("the /bin/sleep stand-in (pid \(pid)) had no readable identity")
            return ProcessIdentity(pid: pid, start: ProcessStart(seconds: 0, microseconds: 0))
        }
        helpers.append(identity)
        return identity
    }

    /// Writes an update request in state `staged`.
    @discardableResult
    func request(stagedName: String, expectedTag: String, app: ProcessIdentity, target: String? = nil,
                 edit: (inout SwapJournal) -> Void = { _ in }) -> SwapJournal {
        var journal = SwapJournal(request: SwapRequest(mode: .update, target: target ?? self.target, stagedName: stagedName,
                                                       expectedTag: expectedTag, token: SwapRequest.newToken(), app: app))
        edit(&journal)
        try! JournalStore(paths: paths).write(journal)
        return journal
    }

    var journal: SwapJournal? { try? JournalStore(paths: paths).read() }

    /// Writes a go-back request for `tag`.
    func requestGoBack(tag: String, app: ProcessIdentity) {
        let journal = SwapJournal(request: SwapRequest(mode: .goBack, target: target, stagedName: "", expectedTag: tag,
                                                       token: SwapRequest.newToken(), app: app))
        try! JournalStore(paths: paths).write(journal)
    }

    /// Installs v1.0.0, swaps to v1.1.0 and checks the commit.
    func updateOnce() {
        install(tag: "v1.0.0")
        let name = stage(tag: "v1.1.0")
        request(stagedName: name, expectedTag: "v1.1.0", app: appProcess(exitingAfter: 0.2))
        precondition(engine().swap() == .committed, "the setup update did not commit")
    }

    var verifier: StaticCodeVerifier { StaticCodeVerifier(requirement: fixtureRequirement, runningTeam: fixtureTeam) }

    func engine(renamer: any Renamer = SystemRenamer(), launcher: (any AppLauncher)? = nil, timeouts: SwapTimeouts = .test,
                faults: SwapFaults = .none) -> SwapEngine {
        SwapEngine(requirement: fixtureRequirement, clock: SystemSwapClock(), watcher: KqueueProcessWatcher(), renamer: renamer,
                   launcher: launcher ?? self.launcher, verifier: verifier, paths: paths, timeouts: timeouts, faults: faults)
    }

    /// The names in a directory ending in `.app`.
    func appBundles(in dir: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".app") }
    }

    func previousEntries() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: paths.previousDirectory)) ?? []).sorted()
    }

    func stagingEntries() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: applications)) ?? []).filter { $0.hasPrefix(SwapPaths.stagingPrefix) }
    }

    func tag(at path: String) -> String? {
        InstalledRelease.read(bundleAt: path)?.tag
    }
}

extension SwapTimeouts {
    /// Short bounds for the tests: the fixtures answer at once.
    static let test = SwapTimeouts(appExit: .seconds(5), handshake: .seconds(10), terminate: .seconds(2), poll: .milliseconds(50))
    /// For a fixture that never answers.
    static let silent = SwapTimeouts(appExit: .seconds(5), handshake: .milliseconds(1500), terminate: .seconds(2), poll: .milliseconds(50))
}

/// Starts `path` suspended, reads its identity, then lets it run. A child
/// that exits at once (`sleep 0`) is otherwise often gone, exited and reaped
/// by `spawn`'s reaper thread, before `ProcessIdentity.of` reads it, most of
/// all on a loaded machine. The read is a short bounded poll that also
/// checks the pid runs the image asked for. On failure the child is killed
/// and the identity is nil.
func spawnIdentified(_ path: String, _ arguments: [String], environment: [String] = []) -> (pid_t, ProcessIdentity?) {
    let pid = spawn(path, arguments, environment: environment, suspended: true)
    var identity: ProcessIdentity?
    let deadline = ContinuousClock.now + .seconds(2)
    while identity == nil {
        if let read = ProcessIdentity.of(pid: pid), executablePath(of: pid) == path {
            identity = read
        } else if ContinuousClock.now >= deadline {
            break
        } else {
            usleep(10_000)
        }
    }
    if identity == nil {
        kill(pid, SIGKILL)
    }
    kill(pid, SIGCONT)
    return (pid, identity)
}

/// The executable path of a live process, from `proc_pidpath`.
func executablePath(of pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
    return String(cString: buffer)
}

/// Starts `path` with `arguments` and the given environment; a thread reaps
/// it, so an exited child never lingers as a zombie. `suspended` starts it
/// stopped (`POSIX_SPAWN_START_SUSPENDED`) until a `SIGCONT`.
func spawn(_ path: String, _ arguments: [String], environment: [String] = [], suspended: Bool = false) -> pid_t {
    let argv: [UnsafeMutablePointer<CChar>?] = ([path] + arguments).map { strdup($0) } + [nil]
    let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup($0) } + [nil]
    defer { (argv + envp).forEach { free($0) } }
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    for fd: Int32 in [0, 1, 2] {
        posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", fd == 0 ? O_RDONLY : O_WRONLY, 0)
    }
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    if suspended {
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_START_SUSPENDED))
    }
    var pid: pid_t = 0
    precondition(posix_spawn(&pid, path, &actions, &attributes, argv, envp) == 0, "posix_spawn failed")
    let child = pid
    Thread.detachNewThread {
        var status: Int32 = 0
        _ = waitpid(child, &status, 0)
    }
    return pid
}

/// FixtureLauncher launches a fixture bundle's executable directly with
/// `posix_spawn`, so pids and cdhashes are real and LaunchServices is not
/// involved. It records every launch and stops every process at the end.
final class FixtureLauncher: AppLauncher, @unchecked Sendable {
    struct Launch: Equatable {
        let path: String
        let arguments: [String]
    }

    let privateDirectory: String
    private let state = Mutex<(launches: [Launch], started: [ProcessIdentity])>(([], []))
    /// When set, launches this bundle instead of the one asked for.
    let substitute = Mutex<String?>(nil)
    /// Run after each launch (an impostor's start, in a test).
    let afterLaunch = Mutex<(@Sendable () -> Void)?>(nil)

    init(privateDirectory: String) {
        self.privateDirectory = privateDirectory
    }

    var launches: [Launch] { state.withLock { $0.launches } }

    func launch(bundleAt path: String, arguments: [String]) throws(LaunchError) -> ProcessIdentity {
        let bundle = substitute.withLock { $0 } ?? path
        let identity = start(executable: bundle + "/Contents/MacOS/k3sm-app", arguments: arguments)
        state.withLock { $0.launches.append(Launch(path: path, arguments: arguments)) }
        guard let identity else { throw .failed }
        if let hook = afterLaunch.withLock({ $0 }) { hook() }
        return identity
    }

    /// Starts a fixture executable with the private directory in its
    /// environment, and tracks it. The identity is read before the fixture
    /// runs (see `spawnIdentified`), so one that exits at once still has it.
    @discardableResult
    func start(executable: String, arguments: [String]) -> ProcessIdentity? {
        let (_, identity) = spawnIdentified(executable, arguments, environment: ["FIXTURE_PRIVATE_DIR=" + privateDirectory])
        if let identity { state.withLock { $0.started.append(identity) } }
        return identity
    }

    /// Kills every started process still running under its own identity, so
    /// a reused pid is never hit.
    func stopAll() {
        for process in state.withLock({ $0.started }) where process.isRunning {
            kill(process.pid, SIGKILL)
        }
    }
}

/// SpyRenamer counts the engine's renames and can fail the swap with an
/// injected errno; every other call goes to the real renamer.
final class SpyRenamer: Renamer, @unchecked Sendable {
    private let calls = Mutex<Int>(0)
    let swapErrno: Int32?

    init(swapErrno: Int32? = nil) {
        self.swapErrno = swapErrno
    }

    var count: Int { calls.withLock { $0 } }

    func swap(fromDir: Int32, from: String, toDir: Int32, to: String) -> Int32 {
        calls.withLock { $0 += 1 }
        if let swapErrno { return swapErrno }
        return SystemRenamer().swap(fromDir: fromDir, from: from, toDir: toDir, to: to)
    }

    func move(fromDir: Int32, from: String, toDir: Int32, to: String) -> Int32 {
        calls.withLock { $0 += 1 }
        return SystemRenamer().move(fromDir: fromDir, from: from, toDir: toDir, to: to)
    }
}

/// The identity of the file at `path`, for the inode assertions.
func identity(_ path: String) -> FileIdentity? {
    FileIdentity.of(path: path)
}
