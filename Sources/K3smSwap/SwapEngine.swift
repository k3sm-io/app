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
import K3smStatus
import Foundation

/// SwapTimeouts bounds each wait of a swap.
public struct SwapTimeouts: Equatable, Sendable {
    /// How long the app has to exit after it asked for the swap.
    public var appExit: Duration
    /// How long the new app has to answer the handshake.
    public var handshake: Duration
    /// How long a terminated process has before it is killed, and again
    /// after the kill.
    public var terminate: Duration
    /// How often the handshake file is read.
    public var poll: Duration

    public init(appExit: Duration = .seconds(30), handshake: Duration = .seconds(60),
                terminate: Duration = .seconds(5), poll: Duration = .milliseconds(100)) {
        self.appExit = appExit
        self.handshake = handshake
        self.terminate = terminate
        self.poll = poll
    }

    /// The shipped bounds: 30 s for the app to exit, 60 s for the handshake.
    public static let standard = SwapTimeouts()
}

/// SwapClock is the engine's time source.
public protocol SwapClock: Sendable {
    func now() -> ContinuousClock.Instant
}

/// SystemSwapClock is the real `SwapClock`.
public struct SystemSwapClock: SwapClock {
    public init() {}

    public func now() -> ContinuousClock.Instant { ContinuousClock.now }
}

/// SwapFaultPhase says where in a journal step a fault point sits: right
/// after the state was written, or right after the act it names.
public enum SwapFaultPhase: Sendable, CaseIterable {
    case written
    case acted
}

/// SwapFaults is the tests' kill switch: a hook asked at every fault point,
/// which stops the engine on the spot, as a killed helper would stop, when it
/// returns true. The helper never sets it.
public struct SwapFaults: Sendable {
    public let stop: (@Sendable (JournalState, SwapFaultPhase) -> Bool)?

    public init(stop: (@Sendable (JournalState, SwapFaultPhase) -> Bool)?) {
        self.stop = stop
    }

    public static let none = SwapFaults(stop: nil)
}

/// SwapEngine replaces the installed app bundle with a verified one, and
/// puts it back when the new one does not come up. The order for `--swap`:
///
/// 1. Take the lock, read the request (the journal) and check every path and
///    name in it against `SwapPaths`; check that the target's volume can
///    take the swap (`SwapPaths.volumeRefusal`); open the target's directory,
///    the staging directory and the previous root once, so every rename
///    after is relative to those descriptors.
/// 2. Check that the staging directory and every entry of the staged bundle
///    belong to this account and are writable by no group and no other user;
///    verify the staged bundle: the requirement, the bundle id, the team
///    stamp, a `K3smPayloadTag` equal to the requested one and strictly
///    above the installed bundle's, which is read from the installed bundle
///    and never from the request. Journal `verified` with both identities.
/// 3. Wait for the app to exit (`NOTE_EXIT`, with the start time). On a
///    timeout the update is abandoned: no rename, the staged copy kept, the
///    journal at `verified`.
/// 4. Check and verify the staged bundle again, journal `swapped`, write the
///    previous record (`PreviousRecord`), then `renameatx_np(RENAME_SWAP)`.
///    Every errno is mapped (`RenameOutcome`); `EXDEV` copies the staged
///    bundle onto the target's volume, verifies the copy and retries once.
/// 5. Move the old bundle at once to `previous/k3sm-<old tag>.previous`.
/// 6. Verify the target again, record its cdhash, journal `launched`, launch
///    it (LaunchServices), then wait for the handshake bound to that cdhash.
/// 7. On the handshake, journal `committed`, remove the staging directory and
///    any older previous copy. Without one, or when the new app exits early:
///    terminate it, re-verify the previous copy, journal `rolledBack`, swap
///    back, remove the new bundle, relaunch the old one with
///    `--update-failed <tag>`.
///
/// Between the check in step 4 and the rename, a process running as this
/// account could still change a file inside the staged bundle; the
/// ownership and mode checks keep every other account out, and nothing can
/// close that window for this one. The binding control is step 6: the
/// target is verified again after the swap, its cdhash recorded, and the
/// handshake accepted only from a process running exactly that code. A
/// bundle changed in the window fails there and is swapped back.
///
/// After the swap the engine reads into a bundle by path only for the
/// launch and the post-swap verification of the constant target, the
/// re-verification of the previous copy before a swap back, and the identity
/// assertions; every rename is relative to the directory descriptors.
/// Nothing writes into, truncates or re-signs a file inside either bundle:
/// every change is a rename of a whole directory.
///
/// `--go-back` is the same engine with the roles reversed: the incoming
/// bundle is the kept previous copy, and the bundle it replaces becomes the
/// previous copy. It restores only the copy the previous record names, at
/// that record's tag and cdhash, while the installed bundle is the one the
/// record names; nothing in the request or the journal can choose another.
///
/// Every stop short of a commit writes the journal's `reason`, which is how
/// the relaunched app learns the outcome.
public struct SwapEngine: Sendable {
    public let requirement: String
    public let clock: any SwapClock
    public let watcher: any ProcessWatcher
    public let renamer: any Renamer
    public let launcher: any AppLauncher
    public let verifier: any BundleVerifier
    public let paths: SwapPaths
    public let timeouts: SwapTimeouts
    let faults: SwapFaults

    /// The engine with every seam given. The helper passes the compiled
    /// requirements and the real adapters; tests pass fixtures and doubles.
    public init(requirement: String, clock: any SwapClock, watcher: any ProcessWatcher, renamer: any Renamer,
                launcher: any AppLauncher, verifier: any BundleVerifier, paths: SwapPaths, timeouts: SwapTimeouts,
                faults: SwapFaults = .none) {
        self.requirement = requirement
        self.clock = clock
        self.watcher = watcher
        self.renamer = renamer
        self.launcher = launcher
        self.verifier = verifier
        self.paths = paths
        self.timeouts = timeouts
        self.faults = faults
    }

    /// Runs a `--swap` request.
    public func swap() -> SwapExit {
        finish(mode: .update)
    }

    /// Runs a `--go-back` request.
    public func goBack() -> SwapExit {
        finish(mode: .goBack)
    }

    /// Launches the target and waits for its handshake, with no rename and
    /// no swap back: the user-side half of the administrator path, which
    /// swapped as root. The journal is read for the token and the tags and
    /// is not written.
    public func relaunch() -> SwapExit {
        let store = JournalStore(paths: paths)
        guard let lock = store.lock() else { return store.privateDirectoryIsSafe() ? .busy : .refusedRequest }
        defer { lock.release() }
        guard let journal = try? store.read(), !journal.state.isTerminal, journal.namesAreValid, validate(journal.request) else {
            return .refusedRequest
        }
        let target = journal.request.target
        guard let post = try? verifier.verify(bundleAt: target, requireTag: true), post.tag == journal.request.expectedTag
        else { return .verificationFailed }
        let check = HandshakeCheck(paths: paths, requirement: requirement)
        check.clear()
        var arguments = [SwapLaunchArguments.handshake]
        if let old = journal.outgoingTag { arguments = [SwapLaunchArguments.updatedFrom, old] + arguments }
        guard let launched = try? launcher.launch(bundleAt: target, arguments: arguments) else { return .abandoned }
        let accepted = awaitHandshake(check: check, token: journal.request.token, launched: launched, cdhash: post.cdhash)
        SwapLog.handshake(accepted: accepted)
        return accepted ? .committed : .abandoned
    }

    private func finish(mode: SwapMode) -> SwapExit {
        let exit: SwapExit
        do {
            exit = try run(mode: mode)
        } catch {
            // A fault point stopped the engine where a kill would.
            return .abandoned
        }
        SwapLog.swap(exit)
        return exit
    }

    /// Killed is thrown at a fault point the tests stop at.
    struct Killed: Error {}

    private func fault(_ state: JournalState, _ phase: SwapFaultPhase) throws(Killed) {
        if faults.stop?(state, phase) == true { throw Killed() }
    }

    /// Slot is one bundle location: a directory descriptor, its path and an
    /// entry name in it.
    struct Slot {
        let dirFD: Int32
        let dirPath: String
        let name: String

        var path: String { dirPath + "/" + name }
        var identity: FileIdentity? { FileIdentity.of(dirFD: dirFD, name: name) }
    }

    /// Run is one request's context: the journal and where it is kept, the
    /// directory descriptors, and the previous record the run replaced.
    struct Run {
        var journal: SwapJournal
        let store: JournalStore
        let target: Slot
        let previousFD: Int32
        var incoming: Slot
        /// Every staging directory this run used, removed at the end.
        var stagingNames: [String]
        /// The previous record before this run wrote its own, put back when
        /// the swap is undone.
        let priorRecord: PreviousRecord?
        var request: SwapRequest { journal.request }
    }

    /// Whether a request names only what `SwapPaths` allows.
    func validate(_ request: SwapRequest) -> Bool {
        guard paths.allowedTargets.contains(request.target), paths.refusal(target: request.target) == nil,
              SwapTag.isReleaseTag(request.expectedTag),
              request.token.utf8.count == 64, request.token.utf8.allSatisfy({ isHexDigit($0) }),
              request.failedTag.map(SwapTag.isReleaseTag) ?? true
        else { return false }
        switch request.mode {
        case .update: return SwapPaths.isStagingName(request.stagedName)
        case .goBack: return request.stagedName.isEmpty
        }
    }

    private func isHexDigit(_ b: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(b) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(b)
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    private func run(mode: SwapMode) throws(Killed) -> SwapExit {
        let store = JournalStore(paths: paths)
        guard store.privateDirectoryIsSafe() else { return .refusedRequest }
        guard let lock = store.lock() else { return .busy }
        defer { lock.release() }
        guard let journal = try? store.read(), journal.state == .staged, journal.request.mode == mode,
              journal.namesAreValid, validate(journal.request)
        else { return .refusedRequest }
        let request = journal.request
        guard (try? store.prepare()) != nil else { return .refusedRequest }

        let target = request.target
        let parentPath = (target as NSString).deletingLastPathComponent
        guard let parentFD = FileOps.openDirectory(parentPath) else { return .refusedRequest }
        defer { close(parentFD) }
        guard let previousFD = FileOps.openDirectory(paths.previousDirectory) else { return .refusedRequest }
        defer { close(previousFD) }
        guard FileOps.isDirectory(at: parentFD, SwapPaths.bundleName), let original = FileIdentity.of(dirFD: parentFD, name: SwapPaths.bundleName)
        else { return .refusedRequest }
        let targetSlot = Slot(dirFD: parentFD, dirPath: parentPath, name: SwapPaths.bundleName)

        // The incoming bundle's location, opened once.
        var stagingFDs: [Int32] = []
        defer { stagingFDs.forEach { close($0) } }
        let incoming: Slot
        switch mode {
        case .update:
            guard let fd = FileOps.openDirectory(at: parentFD, request.stagedName) else { return .refusedRequest }
            stagingFDs.append(fd)
            incoming = Slot(dirFD: fd, dirPath: parentPath + "/" + request.stagedName, name: SwapPaths.bundleName)
        case .goBack:
            incoming = Slot(dirFD: previousFD, dirPath: paths.previousDirectory, name: SwapPaths.previousName(tag: request.expectedTag))
        }
        guard FileOps.isDirectory(at: incoming.dirFD, incoming.name) else { return .refusedRequest }
        var run = Run(journal: journal, store: store, target: targetSlot, previousFD: previousFD, incoming: incoming,
                      stagingNames: mode == .update ? [request.stagedName] : [], priorRecord: store.readRecord())

        // A volume that cannot take the swap is refused before the wait, so
        // it is never found after the app is gone.
        if paths.volumeRefusal(target: target) != nil { return stop(&run, .unsupportedVolume, relaunch: .afterExit) }

        // The floor and the outgoing tag come from the installed bundle, its
        // cdhash from its own signature.
        guard let installed = InstalledRelease.read(bundleAt: target),
              let installedCode = try? verifier.verify(bundleAt: target, requireTag: false), installedCode.identity == original
        else { return stop(&run, .verificationFailed, relaunch: .afterExit) }
        guard let first = checkIncoming(run, installed: installed, installedCode: installedCode) else {
            return stop(&run, .verificationFailed, relaunch: .afterExit)
        }
        run.journal.helper = ProcessIdentity.current()
        run.journal.original = original
        run.journal.incoming = first.identity
        run.journal.outgoingTag = installed.tag
        run.journal.previousName = SwapPaths.previousName(tag: installed.tag)
        run.journal.state = .verified
        guard save(run) else { return stop(&run, .abandoned, relaunch: .afterExit) }
        try fault(.verified, .written)

        // The app must be gone before its bundle is renamed.
        guard watcher.waitForExit(request.app, timeout: timeouts.appExit) else { return stop(&run, .abandoned, relaunch: .never) }

        // The second check, right before the swap.
        guard let second = checkIncoming(run, installed: installed, installedCode: installedCode),
              second.identity == first.identity, second.cdhash == first.cdhash, targetSlot.identity == original
        else { return stop(&run, .verificationFailed, relaunch: .now) }
        try fault(.verified, .acted)

        run.journal.state = .swapped
        run.journal.priorRecord = run.priorRecord
        guard save(run) else { return stop(&run, .abandoned, relaunch: .now) }
        let previousName = SwapPaths.previousName(tag: installed.tag)
        let record = PreviousRecord(name: previousName, tag: installed.tag, cdhash: installedCode.cdhash,
                                    installedTag: request.expectedTag, installedCDHash: first.cdhash,
                                    floorTag: Self.floor(after: run.priorRecord, keeping: installed))
        guard store.writeRecord(record) else { return stop(&run, .abandoned, relaunch: .now) }
        try fault(.swapped, .written)
        var outcome = RenameOutcome(errno: renamer.swap(fromDir: run.incoming.dirFD, from: run.incoming.name, toDir: parentFD, to: targetSlot.name))
        if outcome == .crossDevice, mode == .update {
            // Copy the staged bundle onto the target's volume, verify the
            // copy, and retry once.
            let name = SwapPaths.newStagingName()
            if mkdirat(parentFD, name, 0o700) == 0, let fd = FileOps.openDirectory(at: parentFD, name) {
                stagingFDs.append(fd)
                run.stagingNames.append(name)
                let copy = Slot(dirFD: fd, dirPath: parentPath + "/" + name, name: SwapPaths.bundleName)
                let previousIncoming = run.incoming
                run.incoming = copy
                if DittoCopier.copy(from: previousIncoming.path, to: copy.path),
                   let third = checkIncoming(run, installed: installed, installedCode: installedCode, stagingName: name),
                   third.cdhash == first.cdhash {
                    run.journal.request.stagedName = name
                    run.journal.incoming = third.identity
                    if save(run) {
                        outcome = RenameOutcome(errno: renamer.swap(fromDir: copy.dirFD, from: copy.name, toDir: parentFD, to: targetSlot.name))
                    }
                } else {
                    run.incoming = previousIncoming
                    FileOps.removeTree(at: parentFD, name)
                }
            }
        }
        switch outcome {
        case .done:
            break
        case .unsupportedVolume, .needsAdministrator, .readOnlyVolume, .failed, .crossDevice:
            store.writeRecord(run.priorRecord)
            run.journal.state = .verified
            let exit: SwapExit = switch outcome {
            case .unsupportedVolume: .unsupportedVolume
            case .needsAdministrator: .needsAdministrator
            case .readOnlyVolume: .readOnlyVolume
            default: .abandoned
            }
            return stop(&run, exit, relaunch: .now)
        }
        FileOps.fullSync(parentFD)
        try fault(.swapped, .acted)

        // The swap must have put exactly these two bundles where expected.
        guard targetSlot.identity == run.journal.incoming, run.incoming.identity == original else {
            return rollBack(&run, launched: nil)
        }
        // The old bundle leaves the Applications directory at once. The
        // previous root is on the target's volume (`volumeRefusal`), so this
        // rename cannot cross volumes.
        if run.incoming.dirFD != previousFD || run.incoming.name != previousName {
            if let existing = FileIdentity.of(dirFD: previousFD, name: previousName),
               existing != original, existing != run.journal.incoming {
                FileOps.removeTree(at: previousFD, previousName)
            }
            guard renamer.move(fromDir: run.incoming.dirFD, from: run.incoming.name, toDir: previousFD, to: previousName) == 0 else {
                return rollBack(&run, launched: nil)
            }
            FileOps.fullSync(previousFD)
        }
        let outgoing = Slot(dirFD: previousFD, dirPath: paths.previousDirectory, name: previousName)
        return try launchAndConfirm(&run, outgoing: outgoing)
    }

    /// When a stop relaunches the original app.
    enum Relaunch {
        /// The app is still running (it did not exit in time).
        case never
        /// The app has exited.
        case now
        /// The app is on its way out: wait for it, then relaunch.
        case afterExit
    }

    /// Ends a run short of a commit: the journal's reason is written (its
    /// state as it stands), and the original app comes back with
    /// `--update-failed <tag>` once it has exited.
    private func stop(_ run: inout Run, _ exit: SwapExit, relaunch: Relaunch) -> SwapExit {
        run.journal.reason = exit
        _ = save(run)
        switch relaunch {
        case .never:
            break
        case .now:
            relaunchOriginal(run.request)
        case .afterExit:
            if watcher.waitForExit(run.request.app, timeout: timeouts.appExit) { relaunchOriginal(run.request) }
        }
        return exit
    }

    private func launchAndConfirm(_ run: inout Run, outgoing: Slot) throws(Killed) -> SwapExit {
        let request = run.request
        // The post-swap verification of the constant target, whose cdhash
        // the handshake binds to: the binding control for the whole swap.
        guard let post = try? verifier.verify(bundleAt: request.target, requireTag: request.mode == .update),
              post.identity == run.journal.incoming, tagMatches(post, path: request.target, tag: request.expectedTag)
        else {
            let exit = rollBack(&run, launched: nil)
            return exit == .rolledBack ? .verificationFailed : exit
        }
        let check = HandshakeCheck(paths: paths, requirement: requirement)
        check.clear()
        run.journal.state = .launched
        guard save(run) else { return rollBack(&run, launched: nil) }
        try fault(.launched, .written)
        var arguments = [SwapLaunchArguments.updatedFrom, run.journal.outgoingTag ?? "", SwapLaunchArguments.handshake]
        if let failed = request.failedTag {
            arguments = [SwapLaunchArguments.updateFailed, failed, SwapLaunchArguments.handshake]
        }
        guard let launched = try? launcher.launch(bundleAt: request.target, arguments: arguments) else {
            return rollBack(&run, launched: nil)
        }
        run.journal.launched = launched
        _ = save(run)
        try fault(.launched, .acted)

        let accepted = awaitHandshake(check: check, token: request.token, launched: launched, cdhash: post.cdhash)
        SwapLog.handshake(accepted: accepted)
        guard accepted else { return rollBack(&run, launched: launched) }
        run.journal.state = .committed
        run.journal.reason = nil
        _ = save(run)
        try fault(.committed, .written)
        run.stagingNames.forEach { FileOps.removeTree(at: run.target.dirFD, $0) }
        Self.prunePrevious(previousFD: run.previousFD, keep: outgoing.name)
        check.clear()
        try fault(.committed, .acted)
        return .committed
    }

    /// Removes every previous copy but `keep`; only names of the previous
    /// grammar are touched.
    static func prunePrevious(previousFD: Int32, keep: String) {
        for name in FileOps.entries(previousFD) where name != keep && SwapPaths.tag(ofPreviousName: name) != nil {
            FileOps.removeTree(at: previousFD, name)
        }
    }

    /// Puts the original bundle back at the target and relaunches it. The
    /// original is found by its identity, in the previous root or where the
    /// swap left it, and verified again before the swap back. The previous
    /// record this run wrote gives way to the one it replaced.
    private func rollBack(_ run: inout Run, launched: ProcessIdentity?) -> SwapExit {
        let request = run.request
        if let launched { terminate(launched) }
        let candidates = [Slot(dirFD: run.previousFD, dirPath: paths.previousDirectory, name: run.journal.previousName ?? ""), run.incoming]
        guard let original = run.journal.original,
              let outgoing = candidates.first(where: { !$0.name.isEmpty && $0.identity == original }),
              let verified = try? verifier.verify(bundleAt: outgoing.path, requireTag: false),
              verified.identity == original
        else {
            SwapLog.rollback(succeeded: false)
            run.journal.reason = .abandoned
            _ = save(run)
            return .abandoned
        }
        run.journal.state = .rolledBack
        run.journal.reason = .rolledBack
        _ = save(run)
        if (try? fault(.rolledBack, .written)) == nil { return .abandoned }
        guard renamer.swap(fromDir: outgoing.dirFD, from: outgoing.name, toDir: run.target.dirFD, to: run.target.name) == 0 else {
            SwapLog.rollback(succeeded: false)
            run.journal.reason = .abandoned
            _ = save(run)
            return .abandoned
        }
        FileOps.fullSync(run.target.dirFD)
        run.store.writeRecord(run.priorRecord)
        if (try? fault(.rolledBack, .acted)) == nil { return .abandoned }
        // The incoming bundle now sits where the original was: an update's
        // is removed with its staging directory, a go-back's previous copy
        // goes back to its own name.
        switch request.mode {
        case .update:
            if outgoing.dirFD != run.incoming.dirFD, outgoing.identity == run.journal.incoming {
                FileOps.removeTree(at: outgoing.dirFD, outgoing.name)
            }
            run.stagingNames.forEach { FileOps.removeTree(at: run.target.dirFD, $0) }
        case .goBack:
            if outgoing.name != run.incoming.name || outgoing.dirFD != run.incoming.dirFD {
                _ = renamer.move(fromDir: outgoing.dirFD, from: outgoing.name, toDir: run.incoming.dirFD, to: run.incoming.name)
            }
        }
        SwapLog.rollback(succeeded: true)
        relaunchOriginal(request)
        return .rolledBack
    }

    /// Terminates a launched process: SIGTERM, then SIGKILL after the bound.
    private func terminate(_ process: ProcessIdentity) {
        guard process.isRunning else { return }
        kill(process.pid, SIGTERM)
        if !watcher.waitForExit(process, timeout: timeouts.terminate), process.isRunning {
            kill(process.pid, SIGKILL)
            _ = watcher.waitForExit(process, timeout: timeouts.terminate)
        }
    }

    /// Relaunches the target, which holds the original bundle, with
    /// `--update-failed <tag>`.
    private func relaunchOriginal(_ request: SwapRequest) {
        _ = try? launcher.launch(bundleAt: request.target, arguments: [SwapLaunchArguments.updateFailed, request.expectedTag])
    }

    /// Checks and verifies the incoming bundle of `run`.
    ///
    /// Both: the incoming directory (an update's staging directory, or the
    /// previous root) and every entry of the bundle belong to this account
    /// and are writable by no group and no other user, and the bundle
    /// verifies. An update's must carry a `K3smPayloadTag` equal to the
    /// requested tag and strictly above the installed release. A go-back's is
    /// the kept previous copy, and only the one the previous record names:
    /// the record's name, the requested tag equal to the record's (never
    /// lower), the copy's own tag and cdhash equal to the record's, and the
    /// installed bundle's tag and cdhash equal to the record's.
    private func checkIncoming(_ run: Run, installed: InstalledRelease, installedCode: VerifiedBundle,
                               stagingName: String? = nil) -> VerifiedBundle? {
        let slot = run.incoming
        let request = run.request
        switch request.mode {
        case .update:
            guard FileOps.isPrivateTree(at: run.target.dirFD, stagingName ?? request.stagedName) else { return nil }
        case .goBack:
            guard JournalStore.ownedPrivateDirectory(paths.previousDirectory), FileOps.isPrivateTree(at: slot.dirFD, slot.name)
            else { return nil }
        }
        guard let verified = try? verifier.verify(bundleAt: slot.path, requireTag: request.mode == .update),
              verified.identity == slot.identity
        else { return nil }
        switch request.mode {
        case .update:
            guard verified.tag == request.expectedTag, let version = verified.version, version > installed.version else { return nil }
        case .goBack:
            guard let record = run.store.readRecord(), record.name == slot.name,
                  let recorded = SemanticVersion(record.tag), let requested = SemanticVersion(request.expectedTag),
                  record.tag == request.expectedTag,
                  let floor = SemanticVersion(record.floorTag), !(requested < floor), !(floor < recorded),
                  tagMatches(verified, path: slot.path, tag: record.tag), record.cdhash == FileOps.hex(verified.cdhash),
                  record.installedTag == installed.tag, record.installedCDHash == FileOps.hex(installedCode.cdhash),
                  request.expectedTag != installed.tag
            else { return nil }
        }
        return verified
    }

    /// The floor a new record carries: the old floor or the outgoing tag,
    /// whichever is higher, so it only rises.
    static func floor(after prior: PreviousRecord?, keeping installed: InstalledRelease) -> String {
        if let prior, let old = SemanticVersion(prior.floorTag), !(old < installed.version) { return prior.floorTag }
        return installed.tag
    }

    /// Whether a verified bundle carries `tag`: its `K3smPayloadTag`, or, for
    /// a bundle without one, its short version.
    private func tagMatches(_ verified: VerifiedBundle, path: String, tag: String) -> Bool {
        if let own = verified.tag { return own == tag }
        return InstalledRelease.read(bundleAt: path)?.tag == tag
    }

    private func save(_ run: Run) -> Bool {
        (try? run.store.write(run.journal)) != nil
    }

    /// Reads the handshake file until it holds an acceptable answer, the
    /// launched process exits, or the bound passes.
    private func awaitHandshake(check: HandshakeCheck, token: String, launched: ProcessIdentity, cdhash: Data) -> Bool {
        let deadline = clock.now().advanced(by: timeouts.handshake)
        while true {
            if check.accepts(token: token, launched: launched, cdhash: cdhash) { return true }
            if watcher.waitForExit(launched, timeout: timeouts.poll) { return false }
            if clock.now() >= deadline { return false }
        }
    }
}
